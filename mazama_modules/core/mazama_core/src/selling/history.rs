//! A center's recent sales, one line per sale (specs/center-web): the phone's Sales tab lists the state's sales
//! records, one per product sold; a sale's records all carry its sale number (what [`super::sale`]'s sale proof reads),
//! so the records are grouped by it, each group where its first record is, with its units and its total; and the
//! sales by the date of their first record (the days, as they come), each with how many sales and its total. Held to
//! mazama_modules/selling/history/sale_groups.json.
//!
//! | Input | Answer |
//! |---|---|
//! | a blank sale number (after trimming) | a sale of its own, never grouped with another |
//! | a record with no cost | the sale's total is null, never a smaller figure |
//! | a record with no units sold | the sale's units are null |
//! | a cost in dollars | to cents half up from its decimal digits (0.005 is half a cent: 1), per record, then summed |
//! | units | summed as given; a whole number is answered as an integer |
//! | a day's total | its sales' totals summed; null when any of them is |
//! | a record without a date | its sale is on the day "" |
use serde::Deserialize;
use serde_json::{Number, Value, json};

#[derive(Deserialize)]
struct Sale {
    #[serde(default)]
    sale_number: Option<String>,
    #[serde(default)]
    date: Option<String>,
    #[serde(default)]
    number_sold: Option<f64>,
    #[serde(default)]
    cost: Option<Value>,
}

/// Dollars as JSON writes them, to whole cents half up (away from zero), from the number's decimal digits so no
/// binary rounding moves a half cent. None for anything that isn't a finite number, or past i64 cents.
pub fn dollars_to_cents(v: &Value) -> Option<i64> {
    let n = v.as_number()?;
    if let Some(i) = n.as_i64() {
        return i.checked_mul(100);
    }
    let f = n.as_f64()?;
    if !f.is_finite() {
        return None;
    }
    // Rust prints a float's shortest round-trip decimal without an exponent
    let text = format!("{}", f.abs());
    let (whole, frac) = text.split_once('.').unwrap_or((&text, ""));
    let mut cents: i64 = whole.parse::<i64>().ok()?.checked_mul(100)?;
    let digits: Vec<i64> = frac.chars().map(|c| c.to_digit(10).map(i64::from)).collect::<Option<_>>()?;
    let d = |i: usize| digits.get(i).copied().unwrap_or(0);
    cents = cents.checked_add(d(0) * 10 + d(1))?;
    if d(2) >= 5 {
        cents = cents.checked_add(1)?;
    }
    Some(if f < 0.0 { -cents } else { cents })
}

fn units_value(u: f64) -> Value {
    if u.fract() == 0.0 && u.abs() < 9.0e15 {
        json!(u as i64)
    } else {
        Number::from_f64(u).map(Value::Number).unwrap_or(Value::Null)
    }
}

/// `selling.sale_groups`: `{sales: [{sale_number, date, number_sold, cost}]}` -> `{groups: [{sale_number, rows, units,
/// total_cents}], days: [{date, groups, sales, total_cents}]}`.
pub fn sale_groups_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Input {
        sales: Vec<Sale>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    struct Group {
        number: String,
        date: String,
        rows: Vec<usize>,
        units: Option<f64>,
        cents: Option<i64>,
    }
    let mut groups: Vec<Group> = Vec::new();
    for (i, s) in input.sales.iter().enumerate() {
        let number = s.sale_number.as_deref().unwrap_or("").trim().to_string();
        let cents = s.cost.as_ref().and_then(dollars_to_cents);
        let at = if number.is_empty() { None } else { groups.iter().position(|g| g.number == number) };
        match at {
            Some(g) => {
                let g = &mut groups[g];
                g.rows.push(i);
                g.units = g.units.zip(s.number_sold).map(|(a, b)| a + b);
                g.cents = g.cents.zip(cents).and_then(|(a, b)| a.checked_add(b));
            }
            None => groups.push(Group {
                number,
                date: s.date.clone().unwrap_or_default(),
                rows: vec![i],
                units: s.number_sold,
                cents,
            }),
        }
    }
    // the days, in the order their first sale comes
    let mut days: Vec<(String, Vec<usize>, Option<i64>)> = Vec::new();
    for (gi, g) in groups.iter().enumerate() {
        match days.iter_mut().find(|d| d.0 == g.date) {
            Some(d) => {
                d.1.push(gi);
                d.2 = d.2.zip(g.cents).and_then(|(a, b)| a.checked_add(b));
            }
            None => days.push((g.date.clone(), vec![gi], g.cents)),
        }
    }
    let days: Vec<Value> = days
        .into_iter()
        .map(|(date, gs, cents)| json!({"date": date, "sales": gs.len(), "groups": gs, "total_cents": cents}))
        .collect();
    let out: Vec<Value> = groups
        .into_iter()
        .map(|g| {
            json!({
                "sale_number": g.number,
                "rows": g.rows,
                "units": g.units.map(units_value).unwrap_or(Value::Null),
                "total_cents": g.cents,
            })
        })
        .collect();
    Ok(json!({"groups": out, "days": days}).to_string())
}
