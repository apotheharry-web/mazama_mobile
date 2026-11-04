//! A cart priced as a whole, a line priced on its own, and which lot a unit is drawn from. One rule for the server (pricing.price_cart, carts.build_cart's lines, selling.draw_order /
//! allocate, through the binding) and the phone (cart_pricing.dart's priceWholeCart, the cart's line dialog,
//! packages_client.dart's drawOrder / allocateLots, through the FFI), held to mazama_modules/selling/vectors/cart.json,
//! allocate.json and pricing_cases.json.
//!
//! | Input | Answer |
//! |---|---|
//! | a line priced at a rate per mg that comes to over $10,000 a unit | refused, `unit_cap` |
//! | a total shared over lines whose remainders are equal | the earlier line gets the cent ([`super::pricing::share_total`]) |
//! | two lots of one expiry whose quantities differ only below a unit | whole units (toward zero) decide, then the lower id |
//! | a line's mg that isn't a whole number of 0 or more, a quantity outside 1..999, a group not A or B | an input error |
//!
//! A lot only the state lists (`state_only`, with no lab report of its own) never comes before a lab lot.
use std::cmp::Ordering;

use serde_json::{Value, json};

use super::pricing::{
    MAX_PER_MG_CENTS, MAX_TOTAL_CENTS, MAX_UNIT_CENTS, R, field, flag, input, int, parse_price, share_total, share_wide, text,
    with_tax,
};

struct Line {
    group: u8, // b'A' or b'B'
    mg: i64,
    qty: i64,
}

fn lines(f: &str, v: &Value) -> R<Vec<Line>> {
    let Value::Array(items) = v else { return Err(format!("{f}: lines must be a list").into()) };
    items
        .iter()
        .enumerate()
        .map(|(i, l)| {
            let Value::Object(m) = l else { return Err(format!("{f}: line {i} must be an object").into()) };
            let group = match text(f, field(f, m, "group")?, "a line's group")? {
                "A" => b'A',
                "B" => b'B',
                _ => return Err(format!("{f}: line {i}'s group must be A or B").into()),
            };
            let mg = int(f, field(f, m, "mg")?, "a line's mg")?;
            let qty = int(f, field(f, m, "qty")?, "a line's qty")?;
            if mg < 0 {
                return Err(format!("{f}: line {i}'s mg must be a whole number of 0 or more (PRICE-7)").into());
            }
            if !(1..=999).contains(&qty) {
                return Err(format!("{f}: line {i}'s qty must be from 1 to 999").into());
            }
            Ok(Line { group, mg, qty })
        })
        .collect()
}

fn refused(n: usize, error: &str) -> Value {
    json!({"each": null, "line_errors": vec![Value::Null; n], "error": error})
}

/// One price per unit for every line of a cart priced as a whole, or why it can't be.
/// - total: the typed total in cents (plus tax, half up, when asked) is split between groups A (edibles and extracts)
///   and B (the rest) by the agreement's two weights when the cart has both ([`share_total`]: parts rounded down, the
///   cents left to the largest remainders); each group's part is shared the same way over its lines by mg x quantity
///   (by quantity alone when any line's mg is unknown); a unit costs its line's share / its quantity, half up to the
///   cent.
/// - per_mg: the typed rate is read into whole cents, tax added and rounded half up to whole cents first, then times
///   each unit's whole mg.
///
/// Any unit over $10,000 refuses the whole cart (`unit_cap`).
#[allow(clippy::too_many_arguments)]
fn price_cart(mode: &str, ls: &[Line], total: &str, per_mg: &str, tax: bool, pct: i64, agreement: [i64; 2]) -> R<Value> {
    let n = ls.len();
    if n == 0 {
        return Ok(refused(0, "empty"));
    }
    let each: Vec<i128> = match mode {
        "per_mg" => {
            let Some(mut rate) = parse_price(per_mg, MAX_PER_MG_CENTS) else { return Ok(refused(n, "rate")) };
            if tax {
                rate = with_tax(rate, pct)?;
            }
            if ls.iter().any(|l| l.mg <= 0) {
                let errs: Vec<Value> = ls.iter().map(|l| if l.mg > 0 { Value::Null } else { json!("no_mg") }).collect();
                return Ok(json!({"each": null, "line_errors": errs, "error": "no_mg"}));
            }
            ls.iter().map(|l| i128::from(rate) * i128::from(l.mg)).collect()
        }
        "total" => {
            let Some(t) = parse_price(total, MAX_TOTAL_CENTS) else { return Ok(refused(n, "total")) };
            let grand = if tax { with_tax(t, pct)? } else { t };
            let both = ls.iter().any(|l| l.group == b'A') && ls.iter().any(|l| l.group == b'B');
            let mut parts = [(b'A', grand), (b'B', grand)];
            if both {
                let s = share_total(grand, &agreement);
                parts = [(b'A', s[0]), (b'B', s[1])];
            }
            let mut each = vec![0i128; n];
            for (g, part) in parts {
                let idx: Vec<usize> = (0..n).filter(|i| ls[*i].group == g).collect();
                if idx.is_empty() {
                    continue;
                }
                let known = idx.iter().all(|i| ls[*i].mg > 0);
                let weights: Vec<i128> =
                    idx.iter().map(|i| i128::from(ls[*i].qty) * if known { i128::from(ls[*i].mg) } else { 1 }).collect();
                for (i, share) in idx.iter().zip(share_wide(part, &weights)) {
                    let q = i128::from(ls[*i].qty);
                    each[*i] = (2 * i128::from(share) + q) / (2 * q);
                }
            }
            each
        }
        _ => return Err("selling.price_cart: mode must be total or per_mg".into()),
    };
    if each.iter().any(|c| *c > i128::from(MAX_UNIT_CENTS)) {
        return Ok(refused(n, "unit_cap"));
    }
    let each: Vec<i64> = each.into_iter().map(|c| c as i64).collect(); // each within the unit cap
    Ok(json!({"each": each, "line_errors": vec![Value::Null; n], "error": null}))
}

/// `{"mode", "lines": [{"group", "mg", "qty"}], "total", "per_mg", "tax", "tax_percent", "agreement"}` ->
/// `{"each": [int] | null, "line_errors": [null | "no_mg"], "error": null | "empty" | "total" | "rate" | "no_mg" |
/// "unit_cap"}` (mazama_modules/core/schemas/selling/price_cart.*).
pub fn price_cart_json(input_json: &str) -> R<String> {
    const F: &str = "selling.price_cart";
    let m = input(F, input_json)?;
    let mode = text(F, field(F, &m, "mode")?, "mode")?;
    let ls = lines(F, field(F, &m, "lines")?)?;
    let total = text(F, field(F, &m, "total")?, "total")?;
    let per_mg = text(F, field(F, &m, "per_mg")?, "per_mg")?;
    let tax = flag(F, field(F, &m, "tax")?, "tax")?;
    let pct = int(F, field(F, &m, "tax_percent")?, "tax_percent")?;
    if !(0..=100).contains(&pct) {
        return Err(format!("{F}: tax_percent must be from 0 to 100").into());
    }
    let agreement = match field(F, &m, "agreement")? {
        Value::Array(a) if a.len() == 2 => [int(F, &a[0], "the agreement")?, int(F, &a[1], "the agreement")?],
        _ => return Err(format!("{F}: agreement must be two whole numbers").into()),
    };
    if agreement.iter().any(|w| *w < 1) {
        return Err(format!("{F}: the agreement's weights must be 1 or more").into());
    }
    if !ls.is_empty() && !matches!(mode, "total" | "per_mg") {
        return Err(format!("{F}: mode must be total or per_mg").into());
    }
    Ok(price_cart(mode, &ls, total, per_mg, tax, pct, agreement)?.to_string())
}

/// A whole number of the cart's totals: within 64 bits, else an input error (never a wrapped total).
fn total64(f: &str, x: i128) -> R<i64> {
    i64::try_from(x).map_err(|_| format!("{f}: a total doesn't fit 64 bits").into())
}

/// `{"lines": [{"qty", "price_cents", "group": "A" | "B" | null}], "sales": n}` -> `{"line_totals": [int], "total",
/// "group_totals": {"A", "B"}, "units", "all_total", "all_units"}` (schemas/selling/cart_total.*): each line's quantity x
/// its price each, their sum, the sum per group (a line of no group in neither), the units, and n sales of the cart, in
/// whole cents, exact. The figures are taken as given (what may be sold is held by the line dialog and build_sale); a
/// figure that isn't a 64-bit integer, n below 1 or an answer past 64 bits is an input error.
pub fn cart_total_json(input_json: &str) -> R<String> {
    const F: &str = "selling.cart_total";
    let m = input(F, input_json)?;
    let Value::Array(items) = field(F, &m, "lines")? else { return Err(format!("{F}: lines must be a list").into()) };
    let sales = int(F, field(F, &m, "sales")?, "sales")?;
    if sales < 1 {
        return Err(format!("{F}: sales must be 1 or more").into());
    }
    let (mut each, mut total, mut a, mut b, mut units) = (Vec::with_capacity(items.len()), 0i128, 0i128, 0i128, 0i128);
    for (i, l) in items.iter().enumerate() {
        let Value::Object(l) = l else { return Err(format!("{F}: line {i} must be an object").into()) };
        let qty = i128::from(int(F, field(F, l, "qty")?, "a line's qty")?);
        let price = i128::from(int(F, field(F, l, "price_cents")?, "a line's price_cents")?);
        let line = total64(F, qty * price)?; // two 64-bit factors fit i128; the line's total must fit 64 bits
        let wide = i128::from(line);
        match field(F, l, "group")? {
            Value::Null => {}
            Value::String(g) if g == "A" => a += wide,
            Value::String(g) if g == "B" => b += wide,
            _ => return Err(format!("{F}: line {i}'s group must be A, B or null").into()),
        }
        each.push(line);
        total += wide;
        units += qty;
    }
    // sums of 64-bit figures stay within i128 for any list that fits in memory; n x a 64-bit total does too
    let (total, units) = (total64(F, total)?, total64(F, units)?);
    let out = json!({
        "line_totals": each,
        "total": total,
        "group_totals": {"A": total64(F, a)?, "B": total64(F, b)?},
        "units": units,
        "all_total": total64(F, i128::from(sales) * i128::from(total))?,
        "all_units": total64(F, i128::from(sales) * i128::from(units))?,
    });
    Ok(out.to_string())
}

/// `{"mode": "each" | "per_mg", "text", "mg"}` -> `{"cents": int | null, "error": null | "price" | "rate" | "no_mg" |
/// "unit_cap"}`: a price each, or a rate per mg times the line's whole mg, within the $10,000 unit cap (over it is
/// refused, never sold).
pub fn line_price_json(input_json: &str) -> R<String> {
    const F: &str = "selling.line_price";
    let m = input(F, input_json)?;
    let mode = text(F, field(F, &m, "mode")?, "mode")?;
    let t = text(F, field(F, &m, "text")?, "text")?;
    let mg = int(F, field(F, &m, "mg")?, "mg")?;
    let out = match mode {
        "each" => match parse_price(t, MAX_UNIT_CENTS) {
            Some(c) => json!({"cents": c, "error": null}),
            None => json!({"cents": null, "error": "price"}),
        },
        "per_mg" => {
            if mg <= 0 {
                json!({"cents": null, "error": "no_mg"})
            } else if let Some(rate) = parse_price(t, MAX_PER_MG_CENTS) {
                let c = i128::from(rate) * i128::from(mg);
                if c > i128::from(MAX_UNIT_CENTS) {
                    json!({"cents": null, "error": "unit_cap"})
                } else {
                    json!({"cents": c as i64, "error": null})
                }
            } else {
                json!({"cents": null, "error": "rate"})
            }
        }
        _ => return Err(format!("{F}: mode must be each or per_mg").into()),
    };
    Ok(out.to_string())
}

pub(crate) struct Lot {
    pub(crate) id: i64,
    pub(crate) units: i64,
    expires: Option<String>,
    state_only: bool,
}

pub(crate) fn is_date(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return false;
    }
    let num = |r: std::ops::Range<usize>| -> Option<u32> {
        b[r].iter().try_fold(0u32, |a, c| c.is_ascii_digit().then(|| a * 10 + u32::from(c - b'0')))
    };
    let (Some(y), Some(mo), Some(d)) = (num(0..4), num(5..7), num(8..10)) else { return false };
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let days = match mo {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return false,
    };
    y >= 1 && (1..=days).contains(&d)
}

/// A lot's whole units: its quantity toward zero, null as 0; a figure past 64 bits is held at the 64-bit end.
fn units(f: &str, v: &Value) -> R<i64> {
    match v {
        Value::Null => Ok(0),
        Value::Number(n) => Ok(n.as_i64().unwrap_or_else(|| n.as_f64().map_or(0, |x| x.trunc() as i64))),
        _ => Err(format!("{f}: a lot's quantity must be a number or null").into()),
    }
}

pub(crate) fn lots(f: &str, v: &Value) -> R<Vec<Lot>> {
    let Value::Array(items) = v else { return Err(format!("{f}: lots must be a list").into()) };
    items
        .iter()
        .enumerate()
        .map(|(i, l)| {
            let Value::Object(m) = l else { return Err(format!("{f}: lot {i} must be an object").into()) };
            let expires = match field(f, m, "expires")? {
                Value::Null => None,
                Value::String(s) if is_date(s) => Some(s.clone()),
                _ => return Err(format!("{f}: lot {i}'s expires must be a date YYYY-MM-DD or null").into()),
            };
            let state_only = match m.get("state_only") {
                None => false,
                Some(v) => flag(f, v, "a lot's state_only")?,
            };
            Ok(Lot { id: int(f, field(f, m, "id")?, "a lot's id")?, units: units(f, field(f, m, "quantity")?)?, expires, state_only })
        })
        .collect()
}

/// The draw order: lab lots before state-only ones, the earlier expiry, an undated lot after every dated one, the fewer
/// whole units, the lower id; lots alike in all of that keep the order they were given in.
pub(crate) fn draw_order(ls: &[Lot]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..ls.len()).collect();
    order.sort_by(|a, b| {
        let (x, y) = (&ls[*a], &ls[*b]);
        let date = match (&x.expires, &y.expires) {
            (Some(p), Some(q)) => p.cmp(q),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => Ordering::Equal,
        };
        x.state_only.cmp(&y.state_only).then(date).then(x.units.cmp(&y.units)).then(x.id.cmp(&y.id))
    });
    order
}

/// `{"lots": [{"id", "quantity", "expires", "state_only"?}], "qty"}` -> `{"order": [id], "positions": [index], "takes":
/// [[id, units]] | null, "take_positions": [index] | null}`: `qty` units drawn in draw order, lots that give nothing left
/// out; null when the lots hold fewer than `qty` (refused, never put on the last lot).
pub fn allocate_json(input_json: &str) -> R<String> {
    const F: &str = "selling.allocate";
    let m = input(F, input_json)?;
    let ls = lots(F, field(F, &m, "lots")?)?;
    let qty = int(F, field(F, &m, "qty")?, "qty")?;
    let order = draw_order(&ls);
    let (mut takes, mut at, mut left) = (vec![], vec![], qty);
    for &i in &order {
        if left <= 0 {
            break;
        }
        let take = left.min(ls[i].units);
        if take > 0 {
            takes.push(json!([ls[i].id, take]));
            at.push(i);
            left -= take;
        }
    }
    let (takes, at) = if left > 0 { (Value::Null, Value::Null) } else { (json!(takes), json!(at)) };
    Ok(json!({"order": order.iter().map(|i| ls[*i].id).collect::<Vec<_>>(), "positions": order, "takes": takes,
              "take_positions": at})
    .to_string())
}
