//! Prices in whole cents (specs/core row 6, Task 12; SM-13): a typed price, total or rate per mg read into cents, tax
//! on top, a rate per mg times a unit's mg, a total shared over weights, money as the pages show it, and a product's
//! cart group. One rule for the server (pricing.py, selling.group_of, through the binding) and the phone
//! (lib/pricing.dart, lib/cart_pricing.dart, through the FFI), held to mazama_modules/selling/vectors/pricing.json,
//! cart.json and pricing_cases.json.
//!
//! It is the server's old rule with the owner's decisions of 2026-10-31 (CR-D6) where the two old copies disagreed,
//! "refuse wins":
//!
//! | ID | Input | Answer |
//! |---|---|---|
//! | PRICE-1 | a typed figure of 17-19 digits or more | compared with its cap digit by digit, never overflowing: over every cap, refused |
//! | PRICE-2 | a character only one app trimmed (U+001C..U+001F: Python; U+FEFF: Dart) | only what both trim is trimmed ([`TRIM`]); the rest is refused |
//! | PRICE-4 | a total shared over weights whose remainders are equal | exact integers, the cent to the earlier weight |
//! | PRICE-7 | an mg of more than two decimals in [`per_mg_price_json`] | an input error |
//!
//! Integers only: products are worked in `i128`, and a result that wouldn't fit 64 bits is an error, never a wrapped price.
use serde_json::{Map, Value, json};

use crate::api::Error;

/// The most one unit may cost: $10,000 (mazama_modules/selling/rules.yaml `pricing.max_unit_cents`).
pub const MAX_UNIT_CENTS: i64 = 1_000_000;
/// The most a rate per mg may be: $1,000 (`pricing.max_per_mg_cents`).
pub const MAX_PER_MG_CENTS: i64 = 100_000;
/// The most a whole cart's typed total may be: max_unit_cents x `pricing.max_total_units` (1,000).
pub const MAX_TOTAL_CENTS: i64 = MAX_UNIT_CENTS * 1000;
/// The words of a product type that put it in group A, any case (`pricing_modes.group_a_words`).
pub const GROUP_A_WORDS: [&str; 2] = ["edible", "extract"];

/// What is trimmed from both ends of a typed figure (PRICE-2): what both old apps trimmed, Dart's `String.trim` without
/// U+FEFF (Python's `str.strip` also took U+001C..U+001F; neither is trimmed here, so a figure with one is refused).
pub const TRIM: [char; 25] = [
    '\u{9}', '\u{a}', '\u{b}', '\u{c}', '\u{d}', ' ', '\u{85}', '\u{a0}', '\u{1680}', '\u{2000}', '\u{2001}', '\u{2002}',
    '\u{2003}', '\u{2004}', '\u{2005}', '\u{2006}', '\u{2007}', '\u{2008}', '\u{2009}', '\u{200a}', '\u{2028}', '\u{2029}',
    '\u{202f}', '\u{205f}', '\u{3000}',
];

pub(crate) type R<T> = Result<T, Error>;

/// The input object of the function `f`.
pub(crate) fn input(f: &str, text: &str) -> R<Map<String, Value>> {
    match serde_json::from_str::<Value>(text)? {
        Value::Object(m) => Ok(m),
        _ => Err(format!("{f}: the input must be an object").into()),
    }
}

pub(crate) fn field<'a>(f: &str, m: &'a Map<String, Value>, k: &str) -> R<&'a Value> {
    m.get(k).ok_or_else(|| format!("{f}: {k} is missing").into())
}

/// A JSON integer of 64 bits (a float, even 5.0, is not one).
pub(crate) fn int(f: &str, v: &Value, what: &str) -> R<i64> {
    match v {
        Value::Number(n) if n.is_i64() => Ok(n.as_i64().unwrap_or_default()),
        _ => Err(format!("{f}: {what} must be a whole number of 64 bits").into()),
    }
}

pub(crate) fn text<'a>(f: &str, v: &'a Value, what: &str) -> R<&'a str> {
    v.as_str().ok_or_else(|| format!("{f}: {what} must be text").into())
}

pub(crate) fn flag(f: &str, v: &Value, what: &str) -> R<bool> {
    v.as_bool().ok_or_else(|| format!("{f}: {what} must be true or false").into())
}

fn fits(f: &str, x: i128) -> R<i64> {
    i64::try_from(x).map_err(|_| format!("{f}: the result doesn't fit 64 bits").into())
}

/// A figure typed by a person -> whole cents, rounded half up, or None when it isn't a plain decimal (digits with at
/// most one '.' or ',' as the mark, at least one digit) or its exact value is over `max_cents`. Read digit by digit:
/// any number of digits is refused or read without overflow (PRICE-1).
pub fn parse_price(text: &str, max_cents: i64) -> Option<i64> {
    let t = text.trim_matches(|c| TRIM.contains(&c));
    let (whole, frac) = match t.find(['.', ',']) {
        Some(i) => (&t[..i], &t[i + 1..]),
        None => (t, ""),
    };
    let digits = |s: &str| s.bytes().all(|b| b.is_ascii_digit());
    if !digits(whole) || !digits(frac) || (whole.is_empty() && frac.is_empty()) {
        return None;
    }
    let whole = whole.trim_start_matches('0');
    if whole.len() > 15 {
        return None; // over every cap: the largest is $10,000,000, eight digits
    }
    let dollars: i64 = if whole.is_empty() { 0 } else { whole.parse().ok()? };
    let f = frac.as_bytes();
    let d = |i: usize| f.get(i).map_or(0, |b| i64::from(b - b'0'));
    let cents = dollars * 100 + d(0) * 10 + d(1);
    let rest = if f.len() > 2 { &f[2..] } else { &[] };
    if cents > max_cents || (cents == max_cents && rest.iter().any(|b| *b != b'0')) {
        return None; // the exact typed value is over the cap ("10000.004" is over $10,000)
    }
    Some(if rest.first().is_some_and(|b| *b >= b'5') { cents + 1 } else { cents })
}

/// The cap of a `max` name.
pub(crate) fn cap(f: &str, max: &str) -> R<i64> {
    match max {
        "unit" => Ok(MAX_UNIT_CENTS),
        "total" => Ok(MAX_TOTAL_CENTS),
        "per_mg" => Ok(MAX_PER_MG_CENTS),
        _ => Err(format!("{f}: max must be unit, total or per_mg").into()),
    }
}

/// `x / 100`, rounded half up (away from zero, as Python's ROUND_HALF_UP).
fn half_up_hundredths(x: i128) -> i128 {
    let q = (x.abs() + 50) / 100;
    if x < 0 { -q } else { q }
}

/// `cents` with `percent` per cent on top, rounded half up to the cent.
pub fn with_tax(cents: i64, percent: i64) -> R<i64> {
    fits("selling.with_tax", half_up_hundredths(i128::from(cents) * i128::from(100 + percent)))
}

/// One unit's price at `rate` cents per mg: rate x mg (in hundredths of a mg), half up to the cent.
pub fn per_mg_price(rate: i64, mg_hundredths: i64) -> R<i64> {
    fits("selling.per_mg_price", half_up_hundredths(i128::from(rate) * i128::from(mg_hundredths)))
}

/// A total shared in proportion to `weights`, to the cent, the parts adding up to exactly the total: every part rounded
/// down, the cents left over to the largest remainders, equal remainders to the earlier weight (PRICE-4). A weight of 0
/// or less anywhere: shared equally. `total` is 0 or more.
pub fn share_total(total: i64, weights: &[i64]) -> Vec<i64> {
    let w: Vec<i128> = weights.iter().map(|x| i128::from(*x)).collect();
    share_wide(total, &w)
}

/// [`share_total`] over weights of up to 2^100 (a cart's mg x quantity, exactly).
pub(crate) fn share_wide(total: i64, weights: &[i128]) -> Vec<i64> {
    let n = weights.len();
    if n == 0 {
        return vec![];
    }
    let w: Vec<i128> = if weights.iter().any(|x| *x <= 0) { vec![1; n] } else { weights.to_vec() };
    let s: i128 = w.iter().sum();
    let t = i128::from(total);
    let mut parts: Vec<i128> = w.iter().map(|x| t * x / s).collect();
    let rem: Vec<i128> = w.iter().zip(&parts).map(|(x, p)| t * x - p * s).collect();
    let left = t - parts.iter().sum::<i128>();
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by(|a, b| rem[*b].cmp(&rem[*a]).then(a.cmp(b)));
    for i in order.into_iter().take(usize::try_from(left).unwrap_or(0)) {
        parts[i] += 1;
    }
    parts.into_iter().map(|p| i64::try_from(p).unwrap_or(i64::MAX)).collect()
}

/// `cents` as the pages show it: "$1,234.56", a negative amount "$-12.50" (Python's f"${x:,.2f}"), exactly.
pub fn money(cents: i64) -> String {
    let a = i128::from(cents).abs();
    let digits = (a / 100).to_string();
    let mut dollars = String::new();
    for (i, ch) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            dollars.push(',');
        }
        dollars.push(ch);
    }
    format!("${}{dollars}.{:02}", if cents < 0 { "-" } else { "" }, a % 100)
}

/// "A" when a product's type contains a group A word, any case (edibles and extracts), else "B".
pub fn group_of(product_type: &str) -> &'static str {
    let t = product_type.to_lowercase();
    if GROUP_A_WORDS.iter().any(|w| t.contains(w)) { "A" } else { "B" }
}

/// An mg of at most two decimals, 0 or more (a JSON integer, or text of plain digits): in hundredths (PRICE-7).
fn mg_hundredths(f: &str, v: &Value) -> R<i64> {
    let bad = || -> Error { format!("{f}: mg is a whole number or a plain decimal of at most two places, 0 or more").into() };
    match v {
        Value::Number(_) => {
            let n = int(f, v, "mg")?;
            if n < 0 {
                return Err(bad());
            }
            n.checked_mul(100).ok_or_else(bad)
        }
        Value::String(s) => {
            let (whole, frac) = s.split_once('.').unwrap_or((s, ""));
            if !whole.bytes().all(|b| b.is_ascii_digit()) || !frac.bytes().all(|b| b.is_ascii_digit()) || frac.len() > 2
                || (whole.is_empty() && frac.is_empty())
            {
                return Err(bad());
            }
            let whole = whole.trim_start_matches('0');
            if whole.len() > 18 {
                return Err(bad());
            }
            let w: i64 = if whole.is_empty() { 0 } else { whole.parse().map_err(|_| bad())? };
            let fr: i64 = format!("{frac:0<2}").parse().map_err(|_| bad())?;
            w.checked_mul(100).and_then(|x| x.checked_add(fr)).ok_or_else(bad)
        }
        _ => Err(bad()),
    }
}

/// `{"text": string, "max": "unit" | "total" | "per_mg"}` -> `{"cents": int | null}`.
pub fn parse_price_json(input_json: &str) -> R<String> {
    const F: &str = "selling.parse_price";
    let m = input(F, input_json)?;
    let t = text(F, field(F, &m, "text")?, "text")?;
    let max = cap(F, text(F, field(F, &m, "max")?, "max")?)?;
    Ok(json!({"cents": parse_price(t, max)}).to_string())
}

/// `{"cents": int, "percent": 0..100}` -> `{"cents": int}`.
pub fn with_tax_json(input_json: &str) -> R<String> {
    const F: &str = "selling.with_tax";
    let m = input(F, input_json)?;
    let cents = int(F, field(F, &m, "cents")?, "cents")?;
    let pct = int(F, field(F, &m, "percent")?, "percent")?;
    if !(0..=100).contains(&pct) {
        return Err(format!("{F}: percent must be from 0 to 100").into());
    }
    Ok(json!({"cents": with_tax(cents, pct)?}).to_string())
}

/// `{"rate_cents": int >= 0, "mg": int | string}` -> `{"cents": int}`.
pub fn per_mg_price_json(input_json: &str) -> R<String> {
    const F: &str = "selling.per_mg_price";
    let m = input(F, input_json)?;
    let rate = int(F, field(F, &m, "rate_cents")?, "rate_cents")?;
    if rate < 0 {
        return Err(format!("{F}: rate_cents must be 0 or more").into());
    }
    let mg = mg_hundredths(F, field(F, &m, "mg")?)?;
    Ok(json!({"cents": per_mg_price(rate, mg)?}).to_string())
}

/// `{"total_cents": int >= 0, "weights": [int]}` -> `{"parts": [int]}`.
pub fn share_total_json(input_json: &str) -> R<String> {
    const F: &str = "selling.share_total";
    let m = input(F, input_json)?;
    let total = int(F, field(F, &m, "total_cents")?, "total_cents")?;
    if total < 0 {
        return Err(format!("{F}: total_cents must be 0 or more").into());
    }
    let Value::Array(ws) = field(F, &m, "weights")? else { return Err(format!("{F}: weights must be a list").into()) };
    let weights = ws.iter().map(|w| int(F, w, "a weight")).collect::<R<Vec<i64>>>()?;
    Ok(json!({"parts": share_total(total, &weights)}).to_string())
}

/// `{"cents": int}` -> `{"text": string}`.
pub fn money_json(input_json: &str) -> R<String> {
    const F: &str = "selling.money";
    let m = input(F, input_json)?;
    Ok(json!({"text": money(int(F, field(F, &m, "cents")?, "cents")?)}).to_string())
}

/// `{"product_type": string | null}` -> `{"group": "A" | "B"}`.
pub fn group_of_json(input_json: &str) -> R<String> {
    const F: &str = "selling.group_of";
    let m = input(F, input_json)?;
    let t = match field(F, &m, "product_type")? {
        Value::Null => "",
        v => text(F, v, "product_type")?,
    };
    Ok(json!({"group": group_of(t)}).to_string())
}
