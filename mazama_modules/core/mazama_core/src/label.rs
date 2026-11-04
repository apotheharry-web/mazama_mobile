//! Label spec: what goes on a package's label, from the package record and its lot's report section. The one
//! implementation: the server builds its input and reads the answer (mazama_sales `labelspec.py`), the phone
//! through mazama_core_ffi. Pure: no I/O, `today` is an input. Golden cases in mazama_modules/coa/corpus/labels/
//! (expected.json generated from this module, reviewed).
//!
//! The numbers on a label:
//! - psilocybin (mg/g): the state record's `analyteWeight` when it is above 0, else the report section's of-record
//!   psilocybin; psilocin (mg/g) is always the section's. ND and below-LOQ count as 0, not missing.
//! - TPE (mg/g): [`crate::tpe::tpe`] (the state's figure + 284.25 / 204.27 x psilocin when the state has one, else
//!   the lab's printed total, else the report's psilocybin + that factor x psilocin), rounded to 2 decimals.
//! - each analyte per unit (mg): unit weight (g) x mg/g, rounded to 4 decimals.
//! - dose (mg): the one chosen for a planned package, else a whole `<n> mg` in the name, else unit weight x the
//!   rounded TPE, rounded **up** to a whole mg (ceil(x - 1e-9), so float noise alone never adds a mg), so the
//!   labelled dose is never below what a unit holds.
//! - best-by: the one chosen, else the name's, else counted from the date the state recorded the lot's accepted
//!   potency test, else from `today` (with a warning), by the shelf-life settings (freeze-dried has its own).

use crate::coa::result::{Section, Value};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::LazyLock;

/// What `build_label_spec` reads.
#[derive(Debug, Clone, Deserialize)]
pub struct LabelInput {
    pub package: Package,
    pub section: Option<Section>,
    pub settings: ShelfLife,
    /// ISO date, "2026-10-20".
    pub today: String,
    /// The date the state recorded the lot's accepted potency test as completed (ISO), which best-by counts
    /// from when the name has none; with none, best-by counts from `today` (with a warning).
    #[serde(default)]
    pub test_date: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Package {
    pub pkpr: String,
    pub description: String,
    pub weight_per_unit: f64,
    #[serde(default)]
    pub product_type: String,
    /// The state's psilocybin figure, mg/g (0 when it has none).
    #[serde(default)]
    pub analyte_weight: f64,
    /// The batch/lot id the package was made from.
    #[serde(default)]
    pub lot: String,
    /// The strain as the caller knows it (the server: its certificate's file name and alias table); used before the
    /// name's and the report's when not blank.
    #[serde(default)]
    pub strain: Option<String>,
    /// The certificate's subtype ("Freeze dried", ...), when the caller has one (the server): it then decides the
    /// freeze-dried shelf life and the type code (`plans.type_code`), and the name's code doesn't. `None`: the name's
    /// code decides (the phone).
    #[serde(default)]
    pub subtype: Option<String>,
    /// A package still being planned: the dose the person chose (else the name's, else worked out from TPE).
    #[serde(default)]
    pub dose_mg: Option<i64>,
    /// A package still being planned: the best-by the person chose (ISO), before the name's or a counted one.
    #[serde(default)]
    pub best_by: Option<String>,
}

/// The server's shelfLife* settings.
#[derive(Debug, Clone, Deserialize)]
pub struct ShelfLife {
    pub shelf_months: i32,
    pub fd_months: i32,
    pub shelf_days: Option<i64>,
    pub fd_days: Option<i64>,
}

/// LabelSpec version 2.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LabelSpec {
    pub spec_version: u32,
    pub pkpr: String,
    pub strain: String,
    pub dose_mg_tpe: i64,
    pub net_wt_g: f64,
    pub tpe_mg_per_g: Option<f64>,
    /// mg per unit of each analyte the report gave a value for (lab spellings).
    pub per_unit_mg: BTreeMap<String, f64>,
    pub psilocybin_from: String,
    pub best_by: String,
    pub best_by_from: String,
    pub type_code: String,
    pub source: Option<String>,
    pub description: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum LabelOutcome {
    Spec { spec: LabelSpec, warnings: Vec<String> },
    Blocked { blocked: Vec<String>, warnings: Vec<String> },
}

/// Psilocybin / psilocin molar masses (g/mol): psilocin counted as psilocybin-equivalent.
pub const TPE_FACTOR: f64 = 284.25 / 204.27;

pub const NO_DATE: &str = "no certificate date: best-by counted from today";

pub use crate::names::{canonical_strain, canonical_strain_with, clean_strain};
static NAME_DOSE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*mg").unwrap());
static SOURCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(crate::id_patterns::LOT_ID).unwrap()); // the shared batch/lot id pattern

/// The first `<n> mg` in a package's name, `n` as the name writes it (1 to 4 digits, with up to 2 decimals; not
/// after a digit or a point; "mg" in any case, spaces allowed before it): the dose a label takes from the name when
/// no dose was chosen (a whole `n` only). `None` when the name has none.
pub fn name_dose(description: &str) -> Option<&str> {
    search_not_after_digit(description, &NAME_DOSE).map(|(_, _, d)| d)
}

/// [`name_dose`] on JSON, for bindings: `{"name": str}` in, `{"dose": str | null}` out.
pub fn name_dose_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Input {
        name: String,
    }
    let input: Input = serde_json::from_str(input_json)?;
    Ok(serde_json::json!({"dose": name_dose(&input.name)}).to_string())
}

/// Python's `(?<![0-9.])` + `pattern` searched left to right: the first position not preceded by a digit or a
/// dot where `anchored` (which starts with `^`) matches. -> (start, end, first group).
fn search_not_after_digit<'a>(s: &'a str, anchored: &Regex) -> Option<(usize, usize, &'a str)> {
    let mut prev: Option<char> = None;
    for (i, c) in s.char_indices() {
        if !matches!(prev, Some(p) if p.is_ascii_digit() || p == '.') {
            if let Some(m) = anchored.captures(&s[i..]) {
                let all = m.get(0).unwrap();
                return Some((i, i + all.end(), m.get(1).unwrap().as_str()));
            }
        }
        prev = Some(c);
    }
    None
}

/// What a product name says, as far as labels need it ([`crate::names::parse_product`], the server's reading).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct NameInfo {
    /// The strain as written (before cleaning), when the name has one.
    pub strain: Option<String>,
    /// FD, DH, CH, HN, HG, EX, GM.
    pub code: Option<String>,
    /// ISO date in the name, when it is a real date.
    pub expiry: Option<String>,
}

pub fn parse_name(desc: &str) -> NameInfo {
    let p = crate::names::parse_product(desc, &[], None).expect("no name format is given");
    NameInfo { strain: p.strain_raw, code: p.code, expiry: p.expiry }
}

// --- civil dates (proleptic Gregorian, days since 1970-01-01; H. Hinnant's algorithms) -----------------------

pub fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y as i64 - 1 } else { y as i64 };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

pub fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    (y as i32, m, d)
}

fn days_in_month(y: i32, m: u32) -> u32 {
    let (ny, nm) = if m == 12 { (y + 1, 1) } else { (y, m + 1) };
    (days_from_civil(ny, nm, 1) - days_from_civil(y, m, 1)) as u32
}

/// "2027-08-31" -> days, when it is a real date.
fn iso_date(s: &str) -> Option<i64> {
    let p: Vec<&str> = s.split('-').collect();
    if p.len() != 3 || p[0].len() != 4 || p[1].len() != 2 || p[2].len() != 2 {
        return None;
    }
    let (y, m, d) = (p[0].parse::<i32>().ok()?, p[1].parse::<u32>().ok()?, p[2].parse::<u32>().ok()?);
    (1..=12).contains(&m).then_some(())?;
    (1..=days_in_month(y, m)).contains(&d).then_some(())?;
    Some(days_from_civil(y, m, d))
}

fn iso(days: i64) -> String {
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

/// `plans.default_best_by`: `days` later when a number of days applies, else the last day of the month
/// `months` on.
fn best_by(from: i64, fd: bool, s: &ShelfLife) -> i64 {
    let days = if fd { s.fd_days.filter(|&d| d != 0).or(s.shelf_days) } else { s.shelf_days };
    if let Some(n) = days.filter(|&d| d != 0) {
        return from + n;
    }
    let (y, m, _) = civil_from_days(from);
    let months = if fd { s.fd_months } else { s.shelf_months };
    let total = y as i64 * 12 + (m as i64 - 1) + months as i64 + 1;
    let (ny, nm) = (total.div_euclid(12) as i32, (total.rem_euclid(12) + 1) as u32);
    days_from_civil(ny, nm, 1) - 1
}

fn round_to(x: f64, places: i32) -> f64 {
    let f = 10f64.powi(places);
    (x * f).round() / f
}

fn amount(v: &Value) -> Option<f64> {
    v.amount()
}

/// The label for a package, or why there can be none. The checks run in the server's order (unit weight, lab
/// certificate and best-by, lab values, dose, strain) and every one that fails is reported; a check that
/// can't run because an earlier one failed for the same missing input is left out rather than said twice.
pub fn build_label_spec(input: &LabelInput) -> Result<LabelOutcome, String> {
    let p = &input.package;
    let today = iso_date(&input.today).ok_or_else(|| format!("today is not a date: {:?}", input.today))?;
    let name = parse_name(&p.description);
    let sec = input.section.as_ref();
    let given_best_by = match p.best_by.as_deref() {
        Some(b) => Some(iso_date(b).ok_or_else(|| format!("best_by is not a date: {b:?}"))?),
        None => None,
    };
    let test_date = match input.test_date.as_deref() {
        Some(d) => Some(iso_date(d).ok_or_else(|| format!("test_date is not a date: {d:?}"))?),
        None => None,
    };
    let best_by_from = if given_best_by.is_some() {
        "given"
    } else if name.expiry.is_some() {
        "name"
    } else if test_date.is_some() {
        "test_date"
    } else {
        "today"
    };
    let warnings = if sec.is_some() && best_by_from == "today" { vec![NO_DATE.to_string()] } else { vec![] };
    let sid = SOURCE.is_match(&p.lot).then(|| p.lot.clone());
    let mut blocked: Vec<String> = Vec::new();

    // dose: the one the person chose for a planned package, else the first "<n> mg" in the name when it is a whole
    // number, else worked out below from the unit weight and the label's own TPE, rounded up so a unit never holds
    // more than the label says
    let name_dose = p.dose_mg.map(|d| d as f64).or_else(|| {
        name_dose(&p.description).and_then(|d| d.parse::<f64>().ok()).filter(|d| d.fract() == 0.0)
    });
    let per = p.weight_per_unit;
    let has_weight = per > 0.0;
    if !has_weight {
        blocked.push("the package has no unit weight".into());
    }
    let (fd, type_code) = match &p.subtype {
        Some(sub) => (sub.trim() == "Freeze dried", crate::names::type_code(sub, &p.product_type)),
        None => (
            name.code.as_deref() == Some("FD"),
            name.code.clone().unwrap_or_else(|| crate::names::type_code("", &p.product_type)),
        ),
    };
    let best = match (given_best_by, &name.expiry, sec) {
        (Some(b), _, _) => Some(b),
        (None, Some(e), _) => Some(iso_date(e).unwrap()),
        (None, None, Some(_)) => Some(best_by(test_date.unwrap_or(today), fd, &input.settings)),
        (None, None, None) => None,
    };
    if sec.is_none() {
        blocked.push(if best.is_none() {
            match &sid {
                Some(l) => format!("lot {l} has no lab certificate yet, so there are no lab values or best-by date to print"),
                None => "the package names no batch or lot to find its lab certificate by".to_string(),
            }
        } else {
            "there is no certificate with lab data linked to this batch/lot".to_string()
        });
    }
    let state = p.analyte_weight > 0.0;
    let mut values = None;
    if let Some(s) = sec {
        let psilocybin = if state { Some(p.analyte_weight) } else { amount(&s.analytes.psilocybin) };
        match (psilocybin, amount(&s.analytes.psilocin)) {
            (Some(a), Some(b)) => values = Some((s, a, b)),
            _ => blocked.push("the linked certificate has no psilocybin/psilocin values".into()),
        }
    }
    let mut per_unit_mg = BTreeMap::new();
    let mut tpe = None;
    if let Some((s, psilocybin, psilocin)) = values {
        per_unit_mg.insert("psilocybin".to_string(), round_to(per * psilocybin, 4));
        per_unit_mg.insert("psilocin".to_string(), round_to(per * psilocin, 4));
        for key in ["baeocystin", "norbaeocystin", "norpsilocin", "aeruginascin"] {
            if let Some(v) = s.analytes.get(key).and_then(amount) {
                per_unit_mg.insert(key.to_string(), round_to(per * v, 4));
            }
        }
        // TPE: the state's figure + factor x psilocin when the state has one, else the lab's printed total, else the
        // report's psilocybin + factor x psilocin; rounded to 2 decimals before the dose is worked out from it
        let state_psilocybin = state.then_some(p.analyte_weight);
        tpe = crate::tpe::tpe(Some(psilocybin), Some(psilocin), s.lab_totals.get("tpe").copied(), state_psilocybin, TPE_FACTOR)
            .map(|t| round_to(t, 2));
    }
    let dose = match name_dose {
        Some(d) => Some(d as i64),
        // rounded up, ceil(x - 1e-9), so 2.0 x 6.0 stays 12, not 13 through float noise
        None => tpe.filter(|_| has_weight).map(|t| (per * t - 1e-9).ceil() as i64).filter(|&d| d > 0),
    };
    // no dose: worth saying unless it only follows from the missing unit weight already reported
    if dose.is_none() && (has_weight || tpe.is_none()) {
        blocked.push("the package's name has no dose in mg, and the lab values give no TPE to work one out from".into());
    }
    let sample = sec.map(|s| s.sample.strip_suffix(" FD").unwrap_or(&s.sample).trim().to_string()).unwrap_or_default();
    let strain = p
        .strain
        .as_deref()
        .map(clean_strain)
        .filter(|x| !x.is_empty())
        .unwrap_or_else(|| clean_strain(name.strain.as_deref().filter(|x| !x.is_empty()).unwrap_or(&sample)));
    if strain.is_empty() {
        blocked.push("there is no strain name".into());
    }
    if !blocked.is_empty() {
        return Ok(LabelOutcome::Blocked { blocked, warnings });
    }
    let (best, dose) = (best.unwrap(), dose.unwrap());
    let spec = LabelSpec {
        spec_version: 2,
        pkpr: p.pkpr.clone(),
        strain,
        dose_mg_tpe: dose,
        net_wt_g: per,
        tpe_mg_per_g: tpe,
        per_unit_mg,
        psilocybin_from: if state { "state" } else { "coa" }.to_string(),
        best_by: iso(best),
        best_by_from: best_by_from.to_string(),
        type_code,
        source: sid,
        description: p.description.chars().take(100).collect(),
    };
    Ok(LabelOutcome::Spec { spec, warnings })
}
