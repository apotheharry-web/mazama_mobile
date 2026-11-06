//! A sale's record, its date, the check just before it is sent and how its reply ends. One rule for the server (selling.py, expiry.py, salejobs.py and state/client.py's
//! CreateSalesRecords reply, through the binding) and the phone (selling.dart, sale_outcome.dart, bulk_sale.dart and
//! cart_page.dart's draw and check, through the FFI), held to mazama_modules/selling/vectors/sale_record.json,
//! sale_date.json, expiry.json, sale_check.json, flows/contracts/write_outcomes.json and sale_cases.json.
//!
//! Where an input is odd, a sale or a date is refused, and an outcome is uncertain rather than recorded or not sent:
//!
//! | Input | Answer |
//! |---|---|
//! | a sale date more than 365 days back | `too_old` ([`check_sale_date_json`]); the pickers offer no such day ([`sale_date_bounds_json`]) |
//! | Pacific midnight | the 2007 US daylight-saving rule for every year ([`RULE`]), checked against zoneinfo 2007-2099 |
//! | "today" | the Pacific date of now ([`today_json`]) |
//! | two lines of one product | one draw across the sale ([`allocate_sale_json`]), the check summed per record |
//! | a reply's saleNumber | proof only from text with something besides [`TRIM`], or an integer token above 0 |
//! | a reviewed sale's typed total | to cents half up |
//! | a price each outside $0..$10,000, a quantity outside 1..999, a record lacking a copied value | refused, with the words |
//! | the state's values | passed through as given (an integer keeps its digits) |
//! | a reply whose body was cut off or didn't arrive in time | uncertain, whatever its status |
//! | a copied value that changed since the sale was priced | refused before anything is sent |
//! | a dose other than initial/secondary; a 200 whose body is NaN/Infinity/broken Unicode; a reviewed date in a form other than `YYYY-MM-DD(T| )HH:MM[:SS[.f]]` with its zone | refused; uncertain; no date |
//! | arithmetic past i128; a Pacific day outside years 1..9999 | an input error; no date |
//!
//! Dates are civil days (no time-zone library); money is integers; productCost and costEach are the JSON numbers
//! Python's `cents * qty / 100` and `cents / 100` are. No answer is ever an object whose only key is "error" (that is
//! the library's own failure): a refusal sits beside the record it replaces, an error code beside the date.
use std::collections::HashMap;

use serde_json::{Value, json};

use super::cart::{draw_order, lots};
use super::pricing::{MAX_UNIT_CENTS, R, TRIM, field, input, int, text};
use crate::py::{Int, Py, py_float_repr, quoted};

/// mazama_modules/selling/rules.yaml `sale_date`: the US daylight-saving rule of 2007 (from the 2nd Sunday of March
/// to the 1st Sunday of November), Pacific standard time UTC-8, daylight UTC-7, a sale dated at most 365 days back,
/// and the last year the rule was checked against zoneinfo's America/Los_Angeles (a test fails once it has passed).
pub struct SaleDateRule {
    pub dst_start: (u32, u32),
    pub dst_end: (u32, u32),
    pub standard_offset_hours: i64,
    pub daylight_offset_hours: i64,
    pub backdate_days: i64,
    pub checked_until_year: i64,
}

pub const RULE: SaleDateRule = SaleDateRule {
    dst_start: (3, 2),
    dst_end: (11, 1),
    standard_offset_hours: 8,
    daylight_offset_hours: 7,
    backdate_days: 365,
    checked_until_year: 2099,
};

/// The most units one record may hold (rules.yaml `cart.max_units_per_line`).
pub const MAX_QTY: i64 = 999;

pub const LACKS_GUID: &str = "the state's record lacks productGuid, so it can't be sold";
pub const BAD_PRICE: &str = "the price each must be a whole number of cents from $0 to $10,000";
pub const BAD_QTY: &str = "the quantity must be a whole number from 1 to 999";
pub const BAD_DOSE: &str = "the dose must be initial or secondary";
pub const CAP_UNCHECKED: &str = "the psilocybin limit couldn't be checked.";

// --- civil days ------------------------------------------------------------------------------------------------------

fn leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn month_days(y: i64, m: i64) -> i64 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap(y) => 29,
        2 => 28,
        _ => 0,
    }
}

/// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's days_from_civil).
fn days(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { yoe + era * 400 + 1 } else { yoe + era * 400 }, m, d)
}

/// ISO weekday, Monday 1 .. Sunday 7.
fn weekday(z: i64) -> i64 {
    (z + 3).rem_euclid(7) + 1
}

/// The `n`th Sunday of a month, as a day number.
fn nth_sunday(y: i64, m: u32, n: u32) -> i64 {
    let first = days(y, i64::from(m), 1);
    first + (7 - weekday(first)) % 7 + 7 * (i64::from(n) - 1)
}

/// A day of Python's `date` (years 1..9999).
fn in_range(z: i64) -> bool {
    (days(1, 1, 1)..=days(9999, 12, 31)).contains(&z)
}

pub(crate) fn iso(z: i64) -> String {
    let (y, m, d) = civil(z);
    format!("{y:04}-{m:02}-{d:02}")
}

fn digits(b: &[u8]) -> Option<i64> {
    (!b.is_empty() && b.iter().all(u8::is_ascii_digit)).then(|| b.iter().fold(0, |a, c| a * 10 + i64::from(c - b'0')))
}

fn ymd(y: i64, m: i64, d: i64) -> Option<i64> {
    (y >= 1 && (1..=12).contains(&m) && d >= 1 && d <= month_days(y, m)).then(|| days(y, m, d))
}

/// The day Python's `date.fromisoformat` reads (3.11+): `2026-10-20`, `20261020`, `2026-W43`, `2026W43`, `2026-W43-2`,
/// `2026W432`, ASCII digits only; None for anything else, or a week date outside years 1..9999.
pub fn iso_date(text: &str) -> Option<i64> {
    let b = text.as_bytes();
    let week = |y: &[u8], w: &[u8], d: Option<&[u8]>| -> Option<i64> {
        let (y, w) = (digits(y)?, digits(w)?);
        let d = match d {
            Some(d) => digits(d)?,
            None => 1,
        };
        if y < 1 || !(1..=7).contains(&d) {
            return None;
        }
        let jan1 = days(y, 1, 1);
        let fits = (1..53).contains(&w) || (w == 53 && (weekday(jan1) == 4 || (weekday(jan1) == 3 && leap(y))));
        if !fits {
            return None;
        }
        let jan4 = days(y, 1, 4);
        let z = jan4 - (weekday(jan4) - 1) + (w - 1) * 7 + (d - 1);
        in_range(z).then_some(z)
    };
    match b.len() {
        10 if b[4] == b'-' && b[7] == b'-' => ymd(digits(&b[0..4])?, digits(&b[5..7])?, digits(&b[8..10])?),
        10 if b[4] == b'-' && b[5] == b'W' && b[8] == b'-' => week(&b[0..4], &b[6..8], Some(&b[9..10])),
        8 if b[4] == b'-' && b[5] == b'W' => week(&b[0..4], &b[6..8], None),
        8 if b[4] == b'W' => week(&b[0..4], &b[5..7], Some(&b[7..8])),
        8 => ymd(digits(&b[0..4])?, digits(&b[4..6])?, digits(&b[6..8])?),
        7 if b[4] == b'W' => week(&b[0..4], &b[5..7], None),
        _ => None,
    }
}

/// A plain `YYYY-MM-DD` of years 1..9999 (an input's own date).
fn plain_date(f: &str, v: &Value, what: &str) -> R<i64> {
    let s = text(f, v, what)?;
    let b = s.as_bytes();
    if b.len() == 10 && b[4] == b'-' && b[7] == b'-' {
        if let (Some(y), Some(m), Some(d)) = (digits(&b[0..4]), digits(&b[5..7]), digits(&b[8..10])) {
            if let Some(z) = ymd(y, m, d) {
                return Ok(z);
            }
        }
    }
    Err(format!("{f}: {what} must be a date YYYY-MM-DD").into())
}

/// Whether Pacific time is on daylight time at midnight of day `z` (the 2007 rule: after the 2nd Sunday of March, up
/// to and including the 1st Sunday of November, since the switches happen at 2 am).
fn daylight(z: i64) -> bool {
    let (y, _, _) = civil(z);
    nth_sunday(y, RULE.dst_start.0, RULE.dst_start.1) < z && z <= nth_sunday(y, RULE.dst_end.0, RULE.dst_end.1)
}

fn offset_hours(z: i64) -> i64 {
    if daylight(z) { RULE.daylight_offset_hours } else { RULE.standard_offset_hours }
}

/// Pacific midnight of day `z` as UTC: "2026-10-20T07:00:00.000Z".
pub fn pacific_midnight(z: i64) -> String {
    format!("{}T{:02}:00:00.000Z", iso(z), offset_hours(z))
}

/// The Pacific day of a moment, given as seconds since 1970 UTC, when it is a day of years 1..9999 (a
/// moment at either end of that range can fall on a Pacific day outside it, which no caller can hold).
fn pacific_day(secs: i64) -> Option<i64> {
    Some(pacific_day_any(secs)).filter(|z| in_range(*z))
}

fn pacific_day_any(secs: i64) -> i64 {
    let d = secs.div_euclid(86_400);
    for cand in [d - 1, d] {
        let start = cand * 86_400 + offset_hours(cand) * 3600;
        let next = (cand + 1) * 86_400 + offset_hours(cand + 1) * 3600;
        if start <= secs && secs < next {
            return cand;
        }
    }
    d + 1
}

// --- JSON as Python writes it -------------------------------------------------------------------------------------

/// Compact JSON, keys sorted, as Python's `json.dumps(v, sort_keys=True, ensure_ascii=False, separators=(",", ":"))`:
/// an integer as its digits at any size, a float as its `repr()`.
fn dump(v: &Py) -> String {
    match v {
        Py::Null => "null".into(),
        Py::Bool(b) => (if *b { "true" } else { "false" }).into(),
        Py::Int(n) => n.text(),
        Py::Float(x) if x.is_nan() => "NaN".into(),
        Py::Float(x) if x.is_infinite() => (if *x > 0.0 { "Infinity" } else { "-Infinity" }).into(),
        Py::Float(x) => py_float_repr(*x),
        Py::Str(s) => quoted(s),
        Py::List(a) => format!("[{}]", a.iter().map(dump).collect::<Vec<_>>().join(",")),
        Py::Obj(o) => {
            let mut kv: Vec<&(String, Py)> = o.iter().collect();
            kv.sort_by(|a, b| a.0.cmp(&b.0));
            format!("{{{}}}", kv.iter().map(|(k, v)| format!("{}:{}", quoted(k), dump(v))).collect::<Vec<_>>().join(","))
        }
    }
}

fn is_num(v: &Py) -> bool {
    matches!(v, Py::Int(_) | Py::Float(_))
}

fn int_of(v: &Py) -> Option<i128> {
    match v {
        Py::Int(n) => n.as_i128(),
        _ => None,
    }
}

/// Python's `==` between two JSON values (a bool is 0 or 1; an int and a float are compared exactly).
fn py_eq(a: &Py, b: &Py) -> bool {
    fn num(v: &Py) -> Option<(Option<&Int>, f64)> {
        match v {
            Py::Bool(x) => Some((None, f64::from(u8::from(*x)))),
            Py::Int(n) => Some((Some(n), n.as_f64())),
            Py::Float(x) => Some((None, *x)),
            _ => None,
        }
    }
    match (num(a), num(b)) {
        (Some((Some(x), _)), Some((Some(y), _))) => x == y,
        (Some((Some(n), _)), Some((None, x))) | (Some((None, x)), Some((Some(n), _))) => {
            x.is_finite() && x.fract() == 0.0 && n.text() == format!("{x:.0}").replace("-0", "0")
        }
        (Some((None, x)), Some((None, y))) => x == y,
        (Some(_), None) | (None, Some(_)) => false,
        (None, None) => match (a, b) {
            (Py::Null, Py::Null) => true,
            (Py::Str(x), Py::Str(y)) => x == y,
            (Py::List(x), Py::List(y)) => x.len() == y.len() && x.iter().zip(y).all(|(p, q)| py_eq(p, q)),
            (Py::Obj(x), Py::Obj(y)) => {
                x.len() == y.len() && x.iter().all(|(k, v)| y.iter().any(|(k2, v2)| k == k2 && py_eq(v, v2)))
            }
            _ => false,
        },
    }
}

fn obj<'a>(f: &str, v: &'a Py, what: &str) -> R<&'a Py> {
    match v {
        Py::Obj(_) => Ok(v),
        _ => Err(format!("{f}: {what} must be an object").into()),
    }
}

fn has(v: &Py, k: &str) -> bool {
    matches!(v, Py::Obj(kv) if kv.iter().any(|(have, _)| have == k))
}

fn need<'a>(f: &str, v: &'a Py, k: &str) -> R<&'a Py> {
    if has(v, k) { Ok(v.get(k)) } else { Err(format!("{f}: {k} is missing").into()) }
}

fn small_int(f: &str, v: &Py, what: &str) -> R<i64> {
    match v {
        Py::Int(n) => n.as_i64().ok_or_else(|| format!("{f}: {what} must be a whole number of 64 bits").into()),
        _ => Err(format!("{f}: {what} must be a whole number").into()),
    }
}

fn py_text<'a>(f: &str, v: &'a Py, what: &str) -> R<&'a str> {
    match v {
        Py::Str(s) => Ok(s),
        _ => Err(format!("{f}: {what} must be text").into()),
    }
}

/// Text with something in it besides [`TRIM`]'s characters (the same set a typed price is trimmed of; "blank"
/// otherwise).
fn not_blank(s: &str) -> bool {
    s.chars().any(|c| !TRIM.contains(&c))
}

// --- the record ---------------------------------------------------------------------------------------------------

/// What a record lacks, as the refusal's words, or None.
fn lacks(item: &Py) -> Option<String> {
    let g = match item.get("productGuid") {
        Py::Str(s) if not_blank(s) => s.clone(),
        _ => return Some(LACKS_GUID.into()),
    };
    let finite_non_negative = |v: &Py| match v {
        Py::Int(n) => !n.is_negative(),
        Py::Float(x) => x.is_finite() && *x >= 0.0,
        _ => false,
    };
    let positive_int = |v: &Py| matches!(v, Py::Int(n) if !n.is_negative() && n.text() != "0");
    let missing = if !matches!(item.get("productType"), Py::Str(_)) {
        "productType"
    } else if !positive_int(item.get("id")) {
        "id"
    } else if !finite_non_negative(item.get("weightPerUnit")) {
        "weightPerUnit"
    } else if !finite_non_negative(item.get("analyteWeight")) {
        "analyteWeight"
    } else if !positive_int(item.get("serviceCenterId")) {
        "serviceCenterId"
    } else {
        return None;
    };
    Some(format!("the state's record of {g} lacks {missing}, so it can't be sold"))
}

/// The record the state system's own web page sends to CreateSalesRecords for `qty` units at `cents` each on day `z`,
/// or why it can't be built. Its weightPerUnit, analyteWeight, productGuid, productType (as productGroup), id and
/// serviceCenterId are the state record's own values, copied unchanged; productCost is cents x units / 100 and
/// costEach cents / 100, in dollars; dateOfSale is Pacific midnight of the sale's day.
/// The longest note a record carries.
pub const NOTE_MAX: usize = 100;

/// The strain as a note may carry it: text only; whitespace and control characters made spaces, accented Latin letters
/// made plain, every character but A-Z, a-z, 0-9, space and `- ' . + # ( ) /` dropped, runs of spaces made one,
/// trimmed. A batch or lot id (HB-/PL-, as the batch lookup gives when it knows no strain) is no strain.
fn note_strain(strain: &Py) -> String {
    let Py::Str(s) = strain else { return String::new() };
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        let plain = if c.is_whitespace() || c.is_control() { " " } else { plain_letters(c) };
        for c in plain.chars() {
            if (c.is_ascii_alphanumeric() || " -'.+#()/".contains(c)) && !(c == ' ' && out.ends_with(' ')) {
                out.push(c);
            }
        }
    }
    let out = out.trim().to_string();
    let lot_id = regex::Regex::new(&format!("(?i){}", crate::id_patterns::LOT_ID)).expect("the shared lot id pattern");
    if lot_id.is_match(&out) { String::new() } else { out }
}

/// A Latin letter with an accent or a ligature as plain letters (é to e, ß to ss); anything else as it is (and dropped
/// later when it isn't allowed).
fn plain_letters(c: char) -> &'static str {
    const MAP: &[(&str, &str)] = &[
        ("ÀÁÂÃÄÅĀĂĄ", "A"), ("àáâãäåāăą", "a"), ("ÇĆĈĊČ", "C"), ("çćĉċč", "c"), ("ĎĐ", "D"), ("ďđ", "d"),
        ("ÈÉÊËĒĔĖĘĚ", "E"), ("èéêëēĕėęě", "e"), ("ĜĞĠĢ", "G"), ("ĝğġģ", "g"), ("ĤĦ", "H"), ("ĥħ", "h"),
        ("ÌÍÎÏĨĪĬĮİ", "I"), ("ìíîïĩīĭįı", "i"), ("Ĵ", "J"), ("ĵ", "j"), ("Ķ", "K"), ("ķ", "k"), ("ĹĻĽĿŁ", "L"),
        ("ĺļľŀł", "l"), ("ÑŃŅŇ", "N"), ("ñńņň", "n"), ("ÒÓÔÕÖØŌŎŐ", "O"), ("òóôõöøōŏő", "o"), ("ŔŖŘ", "R"),
        ("ŕŗř", "r"), ("ŚŜŞŠ", "S"), ("śŝşš", "s"), ("ŢŤŦ", "T"), ("ţťŧ", "t"), ("ÙÚÛÜŨŪŬŮŰŲ", "U"),
        ("ùúûüũūŭůűų", "u"), ("Ŵ", "W"), ("ŵ", "w"), ("ÝŸŶ", "Y"), ("ýÿŷ", "y"), ("ŹŻŽ", "Z"), ("źżž", "z"),
        ("ß", "ss"), ("Æ", "AE"), ("æ", "ae"), ("Œ", "OE"), ("œ", "oe"), ("Þ", "TH"), ("þ", "th"), ("Ð", "D"), ("ð", "d"),
    ];
    for (from, to) in MAP {
        if from.contains(c) {
            return to;
        }
    }
    // not in the table: kept only when it is itself allowed (an ASCII character), else dropped by the caller
    const ASCII: &str = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
    ASCII.find(c).map(|i| &ASCII[i..i + 1]).unwrap_or("")
}

/// The unit's mg TPE for the note: the record's own weightPerUnit x [lot_tpe] (mg/g, the lot's lab-report TPE), rounded
/// up by the dose rule; None when lot_tpe isn't a finite number above 0, is more than 0.005 below the record's
/// analyteWeight (the TPE is to 2 places; one below the state's own psilocybin is doubtful), the weight isn't a number,
/// or the mg isn't 1 to 99,999.
fn note_mg(item: &Py, lot_tpe: &Py) -> Option<i64> {
    let tpe = match lot_tpe {
        Py::Int(n) => n.as_f64(),
        Py::Float(x) => *x,
        _ => return None,
    };
    if !tpe.is_finite() || tpe <= 0.0 {
        return None;
    }
    let psilocybin = match item.get("analyteWeight") {
        Py::Int(n) => Some(n.as_f64()),
        Py::Float(x) => Some(*x),
        _ => None,
    };
    if psilocybin.is_some_and(|aw| aw.is_finite() && tpe < aw - 0.005) {
        return None;
    }
    crate::dose::unit_mg_at(item, tpe).filter(|mg| (1..=99_999).contains(mg))
}

/// A record's notes: `<strain> - <n> mg TPE`, the strain alone, `<n> mg TPE` alone, or empty; at most [NOTE_MAX]
/// characters, the strain cut first. Never refuses anything.
pub(crate) fn sale_note(item: &Py, strain: &Py, lot_tpe: &Py) -> String {
    let strain = note_strain(strain);
    let mg = note_mg(item, lot_tpe);
    // a cut strain never ends in a space or a dangling - ( / +
    let cut = |s: &str, n: usize| s.chars().take(n).collect::<String>().trim_end_matches([' ', '-', '(', '/', '+']).to_string();
    match (strain.is_empty(), mg) {
        (true, None) => String::new(),
        (true, Some(mg)) => format!("{mg} mg TPE"),
        (false, None) => cut(&strain, NOTE_MAX),
        (false, Some(mg)) => {
            let tail = format!(" - {mg} mg TPE");
            let head = cut(&strain, NOTE_MAX - tail.len());
            if head.is_empty() { format!("{mg} mg TPE") } else { format!("{head}{tail}") }
        }
    }
}

fn build(item: &Py, cents: &Py, z: i64, dose: &Py, qty: &Py, note: &str) -> Result<String, String> {
    if let Some(why) = lacks(item) {
        return Err(why);
    }
    let cents = match int_of(cents) {
        Some(c) if (0..=i128::from(MAX_UNIT_CENTS)).contains(&c) => c as i64,
        _ => return Err(BAD_PRICE.into()),
    };
    let qty = match int_of(qty) {
        Some(q) if (1..=i128::from(MAX_QTY)).contains(&q) => q as i64,
        _ => return Err(BAD_QTY.into()),
    };
    let initial = match dose {
        Py::Str(d) if d == "initial" => true,
        Py::Str(d) if d == "secondary" => false,
        _ => return Err(BAD_DOSE.into()),
    };
    // whole cents times at most 999 stay far below 2**53: both divisions are Python's correctly rounded int / int
    let product_cost = py_float_repr((cents * qty) as f64 / 100.0);
    let cost_each = py_float_repr(cents as f64 / 100.0);
    let (ini, sec) = if initial { (qty, 0) } else { (0, qty) };
    Ok(format!(
        "{{\"analyteWeight\":{},\"changes\":null,\"costEach\":{cost_each},\"dateCreated\":\"\",\"dateDeleted\":null,\
         \"dateOfSale\":\"{}\",\"deleted\":false,\"deletedBy\":null,\"id\":0,\"initialDose\":{ini},\"isRefund\":\"\",\
         \"notes\":{},\"numberSold\":{qty},\"productCost\":{product_cost},\"productGroup\":{},\"productGuid\":{},\
         \"productId\":{},\"reasonDeleted\":null,\"saleNumber\":\"\",\"secondaryDose\":{sec},\"serviceCenterId\":{},\
         \"wasteOuts\":[],\"weightPerUnit\":{}}}",
        dump(item.get("analyteWeight")),
        pacific_midnight(z),
        quoted(note),
        dump(item.get("productType")),
        dump(item.get("productGuid")),
        dump(item.get("id")),
        dump(item.get("serviceCenterId")),
        dump(item.get("weightPerUnit")),
    ))
}

/// `{"item": object, "price_cents", "sale_date": "YYYY-MM-DD", "dose", "qty"}` -> `{"record": object | null,
/// "refusal": text | null}` (schemas/selling/build_sale.*): the record as sale_record.json has it, its values passed
/// through as the state gave them, or the words of why not. The date is not judged here
/// (check_sale_date).
pub fn build_sale_json(input_json: &str) -> R<String> {
    const F: &str = "selling.build_sale";
    let v = Py::parse(input_json)?;
    obj(F, &v, "the input")?;
    let item = obj(F, need(F, &v, "item")?, "item")?;
    let z = plain_date(F, &serde_json::to_value(py_text(F, need(F, &v, "sale_date")?, "sale_date")?)?, "sale_date")?;
    // the note's inputs are the record's lot's, given beside the item, never read from it
    let note = sale_note(item, v.get("strain"), v.get("lot_tpe"));
    Ok(match build(item, need(F, &v, "price_cents")?, z, need(F, &v, "dose")?, need(F, &v, "qty")?, &note) {
        Ok(record) => format!("{{\"record\":{record},\"refusal\":null}}"),
        Err(why) => format!("{{\"record\":null,\"refusal\":{}}}", quoted(&why)),
    })
}

// --- dates --------------------------------------------------------------------------------------------------------

/// `{"text", "today": "YYYY-MM-DD"}` -> `{"date": "YYYY-MM-DD" | null, "error": null | "bad" | "future"}`: the forms
/// Python's date.fromisoformat reads, "future" after today (sale_date.json).
pub fn parse_sale_date_json(input_json: &str) -> R<String> {
    const F: &str = "selling.parse_sale_date";
    let m = input(F, input_json)?;
    let today = plain_date(F, field(F, &m, "today")?, "today")?;
    let t = text(F, field(F, &m, "text")?, "text")?;
    Ok(match iso_date(t) {
        None => json!({"date": null, "error": "bad"}),
        Some(z) if z > today => json!({"date": null, "error": "future"}),
        Some(z) => json!({"date": iso(z), "error": null}),
    }
    .to_string())
}

/// `{"date", "today"}` -> `{"date", "error": null | "future" | "too_old"}`: a sale may be dated today or up to 365 days
/// back, wherever its date comes from (the cart, the single sale, the phone's pickers, a reviewed sale).
pub fn check_sale_date_json(input_json: &str) -> R<String> {
    const F: &str = "selling.check_sale_date";
    let m = input(F, input_json)?;
    let z = plain_date(F, field(F, &m, "date")?, "date")?;
    let today = plain_date(F, field(F, &m, "today")?, "today")?;
    let error = if z > today {
        Some("future")
    } else if z < today - RULE.backdate_days {
        Some("too_old")
    } else {
        None
    };
    Ok(json!({"date": iso(z), "error": error}).to_string())
}

/// `{"today": "YYYY-MM-DD"}` -> `{"earliest", "latest"}` (schemas/selling/sale_date_bounds.*): the days a sale may be
/// dated, as the date pickers offer them: today back to 365 calendar days before it, the bound check_sale_date holds.
/// An earliest day outside years 1..9999 is an input error.
pub fn sale_date_bounds_json(input_json: &str) -> R<String> {
    const F: &str = "selling.sale_date_bounds";
    let m = input(F, input_json)?;
    let today = plain_date(F, field(F, &m, "today")?, "today")?;
    let earliest = today - RULE.backdate_days;
    if !in_range(earliest) {
        return Err(format!("{F}: the earliest day falls outside years 1..9999").into());
    }
    Ok(json!({"earliest": iso(earliest), "latest": iso(today)}).to_string())
}

/// `{"date"}` -> `{"utc": "YYYY-MM-DDTHH:00:00.000Z"}`: Pacific midnight of the date as UTC, by the 2007 rule.
pub fn pacific_midnight_json(input_json: &str) -> R<String> {
    const F: &str = "selling.pacific_midnight";
    let m = input(F, input_json)?;
    Ok(json!({"utc": pacific_midnight(plain_date(F, field(F, &m, "date")?, "date")?)}).to_string())
}

/// Seconds since 1970 of `YYYY-MM-DD(T| )HH:MM[:SS[.fraction]]` and its zone offset in seconds (None: no zone), or
/// None when the text isn't that.
fn moment(text: &str) -> Option<(i64, Option<i64>)> {
    let b = text.as_bytes();
    if b.len() < 16 || !(b[10] == b'T' || b[10] == b' ') {
        return None;
    }
    let z = ymd(digits(&b[0..4])?, digits(&b[5..7])?, digits(&b[8..10])?).filter(|_| b[4] == b'-' && b[7] == b'-')?;
    let (hh, mm) = (digits(&b[11..13])?, digits(&b[14..16])?);
    if b[13] != b':' || hh > 23 || mm > 59 {
        return None;
    }
    let mut i = 16;
    let mut ss = 0;
    if b.get(i) == Some(&b':') {
        ss = digits(b.get(i + 1..i + 3)?)?;
        if ss > 59 {
            return None;
        }
        i += 3;
        if b.get(i) == Some(&b'.') {
            let n = b[i + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
            if n == 0 {
                return None;
            }
            i += 1 + n;
        }
    }
    let secs = z * 86_400 + hh * 3600 + mm * 60 + ss;
    let rest = &b[i..];
    let off = match rest {
        [] => None,
        [b'Z'] => Some(0),
        [s @ (b'+' | b'-'), h1, h2, b':', m1, m2] | [s @ (b'+' | b'-'), h1, h2, m1, m2] => {
            let (h, m) = (digits(&[*h1, *h2])?, digits(&[*m1, *m2])?);
            if h > 23 || m > 59 {
                return None;
            }
            Some(if *s == b'-' { -(h * 3600 + m * 60) } else { h * 3600 + m * 60 })
        }
        _ => return None,
    };
    Some((secs, off))
}

/// `{"now": RFC 3339 UTC}` -> `{"date"}`: the Pacific date of now, for a sale's default date, the date
/// pickers' last day and the check of a date.
pub fn today_json(input_json: &str) -> R<String> {
    const F: &str = "selling.today";
    let m = input(F, input_json)?;
    let now = text(F, field(F, &m, "now")?, "now")?;
    match moment(now) {
        Some((secs, Some(off))) => match pacific_day(secs - off) {
            Some(z) => Ok(json!({"date": iso(z)}).to_string()),
            None => Err(format!("{F}: now falls on a Pacific day outside years 1..9999").into()),
        },
        _ => Err(format!("{F}: now must be a time with its zone, YYYY-MM-DDTHH:MM:SSZ").into()),
    }
}

/// Python's `str.strip()` set: [`TRIM`] and U+001C..U+001F.
fn py_space(c: char) -> bool {
    TRIM.contains(&c) || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// `{"text": any}` -> `{"date": "YYYY-MM-DD" | null}`: the Pacific date of a failed sale's own dateOfSale, as the phone
/// sent it (Pacific midnight as UTC) or a plain date (salejobs.review_sale_date): ten characters are a date as
/// date.fromisoformat reads it; else `YYYY-MM-DD` and a time with its zone, read as its Pacific date; anything else
/// (a time with no zone names no one day) is null.
pub fn review_sale_date_json(input_json: &str) -> R<String> {
    const F: &str = "selling.review_sale_date";
    let v = Py::parse(input_json)?;
    obj(F, &v, "the input")?;
    let day = match need(F, &v, "text")? {
        Py::Str(s) => {
            let t = s.trim_matches(py_space);
            if t.is_empty() {
                None
            } else if t.chars().count() == 10 {
                iso_date(t)
            } else {
                match moment(t) {
                    Some((secs, Some(off))) => pacific_day(secs - off),
                    _ => None,
                }
            }
        }
        _ => None,
    };
    Ok(json!({"date": day.map(iso)}).to_string())
}

/// `{"text": text | null}` -> `{"date": "YYYY-MM-DD" | null}`: a state-site date as ISO, for the sales history the
/// phone reads from the state (state_date.dart's stateDateIso): `MM/DD/YYYY` (a one-digit month or day allowed) or
/// `YYYY-MM-DD`, after Dart's trim, anything after the first space or `T` ignored; an impossible date is null.
pub fn parse_state_date_json(input_json: &str) -> R<String> {
    const F: &str = "selling.parse_state_date";
    let v = Py::parse(input_json)?;
    obj(F, &v, "the input")?;
    let day = match need(F, &v, "text")? {
        Py::Str(s) => {
            let t = s.trim_matches(|c: char| TRIM.contains(&c) || c == '\u{feff}');
            let head = t.split([' ', 'T']).next().unwrap_or("");
            let b = head.as_bytes();
            let parts: Vec<&[u8]> = b.split(|c| *c == b'/').collect();
            let (y, m, d) = if parts.len() == 3 && (1..=2).contains(&parts[0].len()) && (1..=2).contains(&parts[1].len())
                && parts[2].len() == 4
            {
                (digits(parts[2]), digits(parts[0]), digits(parts[1]))
            } else if b.len() == 10 && b[4] == b'-' && b[7] == b'-' {
                (digits(&b[0..4]), digits(&b[5..7]), digits(&b[8..10]))
            } else {
                (None, None, None)
            };
            match (y, m, d) {
                (Some(y), Some(m), Some(d)) if (1..=12).contains(&m) && d >= 1 && d <= month_days(y, m) => {
                    Some(format!("{y:04}-{m:02}-{d:02}"))
                }
                _ => None,
            }
        }
        _ => None,
    };
    Ok(json!({"date": day}).to_string())
}

// --- the draw and the check --------------------------------------------------------------------------------------

/// `{"lines": [{"product", "qty", "dose"}], "lots": {product: [lot]}}` -> `{"draws": [[line, lot id, units]] | null,
/// "short": line | null}`: one draw across the whole sale, line by line, each in draw order (selling.allocate's), every
/// line taking from what the lines before it left (a lot shared by id); the first line its lots can't cover refuses it.
pub fn allocate_sale_json(input_json: &str) -> R<String> {
    const F: &str = "selling.allocate_sale";
    let m = input(F, input_json)?;
    let Value::Array(lines) = field(F, &m, "lines")? else { return Err(format!("{F}: lines must be a list").into()) };
    let Value::Object(by_product) = field(F, &m, "lots")? else { return Err(format!("{F}: lots must be an object").into()) };
    let mut left: HashMap<i64, i64> = HashMap::new();
    let mut draws = vec![];
    for (i, line) in lines.iter().enumerate() {
        let Value::Object(l) = line else { return Err(format!("{F}: line {i} must be an object").into()) };
        let product = text(F, field(F, l, "product")?, "a line's product")?;
        let mut need = int(F, field(F, l, "qty")?, "a line's qty")?;
        let ls = lots(F, by_product.get(product).ok_or_else(|| format!("{F}: no lots for line {i}'s product"))?)?;
        for k in draw_order(&ls) {
            if need <= 0 {
                break;
            }
            let have = *left.entry(ls[k].id).or_insert(ls[k].units);
            let take = need.min(have);
            if take > 0 {
                draws.push(json!([i, ls[k].id, take]));
                left.insert(ls[k].id, have - take);
                need -= take;
            }
        }
        if need > 0 {
            return Ok(json!({"draws": null, "short": i}).to_string());
        }
    }
    Ok(json!({"draws": draws, "short": null}).to_string())
}

/// A record id as Python's dict finds it: an integer, or a float that is one.
fn id_key(v: &Py) -> Option<String> {
    match v {
        Py::Int(n) => Some(n.text()),
        Py::Float(x) if x.is_finite() && x.fract() == 0.0 => Some(format!("{x:.0}").replace("-0", "0")),
        Py::Bool(b) => Some(u8::from(*b).to_string()),
        _ => None,
    }
}

/// The fields a sent record copies from the state's (the state's key, the record's key).
const COPIED: [(&str, &str); 5] = [
    ("productGuid", "productGuid"),
    ("productType", "productGroup"),
    ("weightPerUnit", "weightPerUnit"),
    ("analyteWeight", "analyteWeight"),
    ("serviceCenterId", "serviceCenterId"),
];

fn cap(lines: &[(&Py, &Py, bool)]) -> Option<String> {
    let items: Vec<String> = lines
        .iter()
        .map(|(rec, qty, initial)| {
            let fig = Py::Obj(vec![
                ("weightPerUnit".into(), rec.get("weightPerUnit").clone()),
                ("analyteWeight".into(), rec.get("analyteWeight").clone()),
            ]);
            format!("{{\"record\":{},\"qty\":{},\"dose\":\"{}\"}}", dump(&fig), dump(qty), if *initial { "initial" } else { "secondary" })
        })
        .collect();
    let ask = format!("{{\"sales\":[{{\"lines\":[{}]}}]}}", items.join(","));
    let answer = crate::dose::sale_limits_json(&ask).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok());
    match answer.as_ref().and_then(|a| a.get(0)) {
        Some(a) if a["allowed"] == json!(true) => None,
        Some(a) if a["allowed"] == json!(false) && a["error"].is_string() => a["error"].as_str().map(String::from),
        _ => Some(CAP_UNCHECKED.into()),
    }
}

/// `{"lines": [{"record_id", "guid", "qty", "dose"?}], "fresh": [state record], "center"?, "sent"?: [record | null],
/// "cap"?: bool}` -> `{"refusal": text | null}`: why the sale must not be sent, on the state's records as read just now,
/// in the sale worker's order: per line the other-center check, then the line's refusal for the units every line asks
/// of its record together (sellability, [`crate::selling`]); then every value a line's sent record copied must still
/// be the state's; then (unless `cap` is false: the caller holds the cap itself) the 50 mg cap ([`crate::dose`]) on
/// the fresh figures.
pub fn check_sale_json(input_json: &str) -> R<String> {
    const F: &str = "selling.check_sale";
    let v = Py::parse(input_json)?;
    obj(F, &v, "the input")?;
    let Py::List(lines) = need(F, &v, "lines")? else { return Err(format!("{F}: lines must be a list").into()) };
    let Py::List(fresh) = need(F, &v, "fresh")? else { return Err(format!("{F}: fresh must be a list").into()) };
    let center = v.get("center"); // null or absent: no other-center check (sale_check.json's records name none)
    if !matches!(center, Py::Int(_) | Py::Null) {
        return Err(format!("{F}: center must be a whole number or null").into());
    }
    let sent = match v.get("sent") {
        Py::Null => None,
        Py::List(s) if s.len() == lines.len() => Some(s),
        _ => return Err(format!("{F}: sent must be a list, one per line").into()),
    };
    let use_cap = match v.get("cap") {
        Py::Null => true,
        Py::Bool(b) => *b,
        _ => return Err(format!("{F}: cap must be true or false").into()),
    };
    let mut by_id: HashMap<String, &Py> = HashMap::new();
    for r in fresh {
        if has(r, "id") {
            if let Some(k) = id_key(r.get("id")) {
                by_id.insert(k, r);
            }
        }
    }
    let mut parsed = vec![];
    let mut want: HashMap<String, i128> = HashMap::new();
    for (i, l) in lines.iter().enumerate() {
        obj(F, l, &format!("line {i}"))?;
        let key = id_key(need(F, l, "record_id")?).ok_or_else(|| format!("{F}: line {i}'s record_id must be a number"))?;
        let guid = py_text(F, need(F, l, "guid")?, "a line's guid")?;
        let qty = int_of(need(F, l, "qty")?).ok_or_else(|| format!("{F}: line {i}'s qty must be a whole number"))?;
        let initial = matches!(l.get("dose"), Py::Str(d) if d == "initial");
        let sum = want.entry(key.clone()).or_default();
        *sum = sum.checked_add(qty).ok_or_else(|| format!("{F}: the units asked of record {key} are too many"))?; // M2
        parsed.push((key, guid, l.get("qty"), initial));
    }
    let refuse = |t: String| Ok(json!({"refusal": t}).to_string());
    for (key, guid, _, _) in &parsed {
        let rec = by_id.get(key).copied();
        let same_guid = rec.is_some_and(|r| matches!(r.get("productGuid"), Py::Str(g) if g == guid));
        if let Some(r) = rec {
            if same_guid && !matches!(center, Py::Null) && !py_eq(r.get("serviceCenterId"), center) {
                return refuse(format!("{guid} belongs to a different service center."));
            }
        }
        if !same_guid {
            return refuse(format!("{guid} is no longer in the state system's inventory for this service center."));
        }
        if let Some(why) = super::reason(rec, &Py::Int(Int::of_i128(want[key]))) {
            return refuse(format!("{guid}: {why}."));
        }
    }
    if let Some(sent) = sent {
        for ((key, _, _, _), rec) in parsed.iter().zip(sent) {
            if matches!(rec, Py::Null) {
                continue;
            }
            obj(F, rec, "a sent record")?;
            let state = by_id[key];
            let changed: Vec<&str> = COPIED
                .iter()
                .filter(|(k, sk)| {
                    let (a, b) = (state.get(k), rec.get(sk));
                    dump(a) != dump(b) && !(is_num(a) && is_num(b) && py_eq(a, b))
                })
                .map(|(k, _)| *k)
                .collect();
            if !changed.is_empty() {
                let who = match rec.get("productGuid") {
                    Py::Str(s) => s.clone(),
                    other => crate::py::show(other),
                };
                return refuse(format!(
                    "{who}: the state's record changed since the sale was priced ({}); nothing was sent.",
                    changed.join(", ")
                ));
            }
        }
    }
    if use_cap {
        let figures: Vec<(&Py, &Py, bool)> = parsed.iter().map(|(key, _, qty, initial)| (by_id[key], *qty, *initial)).collect();
        if let Some(why) = cap(&figures) {
            return refuse(why);
        }
    }
    Ok(json!({"refusal": null}).to_string())
}

// --- outcomes -----------------------------------------------------------------------------------------------------

/// The sale number a reply proves for `sent` records: one object back per record sent, every saleNumber the same text
/// with something besides [`TRIM`] in it, or the same integer token above 0 (77 and "77" are one sale number); never
/// 0, true/false, a float (77.0, 1e2), a list or an object.
fn proof(reply: &Py, sent: &Py) -> Option<String> {
    let sent = int_of(sent)?;
    let Py::List(rs) = reply else { return None };
    if sent < 1 || rs.len() as i128 != sent {
        return None;
    }
    let mut number: Option<String> = None;
    for r in rs {
        let n = match r {
            Py::Obj(_) => match r.get("saleNumber") {
                Py::Str(s) if not_blank(s) => s.clone(),
                Py::Int(n) if !n.is_negative() && n.text() != "0" => n.text(),
                _ => return None,
            },
            _ => return None,
        };
        match &number {
            Some(have) if *have != n => return None,
            _ => number = Some(n),
        }
    }
    number
}

/// `{"reply": any, "sent"}` -> `{"sale_number": text | null}`: what a CreateSalesRecords reply already read proves.
pub fn sale_proof_json(input_json: &str) -> R<String> {
    const F: &str = "selling.sale_proof";
    let v = Py::parse(input_json)?;
    obj(F, &v, "the input")?;
    Ok(json!({"sale_number": proof(need(F, &v, "reply")?, need(F, &v, "sent")?)}).to_string())
}

/// `{"event": {"kind", "status"?, "body"?}, "sent"}` -> `{"outcome": "not_sent" | "uncertain" | "recorded",
/// "sale_number": text | null}` (flows/contracts/write_outcomes.json): only a connection that never opened
/// (dns_failure, connect_refused, tls_failure) or a 4xx answer read in full is not sent; a 200 whose body proves the
/// sale is recorded; everything else, an event nothing names included, may have been recorded.
pub fn sale_outcome_json(input_json: &str) -> R<String> {
    const F: &str = "selling.sale_outcome";
    let v = Py::parse(input_json)?;
    obj(F, &v, "the input")?;
    let event = obj(F, need(F, &v, "event")?, "event")?;
    let sent = need(F, &v, "sent")?;
    let answer = |o: &str, n: Option<String>| Ok(json!({"outcome": o, "sale_number": n}).to_string());
    match event.get("kind") {
        Py::Str(k) if k == "dns_failure" || k == "connect_refused" || k == "tls_failure" => answer("not_sent", None),
        Py::Str(k) if k == "reply" => match (int_of(event.get("status")), event.get("body")) {
            (Some(200), Py::Str(body)) => match Py::parse(body) {
                Ok(reply) => match proof(&reply, sent) {
                    Some(n) => answer("recorded", Some(n)),
                    None => answer("uncertain", None),
                },
                Err(_) => answer("uncertain", None),
            },
            (Some(st), _) if (400..500).contains(&st) => answer("not_sent", None),
            _ => answer("uncertain", None),
        },
        _ => answer("uncertain", None),
    }
}

// --- reviewed sales and expiry ------------------------------------------------------------------------------------

/// `{"cost": number, "qty"}` -> `{"cents"}`: a reviewed sale's typed line total (productCost) to whole cents, half up
/// (the float's shortest digits read as an exact decimal), then the price each: that total / qty, rounded half up to
/// the cent.
pub fn review_each_json(input_json: &str) -> R<String> {
    const F: &str = "selling.review_each";
    let v = Py::parse(input_json)?;
    obj(F, &v, "the input")?;
    let qty = small_int(F, need(F, &v, "qty")?, "qty")?;
    if qty < 1 {
        return Err(format!("{F}: qty must be 1 or more").into());
    }
    // Python's Decimal(str(cost)) x 100, quantized half up: a float's repr read as an exact decimal
    let cents_of = |s: &str| -> R<i128> {
        let too_large = || -> crate::api::Error { format!("{F}: cost is too large").into() };
        let (mant, exp) = match s.split_once('e') {
            Some((m, e)) => (m, e.parse::<i64>().map_err(|_| too_large())?),
            None => (s, 0),
        };
        let neg = mant.starts_with('-');
        let mant = mant.trim_start_matches('-');
        let (whole, frac) = mant.split_once('.').unwrap_or((mant, ""));
        let n: i128 = format!("{whole}{frac}").parse().map_err(|_| too_large())?;
        let e = exp - frac.len() as i64 + 2; // cost x 100 = n x 10^e
        let mag = if e >= 0 {
            if e > 30 {
                return Err(too_large());
            }
            n.checked_mul(10i128.pow(e as u32)).ok_or_else(too_large)?
        } else if -e > 36 {
            0 // n has at most 17 digits: far below half a cent
        } else {
            let d = 10i128.pow((-e) as u32);
            n / d + i128::from(2 * (n % d) >= d)
        };
        Ok(if neg { -mag } else { mag })
    };
    let typed: i128 = match need(F, &v, "cost")? {
        Py::Null | Py::Bool(false) => 0,
        Py::Int(n) => n.as_i128().and_then(|c| c.checked_mul(100)).ok_or_else(|| format!("{F}: cost is too large"))?,
        Py::Float(x) if x.is_finite() => cents_of(&py_float_repr(*x))?,
        _ => return Err(format!("{F}: cost must be a finite number").into()),
    };
    let q = i128::from(qty);
    // checked, so a cost past i128 is an input error in release builds too, never a wrapped number
    let twice = typed.checked_mul(2).and_then(|t| t.checked_add(q)).ok_or_else(|| format!("{F}: cost is too large"))?;
    Ok(json!({"cents": i64::try_from(twice.div_euclid(2 * q)).map_err(|_| format!("{F}: cost is too large"))?}).to_string())
}

/// `{"expires", "today", "fresh_months"}` -> `{"expired", "words", "hue"}` (the server's expiry.py): expired from the
/// day after its date; months left = days / 30.4375; the hue 120 at `fresh_months` (at least 2) or more left, 30 at one
/// month, 0 at the date, in straight lines, by Python's `round` (half to even).
pub fn expiry_json(input_json: &str) -> R<String> {
    const F: &str = "selling.expiry";
    let m = input(F, input_json)?;
    let expires = plain_date(F, field(F, &m, "expires")?, "expires")?;
    let today = plain_date(F, field(F, &m, "today")?, "today")?;
    let fresh = int(F, field(F, &m, "fresh_months")?, "fresh_months")?.max(2);
    let expired = today >= expires + 1;
    let months = (expires - today) as f64 / 30.4375;
    let hue = if months >= fresh as f64 {
        120.0
    } else if months >= 1.0 {
        (30.0 + 90.0 * (months - 1.0) / (fresh - 1) as f64).round_ties_even()
    } else {
        (30.0 * months.max(0.0)).round_ties_even()
    };
    let whole = months.trunc();
    let words = if expired {
        "expired".to_string()
    } else if whole >= 1.0 {
        format!("{whole:.0} mo")
    } else {
        "<1 mo".to_string()
    };
    Ok(json!({"expired": expired, "words": words, "hue": hue as i64}).to_string())
}
