//! The manufacturer's dose plan and a product information sheet's amounts (specs/core row 11, FM-07, FM-08, Task 17),
//! held to the frozen vectors in mazama_modules/manufacturing/ (the server's `plans.product_plan` and `infosheet.build`
//! under CPython 3.14, and the DOSE rows the owner approved, CR-D6, as specs/core/replay/replay_plan.py proposes them).
//!
//! - [`plan_json`]: grams per unit for a dose, rounded DOWN to 0.01 g so the actual TPE never exceeds the dose (the
//!   AGENTS.md rule), worked out in Python's 28-digit decimals from the potency's shortest digits (`Decimal(str(p))`);
//!   the actual mg rounded UP to 0.01; how many units the dry weight allows; or why not. No usable potency (DOSE-12),
//!   an analyteWeight that isn't a JSON number (DOSE-13), a certificate TPE that isn't finite (final review I1) and a
//!   potency the decimals can't divide by are one refusal; the dry weight is read as `records::dry_grams` reads it
//!   (RD-2, DOSE-14).
//! - [`serving_table_json`]: the per-dose table of a batch/lot's sheet (or one package's one-column table), its summary
//!   and note, and the mg shown beside each package: never below what a unit holds (DOSE-15, DOSE-16, DOSE-22); no
//!   amounts at all when the state's potency isn't a JSON number (DOSE-20) or, for that package, when its weight
//!   can't be read.
use std::cmp::Ordering;

use serde_json::{Map, Value, json};

use crate::api::Error;
use crate::dose;
use crate::records::{dry_grams, py_float_text};
use crate::stock::{Num, fmt_g, py_space, round2};

pub const NO_POTENCY: &str = "No potency is known for this batch/lot, so a unit can't be weighed out.";
const TOO_SMALL: &str = "That dose is too small to weigh out.";
const BAD_QTY: &str = "Quantity must be between 1 and 1000.";
/// The most units a plan counts (a dry weight past ~9e13 g); Python's `int()` had no bound.
const MAX_QTY: f64 = 9_007_199_254_740_992.0;
/// Python's `decimal` default context: 28 significant digits.
const PREC: usize = 28;
/// The certificate's psilocin counted as psilocybin (`coa.TPE_FACTOR`, molar masses).
const TPE_FACTOR: f64 = 284.25 / 204.27;
const ALKALOIDS: [(&str, &str); 4] =
    [("Baeocystine", "baeocystine"), ("Norbaeocystine", "norbaeocystine"), ("Norpsilocin", "norpsilocin"), ("Aeruginascin", "aeruginascin")];
const NOTE: &str = "Net weights are rounded down, so a unit never contains more than its TPE";
static NULL: Value = Value::Null;

fn out_of_range() -> Error {
    "manufacturing: a figure out of range".into()
}

// --- Python's readings ------------------------------------------------------------------------------------------

/// A JSON number (not true/false) as a finite float; anything else, or past the largest double, `None`.
fn finite_number(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64().filter(|f| f.is_finite()),
        _ => None,
    }
}

/// Python's truthiness of a JSON value.
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

/// Python's `max(a, b)` of two floats: `a` unless `b > a`.
fn pymax(a: f64, b: f64) -> f64 {
    if b > a { b } else { a }
}

/// `x or 0.0` for an optional float.
fn or0(x: Option<f64>) -> f64 {
    x.filter(|f| *f != 0.0).unwrap_or(0.0)
}

/// `math.ceil(x - 1e-9)`, the one round-up of an mg figure: row 5's `dose::ceil` (`dose.ceil_mg`); an mg that isn't
/// finite or fits no i64 is out of range.
fn ceil_mg(x: f64) -> Result<i64, Error> {
    dose::ceil(x).ok_or_else(out_of_range)
}

/// A package's own figure as RD-2 reads a dry weight: absent or null is 0, a JSON number itself, text that is a plain
/// number that number; anything else (other text, NaN/inf, true/false, a list, an object) is unknown (`None`).
fn package_figure(r: &Map<String, Value>, key: &str) -> Option<f64> {
    match r.get(key).unwrap_or(&NULL) {
        Value::Null => Some(0.0),
        Value::Number(n) => n.as_f64().filter(|f| f.is_finite()),
        Value::String(s) => py_float_text(s).ok().filter(|f| f.is_finite()),
        _ => None,
    }
}

/// A package's weightPerUnit (g): absent or null is 0 (today's `or 0`), else `package_figure`'s reading; unknown
/// (`None`): that package gets no amounts.
fn weight(r: &Map<String, Value>) -> Option<f64> {
    package_figure(r, "weightPerUnit")
}

/// DOSE-23: a package's own analyteWeight (mg/g), read as its weight is (absent or null: 0, no figure); unknown
/// (`None`) when present but unreadable, and that package gets no amounts.
fn own_potency(r: &Map<String, Value>) -> Option<f64> {
    package_figure(r, "analyteWeight")
}

/// `r.get("description") or ""` as `re.search` takes it: text, or a falsy value as ""; anything else raised.
fn description(r: &Map<String, Value>) -> Result<String, Error> {
    match r.get("description").unwrap_or(&NULL) {
        Value::String(s) => Ok(s.clone()),
        v if !truthy(v) => Ok(String::new()),
        _ => Err("manufacturing: a package's description isn't text".into()),
    }
}

/// The first `(?<![0-9.])([0-9]{1,int}(?:\.[0-9]{1,2})?)\s*mg` (case-insensitive) in `s`, as Python's `re.search`
/// finds it: `plans.NAME_DOSE_RE` (int 4, with the fraction) and `infosheet._dose_of`'s (int 3, without).
pub fn name_mg(s: &str, int: usize, frac: bool) -> Option<String> {
    let c: Vec<char> = s.chars().collect();
    let n = c.len();
    let mg_at = |mut p: usize| -> bool {
        while p < n && py_space(c[p]) {
            p += 1;
        }
        p + 1 < n && matches!(c[p], 'm' | 'M') && matches!(c[p + 1], 'g' | 'G')
    };
    for i in 0..n {
        if i > 0 && (c[i - 1].is_ascii_digit() || c[i - 1] == '.') {
            continue;
        }
        let mut j = i;
        while j < n && j - i < int && c[j].is_ascii_digit() {
            j += 1;
        }
        if j == i {
            continue;
        }
        let mut end = j;
        if frac && j < n && c[j] == '.' {
            let mut f = j + 1;
            while f < n && f - (j + 1) < 2 && c[f].is_ascii_digit() {
                f += 1;
            }
            if f > j + 1 {
                end = f;
            }
        }
        // the regex backtracks to a shorter fraction or none, but a digit or the point then follows, never \s*mg
        if mg_at(end) {
            return Some(c[i..end].iter().collect());
        }
    }
    None
}

// --- decimals: Python's `decimal` at 28 digits, on magnitudes -----------------------------------------------------

/// A decimal `digits x 10^exp` (most significant digit first, no leading zeros; zero has no digits).
#[derive(Clone, Debug)]
struct Dec {
    digits: Vec<u8>,
    exp: i32,
}

impl Dec {
    fn of(n: u128) -> Dec {
        if n == 0 { Dec { digits: vec![], exp: 0 } } else { Dec { digits: n.to_string().bytes().map(|b| b - b'0').collect(), exp: 0 } }
    }

    /// Rounded half to even to `prec` significant digits; `sticky`: a nonzero part already dropped below the digits.
    fn round_even(mut self, prec: usize, sticky: bool) -> Dec {
        if self.digits.len() <= prec {
            return self;
        }
        let drop = self.digits.len() - prec;
        let guard = self.digits[prec];
        let rest = sticky || self.digits[prec + 1..].iter().any(|d| *d != 0);
        self.digits.truncate(prec);
        self.exp += drop as i32;
        let odd = self.digits.last().is_some_and(|d| d % 2 == 1);
        if guard > 5 || (guard == 5 && (rest || odd)) {
            let mut k = self.digits.len();
            loop {
                if k == 0 {
                    self.digits.insert(0, 1);
                    self.digits.pop();
                    self.exp += 1;
                    break;
                }
                k -= 1;
                if self.digits[k] == 9 {
                    self.digits[k] = 0;
                } else {
                    self.digits[k] += 1;
                    break;
                }
            }
        }
        self
    }

    /// The whole number of hundredths, toward zero (`up`: away from zero); `None` past 28 digits (Python's quantize
    /// raises InvalidOperation there).
    fn hundredths(&self, up: bool) -> Option<u128> {
        let k = self.exp + 2;
        let mut d = self.digits.clone();
        let mut bump = false;
        if k >= 0 {
            if !d.is_empty() {
                if k as usize > PREC {
                    return None;
                }
                d.extend(std::iter::repeat_n(0, k as usize));
            }
        } else {
            let cut = (-k) as usize;
            let keep = d.len().saturating_sub(cut);
            bump = up && d[keep..].iter().any(|x| *x != 0);
            d.truncate(keep);
        }
        let mut v: u128 = 0;
        for x in &d {
            v = v.checked_mul(10)?.checked_add(*x as u128)?;
        }
        if bump {
            v += 1;
        }
        (v < 10u128.pow(PREC as u32)).then_some(v)
    }

    fn cmp(&self, o: &Dec) -> Ordering {
        match (self.digits.is_empty(), o.digits.is_empty()) {
            (true, true) => return Ordering::Equal,
            (true, false) => return Ordering::Less,
            (false, true) => return Ordering::Greater,
            _ => {}
        }
        let (a, b) = (self.digits.len() as i32 + self.exp, o.digits.len() as i32 + o.exp);
        if a != b {
            return a.cmp(&b);
        }
        let n = self.digits.len().max(o.digits.len());
        let at = |d: &Vec<u8>, i: usize| d.get(i).copied().unwrap_or(0);
        (0..n).map(|i| at(&self.digits, i).cmp(&at(&o.digits, i))).find(|c| c.is_ne()).unwrap_or(Ordering::Equal)
    }
}

/// A positive finite float's shortest round-trip digits (Python's `repr`, `Decimal(str(p))`): `m x 10^e`.
fn shortest(x: f64) -> (u64, i32) {
    let s = format!("{x:e}");
    let (mant, exp) = s.split_once('e').expect("{:e} has an exponent");
    let frac = mant.split_once('.').map_or(0, |(_, f)| f.len()) as i32;
    (mant.replace('.', "").parse().expect("at most 17 digits"), exp.parse::<i32>().expect("an exponent") - frac)
}

/// `n / (m x 10^e)` rounded half to even to 28 digits (Python's `Decimal(n) / Decimal(p)`).
fn divide(n: u64, m: u64, e: i32) -> Dec {
    let mut digits: Vec<u8> = if n / m > 0 { (n / m).to_string().bytes().map(|b| b - b'0').collect() } else { vec![] };
    let mut r = n % m;
    let mut point = 0i32;
    while r != 0 && digits.len() < PREC + 1 {
        r *= 10;
        let d = (r / m) as u8;
        r %= m;
        point += 1;
        if !digits.is_empty() || d != 0 {
            digits.push(d);
        }
    }
    Dec { digits, exp: -point - e }.round_even(PREC, r != 0)
}

/// `k x m x 10^e` rounded half to even to 28 digits (Python's `per_d * Decimal(str(p))`).
fn multiply(k: u128, m: u64, e: i32) -> Dec {
    let mut out: Vec<u8> = vec![]; // least significant first
    let mut carry: u128 = 0;
    for d in k.to_string().bytes().rev() {
        let v = (d - b'0') as u128 * m as u128 + carry;
        out.push((v % 10) as u8);
        carry = v / 10;
    }
    while carry > 0 {
        out.push((carry % 10) as u8);
        carry /= 10;
    }
    while out.last() == Some(&0) {
        out.pop();
    }
    out.reverse();
    Dec { digits: out, exp: e }.round_even(PREC, false)
}

/// The float a decimal `±h / 100` reads as (Python's `float(Decimal)`).
fn from_hundredths(h: u128, negative: bool) -> f64 {
    let s = format!("{}{}.{:02}", if negative { "-" } else { "" }, h / 100, h % 100);
    s.parse().expect("a decimal")
}

/// Grams per unit for `dose` mg at `p` mg/g, rounded down to 0.01 g, and the actual mg rounded up, as today's Python
/// works them out; `None` where its decimals raise or the floor would be over the dose (DOSE-12's refusal).
fn per_and_actual(dose: i64, p: f64) -> Option<(f64, f64)> {
    let (m, e) = shortest(p);
    let negative = dose < 0;
    let n = dose.unsigned_abs();
    let k = divide(n, m, e).hundredths(false)?;
    let mg = multiply(k, m, e - 2);
    // today's `assert per_d * p <= dose`, with the signs put back
    let over = match mg.cmp(&Dec::of(n as u128)) {
        Ordering::Greater => !negative,
        Ordering::Less => negative,
        Ordering::Equal => false,
    };
    if over {
        return None;
    }
    let a = mg.hundredths(true)?;
    Some((from_hundredths(k, negative), from_hundredths(a, negative)))
}

// --- the plan -------------------------------------------------------------------------------------------------------

/// A certificate TPE that isn't finite: JSON can't carry one, so the server hands it over as its text ("inf", "-inf",
/// "nan", `plans.for_core`), and any text that reads as a number past the largest double counts too.
fn not_finite(coa_tpe: &Value) -> bool {
    matches!(coa_tpe, Value::String(s) if py_float_text(s).is_ok_and(|f| !f.is_finite()))
}

/// `plans.product_plan` as approved (CR-D6): `state` the record's analyteWeight as read (DOSE-13), `avail` its dry
/// weight (RD-2), `coa_tpe` as given (echoed back). A certificate TPE that isn't finite is a refusal, echoed as null
/// (stricter than the old code on purpose, final review I1: it raised on an infinite one, so nothing was queued; it is
/// never a plan at the state's potency alone); other text counts as none (DOSE-13).
fn plan(state: Option<f64>, avail: f64, dose: i64, qty: i64, coa_tpe: &Value) -> Value {
    let unreadable = not_finite(coa_tpe);
    let echo = if unreadable { &NULL } else { coa_tpe };
    let ct = finite_number(coa_tpe).filter(|f| *f >= 0.0);
    let p = pymax(state.unwrap_or(0.0), or0(ct));
    let refusal = || {
        json!({"dose": dose, "qty": qty, "potency": p, "state_potency": state.unwrap_or(0.0), "coa_tpe": echo,
               "available": avail, "per_unit": 0.0, "actual_mg": 0.0, "max_qty": 0, "error": NO_POTENCY, "total": 0.0,
               "remaining": round2(Num::F(avail)).f()})
    };
    if unreadable {
        return refusal();
    }
    let Some(state) = state else { return refusal() };
    if !(p > 0.0) {
        return refusal();
    }
    let Some((per, actual)) = per_and_actual(dose, p) else { return refusal() };
    let x = if per > 0.0 { avail / per + 1e-9 } else { 0.0 };
    let max_qty = if x > -MAX_QTY && x < MAX_QTY { x.trunc() as i64 } else if x > 0.0 { MAX_QTY as i64 } else { -(MAX_QTY as i64) };
    let total = round2(Num::F(per * qty as f64)).f();
    let remaining = round2(Num::F(avail - total)).f();
    let error = if per <= 0.0 {
        Some(TOO_SMALL.to_string())
    } else if !(1..=1000).contains(&qty) {
        Some(BAD_QTY.to_string())
    } else if total > avail + 1e-9 {
        Some(format!("Not enough: {qty} x {per:.2} g = {total:.2} g but only {} g is left (at most {max_qty} units).", fmt_g(Num::F(avail))))
    } else {
        None
    };
    json!({"dose": dose, "qty": qty, "potency": p, "state_potency": state, "coa_tpe": coa_tpe, "available": avail,
           "per_unit": per, "actual_mg": actual, "max_qty": max_qty, "error": error, "total": total, "remaining": remaining})
}

fn int_of(v: &Value, what: &str) -> Result<i64, Error> {
    v.as_i64().ok_or_else(|| format!("manufacturing.plan: {what} must be an integer").into())
}

/// `{"plans": [{"source", "dose", "qty", "coa_tpe"}]}` -> one plan per item, in order (CR-D5: a page's in one call).
pub fn plan_json(input: &str) -> Result<String, Error> {
    let v: Value = serde_json::from_str(input)?;
    let items = v.get("plans").and_then(Value::as_array).ok_or("manufacturing.plan: plans must be a list")?;
    let mut out = Vec::with_capacity(items.len());
    for it in items {
        let src = it.get("source").and_then(Value::as_object).ok_or("manufacturing.plan: a plan's source must be an object")?;
        let dose = int_of(it.get("dose").unwrap_or(&NULL), "dose")?;
        let qty = int_of(it.get("qty").unwrap_or(&NULL), "qty")?;
        let state = finite_number(src.get("analyteWeight").unwrap_or(&NULL));
        out.push(plan(state, dry_grams(src.get("dryWeight").unwrap_or(&NULL)), dose, qty, it.get("coa_tpe").unwrap_or(&NULL)));
    }
    Ok(serde_json::to_string(&out)?)
}

// --- the serving table ----------------------------------------------------------------------------------------------

/// A certificate figure as Python's arithmetic takes it: true/false as 1/0, a number itself; text and the rest raised.
fn figure(v: &Value) -> Result<f64, Error> {
    match v {
        Value::Bool(b) => Ok(if *b { 1.0 } else { 0.0 }),
        Value::Number(n) => n.as_f64().ok_or_else(out_of_range),
        _ => Err("manufacturing: a certificate figure isn't a number".into()),
    }
}

/// `meta.get(k) or 0` as a factor.
fn figure_or0(meta: &Map<String, Value>, k: &str) -> Result<f64, Error> {
    let v = meta.get(k).unwrap_or(&NULL);
    if truthy(v) { figure(v) } else { Ok(0.0) }
}

/// `coa.tpe(meta)` (AD-18 as amended by SM-D14): mg/g to 2 places, or `None`.
fn tpe(meta: &Map<String, Value>) -> Result<Option<f64>, Error> {
    let get = |k: &str| meta.get(k).unwrap_or(&NULL);
    let (ps, pc, lab) = (get("psilocybin"), get("psilocin"), get("lab_tpe"));
    let state = get("psilocybin_from") == "state" && !ps.is_null();
    let two = |x: f64| round2(Num::F(x)).f();
    if state && !pc.is_null() {
        return Ok(Some(two(figure(ps)? + TPE_FACTOR * figure(pc)?)));
    }
    let lab_number = match lab {
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        Value::Number(n) => n.as_f64().filter(|f| f.is_finite() && *f >= 0.0),
        _ => None,
    };
    if let Some(l) = lab_number {
        return Ok(Some(two(l)));
    }
    if !state && !ps.is_null() && !pc.is_null() {
        return Ok(Some(two(figure(ps)? + TPE_FACTOR * figure(pc)?)));
    }
    Ok(None)
}

fn n2(v: f64) -> String {
    format!("{v:.2}")
}

/// DOSE-15: an mg a unit holds, to 0.01 and never below it (only float noise forgiven, as `ceil_mg`):
/// `(Decimal(repr(v)) - Decimal("1e-9")).quantize(Decimal("0.01"), ROUND_CEILING)`.
fn n2_up(v: f64) -> Result<String, Error> {
    if !(v > 0.0 && v.is_finite()) {
        return Ok(n2(v));
    }
    if v < 1e-9 {
        return Ok("-0.00".into()); // a negative difference above -0.01 rounds up to minus zero
    }
    if v >= 1e21 {
        return Err(out_of_range());
    }
    let (m, e) = shortest(v);
    let s = (-e).max(9); // v x 10^s and 1e-9 x 10^s are whole numbers
    let x = (m as u128) * 10u128.pow((e + s) as u32) - 10u128.pow((s - 9) as u32);
    let c = x.div_ceil(10u128.pow((s - 2) as u32));
    Ok(format!("{}.{:02}", c / 100, c % 100))
}

/// DOSE-22: what a package holds is reckoned at the larger of its batch/lot's potency and its own analyteWeight
/// (DOSE-23: `own_potency`'s reading; callers have already given an unreadable one no amounts).
fn floor_potency(r: &Map<String, Value>, potency: f64) -> f64 {
    pymax(potency, own_potency(r).unwrap_or(0.0))
}

/// DOSE-23: what a package holds, rounded up to a whole mg, at DOSE-22's floor potency; `None` when that isn't finite or
/// fits no i64, and that package gets no amounts (never an error for one package's figure).
fn holds(r: &Map<String, Value>, w: f64, potency: f64) -> Option<i64> {
    dose::ceil(w * floor_potency(r, potency))
}

/// `infosheet.package_item`'s mg as approved: the dose it was filed under, else the whole mg in its name, else worked
/// out from its weight; then never below what the unit holds (DOSE-16, DOSE-22), the package's own figure counted even
/// when the batch/lot's potency is 0 (DOSE-23); `None` when not known, or its weight or own figure can't be read.
fn package_mg(r: &Map<String, Value>, potency: f64, dose: i64) -> Result<Option<i64>, Error> {
    let (Some(w), Some(_)) = (weight(r), own_potency(r)) else { return Ok(None) };
    let Some(h) = holds(r, w, potency) else { return Ok(None) };
    let m = name_mg(&description(r)?, 4, true);
    let named = m.as_deref().and_then(|g| g.parse::<f64>().ok()).filter(|f| f.fract() == 0.0);
    let mut mg = if dose != 0 {
        Some(dose)
    } else if let Some(f) = named {
        Some(f as i64)
    } else if potency > 0.0 {
        Some(ceil_mg(w * potency)?.max(1))
    } else {
        None
    };
    if let Some(x) = mg {
        mg = Some(x.max(h));
    }
    Ok(mg)
}

/// `infosheet._dose_of` as approved: by the name's dose, else by weight within 0.005 g of the plan's, and (DOSE-22)
/// only when the unit holds no more than that dose; 0: under "other" (also when its weight or own figure can't be read).
fn dose_of(r: &Map<String, Value>, by_dose: &[(i64, f64)], doses: &[i64], potency: f64) -> Result<i64, Error> {
    let (Some(w), Some(_)) = (weight(r), own_potency(r)) else { return Ok(0) };
    let Some(h) = holds(r, w, potency) else { return Ok(0) };
    let named = name_mg(&description(r)?, 3, false).and_then(|g| g.parse::<i64>().ok()).filter(|d| doses.contains(d));
    let d = named.or_else(|| by_dose.iter().find(|(_, per)| (w - per).abs() <= 0.005).map(|(d, _)| *d));
    Ok(match d {
        Some(d) if h > d => 0,
        Some(d) => d,
        None => 0,
    })
}

fn item(r: &Map<String, Value>, mg: Option<i64>) -> Value {
    json!({"guid": r.get("productGuid").unwrap_or(&NULL), "mg": mg})
}

/// DOSE-20: the state's potency is there but isn't a JSON number.
fn unreadable_potency(src: &Map<String, Value>) -> bool {
    matches!(src.get("analyteWeight"), Some(v) if !v.is_null() && !v.is_number())
}

fn object<'a>(v: &'a Value, what: &str) -> Result<&'a Map<String, Value>, Error> {
    v.as_object().ok_or_else(|| format!("manufacturing.serving_table: {what} must be an object").into())
}

/// `{"kind", "guid", "source", "meta", "made", "package", "doses"}` -> `{"serv", "summary", "notes", "packages"}`.
pub fn serving_table_json(input: &str) -> Result<String, Error> {
    let v: Value = serde_json::from_str(input)?;
    let src = object(v.get("source").unwrap_or(&NULL), "source")?;
    let made: Vec<&Map<String, Value>> = v
        .get("made")
        .and_then(Value::as_array)
        .ok_or("manufacturing.serving_table: made must be a list")?
        .iter()
        .map(|r| object(r, "a package"))
        .collect::<Result<_, _>>()?;
    let doses: Vec<i64> = v
        .get("doses")
        .and_then(Value::as_array)
        .ok_or("manufacturing.serving_table: doses must be a list")?
        .iter()
        .map(|d| d.as_i64().ok_or("manufacturing.serving_table: a dose must be an integer"))
        .collect::<Result<_, _>>()?;
    let meta = match v.get("meta").unwrap_or(&NULL) {
        Value::Null => None,
        m => Some(object(m, "meta")?).filter(|m| !m.is_empty()),
    };
    let package = match v.get("package").unwrap_or(&NULL) {
        Value::Null => None,
        p => Some(object(p, "package")?).filter(|p| !p.is_empty()),
    };
    Ok(serde_json::to_string(&sheet(src, meta, &made, package, &doses)?)?)
}

fn sheet(
    src: &Map<String, Value>,
    meta: Option<&Map<String, Value>>,
    made: &[&Map<String, Value>],
    package: Option<&Map<String, Value>>,
    doses: &[i64],
) -> Result<Value, Error> {
    if unreadable_potency(src) {
        let packages: Vec<Value> = made.iter().map(|r| item(r, None)).collect();
        return Ok(json!({"serv": null, "summary": null, "notes": [], "packages": packages}));
    }
    let state_p = or0(finite_number(src.get("analyteWeight").unwrap_or(&NULL)));
    let coa_t = match meta {
        Some(m) => tpe(m)?,
        None => None,
    };
    let potency = pymax(state_p, or0(coa_t));
    let packages: Vec<Value> = made.iter().map(|r| Ok(item(r, package_mg(r, potency, 0)?))).collect::<Result<_, Error>>()?;
    let mut serv = Value::Null;
    let mut summary = Value::Null;
    let mut notes: Vec<String> = vec![];
    if let Some(pk) = package {
        let per = weight(pk).filter(|per| own_potency(pk).is_some() && holds(pk, *per, potency).is_some());
        if let (true, Some(per)) = (potency > 0.0, per) {
            let mut rows = vec![json!(["Net weight (g)", n2(per)])];
            if let Some(m) = meta {
                rows.push(json!(["Psilocybin (mg)", n2_up(per * figure_or0(m, "psilocybin")?)?]));
                rows.push(json!(["Psilocin (mg)", n2(per * figure_or0(m, "psilocin")?)]));
            }
            rows.push(json!(["TPE (mg)", n2_up(per * floor_potency(pk, potency))?]));
            if let Some(m) = meta {
                for (name, k) in ALKALOIDS {
                    if let Some(x) = m.get(k).filter(|x| !x.is_null()) {
                        rows.push(json!([format!("{name} (mg)"), n2(per * figure(x)?)]));
                    }
                }
            }
            serv = json!({"one": pk.get("productGuid").unwrap_or(&NULL), "rows": rows});
        }
    } else if potency > 0.0 {
        let coa_v = coa_t.map_or(Value::Null, |t| json!(t));
        let mut by_dose: Vec<(i64, f64)> = vec![];
        for d in doses {
            if !by_dose.iter().any(|(x, _)| x == d) {
                let p = plan(Some(state_p), 1e9, *d, 1, &coa_v);
                by_dose.push((*d, p["per_unit"].as_f64().unwrap_or(0.0)));
            }
        }
        let per = |d: &i64| by_dose.iter().find(|(x, _)| x == d).map_or(0.0, |(_, p)| *p);
        let mut lots_of: Vec<(i64, Vec<Value>)> = vec![];
        let mut other: Vec<Value> = vec![];
        for r in made {
            let d = dose_of(r, &by_dose, doses, potency)?;
            let it = item(r, package_mg(r, potency, d)?);
            if d != 0 {
                match lots_of.iter_mut().find(|(x, _)| *x == d) {
                    Some((_, l)) => l.push(it),
                    None => lots_of.push((d, vec![it])),
                }
            } else {
                other.push(it);
            }
        }
        let mut rows = vec![json!(["Net weight (g)", doses.iter().map(|d| n2(per(d))).collect::<Vec<_>>()])];
        if let Some(m) = meta {
            let ps = figure_or0(m, "psilocybin")?;
            let pc = figure_or0(m, "psilocin")?;
            rows.push(json!(["Psilocybin (mg)", doses.iter().map(|d| n2_up(per(d) * ps)).collect::<Result<Vec<_>, _>>()?]));
            rows.push(json!(["Psilocin (mg)", doses.iter().map(|d| n2(per(d) * pc)).collect::<Vec<_>>()]));
        }
        rows.push(json!(["TPE (mg)", doses.iter().map(|d| d.to_string()).collect::<Vec<_>>()]));
        if let Some(m) = meta {
            for (name, k) in ALKALOIDS {
                if let Some(x) = m.get(k).filter(|x| !x.is_null()) {
                    let f = figure(x)?;
                    rows.push(json!([format!("{name} (mg)"), doses.iter().map(|d| n2(per(d) * f)).collect::<Vec<_>>()]));
                }
            }
        }
        let lots: Vec<Value> =
            doses.iter().map(|d| json!(lots_of.iter().find(|(x, _)| x == d).map_or(vec![], |(_, l)| l.clone()))).collect();
        serv = json!({"doses": doses, "rows": rows, "lots": lots, "other": other});
        summary = json!(doses.iter().map(|d| json!([d, n2(per(d))])).collect::<Vec<_>>());
        notes.push(format!("{NOTE} (calculated from {} mg/g TPE).", fmt_g(Num::F(potency))));
    }
    Ok(json!({"serv": serv, "summary": summary, "notes": notes, "packages": packages}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_name_patterns_read_as_pythons() {
        for (s, want) in [
            ("Golden 25mg", Some("25")),
            ("x 2.5 MG", Some("2.5")),
            ("x 12345mg", None),
            ("x 1.555mg", None),
            ("a.25mg", None),
            ("25 \u{a0}mg", Some("25")),
            ("25\u{1c}mg", Some("25")),
            ("x 25 m g", None),
            ("1234.56mg", Some("1234.56")),
            ("x 12mg 5mg", Some("12")),
            ("", None),
            ("mg", None),
            ("9mg", Some("9")),
            ("x 25m", None),
        ] {
            assert_eq!(name_mg(s, 4, true).as_deref(), want, "{s:?}");
        }
        assert_eq!(name_mg("x 2.5mg", 3, false), None);
        assert_eq!(name_mg("x 1234 mg", 3, false), None);
        assert_eq!(name_mg("x 123 mg", 3, false).as_deref(), Some("123"));
    }

    #[test]
    fn decimals_as_pythons() {
        assert_eq!(per_and_actual(25, 7.25), Some((3.44, 24.94)));
        assert_eq!(per_and_actual(1, 900.0), Some((0.0, 0.0)));
        assert_eq!(per_and_actual(25, 1e-30), None);
        assert_eq!(per_and_actual(25, 1e-7), Some((250000000.0, 25.0)));
        assert_eq!(n2_up(1.2325).unwrap(), "1.24");
        assert_eq!(n2_up(1.23).unwrap(), "1.23");
        assert_eq!(n2_up(1e-9).unwrap(), "0.00");
        assert_eq!(n2_up(5e-10).unwrap(), "-0.00");
    }
}
