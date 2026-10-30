//! The stock page's shared rules (specs/core row 8; specs/stock-page SP-R1..SP-R3, specs/edibles ED-D1..D3,
//! specs/mazama-inventory MI-R1, specs/web-charts WC-D1): which rows are counted, the summary by strain and size, its
//! pies, the par table, the stock mix by strain and type, and a center's By type pie. Held to
//! mazama_modules/stock/vectors/ (frozen from the server's Python, which was the reference): the numbers keep
//! Python's own arithmetic (an int stays an int through sums, `round(x, 2)` and percents half to even on the exact
//! binary value, `f"{x:g}"`), so both apps show the same figures. The constants are mazama_modules/stock/rules.yaml's
//! (tests/stock_cases.rs holds them equal).
//!
//! Known limits (specs/core Task 14 review): an object's key order isn't kept (`sizes` / `mg_sizes` come back sorted
//! by key, not in SIZE_ORDER; nothing reads them in order, every reader goes by SIZE_ORDER / PAR_COLUMNS itself);
//! `\b` in the name patterns is Rust's Unicode word boundary, which unlike Python's doesn't count numeric symbols such as
//! `²` or `½` as word characters (no real description has them); a mg figure (`unitMgTpe`, `weightPerUnit`,
//! `analyteWeight`) given as text counts as 0 where Python raised TypeError; a quantity that isn't a number is an input
//! error (ValueError) where Python raised TypeError.
use std::cmp::Ordering;
use std::collections::HashMap;
use std::hash::Hash;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Map, Value, json};

use crate::api::Error;

pub const SIZES: [i64; 5] = [25, 20, 15, 10, 5];
pub const OTHER_SIZE: &str = "other";
pub const BOOSTER: &str = "booster";
pub const MICRO: &str = "micro";
pub const EDIBLES: [(&str, &str); 3] = [("CH", "Chocolate"), ("GM", "Gummy"), ("HN", "Honey")];
pub const BOOSTER_FROM_MG: f64 = 3.0;
/// size key -> (par/order size code, word, pie slot)
pub const EDIBLE_SIZES: [(&str, i64, &str, &str); 2] = [(BOOSTER, -1, "Booster", "db"), (MICRO, -2, "Microdose", "dm")];
pub const SIZE_ORDER: [&str; 8] = ["25", "20", "15", "10", "5", BOOSTER, MICRO, OTHER_SIZE];
pub const PAR_COLUMNS: [i64; 8] = [25, 20, 15, 10, 5, -1, -2, 0];
pub const NAME_KEYWORDS: [(&str, &str); 5] = [("gumm", "GM"), ("chocolate", "CH"), ("choc", "CH"), ("honey", "HN"), ("extract", "EX")];
pub const STRAIN_SLOTS: usize = 7;
pub const MAX_STRAIN_ROWS: usize = 12;
pub const FILTERS: [&str; 2] = ["all", "mazama"];
pub const MG_MODES: [&str; 2] = ["tpe", "psilocybin"];
pub const UNKNOWN: &str = "Unknown";
pub const ALL_STRAINS: &str = "All strains";
pub const MIX_TYPE_WORDS: [(&str, &str); 10] = [("FD", "Freeze dried"), ("DH", "Dehydrated"), ("HG", "Homogenized"),
    ("CH", "Chocolate"), ("EX", "Extract"), ("HN", "Honey"), ("GM", "Gummy"), ("LOT", "Process lot"), ("WF", "Whole fungi"),
    ("", "Other type")];

fn mg_title(mode: &str) -> &'static str {
    if mode == "tpe" { "Total mg TPE" } else { "Total mg psilocybin" }
}

// --- Python numbers -------------------------------------------------------------------------------------------

/// A JSON number as Python holds it: an int stays an int (true and false are 1 and 0), anything else is a float.
#[derive(Debug, Clone, Copy)]
pub enum Num {
    I(i64),
    F(f64),
}

impl Num {
    pub const ZERO: Num = Num::I(0);

    pub fn of(v: &Value) -> Option<Num> {
        match v {
            Value::Bool(b) => Some(Num::I(i64::from(*b))),
            Value::Number(n) => Some(n.as_i64().map_or_else(|| Num::F(n.as_f64().unwrap_or(0.0)), Num::I)),
            _ => None,
        }
    }

    pub fn f(self) -> f64 {
        match self {
            Num::I(i) => i as f64,
            Num::F(f) => f,
        }
    }

    pub fn json(self) -> Value {
        match self {
            Num::I(i) => json!(i),
            Num::F(f) => serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number),
        }
    }

    fn op(self, o: Num, int: fn(i64, i64) -> Option<i64>, float: fn(f64, f64) -> f64) -> Num {
        match (self, o) {
            (Num::I(a), Num::I(b)) => int(a, b).map_or_else(|| Num::F(float(a as f64, b as f64)), Num::I),
            _ => Num::F(float(self.f(), o.f())),
        }
    }

    pub fn add(self, o: Num) -> Num {
        self.op(o, i64::checked_add, |a, b| a + b)
    }

    pub fn sub(self, o: Num) -> Num {
        self.op(o, i64::checked_sub, |a, b| a - b)
    }

    pub fn mul(self, o: Num) -> Num {
        self.op(o, i64::checked_mul, |a, b| a * b)
    }

    pub fn cmp(self, o: Num) -> Ordering {
        match (self, o) {
            (Num::I(a), Num::I(b)) => a.cmp(&b),
            _ => self.f().partial_cmp(&o.f()).unwrap_or(Ordering::Equal),
        }
    }

    pub fn gt0(self) -> bool {
        self.cmp(Num::ZERO) == Ordering::Greater
    }

    pub fn truthy(self) -> bool {
        self.f() != 0.0
    }

    /// `-x`.
    pub fn neg(self) -> Num {
        Num::ZERO.sub(self)
    }
}

/// CPython 3.14's `sum()` (`builtin_sum_impl`, the server's Python): ints add exactly while every item is an int; the
/// first float is added plainly to that int sum, and from there every item, float or int (as the nearest double), goes
/// through the compensated sum (Neumaier, `cs_add`), the compensation added at the end when it is finite and not 0.
/// So `sum([1e100, 1, -1e100])` is 1.0 (3.12 and 3.13 added an int in float mode plainly and gave 0.0).
pub fn py_sum(values: impl IntoIterator<Item = Num>) -> Num {
    let mut it = values.into_iter();
    let mut acc = Num::ZERO;
    let (mut hi, mut lo);
    loop {
        match it.next() {
            None => return acc,
            Some(Num::F(x)) => {
                hi = acc.f() + x;
                lo = 0.0;
                break;
            }
            Some(n) => acc = acc.add(n),
        }
    }
    for n in it {
        let x = n.f();
        let t = hi + x;
        if hi.abs() >= x.abs() { lo += (hi - t) + x } else { lo += (x - t) + hi }
        hi = t;
    }
    Num::F(if lo != 0.0 && lo.is_finite() { hi + lo } else { hi })
}

/// Python's `round(x, 2)`: a float rounded half to even on its exact value; an int unchanged.
pub fn round2(n: Num) -> Num {
    match n {
        Num::I(_) => n,
        Num::F(f) if f.is_finite() => Num::F(format!("{f:.2}").parse().unwrap_or(f)),
        Num::F(_) => n,
    }
}

/// The key's whole-number percent: Python's `int(f"{100 * value / total:.0f}")`.
pub fn pct(value: Num, total: Num) -> i64 {
    let x = Num::I(100).mul(value).f() / total.f();
    let s = format!("{x:.0}");
    s.parse::<i64>().unwrap_or(0)
}

/// Python's `f"{x:g}"`: six significant digits, trailing zeros dropped, an exponent below 1e-4 or from 1e6.
pub fn fmt_g(n: Num) -> String {
    let x = n.f();
    if x == 0.0 {
        return if x.is_sign_negative() { "-0".into() } else { "0".into() };
    }
    let e_form = format!("{x:.5e}");
    let (mant, exp) = e_form.split_once('e').unwrap_or((&e_form, "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    let strip = |s: &str| -> String {
        if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s.to_string() }
    };
    if (-4..6).contains(&exp) {
        let decimals = (5 - exp).max(0) as usize;
        strip(&format!("{x:.decimals$}"))
    } else {
        format!("{}e{}{:02}", strip(mant), if exp < 0 { '-' } else { '+' }, exp.abs())
    }
}

// --- reading rows ---------------------------------------------------------------------------------------------

static NULL: Value = Value::Null;

fn get<'a>(r: &'a Value, k: &str) -> &'a Value {
    r.get(k).unwrap_or(&NULL)
}

fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

fn text<'a>(v: &'a Value) -> Result<&'a str, Error> {
    match v {
        Value::Null => Ok(""),
        Value::String(s) => Ok(s),
        Value::Bool(false) => Ok(""),
        other => Err(format!("stock: expected text, got {other}").into()),
    }
}

/// `x or default` for a text field.
fn text_or<'a>(v: &'a Value, default: &'a str) -> Result<&'a str, Error> {
    let t = text(v)?;
    Ok(if t.is_empty() { default } else { t })
}

static NAME_CODE_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\bTPE\s+([A-Z]{2})\b").unwrap());
static PACKAGE_MG_AT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*mg\b").unwrap());
static DOSE_AT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^([0-9]{1,3})\s*mg\b").unwrap());

/// Python's `re.search` of `(?<![0-9.])` + `at`: the first match whose start isn't right after a digit or a dot.
fn search_after_no_digit<'a>(at: &Regex, s: &'a str) -> Option<&'a str> {
    let mut prev: Option<char> = None;
    for (i, c) in s.char_indices() {
        if !matches!(prev, Some(p) if p.is_ascii_digit() || p == '.') {
            if let Some(m) = at.captures(&s[i..]) {
                return m.get(1).map(|g| g.as_str());
            }
        }
        prev = Some(c);
    }
    None
}

/// 25 for "Bluey 25 mg TPE"; None when the description names no standard serving size (stockmath.serving_size).
pub fn serving_size(desc: &str) -> Option<i64> {
    let d: i64 = search_after_no_digit(&DOSE_AT, desc)?.parse().ok()?;
    SIZES.contains(&d).then_some(d)
}

/// The row's kind code: its `type`, else the code after "TPE" in its name, else the first name keyword it contains.
pub fn type_of(r: &Value) -> Result<String, Error> {
    let t = text(get(r, "type"))?;
    if !t.is_empty() {
        return Ok(t.to_string());
    }
    let desc = text(get(r, "description"))?;
    if let Some(m) = NAME_CODE_RE.captures(desc) {
        return Ok(m[1].to_string());
    }
    let low = desc.to_lowercase();
    Ok(NAME_KEYWORDS.iter().find(|(w, _)| low.contains(w)).map_or("", |(_, c)| c).to_string())
}

fn edible_of(r: &Value) -> Result<Option<&'static str>, Error> {
    let t = type_of(r)?;
    Ok(EDIBLES.iter().find(|(c, _)| *c == t).map(|(_, w)| *w))
}

fn mg_per_unit(r: &Value, mode: &str) -> Num {
    if mode == "tpe" {
        let v = get(r, "unitMgTpe");
        return if truthy(v) { Num::of(v).unwrap_or(Num::F(0.0)) } else { Num::F(0.0) };
    }
    match (Num::of(get(r, "weightPerUnit")), Num::of(get(r, "analyteWeight"))) {
        (Some(w), Some(a)) if !get(r, "weightPerUnit").is_null() && !get(r, "analyteWeight").is_null() => w.mul(a),
        _ => Num::F(0.0),
    }
}

fn size_key(r: &Value, mode: &str) -> Result<&'static str, Error> {
    if edible_of(r)?.is_none() {
        return Ok(match serving_size(text(get(r, "description"))?) {
            Some(d) => SIZE_ORDER[SIZES.iter().position(|x| *x == d).unwrap_or(0)],
            None => OTHER_SIZE,
        });
    }
    let mg = match search_after_no_digit(&PACKAGE_MG_AT, text(get(r, "description"))?) {
        Some(m) => Num::F(m.parse().unwrap_or(0.0)),
        None => mg_per_unit(r, mode),
    };
    if !mg.truthy() || !mg.gt0() {
        return Ok(OTHER_SIZE);
    }
    Ok(if mg.f() < BOOSTER_FROM_MG { MICRO } else { BOOSTER })
}

fn has_units(r: &Value) -> Result<bool, Error> {
    crate::records::judge_one(r).has_units.map_err(|_| "stock: a row's quantity isn't a number".into())
}

fn check_mode(mode: &str) -> Result<(), Error> {
    if MG_MODES.contains(&mode) { Ok(()) } else { Err(format!("mg_mode must be one of tpe, psilocybin, not {mode:?}").into()) }
}

/// An insertion-ordered map (Python's dict), with an index so lookups don't scan.
#[derive(Debug, Clone)]
struct Ordered<K, V> {
    items: Vec<(K, V)>,
    index: HashMap<K, usize>,
}

impl<K, V> Default for Ordered<K, V> {
    fn default() -> Self {
        Ordered { items: Vec::new(), index: HashMap::new() }
    }
}

impl<K: Eq + Hash + Clone, V> Ordered<K, V> {
    fn entry(&mut self, k: &K, init: impl FnOnce() -> V) -> &mut V {
        let i = match self.index.get(k) {
            Some(i) => *i,
            None => {
                self.items.push((k.clone(), init()));
                self.index.insert(k.clone(), self.items.len() - 1);
                self.items.len() - 1
            }
        };
        &mut self.items[i].1
    }

    fn get(&self, k: &K) -> Option<&V> {
        self.index.get(k).map(|i| &self.items[*i].1)
    }
}

// --- filter ---------------------------------------------------------------------------------------------------

/// `{"counted": [row], "other": [{"row", "reason": "expired" | "other_maker"}]}` (SP-D2, SP-D3).
pub fn filter(rows: &[Value], makers: &str) -> Result<Value, Error> {
    if !FILTERS.contains(&makers) {
        return Err(format!("makers must be one of all, mazama, not {makers:?}").into());
    }
    let (mut counted, mut other) = (Vec::new(), Vec::new());
    for r in rows {
        if !has_units(r)? {
            continue;
        }
        if truthy(get(r, "expired")) {
            other.push(json!({"row": r, "reason": "expired"}));
        } else if makers == "mazama" && !truthy(get(r, "mazama")) {
            other.push(json!({"row": r, "reason": "other_maker"}));
        } else {
            counted.push(r.clone());
        }
    }
    Ok(json!({"counted": counted, "other": other}))
}

// --- summary --------------------------------------------------------------------------------------------------

struct Slot {
    spell: Ordered<String, Num>,
    units: Num,
    sizes: Ordered<&'static str, Num>,
    mg: Num,
    mg_sizes: Ordered<&'static str, Num>,
}

fn ordered_sizes(sizes: &Ordered<&'static str, Num>, round: bool) -> Value {
    let mut m = Map::new();
    for k in SIZE_ORDER {
        if let Some(v) = sizes.get(&k) {
            m.insert(k.to_string(), if round { round2(*v) } else { *v }.json());
        }
    }
    Value::Object(m)
}

/// Counted rows -> `{"total", "mg_total", "mg_mode", "strains": [{"name", "units", "mg", "sizes", "mg_sizes"}]}`.
pub fn summarize(rows: &[Value], mode: &str) -> Result<Value, Error> {
    check_mode(mode)?;
    let mut by: Ordered<String, Slot> = Ordered::default();
    for r in rows {
        if !has_units(r)? {
            continue;
        }
        let q = Num::of(get(r, "quantity")).ok_or("stock: a row's quantity isn't a number")?;
        let name = match edible_of(r)? {
            Some(w) => w.to_string(),
            None => text_or(get(r, "strain"), UNKNOWN)?.to_string(),
        };
        let k = size_key(r, mode)?;
        let mg = q.mul(mg_per_unit(r, mode));
        let slot = by.entry(&name.to_lowercase(), || Slot {
            spell: Ordered::default(), units: Num::ZERO, sizes: Ordered::default(), mg: Num::F(0.0), mg_sizes: Ordered::default(),
        });
        let s = slot.spell.entry(&name, || Num::ZERO);
        *s = s.add(q);
        slot.units = slot.units.add(q);
        let s = slot.sizes.entry(&k, || Num::ZERO);
        *s = s.add(q);
        slot.mg = slot.mg.add(mg);
        let s = slot.mg_sizes.entry(&k, || Num::F(0.0));
        *s = s.add(mg);
    }
    let mut named: Vec<(String, &Slot)> = by
        .items
        .iter()
        .map(|(_, v)| {
            // max by (count, name): the spelling with most units, a tie the one that sorts last
            let best = v.spell.items.iter().max_by(|a, b| a.1.cmp(b.1).then_with(|| a.0.cmp(&b.0))).map(|(n, _)| n.clone());
            (best.unwrap_or_default(), v)
        })
        .collect();
    named.sort_by(|a, b| b.1.units.cmp(a.1.units).then_with(|| a.0.to_lowercase().cmp(&b.0.to_lowercase())));
    let mut strains = Vec::new();
    let (mut units, mut mgs) = (Vec::new(), Vec::new());
    for (n, v) in &named {
        let mg = round2(v.mg);
        units.push(v.units);
        mgs.push(mg);
        strains.push(json!({"name": n, "units": v.units.json(), "mg": mg.json(), "sizes": ordered_sizes(&v.sizes, false),
                            "mg_sizes": ordered_sizes(&v.mg_sizes, true)}));
    }
    // Python's sum(s["units"] ...) and round(sum(s["mg"] ...), 2)
    Ok(json!({"total": py_sum(units).json(), "mg_total": round2(py_sum(mgs)).json(), "mg_mode": mode, "strains": strains}))
}

// --- pies -----------------------------------------------------------------------------------------------------

fn num_at(v: &Value, k: &str) -> Result<Num, Error> {
    Num::of(get(v, k)).ok_or_else(|| format!("stock: {k} isn't a number").into())
}

fn slice(name: &str, value: Num, slot: &str, total: Num) -> Value {
    json!({"name": name, "value": value.json(), "slot": slot, "pct": pct(value, total)})
}

fn strain_pie(pairs: &[(String, Num)], total: Num, other_word: &str, need_rest: bool) -> Value {
    let (top, rest) = pairs.split_at(pairs.len().min(STRAIN_SLOTS));
    let mut slices: Vec<Value> = top.iter().enumerate().filter(|(_, (_, v))| v.gt0())
        .map(|(i, (n, v))| slice(n, *v, &format!("s{}", i + 1), total)).collect();
    let other = py_sum(rest.iter().map(|(_, v)| *v));
    if (!need_rest || !rest.is_empty()) && other.gt0() {
        slices.push(slice(&format!("Other ({}{})", rest.len(), other_word), other, "oth", total));
    }
    json!({"total": total.json(), "slices": slices})
}

fn size_pie(sizes: &Value, title: &str) -> Value {
    let at = |k: &str| Num::of(get(sizes, k)).unwrap_or(Num::ZERO);
    let total = py_sum(SIZE_ORDER.iter().map(|k| at(k)));
    if !total.gt0() {
        return Value::Null;
    }
    let mut parts: Vec<(String, Num, String)> = SIZES.iter().filter(|d| at(&d.to_string()).truthy())
        .map(|d| (format!("{d} mg"), at(&d.to_string()), format!("d{d}"))).collect();
    for (k, _, word, slot) in EDIBLE_SIZES {
        if at(k).truthy() {
            parts.push((word.to_string(), at(k), slot.to_string()));
        }
    }
    if at(OTHER_SIZE).truthy() {
        parts.push(("Other size".into(), at(OTHER_SIZE), "dx".into()));
    }
    if parts.len() == 1 {
        parts[0].2 = "c".into();
    }
    json!({"title": title, "total": total.json(), "slices": parts.iter().map(|(n, v, s)| slice(n, *v, s, total)).collect::<Vec<_>>()})
}

/// A summary -> `{"units": pie | null, "mg": pie | null, "rows": [...], "more": n}` (charts.stock_view's data).
pub fn pies(summary: &Value) -> Result<Value, Error> {
    let strains = get(summary, "strains").as_array().ok_or("stock: summary.strains isn't a list")?;
    let (total, mg_total) = (num_at(summary, "total")?, num_at(summary, "mg_total")?);
    if !total.gt0() {
        return Ok(json!({"units": null, "mg": null, "rows": [], "more": 0}));
    }
    let name = |s: &Value| -> Result<String, Error> { Ok(text(get(s, "name"))?.to_string()) };
    let mut slots = Vec::new();
    for (i, s) in strains.iter().take(STRAIN_SLOTS).enumerate() {
        slots.push((name(s)?, format!("s{}", i + 1)));
    }
    let units_pairs: Vec<(String, Num)> = strains.iter().map(|s| Ok((name(s)?, num_at(s, "units")?))).collect::<Result<_, Error>>()?;
    let units = strain_pie(&units_pairs, total, " strains", true);
    let mg = if mg_total.gt0() {
        let pairs: Vec<(String, Num)> = strains.iter().map(|s| Ok((name(s)?, num_at(s, "mg")?))).collect::<Result<_, Error>>()?;
        strain_pie(&pairs, mg_total, " strains", true)
    } else {
        Value::Null
    };
    let title = mg_title(text(get(summary, "mg_mode"))?);
    let mut rows = Vec::new();
    for s in strains.iter().take(MAX_STRAIN_ROWS) {
        let n = name(s)?;
        let mut size_pies = vec![size_pie(get(s, "sizes"), "Quantity")];
        if mg_total.gt0() {
            size_pies.push(size_pie(get(s, "mg_sizes"), title));
        }
        let slot = slots.iter().find(|(x, _)| *x == n).map_or("oth".to_string(), |(_, sl)| sl.clone());
        rows.push(json!({"name": n, "units": num_at(s, "units")?.json(), "mg": num_at(s, "mg")?.json(), "slot": slot,
                         "size_pies": size_pies.into_iter().filter(|p| !p.is_null()).collect::<Vec<_>>()}));
    }
    Ok(json!({"units": units, "mg": mg, "rows": rows, "more": strains.len().saturating_sub(MAX_STRAIN_ROWS)}))
}

// --- par table ------------------------------------------------------------------------------------------------

fn size_code(key: &str) -> Result<i64, Error> {
    if let Some((_, c, _, _)) = EDIBLE_SIZES.iter().find(|(k, ..)| *k == key) {
        return Ok(*c);
    }
    if key == OTHER_SIZE {
        return Ok(0);
    }
    key.parse().map_err(|_| format!("stock: {key:?} isn't a size").into())
}

/// Python's `str.isspace()`: Unicode White_Space, plus the four separators U+001C..U+001F.
pub fn py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// Python's `str.strip()`.
pub fn py_strip(s: &str) -> &str {
    s.trim_matches(py_space)
}

pub(crate) fn is_product(name: &str) -> bool {
    let n = py_strip(name).to_lowercase();
    EDIBLES.iter().any(|(_, w)| w.to_lowercase() == n)
}

pub(crate) fn is_all(name: &str) -> bool {
    name.split(py_space).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ").to_lowercase() == ALL_STRAINS.to_lowercase()
}

/// The par/order sizes a row takes (ED-A6): a product Booster, Microdose and Other; a strain 25…5 and Other.
pub(crate) fn sizes_for(name: &str) -> Vec<i64> {
    let product = is_product(name);
    PAR_COLUMNS.iter().copied().filter(|d| ((*d == -1 || *d == -2 || *d == 0) == product) || *d == 0).collect()
}

/// The par column a level's size names (by number: 5.0 is 5), if any.
fn column_of(v: &Value) -> Option<i64> {
    let n = Num::of(v)?;
    PAR_COLUMNS.iter().copied().find(|d| Num::I(*d).cmp(n) == Ordering::Equal)
}

/// A summary of all counted stock and the center's par levels -> the par table (charts.par_view's data).
pub fn par_table(summary: &Value, levels: &[Value]) -> Result<Value, Error> {
    let mut par: Ordered<String, Ordered<i64, Num>> = Ordered::default();
    let mut names: Ordered<String, String> = Ordered::default();
    let mut combined: Ordered<i64, Num> = Ordered::default();
    for lv in levels {
        let (p, Some(size)) = (get(lv, "par"), column_of(get(lv, "size"))) else { continue };
        if p.is_null() {
            continue;
        }
        let p = Num::of(p).ok_or("stock: a par level isn't a number")?;
        let strain = text(get(lv, "strain"))?;
        if is_all(strain) {
            if sizes_for(ALL_STRAINS).contains(&size) {
                *combined.entry(&size, || p) = p;
            }
            continue;
        }
        let k = strain.to_lowercase();
        *par.entry(&k, Ordered::default).entry(&size, || p) = p;
        *names.entry(&k, String::new) = strain.to_string();
    }
    let strains = get(summary, "strains").as_array().ok_or("stock: summary.strains isn't a list")?;
    let mut table: Vec<(String, Ordered<i64, Num>, Ordered<i64, Num>)> = Vec::new();
    let mut seen = Vec::new();
    for s in strains {
        let n = text(get(s, "name"))?.to_string();
        if is_all(&n) {
            continue;
        }
        seen.push(n.to_lowercase());
        let mut have = Ordered::default();
        if let Some(sizes) = get(s, "sizes").as_object() {
            for (k, u) in sizes {
                let u = Num::of(u).ok_or("stock: a size's units isn't a number")?;
                *have.entry(&size_code(k)?, || u) = u;
            }
        }
        let lvl = par.get(&n.to_lowercase()).cloned().unwrap_or_default();
        table.push((n, have, lvl));
    }
    let mut extra: Vec<&String> = par.items.iter().map(|(k, _)| k).filter(|k| !seen.contains(k)).collect();
    extra.sort_by_key(|k| names.get(k).map(|n| n.to_lowercase()).unwrap_or_default());
    for k in extra {
        table.push((names.get(k).cloned().unwrap_or_default(), Ordered::default(), par.get(k).cloned().unwrap_or_default()));
    }
    let (mut rows, mut short_total) = (Vec::new(), Num::ZERO);
    let mut all_have: Ordered<i64, Num> = Ordered::default();
    let mut strain_short: Ordered<i64, Num> = Ordered::default();
    for (name, have, lvl) in &table {
        let (mut cells, mut short) = (Vec::new(), Num::ZERO);
        for d in PAR_COLUMNS {
            let h = have.get(&d).copied().unwrap_or(Num::ZERO);
            let p = lvl.get(&d).copied();
            let gap = match p { Some(p) if h.cmp(p) == Ordering::Less => p.sub(h), _ => Num::ZERO };
            short = short.add(gap);
            cells.push(json!({"size": d, "have": h.json(), "par": p.map_or(Value::Null, Num::json), "short": gap.json()}));
            if !is_product(name) {
                let a = all_have.entry(&d, || Num::ZERO);
                *a = a.add(h);
                let s = strain_short.entry(&d, || Num::ZERO);
                *s = s.add(gap);
            }
        }
        short_total = short_total.add(short);
        rows.push(json!({"name": name, "cells": cells, "short": short.json()}));
    }
    let (mut all_cells, mut all_short, mut all_extra) = (Vec::new(), Num::ZERO, Num::ZERO);
    for d in sizes_for(ALL_STRAINS) {
        let h = all_have.get(&d).copied().unwrap_or(Num::ZERO);
        let p = combined.get(&d).copied();
        let gap = match p { Some(p) if h.cmp(p) == Ordering::Less => p.sub(h), _ => Num::ZERO };
        let over = gap.sub(strain_short.get(&d).copied().unwrap_or(Num::ZERO));
        let extra = if over.gt0() { over } else { Num::ZERO };       // Python's max(0, x)
        all_short = all_short.add(gap);
        all_extra = all_extra.add(extra);
        all_cells.push(json!({"size": d, "have": h.json(), "par": p.map_or(Value::Null, Num::json), "short": gap.json(),
                              "extra": extra.json()}));
    }
    short_total = short_total.add(all_extra);
    let line = if short_total.truthy() {
        format!("{} units below par", fmt_g(short_total))
    } else if !par.items.is_empty() || !combined.items.is_empty() {
        "All strains with a par level are at or above it.".to_string()
    } else {
        "No par levels entered yet.".to_string()
    };
    Ok(json!({"heads": PAR_COLUMNS, "rows": rows, "short_total": short_total.json(), "summary": line,
              "all": {"name": ALL_STRAINS, "cells": all_cells, "short": all_short.json(), "extra": all_extra.json()}}))
}

// --- mix ------------------------------------------------------------------------------------------------------

fn mix_word(code: &str) -> String {
    MIX_TYPE_WORDS.iter().find(|(c, _)| *c == code).map_or(code, |(_, w)| w).to_string()
}

/// mix()'s cleaning: rows with mg above 0, an empty strain "Unknown", a missing code "".
fn clean_mix(rows: &[Value]) -> Result<Vec<(String, String, Num)>, Error> {
    let mut out = Vec::new();
    for r in rows {
        let mg = get(r, "mg");
        if !truthy(mg) {
            continue;
        }
        let mg = Num::of(mg).ok_or("stock: a mix row's mg isn't a number")?;
        if mg.gt0() {
            out.push((text_or(get(r, "strain"), UNKNOWN)?.to_string(), text(get(r, "type"))?.to_string(), Num::F(mg.f())));
        }
    }
    Ok(out)
}

fn breakdown(pairs: Vec<(String, Num)>, total: Num) -> Value {
    let mut slices: Vec<Value> = pairs.iter().enumerate().filter(|(_, (_, v))| v.gt0())
        .map(|(i, (n, v))| slice(n, *v, &format!("s{}", i + 1), total)).collect();
    if slices.len() == 1 {
        slices[0]["slot"] = json!("c");
    }
    json!({"total": total.json(), "slices": slices})
}

/// The stock mix by strain and by type (MI-R1; stockview.mix).
pub fn mix(rows: &[Value]) -> Result<Value, Error> {
    let clean = clean_mix(rows)?;
    let total = py_sum(clean.iter().map(|(_, _, m)| *m));
    if !total.gt0() {
        return Ok(json!({"total": 0}));
    }
    let mut strains: Ordered<String, Num> = Ordered::default();
    let mut types: Ordered<String, Num> = Ordered::default();
    let mut cell: Ordered<(String, String), Num> = Ordered::default();
    for (s, c, mg) in &clean {
        let x = strains.entry(s, || Num::ZERO);
        *x = x.add(*mg);
        let x = types.entry(c, || Num::ZERO);
        *x = x.add(*mg);
        let x = cell.entry(&(s.clone(), c.clone()), || Num::ZERO);
        *x = x.add(*mg);
    }
    let by_rank = |m: &Ordered<String, Num>| {
        let mut v = m.items.clone();
        v.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(&b.0)));
        v
    };
    let (order_s, order_t) = (by_rank(&strains), by_rank(&types));
    let slot = |i: usize| if i < STRAIN_SLOTS { format!("s{}", i + 1) } else { "oth".to_string() };
    let largest_first = |mut v: Vec<(String, Num)>| {
        v.sort_by(|a, b| b.1.cmp(a.1));
        v
    };
    let strain_cards: Vec<Value> = order_s.iter().enumerate().map(|(i, (s, tot))| {
        let pairs = types.items.iter().filter_map(|(c, _)| cell.get(&(s.clone(), c.clone())).map(|v| (mix_word(c), *v))).collect();
        json!({"name": s, "slot": slot(i), "total": tot.json(), "pie": breakdown(largest_first(pairs), *tot)})
    }).collect();
    let type_cards: Vec<Value> = order_t.iter().enumerate().map(|(i, (c, tot))| {
        let pairs = strains.items.iter().filter_map(|(s, _)| cell.get(&(s.clone(), c.clone())).map(|v| (s.clone(), *v))).collect();
        json!({"name": mix_word(c), "slot": slot(i), "total": tot.json(), "pie": breakdown(largest_first(pairs), *tot)})
    }).collect();
    let typed: Vec<(String, Num)> = order_t.iter().map(|(c, v)| (mix_word(c), *v)).collect();
    Ok(json!({
        "total": total.json(),
        "by_strain": strain_pie(&order_s, total, "", false),
        "by_type": strain_pie(&typed, total, "", false),
        "strain_cards": strain_cards,
        "type_cards": type_cards,
        "types": order_t.iter().map(|(c, _)| mix_word(c)).collect::<Vec<_>>(),
        "table": order_s.iter().map(|(s, v)| json!({"strain": s,
            "cells": order_t.iter().map(|(c, _)| cell.get(&(s.clone(), c.clone())).map_or(Value::Null, |x| x.json())).collect::<Vec<_>>(),
            "total": v.json()})).collect::<Vec<_>>(),
        "type_totals": order_t.iter().map(|(_, v)| v.json()).collect::<Vec<_>>(),
    }))
}

/// The mix rows summed per (strain, type), first-seen order, mg rounded to 2 decimals (route C12, MI-A2).
pub fn mix_cells(rows: &[Value]) -> Result<Value, Error> {
    let mut cells: Ordered<(String, String), Num> = Ordered::default();
    for (s, c, mg) in clean_mix(rows)? {
        let x = cells.entry(&(s, c), || Num::ZERO);
        *x = x.add(mg);
    }
    Ok(Value::Array(cells.items.iter().map(|((s, c), mg)| json!({"strain": s, "type": c, "mg": round2(*mg).json()})).collect()))
}

/// A center's By type pie (WC-D1): by mg when the rows have any mg figure, else by units; null when nothing is left.
pub fn by_type(rows: &[Value], mode: &str) -> Result<Value, Error> {
    let by_mg = Num::of(get(&summarize(rows, mode)?, "mg_total")).is_some_and(Num::gt0);
    let mut cells = Vec::new();
    for r in rows {
        if !has_units(r)? {
            continue;
        }
        let q = get(r, "quantity");
        let q = if truthy(q) { Num::of(q).ok_or("stock: a row's quantity isn't a number")? } else { Num::ZERO };
        let mg = q.mul(if by_mg { mg_per_unit(r, mode) } else { Num::I(1) });
        cells.push(json!({"strain": "", "type": type_of(r)?, "mg": mg.json()}));
    }
    let pie = mix(&cells)?;
    Ok(if Num::of(get(&pie, "total")).is_some_and(Num::gt0) { pie["by_type"].clone() } else { Value::Null })
}

// --- JSON entry points ----------------------------------------------------------------------------------------

fn input(json: &str) -> Result<Value, Error> {
    let v: Value = serde_json::from_str(json)?;
    if v.is_object() { Ok(v) } else { Err("stock: the input must be an object".into()) }
}

fn list<'a>(v: &'a Value, k: &str) -> Result<&'a [Value], Error> {
    let items = v.get(k).and_then(Value::as_array).ok_or_else(|| format!("stock: {k} must be a list"))?;
    if items.iter().all(Value::is_object) { Ok(items) } else { Err(format!("stock: every item of {k} must be an object").into()) }
}

fn word<'a>(v: &'a Value, k: &str) -> Result<&'a str, Error> {
    v.get(k).and_then(Value::as_str).ok_or_else(|| format!("stock: {k} must be text").into())
}

fn object<'a>(v: &'a Value, k: &str) -> Result<&'a Value, Error> {
    v.get(k).filter(|x| x.is_object()).ok_or_else(|| format!("stock: {k} must be an object").into())
}

pub fn filter_json(s: &str) -> Result<String, Error> {
    let v = input(s)?;
    Ok(filter(list(&v, "rows")?, word(&v, "makers")?)?.to_string())
}

pub fn summarize_json(s: &str) -> Result<String, Error> {
    let v = input(s)?;
    Ok(summarize(list(&v, "rows")?, word(&v, "mg_mode")?)?.to_string())
}

pub fn pies_json(s: &str) -> Result<String, Error> {
    let v = input(s)?;
    Ok(pies(object(&v, "summary")?)?.to_string())
}

pub fn par_table_json(s: &str) -> Result<String, Error> {
    let v = input(s)?;
    Ok(par_table(object(&v, "summary")?, list(&v, "levels")?)?.to_string())
}

pub fn mix_json(s: &str) -> Result<String, Error> {
    let v = input(s)?;
    Ok(mix(list(&v, "rows")?)?.to_string())
}

pub fn mix_cells_json(s: &str) -> Result<String, Error> {
    let v = input(s)?;
    Ok(mix_cells(list(&v, "rows")?)?.to_string())
}

/// `{"rows", "mg_mode"}` in, `{"pie": pie | null}` out (an object, so every reply of the table is one).
pub fn by_type_json(s: &str) -> Result<String, Error> {
    let v = input(s)?;
    Ok(json!({"pie": by_type(list(&v, "rows")?, word(&v, "mg_mode")?)?}).to_string())
}
