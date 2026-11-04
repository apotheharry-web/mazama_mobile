//! The dose rules: a unit's mg TPE (`unit_mg`, `ceil_mg`) and, for a whole sale, its raw psilocybin, the 50 mg cap
//! and the minimum session length (`sale_limits`). One rule for the server (mazama_sales' dose.py and
//! selling.sale_limits, through the binding) and the phone (lib/dose.dart, through the FFI), held to
//! mazama_modules/dose/vectors/ and selling/vectors/dose_limits.json.
//!
//! The cap fallback's strongest lot (`highest_lot`): the lot a line its lots can't cover is counted on.
//!
//! A unit's mg TPE: the record's `weightPerUnit` (g) x the lot's TPE (mg/g) when the caller has one, else x the state
//! record's `analyteWeight` (mg/g, 0 or null = none), rounded **up** to a whole mg, ceil(x - 1e-9): in f64, in that
//! order (`w * per_g`, then `- 1e-9`, then ceil), so only float noise is forgiven and the mg shown is never below what
//! the unit holds.
//!
//! A sale's psilocybin: the sum over its lines of `weightPerUnit` x `analyteWeight` x units, the state record's raw
//! psilocybin (not TPE: mg TPE is not subject to the cap). The sale is allowed up to and including 50 mg; the minimum
//! session length is looked up from the total (and from the initial-dose lines' total) in the table below.
//!
//! | Input | Answer |
//! |---|---|
//! | the sum | exact decimals of each figure's shortest digits (Python's `Decimal(repr(float))`), never rounded; a figure with more than 6 decimal places, below 0.000001 or of a billion or more isn't usable, so a total fits |
//! | a figure that isn't a number, a negative one, units that aren't an integer from 0 to a million | the sale refused, [`UNUSABLE`] |
//! | a figure null, absent or 0 on a line that sells units | the sale refused, [`UNKNOWN`] |
//! | the total in the over-cap message | rounded up to 0.1: an over-cap total never reads as 50.0 |
//! | unit mg: a weightPerUnit or analyteWeight that isn't a JSON number or null | unknown (`null`) |
//! | unit mg: a negative figure | unchanged: a negative mg (pinned by the vectors) |
//! | unit mg: a product that isn't finite, or a mg beyond 64 bits | unknown (`null`) |
//!
//! The input is read as Python's `json` reads it (crate::py): an integer keeps its digits, a key given twice its last
//! value. The cap and the session table are mazama_modules/selling/rules.yaml's "dose" (a test holds them equal). A
//! total past i128 (more than a hundred lines of figures at their bounds, each a million units) is refused as
//! [`UNUSABLE`], never a panic.
use serde_json::{Value, json};

use crate::py::{Py, py_float_repr};

/// Only floating-point noise is forgiven when an mg figure is rounded up: ceil(x - 1e-9), so 12.0000000001 is 12.
const NOISE: f64 = 1e-9;

/// rules.yaml dose.max_psilocybin_mg_per_sale.
pub const MAX_PSILOCYBIN_MG_PER_SALE: i128 = 50;

/// rules.yaml dose.session_minutes: (limit in tenths of a mg, inclusive (`up_to_mg`), minutes). The first row whose
/// limit the total is below (or, for an inclusive row, at) gives the minutes: under 2.5 mg 30, under 5 mg 60, under
/// 10 mg 120, under 15 mg 180, under 25 mg 240, under 35 mg 300, up to 50 mg 360.
pub const SESSION_MINUTES: [(i128, bool, i64); 7] =
    [(25, false, 30), (50, false, 60), (100, false, 120), (150, false, 180), (250, false, 240), (350, false, 300), (500, true, 360)];

/// The most decimal places a figure in the cap may have, and so the smallest one (0.000001).
const DECIMALS_MAX: i64 = 6;

/// The most units one line may sell.
const QTY_MAX: i64 = 1_000_000;

pub const UNUSABLE: &str = "This sale's psilocybin can't be worked out (a unit's weightPerUnit or analyteWeight is not a \
                            usable number), so it can't be sold here.";
pub const UNKNOWN: &str = "This sale holds a unit whose psilocybin isn't known (no weightPerUnit or analyteWeight), so it \
                           can't be sold here.";

// --- unit mg --------------------------------------------------------------------------------------------------------

/// A JSON number as Python's `float()` gives it (an integer at any size correctly rounded; past the largest double,
/// infinite), or None for anything else.
fn float_of(v: &Py) -> Option<f64> {
    match v {
        Py::Int(n) => Some(n.as_f64()),
        Py::Float(x) => Some(*x),
        _ => None,
    }
}

/// x rounded up to a whole mg, ceil(x - 1e-9); None when x isn't finite or the result is beyond 64 bits.
pub(crate) fn ceil(x: f64) -> Option<i64> {
    if !x.is_finite() {
        return None;
    }
    let c = (x - NOISE).ceil();
    // every integral double from -2**63 up to (not including) 2**63 is an i64 exactly
    (c >= -9_223_372_036_854_775_808.0 && c < 9_223_372_036_854_775_808.0).then_some(c as i64)
}

/// The mg/g a unit's mg TPE is worked out from and its mg TPE: the lot's TPE, else the state's psilocybin (0 or null =
/// none), with the unit weight `weightPerUnit` in grams (null = 0); both None when a figure isn't a JSON number or
/// null; the mg None when no potency is known or the product isn't finite or fits no i64.
fn unit(record: &Py, tpe: Option<f64>) -> (Option<f64>, Option<i64>) {
    let (w, s) = (record.get("weightPerUnit"), record.get("analyteWeight"));
    let readable = |v: &Py| matches!(v, Py::Null | Py::Int(_) | Py::Float(_));
    if !readable(w) || !readable(s) {
        return (None, None);
    }
    let w = float_of(w).unwrap_or(0.0);
    let s = float_of(s).filter(|x| *x != 0.0);
    let Some(per_g) = tpe.or(s) else { return (None, None) };
    (Some(per_g), ceil(w * per_g))
}

fn object<'a>(v: &'a Py, what: &str) -> Result<&'a Py, crate::api::Error> {
    match v {
        Py::Obj(_) => Ok(v),
        _ => Err(format!("{what} must be an object").into()),
    }
}

fn list<'a>(v: &'a Py, key: &str, what: &str) -> Result<&'a [Py], crate::api::Error> {
    match v.get(key) {
        Py::List(items) => Ok(items),
        _ => Err(format!("{what}: {key} must be a list").into()),
    }
}

fn has(v: &Py, key: &str) -> bool {
    matches!(v, Py::Obj(kv) if kv.iter().any(|(k, _)| k == key))
}

/// A float as JSON; null for one JSON can't hold (infinite: a number given past the largest double).
fn float_json(x: Option<f64>) -> Value {
    x.and_then(serde_json::Number::from_f64).map_or(Value::Null, Value::Number)
}

/// `{"units": [{"record": object, "tpe": number | null}]}` in (tpe absent = null), `[{"tpe_per_g": number | null,
/// "tpe_mg": int | null}]` out, one per unit (schemas/dose/unit_mg.*). Only the wrong shape is an error.
pub fn unit_mg_json(input_json: &str) -> Result<String, crate::api::Error> {
    let input = Py::parse(input_json)?;
    object(&input, "dose.unit_mg: the input")?;
    let units = list(&input, "units", "dose.unit_mg")?;
    let mut out = Vec::with_capacity(units.len());
    for (i, u) in units.iter().enumerate() {
        object(u, &format!("dose.unit_mg: unit {i}"))?;
        if !has(u, "record") {
            return Err(format!("dose.unit_mg: unit {i} needs its record").into());
        }
        let record = object(u.get("record"), &format!("dose.unit_mg: unit {i}'s record"))?;
        let tpe = match u.get("tpe") {
            Py::Null => None,
            t @ (Py::Int(_) | Py::Float(_)) => float_of(t),
            _ => return Err(format!("dose.unit_mg: unit {i}'s tpe must be a number or null").into()),
        };
        let (per_g, mg) = unit(record, tpe);
        out.push(json!({"tpe_per_g": float_json(per_g), "tpe_mg": mg}));
    }
    Ok(serde_json::to_string(&out)?)
}

/// `{"xs": [number]}` in, `[int | null]` out: each x rounded up, ceil(x - 1e-9), null when it isn't finite or
/// fits no i64.
pub fn ceil_mg_json(input_json: &str) -> Result<String, crate::api::Error> {
    let input = Py::parse(input_json)?;
    object(&input, "dose.ceil_mg: the input")?;
    let xs = list(&input, "xs", "dose.ceil_mg")?;
    let mut out = Vec::with_capacity(xs.len());
    for (i, x) in xs.iter().enumerate() {
        let Some(x) = float_of(x) else { return Err(format!("dose.ceil_mg: x {i} must be a number").into()) };
        out.push(json!(ceil(x)));
    }
    Ok(serde_json::to_string(&out)?)
}

// --- the strongest lot ------------------------------------------------------------------------------------------------

/// A figure of a lot as the strongest-lot pick reads it: None when it can't be used (not a JSON number or null, not
/// finite, or negative), else its value (null or absent as 0).
fn pick_figure(v: &Py) -> Option<f64> {
    match v {
        Py::Null => Some(0.0),
        Py::Int(_) | Py::Float(_) => float_of(v).filter(|x| x.is_finite() && *x >= 0.0),
        _ => None,
    }
}

/// `{"lots": [{"weightPerUnit", "analyteWeight"}]}` -> `{"index": int | null}` (schemas/dose/highest_lot.*): the lot a
/// line its lots can't cover is counted on, so it is never counted lower than any lot it could draw. The first, in the
/// lots' order, of the highest rank: a figure that can't be used, then unknown potency (a figure 0 or null), then the
/// largest weightPerUnit x analyteWeight (a 64-bit float product; a tie keeps the earlier lot). No lots: null.
pub fn highest_lot_json(input_json: &str) -> Result<String, crate::api::Error> {
    let input = Py::parse(input_json)?;
    object(&input, "dose.highest_lot: the input")?;
    let lots = list(&input, "lots", "dose.highest_lot")?;
    let mut best: Option<(usize, u8, f64)> = None; // (index, rank, product)
    for (i, lot) in lots.iter().enumerate() {
        object(lot, &format!("dose.highest_lot: lot {i}"))?;
        let (rank, product) = match (pick_figure(lot.get("weightPerUnit")), pick_figure(lot.get("analyteWeight"))) {
            (Some(w), Some(a)) if w != 0.0 && a != 0.0 => (0, w * a),
            (Some(_), Some(_)) => (1, 0.0),
            _ => (2, 0.0),
        };
        best = match best {
            Some((_, rb, pb)) if rank > rb || (rank == rb && rank == 0 && product > pb) => Some((i, rank, product)),
            None => Some((i, rank, product)),
            kept => kept,
        };
    }
    Ok(json!({"index": best.map(|(i, _, _)| i)}).to_string())
}

// --- the cap ----------------------------------------------------------------------------------------------------------

/// An exact decimal, `coeff / 10**scale`, as Python's Decimal keeps it (the exponent is `-scale`; trailing zeros kept).
#[derive(Debug, Clone, Copy, PartialEq)]
struct Dec {
    coeff: i128,
    scale: u32,
}

impl Dec {
    const ZERO: Dec = Dec { coeff: 0, scale: 0 };

    /// Python's Decimal product: exponents add.
    fn mul(self, o: Dec) -> Option<Dec> {
        Some(Dec { coeff: self.coeff.checked_mul(o.coeff)?, scale: self.scale.checked_add(o.scale)? })
    }

    /// Python's Decimal sum: exact, with the smaller exponent.
    fn add(self, o: Dec) -> Option<Dec> {
        let scale = self.scale.max(o.scale);
        Some(Dec { coeff: self.rescaled(scale)?.checked_add(o.rescaled(scale)?)?, scale })
    }

    fn rescaled(self, scale: u32) -> Option<i128> {
        self.coeff.checked_mul(10i128.checked_pow(scale - self.scale)?)
    }

    /// `self` against `tenths / 10`, exactly.
    fn cmp_tenths(self, tenths: i128) -> Option<std::cmp::Ordering> {
        if self.scale >= 1 {
            Some(self.coeff.cmp(&tenths.checked_mul(10i128.checked_pow(self.scale - 1)?)?))
        } else {
            Some(self.coeff.checked_mul(10)?.cmp(&tenths))
        }
    }

    /// Rounded up to a whole tenth (ROUND_CEILING; a total is never negative), as text: "50.1", "72.0".
    fn ceil_tenths_text(self) -> Option<String> {
        let tenths = if self.scale >= 1 {
            let d = 10i128.checked_pow(self.scale - 1)?;
            self.coeff / d + i128::from(self.coeff % d != 0)
        } else {
            self.coeff.checked_mul(10)?
        };
        Some(format!("{}.{}", tenths / 10, tenths % 10))
    }

    /// Python's `str(Decimal)` of a value that is never negative: plain digits while the exponent is at most 0 and the
    /// adjusted exponent at least -6, else scientific ("1E-12", "0E-12").
    fn text(self) -> String {
        let digits = self.coeff.unsigned_abs().to_string();
        let exp = -i64::from(self.scale);
        if exp == 0 {
            return digits;
        }
        let adjusted = exp + digits.len() as i64 - 1;
        if adjusted >= -6 {
            let point = digits.len() as i64 + exp; // the decimal point's place, counted from the left
            return if point > 0 {
                format!("{}.{}", &digits[..point as usize], &digits[point as usize..])
            } else {
                format!("0.{}{digits}", "0".repeat((-point) as usize))
            };
        }
        let rest = if digits.len() > 1 { format!(".{}", &digits[1..]) } else { String::new() };
        format!("{}{rest}E{adjusted}", &digits[..1])
    }
}

/// A figure in the cap.
enum Figure {
    /// null, absent or 0: the unit's psilocybin isn't known.
    Unknown,
    /// not a number, negative, a billion or more, or more than 6 decimal places.
    Unusable,
    Exact(Dec),
}

/// An unsigned decimal text as Python's `Decimal(text)` reads it ("7.25", "1e-06", "5.0"): its coefficient and its
/// scale (minus the exponent); None past i128.
fn decimal_of(text: &str) -> Option<(i128, i64)> {
    let (mant, exp) = match text.split_once(['e', 'E']) {
        Some((m, e)) => (m, e.parse::<i64>().ok()?),
        None => (text, 0),
    };
    let (int, frac) = mant.split_once('.').unwrap_or((mant, ""));
    let coeff = format!("{int}{frac}").parse::<i128>().ok()?;
    Some((coeff, frac.len() as i64 - exp))
}

/// A figure as the cap reads it: an integer within 64 bits exactly, any other number
/// through its float's shortest digits (Python's repr); then 0 is unknown, and a figure is usable only when it is
/// positive, below a billion and has at most 6 decimal places (so at least 0.000001).
fn figure(v: &Py) -> Figure {
    let (coeff, scale) = match v {
        Py::Null => return Figure::Unknown,
        Py::Int(n) => match n.as_i64() {
            Some(i) => (i128::from(i), 0),
            None => return Figure::Unusable, // beyond 64 bits: past a billion either way
        },
        Py::Float(x) if x.is_finite() => match decimal_of(py_float_repr(*x).trim_start_matches('-')) {
            Some((c, s)) => (if x.is_sign_negative() { -c } else { c }, s),
            None => return Figure::Unusable,
        },
        _ => return Figure::Unusable,
    };
    if coeff == 0 {
        return Figure::Unknown;
    }
    if coeff < 0 || scale < 0 {
        return Figure::Unusable; // negative, or written with a positive exponent: 1e+16 and up
    }
    let (mut c, mut s) = (coeff, scale); // normalised: the fewest decimal places it has
    while s > 0 && c % 10 == 0 {
        c /= 10;
        s -= 1;
    }
    if s > DECIMALS_MAX {
        return Figure::Unusable; // more than 6 decimal places, or below 0.000001
    }
    let scale = scale as u32; // at most 6 and the trailing zeros of a coefficient within i128
    if 10i128.checked_pow(scale).and_then(|p| p.checked_mul(1_000_000_000)).is_some_and(|billion| coeff >= billion) {
        return Figure::Unusable; // a billion or more
    }
    Figure::Exact(Dec { coeff, scale })
}

/// The session length for `total` (rules.yaml dose.session_minutes); None above the cap.
fn session_minutes(total: Dec) -> Option<i64> {
    use std::cmp::Ordering::{Equal, Less};
    for (limit, inclusive, minutes) in SESSION_MINUTES {
        match total.cmp_tenths(limit)? {
            Less => return Some(minutes),
            Equal if inclusive => return Some(minutes),
            _ => {}
        }
    }
    None
}

fn refused(why: &str) -> Value {
    json!({"psilocybin_mg": null, "allowed": false, "error": why, "session_minutes": null, "session_minutes_initial": null})
}

/// One sale: its lines' raw psilocybin (weightPerUnit g x analyteWeight mg/g x units) summed exactly, the cap (over
/// 50 mg is refused; exactly 50 is allowed), its message and both session lengths (all lines; the initial-dose lines).
fn limits(lines: &[Py]) -> Value {
    let (mut total, mut initial) = (Dec::ZERO, Dec::ZERO);
    let mut unknown = false;
    for line in lines {
        let record = line.get("record");
        let (w, a) = (figure(record.get("weightPerUnit")), figure(record.get("analyteWeight")));
        let qty = match line.get("qty") {
            Py::Int(n) => n.as_i64().filter(|q| (0..=QTY_MAX).contains(q)),
            _ => None,
        };
        let (Some(q), false, false) = (qty, matches!(w, Figure::Unusable), matches!(a, Figure::Unusable)) else {
            return refused(UNUSABLE);
        };
        let (Figure::Exact(w), Figure::Exact(a)) = (w, a) else {
            unknown = unknown || q > 0;
            continue;
        };
        let Some(mg) = w.mul(a).and_then(|x| x.mul(Dec { coeff: i128::from(q), scale: 0 })) else { return refused(UNUSABLE) };
        let Some(t) = total.add(mg) else { return refused(UNUSABLE) };
        total = t;
        if matches!(line.get("dose"), Py::Str(d) if d == "initial") {
            let Some(i) = initial.add(mg) else { return refused(UNUSABLE) };
            initial = i;
        }
    }
    if unknown {
        return refused(UNKNOWN);
    }
    let Some(over) = total.cmp_tenths(MAX_PSILOCYBIN_MG_PER_SALE * 10) else { return refused(UNUSABLE) };
    let error = if over == std::cmp::Ordering::Greater {
        let Some(shown) = total.ceil_tenths_text() else { return refused(UNUSABLE) };
        Some(format!(
            "This sale would total {shown} mg psilocybin - more than the {MAX_PSILOCYBIN_MG_PER_SALE} mg limit per sale \
             (mg TPE is not subject to this cap)."
        ))
    } else {
        None
    };
    json!({"psilocybin_mg": total.text(), "allowed": error.is_none(), "error": error,
           "session_minutes": session_minutes(total), "session_minutes_initial": session_minutes(initial)})
}

/// `{"sales": [{"lines": [{"record": object, "qty": any, "dose": "initial" | "secondary"}]}]}` in,
/// `[{"psilocybin_mg": string | null, "allowed": bool, "error": string | null, "session_minutes": int | null,
/// "session_minutes_initial": int | null}]` out, one per sale (schemas/dose/sale_limits.*). Every sale has an answer;
/// only the wrong shape is an error.
pub fn sale_limits_json(input_json: &str) -> Result<String, crate::api::Error> {
    let input = Py::parse(input_json)?;
    object(&input, "dose.sale_limits: the input")?;
    let sales = list(&input, "sales", "dose.sale_limits")?;
    let mut out = Vec::with_capacity(sales.len());
    for (i, sale) in sales.iter().enumerate() {
        object(sale, &format!("dose.sale_limits: sale {i}"))?;
        let lines = list(sale, "lines", &format!("dose.sale_limits: sale {i}"))?;
        for (j, line) in lines.iter().enumerate() {
            let what = format!("dose.sale_limits: sale {i} line {j}");
            object(line, &what)?;
            if !has(line, "record") || !has(line, "qty") || !has(line, "dose") {
                return Err(format!("{what} needs its record, qty and dose").into());
            }
            object(line.get("record"), &format!("{what}'s record"))?;
            if !matches!(line.get("dose"), Py::Str(d) if d == "initial" || d == "secondary") {
                return Err(format!("{what}'s dose must be \"initial\" or \"secondary\"").into());
            }
        }
        out.push(limits(lines));
    }
    Ok(serde_json::to_string(&out)?)
}
