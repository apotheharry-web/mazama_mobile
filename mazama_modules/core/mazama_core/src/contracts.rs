//! Which state records and licenses the apps can use (specs/core row 10, SM-21), held to the frozen vectors in
//! mazama_modules/contracts/vectors/ (the server's own Python under CPython 3.14, the reference):
//!
//! - [`package_keys`]: the state id and PKPR of each GetPackagedProducts record, or the server's reason for skipping
//!   it (`state/mapping.packaged_product`'s first lines).
//! - [`service_centers`]: which GetApplicableLicenses entries are service centers, with id, name and license
//!   (`directory.service_centers`).
//!
//! The readings are Python's: an id is `Decimal(str(v))` taken as a whole number, text is `str(v).strip()`. Known
//! limits, each a documented ruling rather than the reference's behaviour:
//!
//! - an id is kept only while it fits in 64 bits (`1e100`, `9223372036854775808`); beyond that the record is skipped
//!   as having no numeric id, where Python would hand a number no column could hold;
//! - only ASCII digits count, where `Decimal` also reads other scripts' decimal digits (`١٢٣`);
//! - a list or an object as an id, a PKPR, a name or a license id counts as blank, where Python's `str()` would show
//!   its repr (both apps read one today under different texts; the core won't invent one).
use serde_json::{Value, json};

use crate::api::Error;
use crate::stock::{py_space, py_strip};
use crate::stock_order::py_float_repr;

const NO_ID: &str = "a package record has no numeric id";

/// Python's `str(v)` of a JSON value, for the values `text()` reads: a list or an object has none (see the module
/// docs) and comes back as `None`.
fn py_str(v: &Value) -> Option<String> {
    Some(match v {
        Value::Bool(b) => if *b { "True".into() } else { "False".into() },
        Value::Number(n) => match (n.as_i64(), n.as_u64()) {
            (Some(i), _) => i.to_string(),
            (None, Some(u)) => u.to_string(),
            _ => py_float_repr(n.as_f64()?),
        },
        Value::String(s) => s.clone(),
        Value::Null | Value::Array(_) | Value::Object(_) => return None,
    })
}

/// `mapping.text`: `str(v).strip()`, or `None` when the field is absent, null or blank.
fn py_text(v: &Value) -> Option<String> {
    let s = py_str(v)?;
    let t = py_strip(&s);
    (!t.is_empty()).then(|| t.to_string())
}

/// `mapping.whole`: `Decimal(str(v))` when it is a whole number — an int, a float with no fraction, or text of one —
/// and `None` for anything else (a bool, blank, a fraction, infinity, NaN, text that is not a number).
fn py_whole(v: &Value) -> Option<i64> {
    match v {
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
        Value::Number(n) => match (n.as_i64(), n.is_u64()) {
            (Some(i), _) => Some(i),
            (None, true) => None, // above i64::MAX
            _ => {
                let f = n.as_f64()?;
                f.is_finite().then(|| decimal_whole(&py_float_repr(f)))?
            }
        },
        Value::String(s) => decimal_whole(s),
    }
}

/// `Decimal(text)` taken as a whole number. Python's constructor strips surrounding whitespace (U+001C..U+001F
/// included) and ignores `_`; interior whitespace, infinity, NaN and anything else that is not a decimal number give
/// `None`, as does a number with a fraction left or one beyond 64 bits.
fn decimal_whole(text: &str) -> Option<i64> {
    let stripped = py_strip(text);
    if stripped.is_empty() || stripped.chars().any(py_space) {
        return None;
    }
    let body: Vec<char> = stripped.chars().filter(|c| *c != '_').collect();
    let mut p = 0;
    let negative = match body.first() {
        Some('+') => {
            p = 1;
            false
        }
        Some('-') => {
            p = 1;
            true
        }
        _ => false,
    };
    let mut digits = String::new();
    while body.get(p).is_some_and(char::is_ascii_digit) {
        digits.push(body[p]);
        p += 1;
    }
    let mut fraction = 0usize;
    if body.get(p) == Some(&'.') {
        p += 1;
        while body.get(p).is_some_and(char::is_ascii_digit) {
            digits.push(body[p]);
            fraction += 1;
            p += 1;
        }
    }
    if digits.is_empty() {
        return None; // "", ".", "Infinity", "NaN", "0x10", "e3": no number, or none that is finite
    }
    let mut exponent: i64 = 0;
    if matches!(body.get(p), Some('e') | Some('E')) {
        p += 1;
        let sign = match body.get(p) {
            Some('+') => {
                p += 1;
                1
            }
            Some('-') => {
                p += 1;
                -1
            }
            _ => 1,
        };
        let start = p;
        let mut e: i64 = 0;
        while body.get(p).is_some_and(char::is_ascii_digit) {
            e = (e.saturating_mul(10).saturating_add(i64::from(body[p] as u8 - b'0'))).min(1 << 40);
            p += 1;
        }
        if p == start {
            return None;
        }
        exponent = sign * e;
    }
    if p != body.len() {
        return None;
    }
    if digits.bytes().all(|c| c == b'0') {
        return Some(0); // every exponent: zero is a whole number, and -0 is 0
    }
    let shift = exponent - fraction as i64;
    let whole = if shift >= 0 {
        if shift > 40 {
            return None; // beyond 64 bits
        }
        format!("{digits}{}", "0".repeat(shift as usize))
    } else {
        let cut = (-shift) as usize;
        if cut >= digits.len() {
            return None; // below 1 with digits left: not a whole number
        }
        let (head, tail) = digits.split_at(digits.len() - cut);
        if !tail.bytes().all(|c| c == b'0') {
            return None; // a fraction
        }
        head.to_string()
    };
    let whole = whole.trim_start_matches('0');
    if whole.len() > 38 {
        return None;
    }
    let value: i128 = whole.parse().ok()?;
    i64::try_from(if negative { -value } else { value }).ok()
}

/// One answer per record, in the order given: `{"state_id", "pkpr"}` for a record the server would map, or
/// `{"problem"}` with the words it skips the rest under. A record that is not an object is no record: the server's
/// own mapper raises on one, so this refuses the call.
pub fn package_keys(records: &[Value]) -> Result<Vec<Value>, Error> {
    records
        .iter()
        .map(|r| {
            let record = r.as_object().ok_or_else(|| -> Error { "records: a record is not an object".into() })?;
            let field = |k: &str| record.get(k).unwrap_or(&Value::Null).clone();
            Ok(match (py_whole(&field("id")), py_text(&field("productGuid"))) {
                (None, _) => json!({"problem": NO_ID}),
                (Some(state_id), None) => json!({"problem": format!("package record {state_id} has no PKPR id")}),
                (Some(state_id), Some(pkpr)) => json!({"state_id": state_id, "pkpr": pkpr}),
            })
        })
        .collect()
}

/// The ServiceCenter entries of a GetApplicableLicenses answer, in the order given: `licenseType` exactly
/// `ServiceCenter`, a whole-number id above 0, the first entry for an id, a blank name shown as
/// "Service center &lt;id&gt;", a blank license id `null`. Anything else is skipped.
pub fn service_centers(licenses: &[Value]) -> Vec<Value> {
    let mut seen: std::collections::HashSet<i64> = std::collections::HashSet::new();
    let mut out = Vec::new();
    for entry in licenses {
        let Some(license) = entry.as_object() else { continue };
        if license.get("licenseType").and_then(Value::as_str) != Some("ServiceCenter") {
            continue;
        }
        let field = |k: &str| license.get(k).unwrap_or(&Value::Null).clone();
        let Some(state_id) = py_whole(&field("id")) else { continue };
        if state_id <= 0 || !seen.insert(state_id) {
            continue;
        }
        let name = py_text(&field("licenseName")).unwrap_or_else(|| format!("Service center {state_id}"));
        out.push(json!({"state_id": state_id, "name": name, "license": py_text(&field("licenseId"))}));
    }
    out
}

/// `{"records": [object]}` -> `[{"state_id", "pkpr"} | {"problem"}]`.
pub fn package_keys_json(input: &str) -> Result<String, Error> {
    #[derive(serde::Deserialize)]
    struct Input {
        records: Vec<Value>,
    }
    let i: Input = serde_json::from_str(input)?;
    Ok(Value::Array(package_keys(&i.records)?).to_string())
}

/// `{"licenses": [any]}` -> `[{"state_id", "name", "license"}]`.
pub fn service_centers_json(input: &str) -> Result<String, Error> {
    #[derive(serde::Deserialize)]
    struct Input {
        licenses: Vec<Value>,
    }
    let i: Input = serde_json::from_str(input)?;
    Ok(Value::Array(service_centers(&i.licenses)).to_string())
}
