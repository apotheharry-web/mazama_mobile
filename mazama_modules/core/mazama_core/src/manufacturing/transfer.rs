//! A transfer between the manufacturer and a service center (FM-13): the check of a transfer the web form or the phone
//! asks for, and what it sends. Held to the frozen vectors in mazama_modules/manufacturing/vectors/transfer*.json,
//! which carry the server's answers before the move (`manufacturing/transfers.py`'s `parse`, `form_items`,
//! `price_cents`, `planned_transfers`, `planned_manifest` and `split_plan`) and the intended changes beside them.
//!
//! - [`transfer_items_json`]: the packages a request names, each once, with its quantity (specs/manufacturer-phone
//!   MP-R15): ids and quantities of ASCII digits only, a blank quantity names nothing, a record named twice is refused.
//! - [`transfer_check_json`]: every field of the request checked with the server's words, the parsed fields, and, when
//!   nothing is wrong, the planned transfers, the packages to split and (given the driver) the planned manifest. Two
//!   changes from the server it replaces: a mode other than `send` or `retrieve` is refused ("Choose send or
//!   retrieve.", MP-R18), never read as a send, and an arrival earlier than the departure on the same day is refused
//!   like one on an earlier day (MP-R22).
//! - [`transfer_plan_json`]: for checked fields (the sync worker's, from a queued job), the packages to split, the
//!   planned transfers and the manifest's fields.
//!
//! The readings are Python's, as the server had them: `str.strip()`, `int()` of a driver id (Unicode digits,
//! underscores between digits, at most 4300 digits), `Decimal()` of a price (Unicode digits, underscores anywhere,
//! exponents, the decimal module's limits; a price whose quantization overflows 28 digits is an error, as it raised),
//! `date.fromisoformat`, `re`'s Unicode `\d` in a time and a phone number, and `round(x, 2)`.
use std::collections::{BTreeMap, HashMap};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Map, Value, json};

use crate::api::Error;
use crate::names::{is_nd, nd_value};
use crate::selling::sale::{iso, iso_date, pacific_midnight};
use crate::stock::{Num, py_strip, round2};
use crate::stock_order::py_float_repr;

type R<T> = Result<T, Error>;

/// The highest sale price, in cents ($1,000,000).
const MAX_PRICE_CENTS: i128 = 100_000_000;
/// The longest route kept, in characters.
const NOTE_MAX: usize = 1000;
/// Python's `int()` refuses text of more digits (sys.get_int_max_str_digits()).
const INT_MAX_DIGITS: usize = 4300;
/// The decimal module's default precision, and its exponent limits (64-bit builds).
const DEC_PREC: usize = 28;
const DEC_EMAX: i128 = 999_999_999_999_999_999;
const DEC_ETINY: i128 = -1_999_999_999_999_999_997;

const NOT_AVAILABLE: &str = "isn't available to transfer (it may be locked, flagged, already in a transfer or out of stock).";
const BAD_PRICE: &str = "The sale price must be an amount from 0 to 1,000,000 with at most two decimals.";
const OWNER_PRICE: &str = "Only the owner can put a sale price on a transfer. Leave it at 0.";

static QTY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[0-9]{1,6}$").expect("QTY"));
static NULL: Value = Value::Null;

fn get<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&NULL)
}

/// Python's truthiness of a JSON value.
fn truthy(v: &Value) -> bool {
    crate::py::truthy(v)
}

/// A text field of the request: absent is blank; anything but text is a caller's mistake.
fn text<'a>(v: &'a Value, k: &str, absent: &'a str) -> R<&'a str> {
    match v.get(k) {
        None | Some(Value::Null) => Ok(absent),
        Some(Value::String(s)) => Ok(s),
        Some(_) => Err(format!("manufacturing.transfer_check: fields.{k} must be text").into()),
    }
}

/// Python's `str()` of a scalar the server puts into its words (a record's id, guid or quantity).
fn py_str(v: &Value) -> R<String> {
    Ok(match v {
        Value::Null => "None".into(),
        Value::Bool(b) => if *b { "True" } else { "False" }.into(),
        Value::String(s) => s.clone(),
        Value::Number(n) => match n.as_i64().map(|i| i.to_string()).or_else(|| n.as_u64().map(|u| u.to_string())) {
            Some(s) => s,
            None => py_float_repr(n.as_f64().unwrap_or(f64::NAN)),
        },
        _ => return Err("manufacturing.transfer: a record's id, guid or quantity must be a plain value".into()),
    })
}

fn int_of(v: &Value, what: &str) -> R<i64> {
    v.as_i64().ok_or_else(|| format!("manufacturing.transfer: {what} must be a whole number").into())
}

// --- the packages named ------------------------------------------------------------------------------------------

/// The packages a request names, (record id, quantity) in record id order, and the problems.
type Named = (Vec<(i64, i64)>, Vec<String>);

/// What a request names, as `transfers.form_items` read the web form's `qty_<id>` fields (the page turns them into
/// this list, in the form's order).
fn named_items(items: &[Value]) -> R<Named> {
    let mut bad = Vec::new();
    let mut seen: BTreeMap<i64, i64> = BTreeMap::new();
    let mut named: Vec<i64> = Vec::new();
    let mut twice: Vec<i64> = Vec::new();
    for it in items {
        let pid = int_of(get(it, "record_id"), "an item's record_id")?;
        // the quantity's text as the form had it: a phone's whole number is its digits; anything else can't be one
        let qty = match get(it, "qty") {
            Value::String(s) => Some(py_strip(s).to_string()),
            Value::Number(n) if n.is_i64() || n.is_u64() => Some(n.to_string()),
            _ => None,
        };
        if qty.as_deref() == Some("") {
            continue; // a blank quantity names nothing
        }
        if named.contains(&pid) {
            if !twice.contains(&pid) {
                twice.push(pid);
            }
            continue;
        }
        named.push(pid);
        match qty.filter(|q| QTY.is_match(q)) {
            None => bad.push(format!("Quantity for package {pid} must be a whole number.")),
            Some(q) => {
                let q: i64 = q.parse()?;
                if q > 0 {
                    seen.insert(pid, q);
                }
            }
        }
    }
    for pid in twice {
        seen.remove(&pid);
        bad.push(format!("Package record {pid} is listed twice."));
    }
    Ok((seen.into_iter().collect(), bad))
}

/// `{items: [{record_id, qty}]}` -> `{wanted: [{record_id, qty}], problems}`.
pub fn transfer_items_json(input: &str) -> R<String> {
    let v: Value = serde_json::from_str(input)?;
    let items = get(&v, "items").as_array().ok_or("manufacturing.transfer_items: items must be a list")?;
    let (wanted, bad) = named_items(items)?;
    let wanted: Vec<Value> = wanted.iter().map(|(p, q)| json!({"record_id": p, "qty": q})).collect();
    Ok(json!({"wanted": wanted, "problems": bad}).to_string())
}

// --- Python's readings ---------------------------------------------------------------------------------------------

/// Python's `int()` of a text: Unicode whitespace around it (in ASCII only space, tab, the line breaks, \v and \f), a
/// sign, Unicode decimal digits with single underscores between them, at most 4300 digits. -> (negative, digits).
fn py_int(t: &str) -> Option<(bool, String)> {
    let ascii_space = |c: char| matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r');
    let space = |c: char| if c.is_ascii() { ascii_space(c) } else { crate::stock::py_space(c) };
    let t = t.trim_matches(space);
    let (neg, body) = match t.chars().next() {
        Some('-') => (true, &t[1..]),
        Some('+') => (false, &t[1..]),
        _ => (false, t),
    };
    let mut digits = String::new();
    let mut prev_digit = false;
    for c in body.chars() {
        if c == '_' && prev_digit {
            prev_digit = false;
        } else if is_nd(c) {
            digits.push(char::from_digit(nd_value(c), 10)?);
            prev_digit = true;
        } else {
            return None;
        }
    }
    if digits.is_empty() || !prev_digit || digits.len() > INT_MAX_DIGITS {
        return None;
    }
    let d = digits.trim_start_matches('0');
    Some(if d.is_empty() { (false, "0".into()) } else { (neg, d.into()) })
}

/// A driver id as the server read it: `int()` of the form's text (0 when it isn't one), or the phone's whole number.
/// -> the id when it fits 64 bits, else its digits (Python keeps any size; such an id names no driver).
enum DriverId {
    Id(i64),
    Big(String),
}

fn driver_id(v: &Value) -> DriverId {
    match v {
        Value::Number(n) if n.is_i64() => DriverId::Id(n.as_i64().unwrap_or(0)),
        Value::Number(n) if n.is_u64() => DriverId::Big(n.to_string()),
        Value::String(s) => match py_int(s) {
            None => DriverId::Id(0),
            Some((neg, d)) => {
                let text = if neg { format!("-{d}") } else { d };
                text.parse::<i64>().map_or(DriverId::Big(text), DriverId::Id)
            }
        },
        _ => DriverId::Id(0),
    }
}

/// `transfers.fmt_time`: "05:00" -> "5 am" (`re`'s `\d` takes any decimal digit for the hour's and the minute's second
/// digit, and `int()` reads it). -> (the state's text, minutes after midnight).
fn fmt_time(hhmm: &str) -> Option<(String, u32)> {
    let c: Vec<char> = hhmm.chars().collect();
    if c.len() != 5 || c[2] != ':' {
        return None;
    }
    let hour_ok = (matches!(c[0], '0' | '1') && is_nd(c[1])) || (c[0] == '2' && ('0'..='3').contains(&c[1]));
    if !hour_ok || !('0'..='5').contains(&c[3]) || !is_nd(c[4]) {
        return None;
    }
    let h = nd_value(c[0]) * 10 + nd_value(c[1]);
    let mi: String = c[3..5].iter().collect();
    let twelve = if h.is_multiple_of(12) { 12 } else { h % 12 };
    let text = format!("{twelve}{} {}", if mi == "00" { String::new() } else { format!(":{mi}") }, if h < 12 { "am" } else { "pm" });
    Some((text, h * 60 + nd_value(c[3]) * 10 + nd_value(c[4])))
}

/// What `transfers.price_cents` answered for a typed price.
#[derive(Debug, PartialEq)]
enum Price {
    Cents(i64),
    Refused,
    /// `Decimal.quantize` raised InvalidOperation (more than 28 digits): the server raised too.
    Raises,
}

/// `transfers.price_cents`: `Decimal((text or "0").strip() or "0")`, refused unless finite, not negative and of at
/// most two decimals, in whole cents up to $1,000,000.
fn price_cents(text: &str) -> Price {
    let t = py_strip(text);
    let t = if t.is_empty() { "0" } else { t };
    // the decimal module's own reading: underscores dropped, every decimal digit as its ASCII digit
    let mut s = String::with_capacity(t.len());
    for c in t.chars() {
        if c == '_' {
            continue;
        }
        if c.is_ascii() {
            if c == '\0' {
                return Price::Refused;
            }
            s.push(c);
        } else if is_nd(c) {
            s.push(char::from_digit(nd_value(c), 10).unwrap_or('?'));
        } else {
            return Price::Refused;
        }
    }
    let (neg, body) = match s.as_bytes().first() {
        Some(b'-') => (true, &s[1..]),
        Some(b'+') => (false, &s[1..]),
        _ => (false, &s[..]),
    };
    let lower = body.to_ascii_lowercase();
    if lower == "inf" || lower == "infinity" {
        return Price::Refused;
    }
    let nan = |p: &str| lower.strip_prefix(p).is_some_and(|payload| payload.bytes().all(|b| b.is_ascii_digit()));
    if nan("snan") || nan("nan") {
        return Price::Refused; // not finite
    }
    let (mantissa, exp_text) = match body.find(['e', 'E']) {
        Some(i) => (&body[..i], Some(&body[i + 1..])),
        None => (body, None),
    };
    let (int_part, frac_part) = match mantissa.find('.') {
        Some(i) => (&mantissa[..i], &mantissa[i + 1..]),
        None => (mantissa, ""),
    };
    let all_digits = |x: &str| x.bytes().all(|b| b.is_ascii_digit());
    if (int_part.is_empty() && frac_part.is_empty()) || !all_digits(int_part) || !all_digits(frac_part) {
        return Price::Refused;
    }
    let e: i128 = match exp_text {
        None => 0,
        Some(x) => {
            let (eneg, ed) = match x.as_bytes().first() {
                Some(b'-') => (true, &x[1..]),
                Some(b'+') => (false, &x[1..]),
                _ => (false, x),
            };
            if ed.is_empty() || !all_digits(ed) {
                return Price::Refused;
            }
            let ed = ed.trim_start_matches('0');
            if ed.len() > 30 {
                return Price::Refused; // far beyond the module's limits
            }
            let n: i128 = if ed.is_empty() { 0 } else { ed.parse().unwrap_or(i128::MAX) };
            if eneg { -n } else { n }
        }
    };
    let coef: String = format!("{int_part}{frac_part}").trim_start_matches('0').to_string();
    let zero = coef.is_empty();
    let n = if zero { 1 } else { coef.len() } as i128;
    let exp = e - frac_part.len() as i128;
    if exp < DEC_ETINY || exp + n - 1 > DEC_EMAX {
        return Price::Refused; // the constructor refuses it
    }
    if zero {
        return Price::Cents(0); // "-0" too
    }
    if neg {
        return Price::Refused;
    }
    // quantize to cents: the coefficient at exponent -2, rounded half to even; more than 28 digits raises
    let shift = exp + 2;
    let cents: i128 = if shift >= 0 {
        if n + shift > DEC_PREC as i128 {
            return Price::Raises;
        }
        let mut v: i128 = coef.parse().unwrap_or(0);
        for _ in 0..shift {
            v *= 10;
        }
        v
    } else {
        let drop = usize::try_from(-shift).unwrap_or(usize::MAX);
        if drop >= coef.len() {
            return Price::Refused; // every digit is beyond the cents (and it rounds to 0 or 1 cent, never too many digits)
        }
        let (kept, dropped) = coef.split_at(coef.len() - drop);
        if kept.len() > DEC_PREC {
            return Price::Raises;
        }
        let exact = dropped.bytes().all(|b| b == b'0');
        if !exact && kept.len() == DEC_PREC && kept.bytes().all(|b| b == b'9') {
            // rounded half to even, all nines would carry into a 29th digit
            let first = dropped.as_bytes()[0];
            if first >= b'5' {
                return Price::Raises;
            }
        }
        if !exact {
            return Price::Refused; // more than two decimals
        }
        kept.parse().unwrap_or(0)
    };
    if cents > MAX_PRICE_CENTS { Price::Refused } else { Price::Cents(cents as i64) }
}

/// `re.sub(r"\D", "", phone)[-10:]`: the decimal digits of a phone number, its last ten.
fn phone_digits(phone: &str) -> String {
    let d: Vec<char> = phone.chars().filter(|&c| is_nd(c)).collect();
    d[d.len().saturating_sub(10)..].iter().collect()
}

/// `re.sub(r"[\x00-\x08\x0b-\x1f\x7f<>]", "", route).strip()[:1000]`.
fn clean_route(route: &str) -> String {
    let kept: String = route.chars().filter(|&c| !(c <= '\x08' || ('\x0b'..='\x1f').contains(&c) || c == '\x7f' || c == '<' || c == '>')).collect();
    py_strip(&kept).chars().take(NOTE_MAX).collect()
}

// --- what is sent ---------------------------------------------------------------------------------------------------

/// The records by id, as the server's `{p["id"]: p for p in packages}` (a later record of one id wins).
fn by_id(records: &[Value]) -> R<HashMap<i64, &Value>> {
    let mut out = HashMap::new();
    for r in records {
        out.insert(int_of(get(r, "id"), "a record's id")?, r);
    }
    Ok(out)
}

fn need<'a>(r: &'a Value, k: &str) -> R<&'a Value> {
    r.get(k).ok_or_else(|| format!("manufacturing.transfer: a record has no {k}").into())
}

/// `round(weightPerUnit * qty, 2)`: an int (or a bool) stays a whole number, a float is rounded half to even.
fn product_weight(w: &Value, qty: i64) -> R<Value> {
    let bad = || -> Error { "manufacturing.transfer: a record's weightPerUnit must be a number".into() };
    match w {
        Value::Bool(b) => Ok(json!(i64::from(*b) * qty)),
        Value::Number(n) if n.is_i64() || n.is_u64() => {
            let p = n.as_i64().map_or(n.as_u64().map_or(0, i128::from), i128::from) * i128::from(qty);
            Ok(i64::try_from(p).map(Value::from).map_err(|_| -> Error { "manufacturing.transfer: a product weight past 64 bits".into() })?)
        }
        Value::Number(n) => match round2(Num::F(n.as_f64().ok_or_else(bad)? * qty as f64)) {
            Num::F(f) => serde_json::Number::from_f64(f).map(Value::Number).ok_or_else(bad),
            Num::I(i) => Ok(json!(i)),
        },
        _ => Err(bad()),
    }
}

/// `transfers.planned_transfers`: each transfer as the state system will show it once it has the package's details.
fn planned(records: &HashMap<i64, &Value>, items: &[(i64, i64)]) -> R<Vec<Value>> {
    let mut out = Vec::new();
    for &(rid, qty) in items {
        let p = records.get(&rid).ok_or_else(|| format!("manufacturing.transfer: no record {rid}"))?;
        out.push(json!({"id": 0, "productId": need(p, "productGuid")?, "productType": need(p, "productType")?,
                        "description": need(p, "description")?, "quantity": qty, "weightEach": need(p, "weightPerUnit")?,
                        "analyteEach": need(p, "analyteWeight")?, "productWeight": product_weight(need(p, "weightPerUnit")?, qty)?,
                        "packagedProductId": rid}));
    }
    Ok(out)
}

/// The quantity of a record, compared with a unit count.
fn more_than(q: i64, quantity: &Value) -> R<bool> {
    match quantity {
        Value::Number(n) if n.is_i64() => Ok(q > n.as_i64().unwrap_or(0)),
        Value::Number(n) if n.is_u64() => Ok(false),
        Value::Number(n) => Ok((q as f64) > n.as_f64().unwrap_or(f64::NAN)),
        Value::Bool(b) => Ok(q > i64::from(*b)),
        _ => Err("manufacturing.transfer: a record's quantity must be a number".into()),
    }
}

/// `transfers.split_plan`: the packages only partly moved, [{record_id, qty}] in the items' order.
fn splits(records: &HashMap<i64, &Value>, items: &[(i64, i64)]) -> R<Vec<Value>> {
    let mut out = Vec::new();
    for &(rid, qty) in items {
        let p = records.get(&rid).ok_or_else(|| format!("manufacturing.transfer: no record {rid}"))?;
        if less_than(qty, need(p, "quantity")?) {
            out.push(json!({"record_id": rid, "qty": qty}));
        }
    }
    Ok(out)
}

/// `qty < record["quantity"]` (a quantity that isn't a number is refused before: `more_than`).
fn less_than(q: i64, quantity: &Value) -> bool {
    match quantity {
        Value::Number(n) if n.is_i64() => q < n.as_i64().unwrap_or(0),
        Value::Number(n) if n.is_u64() => true,
        Value::Number(n) => (q as f64) < n.as_f64().unwrap_or(f64::NAN),
        Value::Bool(b) => q < i64::from(*b),
        _ => false,
    }
}

/// One end of a transfer: its license and address as the server holds them.
struct End<'a> {
    license: &'a Value,
    address: &'a Value,
}

/// The checked fields a manifest is written from.
struct Sent<'a> {
    dep: i64,
    dep_time: &'a str,
    arr: i64,
    arr_time: &'a str,
    route: &'a str,
    price_cents: i64,
}

/// `transfers.planned_manifest`: the manifest as it will be filled in (`manifest_fields` with its id and the two
/// licenses). The address, driver and vehicle fields are the server's values as they are.
fn manifest(src: &End, dst: &End, f: &Sent, drv: &Value) -> R<Value> {
    let d = |k: &str| -> R<&Value> { drv.get(k).ok_or_else(|| format!("manufacturing.transfer: the driver has no {k}").into()) };
    let phone = d("phone")?.as_str().ok_or("manufacturing.transfer: the driver's phone must be text")?;
    Ok(json!({
        "id": "", "originatingLicense": src.license, "destinationLicense": dst.license,
        "originatingAddress": src.address, "destinationAddress": dst.address, "salePrice": f.price_cents as f64 / 100.0, "testing": false,
        "dateOfDeparture": pacific_midnight(f.dep), "estimatedDepartureTime": f.dep_time, "generalRoute": f.route,
        "dateOfArrival": pacific_midnight(f.arr), "estimatedArrivalTime": f.arr_time,
        "driverName": d("name")?, "driverPhoneNumber": phone_digits(phone), "driverWorkerPermit": d("permit")?, "driverSignature": "",
        "representativeName": "", "representativePhoneNumber": "", "representativeWorkerPermit": "", "representativeSignature": "",
        "vehicleMake": d("make")?, "vehicleModel": d("model")?, "vehiclePlateNumber": d("plate")?,
        "overnightStop": false, "overnightAddress": "", "estimatedOvernightDuration": "", "overnightStopPurpose": "",
    }))
}

// --- the check ------------------------------------------------------------------------------------------------------

/// `{items, fields: {mode, dest, driver, dep, dep_time, arr, arr_time, route, price, sign}, packages, centers: [{slug,
/// name, license, address}], mfr: {license, address}, driver_ids, driver?, today, is_owner}` -> `{fields: {mode, dest,
/// driver, dep, dep_time, arr, arr_time, route, price_cents, sign, items}, problems, planned, splits, manifest}`.
/// `packages` are the records that may be moved now; `driver` (name, phone, permit, make, model, plate) the chosen
/// driver's details for the manifest. planned and splits are empty, and manifest null, while there are problems
/// (manifest also without a driver).
pub fn transfer_check_json(input: &str) -> R<String> {
    let v: Value = serde_json::from_str(input)?;
    let fields = get(&v, "fields");
    if !fields.is_object() {
        return Err("manufacturing.transfer_check: fields must be an object".into());
    }
    let items = get(&v, "items").as_array().ok_or("manufacturing.transfer_check: items must be a list")?;
    let packages = get(&v, "packages").as_array().ok_or("manufacturing.transfer_check: packages must be a list")?;
    let centers = get(&v, "centers").as_array().ok_or("manufacturing.transfer_check: centers must be a list")?;
    let mfr = get(&v, "mfr");
    let driver_ids: Vec<i64> = get(&v, "driver_ids").as_array().ok_or("manufacturing.transfer_check: driver_ids must be a list")?
        .iter().map(|d| int_of(d, "a driver id")).collect::<R<_>>()?;
    let today = get(&v, "today").as_str().and_then(iso_date).ok_or("manufacturing.transfer_check: today must be a date")?;
    let is_owner = get(&v, "is_owner").as_bool().ok_or("manufacturing.transfer_check: is_owner must be true or false")?;

    let mut bad: Vec<String> = Vec::new();
    let mut f = Map::new();
    let mode_text = text(fields, "mode", "")?;
    let known_mode = mode_text == "send" || mode_text == "retrieve";
    if !known_mode {
        bad.push("Choose send or retrieve.".into());
    }
    let retrieve = mode_text == "retrieve";
    f.insert("mode".into(), json!(if known_mode { mode_text } else { "" }));

    let dest_text = text(fields, "dest", "")?;
    let dest = centers.iter().find(|c| get(c, "slug").as_str() == Some(dest_text));
    match dest {
        None => bad.push(if retrieve { "Choose the service center." } else { "Choose the destination." }.into()),
        Some(c) if !(truthy(get(c, "license")) && truthy(get(c, "address"))) => {
            bad.push(format!("{} has no license number or address set up on the server.", py_str(get(c, "name"))?));
        }
        Some(_) => {}
    }
    f.insert("dest".into(), dest.map_or(json!(""), |c| get(c, "slug").clone()));
    if !(truthy(get(mfr, "address")) && truthy(get(mfr, "license"))) {
        bad.push("The manufacturer has no license number or address set up on the server.".into());
    }
    let driver = driver_id(fields.get("driver").unwrap_or(&json!("")));
    if !matches!(driver, DriverId::Id(d) if driver_ids.contains(&d)) {
        bad.push("Choose the driver.".into());
    }

    let mut days: [Option<i64>; 2] = [None, None];
    let mut times: [Option<(String, u32)>; 2] = [None, None];
    for (i, (key, label)) in [("dep", "departure"), ("arr", "arrival")].into_iter().enumerate() {
        days[i] = iso_date(text(fields, key, "")?);
        f.insert(key.into(), json!(days[i].map_or(String::new(), iso)));
        if days[i].is_none() {
            bad.push(format!("Enter the {label} date."));
        }
        times[i] = fmt_time(text(fields, &format!("{key}_time"), "")?);
        f.insert(format!("{key}_time"), json!(times[i].as_ref().map_or("", |t| t.0.as_str())));
        if times[i].is_none() {
            bad.push(format!("Enter the estimated {label} time."));
        }
    }
    if days[0].is_some_and(|d| d < today) {
        bad.push("The departure date can't be in the past.".into());
    }
    if let (Some(dep), Some(arr)) = (days[0], days[1]) {
        let earlier_time = matches!((&times[0], &times[1]), (Some(d), Some(a)) if a.1 < d.1);
        if arr < dep || (arr == dep && earlier_time) {
            bad.push("The arrival can't be before the departure.".into());
        }
    }
    let route = clean_route(text(fields, "route", "")?);
    if route.is_empty() {
        bad.push("Enter the general route (for example: direct).".into());
    }
    f.insert("route".into(), json!(route));
    let cents = match price_cents(text(fields, "price", "0")?) {
        Price::Raises => return Err("manufacturing.transfer_check: the price has more digits than a decimal holds".into()),
        Price::Refused => {
            bad.push(BAD_PRICE.into());
            0
        }
        Price::Cents(c) if c != 0 && !is_owner => {
            bad.push(OWNER_PRICE.into());
            0
        }
        Price::Cents(c) => c,
    };
    f.insert("price_cents".into(), json!(cents));
    let sign = match fields.get("sign") {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => s == "1",
        _ => false,
    };
    f.insert("sign".into(), json!(sign));

    let byid = by_id(packages)?;
    let (wanted, problems) = named_items(items)?;
    bad.extend(problems);
    let mut chosen: Vec<(i64, i64)> = Vec::new();
    let mut rows = Vec::new();
    for (pid, q) in wanted {
        match byid.get(&pid) {
            None => bad.push(format!("Package record {pid} {NOT_AVAILABLE}")),
            Some(p) if more_than(q, need(p, "quantity")?)? => {
                bad.push(format!("{}: you asked for {q} but only {} are in stock.", py_str(need(p, "productGuid")?)?, py_str(need(p, "quantity")?)?));
            }
            Some(p) => {
                let desc = get(p, "description");
                rows.push(json!({"record_id": pid, "guid": need(p, "productGuid")?, "description": if truthy(desc) { desc.clone() } else { json!("") },
                                 "qty": q, "stock": need(p, "quantity")?}));
                chosen.push((pid, q));
            }
        }
    }
    if rows.is_empty() {
        bad.push("Choose at least one package and a quantity.".into());
    }
    f.insert("items".into(), Value::Array(rows));

    let (mut plan, mut split, mut man) = (Value::Array(vec![]), Value::Array(vec![]), Value::Null);
    if bad.is_empty() {
        plan = Value::Array(planned(&byid, &chosen)?);
        split = Value::Array(splits(&byid, &chosen)?);
        if let (Some(drv), Some(c)) = (v.get("driver").filter(|d| !d.is_null()), dest) {
            let (m, c) = (End { license: get(mfr, "license"), address: get(mfr, "address") }, End { license: get(c, "license"), address: get(c, "address") });
            let (src, dst) = if retrieve { (&c, &m) } else { (&m, &c) };
            let sent = Sent {
                dep: days[0].unwrap_or(0), dep_time: times[0].as_ref().map_or("", |t| t.0.as_str()), arr: days[1].unwrap_or(0),
                arr_time: times[1].as_ref().map_or("", |t| t.0.as_str()), route: f["route"].as_str().unwrap_or(""), price_cents: cents,
            };
            man = manifest(src, dst, &sent, drv)?;
        }
    }
    // the fields as JSON, the driver id written as its own digits (an id past 64 bits too, as Python keeps it)
    let driver_text = match &driver {
        DriverId::Id(d) => d.to_string(),
        DriverId::Big(s) => s.clone(),
    };
    let rest = serde_json::to_string(&f)?;
    let fields_text = format!("{{\"driver\":{driver_text},{}", &rest[1..]);
    Ok(format!("{{\"fields\":{fields_text},\"problems\":{},\"planned\":{},\"splits\":{},\"manifest\":{}}}",
               serde_json::to_string(&bad)?, plan, split, man))
}

/// `{records, items: [{record_id, qty}], planned?, manifest?: {src: {license, address}, dst: {license, address}, fields:
/// {dep, dep_time, arr, arr_time, route, price_cents}, driver}}` -> `{splits, planned, manifest}`: for a checked
/// transfer (a queued job's), the packages to split, the planned transfers when asked (`planned: true`, else null) and
/// the manifest's fields when given what it is written from (else null).
pub fn transfer_plan_json(input: &str) -> R<String> {
    let v: Value = serde_json::from_str(input)?;
    let records = get(&v, "records").as_array().ok_or("manufacturing.transfer_plan: records must be a list")?;
    let items: Vec<(i64, i64)> = get(&v, "items").as_array().ok_or("manufacturing.transfer_plan: items must be a list")?
        .iter().map(|i| Ok((int_of(get(i, "record_id"), "an item's record_id")?, int_of(get(i, "qty"), "an item's qty")?))).collect::<R<_>>()?;
    let byid = by_id(records)?;
    let plan = if get(&v, "planned").as_bool() == Some(true) { Value::Array(planned(&byid, &items)?) } else { Value::Null };
    let man = match v.get("manifest").filter(|m| !m.is_null()) {
        None => Value::Null,
        Some(m) => {
            let end = |k: &str| -> R<End> {
                let e = m.get(k).filter(|e| e.is_object()).ok_or_else(|| format!("manufacturing.transfer_plan: manifest.{k} must be an object"))?;
                Ok(End { license: get(e, "license"), address: get(e, "address") })
            };
            let mf = get(m, "fields");
            let s = |k: &str| -> R<&str> { get(mf, k).as_str().ok_or_else(|| format!("manufacturing.transfer_plan: fields.{k} must be text").into()) };
            let day = |k: &str| -> R<i64> { iso_date(s(k)?).ok_or_else(|| format!("manufacturing.transfer_plan: fields.{k} must be a date").into()) };
            let sent = Sent { dep: day("dep")?, dep_time: s("dep_time")?, arr: day("arr")?, arr_time: s("arr_time")?, route: s("route")?,
                              price_cents: int_of(get(mf, "price_cents"), "fields.price_cents")? };
            manifest(&end("src")?, &end("dst")?, &sent, get(m, "driver"))?
        }
    };
    Ok(json!({"splits": splits(&byid, &items)?, "planned": plan, "manifest": man}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prices_as_the_decimal_module_reads_them() {
        let c = |t: &str| price_cents(t);
        assert_eq!(c(" 12.5 "), Price::Cents(1250));
        assert_eq!(c("+5"), Price::Cents(500));
        assert_eq!(c("-0"), Price::Cents(0));
        assert_eq!(c("0.010"), Price::Cents(1));
        assert_eq!(c("1E+2"), Price::Cents(10000));
        assert_eq!(c("NaN"), Price::Refused);
        assert_eq!(c("Infinity"), Price::Refused);
        assert_eq!(c("1_000"), Price::Cents(100000));
        assert_eq!(c("\u{661}\u{662}"), Price::Cents(1200));
        assert_eq!(c("1000000.00"), Price::Cents(100_000_000));
        assert_eq!(c("1000000.01"), Price::Refused);
        assert_eq!(c("1E+26"), Price::Raises);
        assert_eq!(c("99999999999999999999999999.995"), Price::Raises);
        assert_eq!(c("99999999999999999999999999.994"), Price::Refused);
        assert_eq!(c("0e999999999999999999"), Price::Cents(0));
        assert_eq!(c("0e1000000000000000000"), Price::Refused);
        assert_eq!(c("1e-1999999999999999997"), Price::Refused);
        assert_eq!(c(""), Price::Cents(0));
    }

    #[test]
    fn ints_as_python_reads_them() {
        assert_eq!(py_int(" +0_3\u{a0}"), Some((false, "3".into())));
        assert_eq!(py_int("\u{663}"), Some((false, "3".into())));
        assert_eq!(py_int("-0"), Some((false, "0".into())));
        assert_eq!(py_int("3__0"), None);
        assert_eq!(py_int("\x1c3"), None);
        assert_eq!(py_int(&"1".repeat(4301)), None);
    }

    #[test]
    fn times_as_the_state_writes_them() {
        assert_eq!(fmt_time("05:00").map(|t| t.0), Some("5 am".into()));
        assert_eq!(fmt_time("12:15").map(|t| t.0), Some("12:15 pm".into()));
        assert_eq!(fmt_time("0\u{665}:3\u{660}").map(|t| t.0), Some("5:3\u{660} am".into()));
        assert_eq!(fmt_time("24:00"), None);
    }
}
