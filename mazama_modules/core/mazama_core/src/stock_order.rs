//! Order lines (specs/core row 9; specs/mazama-inventory MI-D6..D9, MI-D16, MI-D17, specs/edibles ED-A6): the server's
//! check of a center's order (`check`, held to mazama_modules/stock/vectors/order_check.json, frozen from the server's
//! Python `store.order_lines`) and the lines the phone's order form starts from (`form`, held to
//! mazama_modules/stock/order_form/cases.json, frozen from the phone's Dart).
//!
//! Known limits: in a refused line's description a list or an object is shown as compact JSON, where the server's
//! Python showed its repr, and an int beyond 64 bits in a line's strain as a float (the server's layer hands one in a
//! size, type or quantity over as its digits, so those read as Python's did) — only an error message; the phone sends
//! typed lines. Python's whitespace (U+001C..U+001F included) is the check's; the form uses Dart's (U+FEFF included).
use std::collections::HashMap;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::api::Error;
use crate::label::{canonical_strain_with, clean_strain};
use crate::names_table::STRAIN_MAX;
use crate::stock::{ALL_STRAINS, EDIBLES, PAR_COLUMNS, is_all, is_product, py_strip, sizes_for};

pub const ORDER_NOTE_MAX: usize = 1000;
pub const ORDER_BAD: &str = "These lines are not a strain with a size of 25, 20, 15, 10, 5 or 0 (other) and FD, DH or HG, or Chocolate, Gummy or \
Honey with a size of -1 (Booster), -2 (Microdose) or 0 and its own type (CH, GM, HN), and a whole number from 1 to 99999: ";


/// Python's `repr` of a float (shortest digits; exponent form below 1e-4 or from 1e16).
pub fn py_float_repr(f: f64) -> String {
    if f == 0.0 {
        return if f.is_sign_negative() { "-0.0".into() } else { "0.0".into() };
    }
    if !f.is_finite() {
        return if f.is_nan() { "nan".into() } else if f > 0.0 { "inf".into() } else { "-inf".into() };
    }
    let e_form = format!("{:e}", f.abs()); // "1.5e-7", "1e20"
    let (mant, exp) = e_form.split_once('e').unwrap_or((&e_form, "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    let digits: String = mant.chars().filter(char::is_ascii_digit).collect();
    let sign = if f < 0.0 { "-" } else { "" };
    let point = exp + 1;
    if (-4..16).contains(&exp) {
        let n = digits.len() as i32;
        if point <= 0 {
            format!("{sign}0.{}{digits}", "0".repeat((-point) as usize))
        } else if point >= n {
            format!("{sign}{digits}{}.0", "0".repeat((point - n) as usize))
        } else {
            format!("{sign}{}.{}", &digits[..point as usize], &digits[point as usize..])
        }
    } else {
        let rest = &digits[1..];
        format!("{sign}{}{}e{}{:02}", &digits[..1], if rest.is_empty() { String::new() } else { format!(".{rest}") },
                if exp < 0 { '-' } else { '+' }, exp.abs())
    }
}

/// Python's `str()` of a JSON value as the server shows it (a list or an object as compact JSON: see the module docs).
fn py_str(v: &Value) -> String {
    match v {
        Value::Null => "None".into(),
        Value::Bool(b) => if *b { "True".into() } else { "False".into() },
        Value::Number(n) => match (n.as_i64(), n.as_u64()) {
            (Some(i), _) => i.to_string(),
            (None, Some(u)) => u.to_string(),
            _ => py_float_repr(n.as_f64().unwrap_or(0.0)),
        },
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn first_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// A JSON integer (Python's `type(x) is int`: not a bool, not a float).
fn int_of(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) if n.is_i64() => n.as_i64(),
        Value::Number(n) if n.is_u64() => Some(i64::MAX), // above every bound checked here
        _ => None,
    }
}

fn product_word(name: &str) -> Option<&'static str> {
    let n = py_strip(name).to_lowercase();
    EDIBLES.iter().find(|(_, w)| w.to_lowercase() == n).map(|(_, w)| *w)
}

fn product_code(word: &str) -> Option<&'static str> {
    EDIBLES.iter().find(|(_, w)| *w == word).map(|(c, _)| *c)
}

/// `store._row_name`: an edible product's own word, the combined row's name, else the strain cleaned to its
/// canonical spelling; "" when nothing is left (or the name isn't text).
fn row_name(raw: &Value, aliases: &[(String, String)]) -> String {
    let Value::String(raw) = raw else { return String::new() };
    if is_all(raw) {
        return ALL_STRAINS.to_string();
    }
    if is_product(raw) {
        return product_word(raw).unwrap_or_default().to_string();
    }
    clean_strain(&canonical_strain_with(py_strip(raw), aliases))
}

/// The order's lines with canonical strain names and its note trimmed, or the server's refusal text.
pub fn check(lines: &[Value], note: &str, aliases: &[(String, String)]) -> Result<(Vec<Value>, String), String> {
    let note = py_strip(note);
    if note.chars().count() > ORDER_NOTE_MAX {
        return Err(format!("The notes are longer than {ORDER_NOTE_MAX} characters."));
    }
    let (mut good, mut bad) = (Vec::new(), Vec::new());
    let empty = Value::Object(Default::default());
    for ln in lines {
        let ln = if ln.is_object() { ln } else { &empty };
        let at = |k: &str| ln.get(k).unwrap_or(&Value::Null);
        let (raw, d, kind, q) = (at("strain"), at("size"), at("type"), at("quantity"));
        let name = row_name(raw, aliases);
        let size = int_of(d);
        let quantity = int_of(q);
        let kind_ok = match (product_code(&name), kind.as_str()) {
            (Some(code), Some(k)) if is_product(&name) => k == code,
            (_, Some(k)) if !is_product(&name) => matches!(k, "FD" | "DH" | "HG"),
            _ => false,
        };
        let ok = !name.is_empty() && name.chars().count() <= STRAIN_MAX
            && size.is_some_and(|s| sizes_for(&name).contains(&s))
            && kind_ok
            && quantity.is_some_and(|x| (1..=99_999).contains(&x));
        if ok {
            good.push(json!({"strain": name, "size": size, "type": kind, "quantity": quantity}));
        } else {
            bad.push(format!("{} {} {} {}", first_chars(&py_str(raw), 30), first_chars(&py_str(d), 10),
                             first_chars(&py_str(kind), 10), first_chars(&py_str(q), 10)));
        }
    }
    if !bad.is_empty() {
        return Err(format!("{ORDER_BAD}{}", bad.iter().take(6).cloned().collect::<Vec<_>>().join(", ")));
    }
    if good.is_empty() {
        return Err("The order has no lines.".into());
    }
    Ok((good, note.to_string()))
}

/// One par level as the phone has it (`ParLevel`).
#[derive(Debug, Clone, Deserialize)]
pub struct Level {
    pub strain: String,
    pub size: i64,
    pub par: Option<i64>,
}

/// Dart's `String.compareTo`: UTF-16 code units.
fn dart_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// Dart's whitespace (`String.trim`, RegExp `\s`): Unicode White_Space and U+FEFF.
fn dart_space(c: char) -> bool {
    c.is_whitespace() || c == '\u{feff}'
}

fn dart_is_product(name: &str) -> bool {
    let n = name.trim_matches(dart_space).to_lowercase();
    EDIBLES.iter().any(|(_, w)| w.to_lowercase() == n)
}

/// Dart's `stockIsAll`: trimmed, runs of whitespace one space, any case.
fn dart_is_all(name: &str) -> bool {
    name.split(dart_space).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ").to_lowercase() == ALL_STRAINS.to_lowercase()
}

/// Dart's `stockSizesFor`.
fn dart_sizes_for(name: &str) -> Vec<i64> {
    let product = dart_is_product(name);
    PAR_COLUMNS.iter().copied().filter(|d| *d == 0 || (*d < 0) == product).collect()
}

fn dart_word(name: &str) -> Option<&'static str> {
    let n = name.trim_matches(dart_space).to_lowercase();
    EDIBLES.iter().find(|(_, w)| w.to_lowercase() == n).map(|(_, w)| *w)
}

fn rank(size: i64) -> usize {
    PAR_COLUMNS.iter().position(|d| *d == size).unwrap_or(PAR_COLUMNS.len())
}

/// The order form's lines from the center's par levels: strains by name ignoring case then size, the combined All
/// strains lines by size, then each edible product with a level, Booster and Microdose (0 where it has none). A level
/// with no par, or a size its row doesn't take, or an edible's other size, is no line; a later level for the same
/// row and size replaces an earlier one in its place.
pub fn form(levels: &[Level]) -> Vec<Value> {
    let mut keys: HashMap<String, usize> = HashMap::new();
    let mut by: Vec<&Level> = Vec::new();
    for l in levels {
        if l.par.is_none() || !dart_sizes_for(&l.strain).contains(&l.size) {
            continue;
        }
        if dart_is_product(&l.strain) && l.size == 0 {
            continue;
        }
        let name = if dart_is_all(&l.strain) { ALL_STRAINS } else { l.strain.as_str() };
        let key = format!("{}|{}", name.to_lowercase(), l.size);
        match keys.get(&key) {
            Some(i) => by[*i] = l,
            None => {
                keys.insert(key, by.len());
                by.push(l);
            }
        }
    }
    let mut strains: Vec<&Level> = by.iter().copied().filter(|l| !dart_is_product(&l.strain) && !dart_is_all(&l.strain)).collect();
    strains.sort_by(|a, b| dart_cmp(&a.strain.to_lowercase(), &b.strain.to_lowercase()).then(rank(a.size).cmp(&rank(b.size))));
    let mut combined: Vec<&Level> = by.iter().copied().filter(|l| dart_is_all(&l.strain)).collect();
    combined.sort_by_key(|l| rank(l.size));
    let products: Vec<&str> = by.iter().filter_map(|l| if dart_is_product(&l.strain) { dart_word(&l.strain) } else { None }).collect();
    let mut out: Vec<Value> = strains.iter().map(|l| json!({"strain": l.strain, "size": l.size, "par": l.par})).collect();
    out.extend(combined.iter().map(|l| json!({"strain": ALL_STRAINS, "size": l.size, "par": l.par})));
    for (_, w) in EDIBLES {
        if products.contains(&w) {
            for d in [-1, -2] {
                let par = keys.get(&format!("{}|{d}", w.to_lowercase())).and_then(|i| by[*i].par).unwrap_or(0);
                out.push(json!({"strain": w, "size": d, "par": par}));
            }
        }
    }
    out
}

/// `{"lines": [any], "note": string | null, "aliases": [[spelling, name]]}` -> `{"lines", "note"}` or `{"refused"}`.
pub fn check_json(input: &str) -> Result<String, Error> {
    #[derive(Deserialize)]
    struct Input {
        lines: Vec<Value>,
        note: Option<String>,
        #[serde(default)]
        aliases: Vec<(String, String)>,
    }
    let i: Input = serde_json::from_str(input)?;
    Ok(match check(&i.lines, i.note.as_deref().unwrap_or(""), &i.aliases) {
        Ok((lines, note)) => json!({"lines": lines, "note": note}),
        Err(refused) => json!({"refused": refused}),
    }
    .to_string())
}

/// `{"levels": [{"strain", "size", "par"}]}` -> `[{"strain", "size", "par"}]`.
pub fn form_json(input: &str) -> Result<String, Error> {
    #[derive(Deserialize)]
    struct Input {
        levels: Vec<Level>,
    }
    let i: Input = serde_json::from_str(input)?;
    Ok(Value::Array(form(&i.levels)).to_string())
}
