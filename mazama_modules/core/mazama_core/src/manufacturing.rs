//! Certificate corrections and saved ingredient text (specs/core row 12, FM-09, FM-10), held to the frozen vectors in
//! mazama_modules/manufacturing/vectors/ (the server's own Python under CPython 3.14, the reference):
//!
//! - [`coa_edit`]: one correction of the lab data in a certificate image's description (`coaedit.apply_edit`). It answers
//!   with the *changes*, never a whole description: the server applies them to its own dict, so the image's other
//!   fields stay byte for byte (a number past 64 bits stays itself) and `json.dumps` writes the keys in the old order.
//! - [`coa_number`]: a typed mg/g figure (`coaedit.number`).
//! - [`clean_text`]: saved ingredient and allergen text (`infosheet.clean_text`).
//!
//! The readings are Python's: `float()` of a stripped, lower-cased text, `repr` of a float, `str.strip()` / `split()`
//! whitespace, `date.fromisoformat` as CPython 3.14 reads it, `$` letting one line feed follow. Two documented rulings
//! where the core is not the reference: only ASCII digits are read as a number (`float()` also reads other scripts'
//! decimal digits), and a list or an object as the image's own `subtype` counts as blank (Python compares with its
//! `repr`).
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Map, Value, json};

use crate::api::Error;
use crate::label::{civil_from_days, days_from_civil};
use crate::stock::{py_space, py_strip};
use crate::stock_order::py_float_repr;

const NUM_KEYS: [(&str, &str); 6] = [
    ("psilocybin", "Psilocybin"),
    ("psilocin", "Psilocin"),
    ("baeocystine", "Baeocystine"),
    ("norbaeocystine", "Norbaeocystine"),
    ("norpsilocin", "Norpsilocin"),
    ("aeruginascin", "Aeruginascin"),
];
/// The image's other spellings of a figure (`coa.COA_ALIASES`).
const ALIASES: [(&str, &str); 1] = [("aeruginascin", "aeruginosin")];
const BATCH_SUBTYPES: [&str; 2] = ["Freeze dried", "Dehydrated"];
const LOT_SUBTYPES: [&str; 4] = ["Homogenized", "Extract", "Chocolate", "Honey"];
const STRAIN_MAX: usize = 80;
const NOT_AN_ID: &str = "Not a batch or lot id";

static LOT_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(crate::id_patterns::LOT_ID).expect("LOT_ID"));

/// Python's `float(text)` for the finite numbers of ASCII digits (underscores only between digits), else `None`.
fn py_float(t: &str) -> Option<f64> {
    let b: Vec<char> = t.chars().collect();
    let mut p = 0;
    let mut clean = String::new();
    if matches!(b.first(), Some('+') | Some('-')) {
        clean.push(b[0]);
        p = 1;
    }
    // digits with single underscores between digits
    let digits = |p: &mut usize, clean: &mut String| -> usize {
        let start = *p;
        let mut n = 0;
        while let Some(&c) = b.get(*p) {
            if c.is_ascii_digit() {
                clean.push(c);
                n += 1;
                *p += 1;
            } else if c == '_' && n > 0 && b.get(*p + 1).is_some_and(char::is_ascii_digit) {
                *p += 1;
            } else {
                break;
            }
        }
        *p - start
    };
    let int_len = digits(&mut p, &mut clean);
    let mut frac_len = 0;
    if b.get(p) == Some(&'.') {
        clean.push('.');
        p += 1;
        frac_len = digits(&mut p, &mut clean);
    }
    if int_len == 0 && frac_len == 0 {
        return None;
    }
    if b.get(p) == Some(&'e') {
        clean.push('e');
        p += 1;
        if matches!(b.get(p), Some('+') | Some('-')) {
            clean.push(b[p]);
            p += 1;
        }
        if digits(&mut p, &mut clean) == 0 {
            return None;
        }
    }
    if p != b.len() {
        return None;
    }
    clean.parse::<f64>().ok().filter(|v| v.is_finite())
}

/// `coaedit.number`: "6.51" -> 6.51; "ND" (or blank, for the minor alkaloids) -> 0.0; `None` if it isn't a sensible mg/g
/// figure (finite, from 0 up to but not including 1000), else rounded to 4 places.
pub fn coa_number(text: Option<&str>, required: bool) -> Option<f64> {
    let t = py_strip(text.unwrap_or("")).to_lowercase().replace(',', ".");
    if t == "nd" || t == "n/d" || (t.is_empty() && !required) {
        return Some(0.0);
    }
    let v = py_float(&t)?;
    if !(0.0 <= v && v < 1000.0) {
        return None;
    }
    format!("{v:.4}").parse().ok()
}

/// `date.fromisoformat` (CPython 3.11+) as (year, month, day): `YYYY-MM-DD`, `YYYYMMDD`, and the week dates
/// `YYYY-Www`, `YYYY-Www-D`, `YYYYWww`, `YYYYWwwD`.
fn iso_date(s: &str) -> Option<(i32, u32, u32)> {
    let c: Vec<char> = s.chars().collect();
    let num = |from: usize, to: usize| -> Option<u32> {
        let part = c.get(from..to)?;
        part.iter().all(char::is_ascii_digit).then(|| part.iter().fold(0u32, |a, d| a * 10 + (*d as u32 - '0' as u32)))
    };
    let is = |i: usize, ch: char| c.get(i) == Some(&ch);
    let ymd = |y: u32, m: u32, d: u32| -> Option<(i32, u32, u32)> {
        let y = i32::try_from(y).ok()?;
        (1..=9999).contains(&y).then_some(())?;
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let days = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        (1..=12).contains(&m).then_some(())?;
        (1..=days[(m - 1) as usize]).contains(&d).then_some((y, m, d))
    };
    let week = |y: u32, w: u32, d: u32| -> Option<(i32, u32, u32)> {
        let y = i32::try_from(y).ok()?;
        (1..=9999).contains(&y).then_some(())?;
        (1..=7).contains(&d).then_some(())?;
        let weekday = |days: i64| (days + 3).rem_euclid(7); // 0 = Monday (1970-01-01 was a Thursday)
        let jan1 = weekday(days_from_civil(y, 1, 1));
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let weeks = if jan1 == 3 || (jan1 == 2 && leap) { 53 } else { 52 };
        (1..=weeks).contains(&w).then_some(())?;
        let jan4 = days_from_civil(y, 1, 4);
        let monday = jan4 - weekday(jan4);
        let (ry, rm, rd) = civil_from_days(monday + i64::from(w - 1) * 7 + i64::from(d - 1));
        (1..=9999).contains(&ry).then_some((ry, rm, rd))
    };
    match c.len() {
        10 if is(4, '-') && is(7, '-') => ymd(num(0, 4)?, num(5, 7)?, num(8, 10)?),
        10 if is(4, '-') && is(5, 'W') && is(8, '-') => week(num(0, 4)?, num(6, 8)?, num(9, 10)?),
        8 if c.iter().all(char::is_ascii_digit) => ymd(num(0, 4)?, num(4, 6)?, num(6, 8)?),
        8 if is(4, '-') && is(5, 'W') => week(num(0, 4)?, num(6, 8)?, 1),
        8 if is(4, 'W') => week(num(0, 4)?, num(5, 7)?, num(7, 8)?),
        7 if is(4, 'W') => week(num(0, 4)?, num(5, 7)?, 1),
        _ => None,
    }
}

/// Python's `str(v)` of a JSON scalar (`True`, a float's repr), for the image's own `subtype`; a falsy value, a list and
/// an object are the empty text (the module docs).
fn subtype_text(v: &Value) -> String {
    match v {
        Value::Bool(true) => "True".into(),
        Value::Number(n) => match (n.as_i64(), n.as_u64()) {
            (Some(0), _) | (_, Some(0)) => String::new(),
            (Some(i), _) => i.to_string(),
            (None, Some(u)) => u.to_string(),
            _ => n.as_f64().filter(|f| *f != 0.0).map(py_float_repr).unwrap_or_default(),
        },
        Value::String(s) => s.clone(),
        _ => String::new(),
    }
}

fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// What `coa_edit` answers: the keys to drop, the [key, text] pairs to set in order, and the errors (when there are
/// any, nothing is to be changed).
pub struct Edit {
    pub errors: Vec<String>,
    pub drop: Vec<String>,
    pub set: Vec<(String, String)>,
}

/// `coaedit.apply_edit`. `keys` are the keys of the image's description among the ones this rule reads, `subtype` the
/// value of its `subtype`; `form` the typed fields (absent = blank, but `subtype`'s presence matters).
pub fn coa_edit(keys: &[String], subtype: &Value, uid: &str, psilocybin: Option<&Value>, form: &Map<String, Value>, kind: &str) -> Edit {
    let has = |k: &str| keys.iter().any(|x| x == k);
    let field = |k: &str| form.get(k).and_then(Value::as_str).unwrap_or("");
    let mut out = Edit { errors: vec![], drop: vec!["review".into()], set: vec![] };
    let id = uid.strip_suffix('\n').unwrap_or(uid); // Python's `$` lets one line feed follow
    if !LOT_ID.is_match(id) {
        out.errors.push(NOT_AN_ID.into());
        return out;
    }
    out.set.push(("uid".into(), uid.into()));
    if let Some(p) = psilocybin {
        let text = match (p.as_i64(), p.as_u64()) {
            (Some(i), _) => i.to_string(),
            (None, Some(u)) => u.to_string(),
            _ => p.as_f64().map(py_float_repr).unwrap_or_default(),
        };
        out.set.push(("psilocybin".into(), text));
    }
    out.set.push(("strain".into(), truncate(py_strip(field("strain")), STRAIN_MAX)));
    if form.contains_key("subtype") {
        let st = py_strip(field("subtype"));
        let allowed: &[&str] = match kind {
            "batch" => &BATCH_SUBTYPES,
            "lot" => &LOT_SUBTYPES,
            _ => &[],
        };
        if !st.is_empty() && !allowed.contains(&st) && st != subtype_text(subtype) {
            out.errors.push("Product subtype: pick one from the list".into());
        } else if !st.is_empty() || has("subtype") {
            out.set.push(("subtype".into(), st.into()));
        }
    }
    let sd = py_strip(field("sample_date"));
    if sd.is_empty() {
        out.set.push(("sample_date".into(), String::new()));
    } else if let Some((y, m, d)) = iso_date(sd) {
        out.set.push(("sample_date".into(), format!("{m:02}{d:02}{y:04}")));
    } else {
        out.errors.push("Test date: pick a valid date".into());
    }
    for (k, label) in NUM_KEYS.iter().skip(1) {
        let alias = ALIASES.iter().find(|(a, _)| a == k).map(|(_, b)| *b);
        let recorded = has(k) || alias.is_some_and(has);
        if py_strip(field(k)).is_empty() && *k != "psilocin" && !recorded {
            continue; // never tested/recorded and left blank: don't invent a "0.0"
        }
        match coa_number(form.get(*k).and_then(Value::as_str), *k == "psilocin") {
            None => out.errors.push(format!("{label}: enter a number in mg/g (or ND)")),
            Some(v) => {
                let key = match alias {
                    Some(a) if has(a) && !has(k) => a,
                    _ => k,
                };
                out.set.push((key.to_string(), py_float_repr(v)));
            }
        }
    }
    if !out.errors.is_empty() {
        out.set.clear();
    }
    out
}

/// `infosheet.clean_text`: saved text keeps its line breaks but not stray spaces, control characters or angle brackets.
pub fn clean_text(text: &str, limit: usize) -> String {
    let lines: Vec<String> = text
        .replace('\r', "")
        .split('\n')
        .map(|line| {
            let kept: String = line.chars().filter(|c| !matches!(c, '\u{0}'..='\u{8}' | '\u{b}'..='\u{1f}' | '\u{7f}' | '<' | '>')).collect();
            kept.split(py_space).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ")
        })
        .collect();
    truncate(py_strip(&lines.join("\n")), limit)
}

/// `{raw: {keys, subtype}, uid, psilocybin, form, kind}` -> `{errors, drop, set: [[key, text]]}`.
pub fn coa_edit_json(input: &str) -> Result<String, Error> {
    #[derive(serde::Deserialize)]
    struct Raw {
        keys: Vec<String>,
        #[serde(default)]
        subtype: Value,
    }
    #[derive(serde::Deserialize)]
    struct Input {
        raw: Raw,
        uid: String,
        psilocybin: Option<serde_json::Number>,
        form: Map<String, Value>,
        kind: String,
    }
    let i: Input = serde_json::from_str(input)?;
    if let Some((k, _)) = i.form.iter().find(|(_, v)| !v.is_string() && !v.is_null()) {
        return Err(format!("form: {k} is not text").into());
    }
    let psilocybin = i.psilocybin.map(Value::Number);
    let e = coa_edit(&i.raw.keys, &i.raw.subtype, &i.uid, psilocybin.as_ref(), &i.form, &i.kind);
    Ok(json!({"errors": e.errors, "drop": e.drop, "set": e.set.iter().map(|(k, v)| json!([k, v])).collect::<Vec<_>>()}).to_string())
}

/// `{text, required}` -> `{value}`.
pub fn coa_number_json(input: &str) -> Result<String, Error> {
    #[derive(serde::Deserialize)]
    struct Input {
        text: Option<String>,
        required: bool,
    }
    let i: Input = serde_json::from_str(input)?;
    Ok(json!({"value": coa_number(i.text.as_deref(), i.required)}).to_string())
}

/// `{text, limit}` -> `{text}`.
pub fn clean_text_json(input: &str) -> Result<String, Error> {
    #[derive(serde::Deserialize)]
    struct Input {
        text: Option<String>,
        limit: usize,
    }
    let i: Input = serde_json::from_str(input)?;
    Ok(json!({"text": clean_text(i.text.as_deref().unwrap_or(""), i.limit)}).to_string())
}
