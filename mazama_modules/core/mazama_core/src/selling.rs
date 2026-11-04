//! What may be sold: why `qty` units of a package can't be sold, or nothing, and whether a record is one the server
//! would sell at all (`sellable_record`). One rule for the server (recordrules.unsellable_reason / sellable_record,
//! through the binding) and the phone (lib/sellability.dart, through the FFI), held to
//! mazama_modules/selling/vectors/sellability.json and sellability_cases.json.
//!
//! The holds are checked in a fixed order (pending transfer, locked, flagged, then units) and the first one is the
//! reason. Where an input is odd, the answer is the one that refuses:
//!
//! | Input | Answer |
//! |---|---|
//! | a quantity that isn't a number (text, true, a list or an object) | 0 units: refused |
//! | a value shown in a refusal | `py::show`: `None`, `True`, text as itself, Python's repr of a float, an integer beyond 64 bits as its float (`inf` past the largest double), compact JSON |
//! | no record | `package not found in this service center's inventory` |
//! | sellable_record without a productGuid | false, the quantity never read |
//! | a flag given as text or a number | held when truthy (the safe direction) |
//! | a fractional quantity | compared as it is: 2.5 units sell 2, not 3 |
//! | units asked that aren't an integer of 1 or more | refused: `the quantity to sell must be 1 or more (asked for 0)` |
//!
//! Numbers are read as Python's `json` reads them and compared exactly, so an integer beyond 64 bits is never rounded
//! into a sale. Expired stock is not refused; a failed test doesn't stop a sale.
use serde_json::{Value, json};

pub mod cart;
pub mod pricing;
pub mod sale;

use crate::py::{Int, Py, as_int, less_than, show};

pub use crate::py::py_float_repr;

const NOT_FOUND: &str = "package not found in this service center's inventory";

/// Why `qty` units of `record` can't be sold (None: they can); `None` for the record is "not in the center's inventory".
pub(crate) fn reason(record: Option<&Py>, qty: &Py) -> Option<String> {
    let Some(r) = record else { return Some(NOT_FOUND.into()) };
    let Some(n) = as_int(qty).filter(|n| **n >= Int::one()) else {
        return Some(format!("the quantity to sell must be 1 or more (asked for {})", show(qty)));
    };
    if r.get("pendingTransfer").truthy() {
        return Some("package has a pending transfer".into());
    }
    for (flag, why, word) in [("locked", "reasonLocked", "locked"), ("flagged", "reasonFlagged", "flagged")] {
        if r.get(flag).truthy() {
            let why = r.get(why);
            return Some(format!("package is {word} ({})", if why.truthy() { show(why) } else { "no reason".into() }));
        }
    }
    let quantity = r.get("quantity");
    if r.get("zeroOut").truthy() || less_than(quantity, n) {
        return Some(format!("no units remaining (system reports quantity={}, zeroOut={})", show(quantity), show(r.get("zeroOut"))));
    }
    None
}

/// A record the server would sell: a truthy productGuid, then nothing against one unit (the guid is checked first, so
/// a record without one is never sellable whatever its quantity).
fn sellable_record(record: Option<&Py>) -> bool {
    record.is_some_and(|r| r.get("productGuid").truthy() && reason(Some(r), &Py::Int(Int::one())).is_none())
}

/// `{"checks": [{"record": object | null, "qty": any}]}` in, `[{"reason": string | null, "sellable_record": bool}]` out,
/// one per check, in order (mazama_modules/core/schemas/selling/sellable.*). Every check has an answer; only a record
/// that is neither an object nor null (or input that isn't this shape) is an error.
pub fn sellable_json(input_json: &str) -> Result<String, crate::api::Error> {
    let input = Py::parse(input_json)?;
    let Py::Obj(_) = input else { return Err("selling.sellable: the input must be an object".into()) };
    let Py::List(checks) = input.get("checks") else { return Err("selling.sellable: checks must be a list".into()) };
    let mut out: Vec<Value> = Vec::with_capacity(checks.len());
    for (i, c) in checks.iter().enumerate() {
        let Py::Obj(kv) = c else { return Err(format!("selling.sellable: check {i} must be an object").into()) };
        let has = |k: &str| kv.iter().any(|(have, _)| have == k);
        if !has("record") || !has("qty") {
            return Err(format!("selling.sellable: check {i} needs its record and qty").into());
        }
        let record = match c.get("record") {
            Py::Null => None,
            r @ Py::Obj(_) => Some(r),
            _ => return Err(format!("selling.sellable: check {i}'s record must be an object or null").into()),
        };
        out.push(json!({"reason": reason(record, c.get("qty")), "sellable_record": sellable_record(record)}));
    }
    Ok(serde_json::to_string(&out)?)
}
