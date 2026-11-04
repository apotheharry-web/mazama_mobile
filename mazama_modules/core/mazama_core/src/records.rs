//! The record rules: what a state record means, decided once. A rule takes one state record, the raw JSON object the state system sends (as the server's mirror keeps it,
//! or as a phone uploads it), and answers with a plain value: does it still have stock, which holds does it carry,
//! can it be made into products or transferred. Sellability (`unsellable_reason`, `sellable_record`) is
//! [`crate::selling`]; both read a record with Python's truthiness ([`crate::py`]).
//!
//! The rules are held to the frozen vectors in mazama_modules/records/vectors/ and follow Python's semantics over
//! JSON values: truthiness (`0`, `""`, `[]`, `{}`, `null` and `false` are false),
//! `x or 0`, comparison with 0 (`true` is 1; text, a list or an object can't be compared: TypeError), `float()` of text
//! (ValueError when it isn't a number), `0 + x` and `==` against an id. Where a rule raises, the answer is a
//! [`Raise`]: the server raises the same exception class when it reads that answer (a quantity or analyteWeight that
//! can't be compared with 0). The dry weight is the exception to Python's semantics: every rule reads it through
//! [`dry_grams`], so one that isn't a plain number is none (0 g), never a raise.
//!
//! The rules differ from each other on purpose, each a named answer:
//!
//! - `units_counted` sums the quantity of every record not zeroOut, so a negative quantity lowers a total;
//!   `has_units` leaves it out.
//! - An unreadable dry weight counts as none: every rule reads dryWeight through [`dry_grams`], so a dryWeight that
//!   isn't a plain number is 0 g (no material, nothing can be planned or sold from it), and text that is one is that
//!   number. `has_material_strict` gives the same answer as `has_material` (kept for its callers).
//! - `has_material_or_units` (the manufacturer page's list) vs `has_material`: a process lot with units but no dry
//!   weight is listed but not counted as material.
//! - `is_held` never counts a failed test; `holds` names it.
//! - Sellability names a pending transfer first; `source_problem` names locked first.
//! - A package with failedTest may be sold and transferred (`can_transfer`); a batch/lot with failedTest can't be
//!   made into products (`source_problem`).
//! - `can_transfer` is sellability's holds and units plus who holds the package.
use serde::Deserialize;
use serde_json::{Map, Number, Value, json};

use crate::py::truthy;

/// The exception a rule gives for a record, which the server raises again when it reads the answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Raise {
    TypeError,
    ValueError,
}

/// A rule's answer, or the exception it raises for this record.
pub type Answer<T> = Result<T, Raise>;

/// An answer as JSON: the value, or `{"raises": "TypeError" | "ValueError"}`.
pub fn answer_value(a: &Answer<Value>) -> Value {
    match a {
        Ok(v) => v.clone(),
        Err(Raise::TypeError) => json!({"raises": "TypeError"}),
        Err(Raise::ValueError) => json!({"raises": "ValueError"}),
    }
}

/// The state's five status flags of a record, each false when absent, null or falsy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Flags {
    pub zero_out: bool,
    pub locked: bool,
    pub flagged: bool,
    pub pending_transfer: bool,
    pub failed_test: bool,
}

/// Every record rule's answer for one record.
#[derive(Debug, Clone, PartialEq)]
pub struct Judgement {
    pub flags: Flags,
    /// A package with units on hand: not zeroOut and quantity > 0.
    pub has_units: Answer<bool>,
    /// The units a record adds to a units total: its quantity when not zeroOut, else 0; a negative one counts.
    pub units_counted: Answer<Number>,
    /// A batch/lot with material left: not zeroOut and dryWeight > 0, an unreadable dry weight as 0 ([`dry_grams`]).
    pub has_material: bool,
    /// The same answer as `has_material`, as an [`Answer`] for the callers that take one; it never raises.
    pub has_material_strict: Answer<bool>,
    /// Listed on the manufacturer page: not zeroOut, and dryWeight > 0 or quantity > 0.
    pub has_material_or_units: Answer<bool>,
    /// The state's holds, in one fixed order, only those set: (name, why); a reason without its flag is no hold.
    pub holds: Vec<(&'static str, Value)>,
    /// Locked, flagged or pending a transfer; a failed test isn't counted.
    pub is_held: bool,
    /// Why nothing can be packaged from this batch/lot (None = fine): locked named before pending transfer; a
    /// failed test stops it.
    pub source_problem: Answer<Option<&'static str>>,
}

impl Judgement {
    pub fn to_value(&self) -> Value {
        let f = &self.flags;
        json!({
            "flags": {"zero_out": f.zero_out, "locked": f.locked, "flagged": f.flagged,
                      "pending_transfer": f.pending_transfer, "failed_test": f.failed_test},
            "has_units": answer_value(&self.has_units.map(Value::Bool)),
            "units_counted": answer_value(&self.units_counted.clone().map(Value::Number)),
            "has_material": self.has_material,
            "has_material_strict": answer_value(&self.has_material_strict.map(Value::Bool)),
            "has_material_or_units": answer_value(&self.has_material_or_units.map(Value::Bool)),
            "holds": self.holds.iter().map(|(n, w)| json!([n, w])).collect::<Vec<_>>(),
            "is_held": self.is_held,
            "source_problem": answer_value(&self.source_problem.map(|p| p.map_or(Value::Null, |s| Value::String(s.into())))),
        })
    }
}

static NULL: Value = Value::Null;

fn get<'a>(r: &'a Value, key: &str) -> &'a Value {
    r.get(key).unwrap_or(&NULL)
}


/// The sign of a JSON number: Less, Equal or Greater than 0 (None for NaN, which JSON can't hold).
fn sign(n: &Number) -> Option<std::cmp::Ordering> {
    if let Some(i) = n.as_i64() {
        Some(i.cmp(&0))
    } else if let Some(u) = n.as_u64() {
        Some(u.cmp(&0))
    } else {
        n.as_f64().and_then(|f| f.partial_cmp(&0.0))
    }
}

/// `(v or 0) > 0`.
fn gt0(v: &Value) -> Answer<bool> {
    if !truthy(v) {
        return Ok(false);
    }
    match v {
        Value::Bool(_) => Ok(true), // only true is truthy: True > 0
        Value::Number(n) => Ok(sign(n) == Some(std::cmp::Ordering::Greater)),
        _ => Err(Raise::TypeError),
    }
}

/// `(v or 0) <= 0`.
fn le0(v: &Value) -> Answer<bool> {
    if !truthy(v) {
        return Ok(true);
    }
    match v {
        Value::Bool(_) => Ok(false),
        Value::Number(n) => Ok(matches!(sign(n), Some(std::cmp::Ordering::Less | std::cmp::Ordering::Equal))),
        _ => Err(Raise::TypeError),
    }
}

/// Python's `float(text)`: surrounding whitespace ignored, `_` allowed between digits, `inf`/`infinity`/`nan` in any
/// case, with an optional sign; anything else is a ValueError.
pub(crate) fn py_float_text(s: &str) -> Answer<f64> {
    // CPython first writes a non-ASCII space as a space and a non-ASCII decimal digit as its ASCII digit; any other
    // character that isn't ASCII can't be part of a number (ASCII is kept as it is: U+001C..U+001F are no spaces here)
    let ascii: String = s
        .chars()
        .map(|c| match c {
            c if c.is_ascii() => c,
            c if crate::names::py_space(c) => ' ',
            c if crate::names::is_nd(c) => char::from_digit(crate::names::nd_value(c), 10).unwrap(),
            _ => '?',
        })
        .collect();
    let t = ascii.trim();
    let chars: Vec<char> = t.chars().collect();
    let mut clean = String::with_capacity(t.len());
    for (i, c) in chars.iter().enumerate() {
        if *c == '_' {
            let digit_before = i > 0 && chars[i - 1].is_ascii_digit();
            let digit_after = chars.get(i + 1).is_some_and(|n| n.is_ascii_digit());
            if !(digit_before && digit_after) {
                return Err(Raise::ValueError);
            }
        } else {
            clean.push(*c);
        }
    }
    let body = clean.strip_prefix(['+', '-']).unwrap_or(&clean);
    let word = body.to_ascii_lowercase();
    let ok = if matches!(word.as_str(), "inf" | "infinity" | "nan") {
        true
    } else {
        decimal(body)
    };
    if !ok {
        return Err(Raise::ValueError);
    }
    clean.parse::<f64>().map_err(|_| Raise::ValueError)
}

/// `digits [. digits] [e [sign] digits]` or `. digits [...]`, ASCII digits only.
fn decimal(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    let int_digits = b.iter().take_while(|c| c.is_ascii_digit()).count();
    i += int_digits;
    let mut frac_digits = 0;
    if b.get(i) == Some(&b'.') {
        i += 1;
        frac_digits = b[i..].iter().take_while(|c| c.is_ascii_digit()).count();
        i += frac_digits;
    }
    if int_digits + frac_digits == 0 {
        return false;
    }
    if matches!(b.get(i), Some(b'e' | b'E')) {
        i += 1;
        if matches!(b.get(i), Some(b'+' | b'-')) {
            i += 1;
        }
        let exp = b[i..].iter().take_while(|c| c.is_ascii_digit()).count();
        if exp == 0 {
            return false;
        }
        i += exp;
    }
    i == b.len()
}

/// A record's dry weight in grams, as every rule reads it (unreadable counts as none). A JSON number is itself (a negative one stays negative); text that is a plain number is that number, read as
/// Python's `float()` reads it (surrounding whitespace, `_` between digits, an exponent: `"5"`, `" 5 "`, `"5.5"`,
/// `"1e2"`); anything else (other text, `""`, `"NaN"`, `"inf"`, text too big for a finite number, true/false, a list,
/// an object, null or absent) is none, 0 g.
pub fn dry_grams(v: &Value) -> f64 {
    match v {
        Value::Number(n) => n.as_f64().filter(|f| f.is_finite()).unwrap_or(0.0),
        Value::String(s) => py_float_text(s).ok().filter(|f| f.is_finite()).unwrap_or(0.0),
        _ => 0.0,
    }
}

/// `{values: [dryWeight]}` -> `[grams]`: each record's dry weight in grams as every record rule reads it
/// ([`dry_grams`]), for the grams the pages show and weigh out.
pub fn dry_grams_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Input {
        values: Vec<Value>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let out: Vec<Value> = input.values.iter().map(|v| json!(dry_grams(v))).collect();
    Ok(Value::Array(out).to_string())
}

/// `0 + (v or 0)`: an int stays an int, true is 1.
fn plus0(v: &Value) -> Answer<Number> {
    if !truthy(v) {
        return Ok(Number::from(0));
    }
    match v {
        Value::Bool(_) => Ok(Number::from(1)),
        Value::Number(n) => Ok(n.clone()),
        _ => Err(Raise::TypeError),
    }
}

/// Python's `v == id` for an int id (`225.0 == 225`, `True == 1`; text is never equal), or for no id (`None == None`:
/// only a missing or null value).
fn eq_id(v: &Value, id: Option<i64>) -> bool {
    let Some(id) = id else { return v.is_null() };
    match v {
        Value::Bool(b) => i64::from(*b) == id,
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i == id
            } else if n.as_u64().is_some() {
                false // above i64::MAX, so not an i64 id
            } else {
                n.as_f64().is_some_and(|f| f == id as f64)
            }
        }
        _ => false,
    }
}

/// The state's flags of a record.
pub fn flags(r: &Value) -> Flags {
    Flags {
        zero_out: truthy(get(r, "zeroOut")),
        locked: truthy(get(r, "locked")),
        flagged: truthy(get(r, "flagged")),
        pending_transfer: truthy(get(r, "pendingTransfer")),
        failed_test: truthy(get(r, "failedTest")),
    }
}

fn holds(r: &Value, f: &Flags) -> Vec<(&'static str, Value)> {
    let why = |key: &str| {
        let v = get(r, key);
        if truthy(v) { v.clone() } else { Value::String(String::new()) }
    };
    let mut out = Vec::new();
    if f.locked {
        out.push(("locked", why("reasonLocked")));
    }
    if f.flagged {
        out.push(("flagged", why("reasonFlagged")));
    }
    if f.pending_transfer {
        out.push(("pending transfer", Value::String(String::new())));
    }
    if f.failed_test {
        out.push(("failed test", Value::String(String::new())));
    }
    out
}

fn source_problem(r: &Value, f: &Flags) -> Answer<Option<&'static str>> {
    if f.zero_out || dry_grams(get(r, "dryWeight")) <= 0.0 {
        return Ok(Some("There is no weight left in it."));
    }
    for (set, why) in [(f.locked, "It is locked."), (f.flagged, "It is flagged."),
                       (f.pending_transfer, "It has a pending transfer."), (f.failed_test, "It has failed a test.")] {
        if set {
            return Ok(Some(why));
        }
    }
    if le0(get(r, "analyteWeight"))? {
        return Ok(Some("It has no potency result, so a TPE dose can't be worked out."));
    }
    Ok(None)
}

/// Every rule's answer for one record.
pub fn judge_one(r: &Value) -> Judgement {
    let f = flags(r);
    let qty = get(r, "quantity");
    let dry = dry_grams(get(r, "dryWeight"));
    Judgement {
        flags: f,
        has_units: if f.zero_out { Ok(false) } else { gt0(qty) },
        units_counted: if f.zero_out { Ok(Number::from(0)) } else { plus0(qty) },
        has_material: !f.zero_out && dry > 0.0,
        has_material_strict: Ok(!f.zero_out && dry > 0.0),
        has_material_or_units: if f.zero_out || dry > 0.0 { Ok(!f.zero_out) } else { gt0(qty) },
        holds: holds(r, &f),
        is_held: f.locked || f.flagged || f.pending_transfer,
        source_problem: source_problem(r, &f),
    }
}

/// Every rule's answer for each record, in order: a whole list is judged in one call.
pub fn judge(records: &[Value]) -> Vec<Judgement> {
    records.iter().map(judge_one).collect()
}

/// A package that can go on a transfer: held by the org with state id `holder_state_id` (the center for "retrieve",
/// else the manufacturer, with no center), in stock, not locked, flagged or already in a transfer. A failed test
/// doesn't stop it: it is sellability's holds and units, plus the holder.
pub fn can_transfer_one(p: &Value, holder_state_id: Option<i64>, mode: &str) -> Answer<bool> {
    let mine = if mode == "retrieve" {
        eq_id(get(p, "serviceCenterId"), holder_state_id)
    } else {
        eq_id(get(p, "manufacturerId"), holder_state_id) && !truthy(get(p, "serviceCenterId"))
    };
    if !mine || !gt0(get(p, "quantity"))? {
        return Ok(false);
    }
    let f = flags(p);
    Ok(!f.zero_out && !f.locked && !f.flagged && !f.pending_transfer)
}

/// `can_transfer_one` for each record, in order.
pub fn can_transfer(records: &[Value], holder_state_id: Option<i64>, mode: &str) -> Vec<Answer<bool>> {
    records.iter().map(|p| can_transfer_one(p, holder_state_id, mode)).collect()
}

fn objects(records: Vec<Map<String, Value>>) -> Vec<Value> {
    records.into_iter().map(Value::Object).collect()
}

/// `{"records": [object]}` in, `[Judgement]` out (mazama_modules/core/schemas/records/judge.*).
pub fn judge_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Input {
        records: Vec<Map<String, Value>>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let out: Vec<Value> = judge(&objects(input.records)).iter().map(Judgement::to_value).collect();
    Ok(serde_json::to_string(&out)?)
}

/// `{"records": [object], "holder_state_id": int | null, "mode": str}` in, `[bool | {"raises": ...}]` out.
pub fn can_transfer_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Input {
        records: Vec<Map<String, Value>>,
        holder_state_id: Value, // required: null or an integer
        mode: String,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let holder = match &input.holder_state_id {
        Value::Null => None,
        v => Some(v.as_i64().ok_or("records.can_transfer: holder_state_id must be an integer or null")?),
    };
    let out: Vec<Value> = can_transfer(&objects(input.records), holder, &input.mode)
        .into_iter()
        .map(|a| answer_value(&a.map(Value::Bool)))
        .collect();
    Ok(serde_json::to_string(&out)?)
}
