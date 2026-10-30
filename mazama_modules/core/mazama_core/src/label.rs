//! Label spec: what goes on a package's label, from the package record and its lot's report section. The one
//! implementation (SM-05): the server builds its input and reads the answer (mazama_sales `labelspec.py`), the phone
//! through mazama_core_ffi. The rules started as the server's (`package_label_spec`, `payloads.label_amounts`,
//! `plans.default_best_by`, `names.parse_product_name`, `strains.clean_strain`); owner decisions since: SM-D14 (TPE),
//! SM-D17 (rounding), SM-D18 (best-by from the state's test date), SM-D19 (every reason). Pure: no I/O, `today` is an
//! input. Golden cases in mazama_modules/coa/corpus/labels/ (expected.json generated from this module, reviewed).
//! Design: specs/coa/08-phone-label-debug.md.

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
    /// SM-D18: the date the state recorded the lot's accepted potency test as completed (ISO), which best-by counts
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

/// LabelSpec version 2 (specs/labels/04-label-spec.md).
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

use crate::names_table::{self, CODE_WORDS, STRAIN_MAX};   // the shared names table (SM-19)
static NAME_DOSE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*mg").unwrap());
static DOSE_ANYWHERE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^(\d{1,4}(?:\.\d{1,2})?)\s*mg\b").unwrap());
static CANONICAL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(
        r"(?i)^(?P<strain>.+?)\s+(?P<dose>\d{{1,4}}(?:\.\d{{1,2}})?)\s*mg(?:\s+TPE)?(?:\s+(?P<code>{CODE_WORDS}))?(?:\s*\((?P<exp>\d{{4}}-\d\d-\d\d)\))?$"
    ))
    .unwrap()
});
static TRAILING_EXPIRY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\(\s*(\d{4}-\d\d-\d\d)\s*\)\s*$").unwrap());
static TRAILING_CODE: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!(r"(?i)\s+(?P<code>{CODE_WORDS})$")).unwrap());
static MISSPELLINGS: LazyLock<Regex> = LazyLock::new(|| {
    let words: Vec<String> = names_table::MISSPELLINGS.iter().map(|(w, _)| regex::escape(w)).collect();
    Regex::new(&format!(r"(?i)\b({})\b", words.join("|"))).unwrap()
});
static STRAIN_BAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!("[^{}]", names_table::STRAIN_ALLOWED)).unwrap());
static SOURCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(crate::id_patterns::LOT_ID).unwrap()); // SM-09, SM-D7

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

fn code_of(word: &str) -> Option<String> {
    let w = word.to_uppercase();
    names_table::CODES.iter().find(|(spelling, _)| *spelling == w).map(|(_, code)| code.to_string())
}

/// `strains.fix_spelling`: a misspelt word ("Mazatapec") spelled right, wherever it is a whole word.
fn fix_spelling(s: &str) -> String {
    MISSPELLINGS
        .replace_all(s, |c: &regex::Captures| {
            let w = c[1].to_lowercase();
            names_table::MISSPELLINGS.iter().find(|(m, _)| *m == w).map_or(c[1].to_string(), |(_, right)| right.to_string())
        })
        .into_owned()
}

/// `strains.strain_key`: lower case, every run of other characters one space.
fn strain_key(name: &str) -> String {
    let lower = name.to_lowercase();
    let mut out = String::new();
    for part in lower.split(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit())).filter(|p| !p.is_empty()) {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(part);
    }
    out
}

/// `strains.canonical_strain` with the built-in spellings only ('GT' / 'golden' -> 'Golden Teacher'); a name it
/// doesn't know comes back unchanged. (The server also has the Strains page's spellings, which the phone can't see.)
pub fn canonical_strain(name: &str) -> String {
    builtin_strain(&strain_key(name)).unwrap_or_else(|| name.to_string())
}

fn builtin_strain(key: &str) -> Option<String> {
    names_table::BUILTIN_ALIASES
        .iter()
        .find(|(canon, aliases)| strain_key(canon) == key || aliases.iter().any(|a| strain_key(a) == key))
        .map(|(canon, _)| canon.to_string())
}

/// `strains.canonical_strain(name, extra)` with the Strains page's (spelling, name to show) pairs: they come first (a
/// later pair for the same spelling wins), and the name they point to is itself looked up among the built-in ones.
pub fn canonical_strain_with(name: &str, extras: &[(String, String)]) -> String {
    let key = strain_key(name);
    let mut chosen: Option<&String> = None;
    for (spelling, shown) in extras {
        let k = strain_key(spelling);
        if !k.is_empty() && k == key {
            chosen = Some(shown);
        }
    }
    match chosen {
        Some(shown) => builtin_strain(&strain_key(shown)).unwrap_or_else(|| shown.clone()),
        None => canonical_strain(name),
    }
}

/// `strains.clean_strain`: only safe characters, "Mazatapec" spelled "Maztapec", at most 30 characters.
pub fn clean_strain(s: &str) -> String {
    let fixed = fix_spelling(s);
    let safe = STRAIN_BAD.replace_all(&fixed, "");
    let trimmed = safe.trim_matches(|c| c == ' ' || c == '.');
    trimmed.chars().take(STRAIN_MAX).collect::<String>().trim().to_string()
}

/// `names._strain`'s validity check: no characters outside the safe set, and some letters left after cleaning.
pub(crate) fn strain_ok(raw: &str) -> bool {
    let raw = raw.trim();
    if STRAIN_BAD.is_match(&fix_spelling(raw)) {
        return false;
    }
    let c = clean_strain(raw);
    !c.is_empty() && c.chars().any(|ch| ch.is_ascii_alphabetic())
}

/// What `names.parse_product_name` reads from a product name, as far as labels need it.
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
    let t = desc.trim();
    if t.is_empty() {
        return NameInfo::default();
    }
    if let Some(m) = CANONICAL.captures(t) {
        let raw = m["strain"].trim().to_string();
        if !strain_ok(&raw) {
            return NameInfo { strain: Some(raw), ..Default::default() };
        }
        let expiry = m.name("exp").and_then(|e| iso_date(e.as_str())).map(|_| m["exp"].to_string());
        return NameInfo { strain: Some(raw), code: m.name("code").and_then(|c| code_of(c.as_str())), expiry };
    }
    let Some((start, end, _)) = search_not_after_digit(t, &DOSE_ANYWHERE) else {
        return NameInfo::default();
    };
    let raw = t[..start].trim().to_string();
    if !strain_ok(&raw) {
        return NameInfo { strain: (!raw.is_empty()).then_some(raw), ..Default::default() };
    }
    let rest = &t[end..];
    let expiry = TRAILING_EXPIRY.captures(rest).and_then(|c| iso_date(&c[1]).map(|_| c[1].to_string()));
    let without_date = TRAILING_EXPIRY.replace(rest, "");
    let code = TRAILING_CODE.captures(without_date.trim_end()).and_then(|c| code_of(&c["code"]));
    NameInfo { strain: Some(raw), code, expiry }
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

/// The report's "MM/DD/YYYY" -> days, when it is a real date.
fn us_date(s: &str) -> Option<i64> {
    let p: Vec<&str> = s.trim().split('/').collect();
    if p.len() != 3 {
        return None;
    }
    iso_date(&format!("{:0>4}-{:0>2}-{:0>2}", p[2], p[0], p[1]))
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

/// `plans.SUBTYPE_CODE` / `plans.type_code`: a certificate subtype's code, "HG" for a homogenized product without one.
fn subtype_code(subtype: &str, product_type: &str) -> String {
    let sub = subtype.trim();
    if sub.is_empty() && product_type.to_lowercase().contains("homogenized") {
        return "HG".to_string();
    }
    names_table::SUBTYPE_CODE.iter().find(|(s, _)| *s == sub).map_or(String::new(), |(_, c)| c.to_string())
}

/// The label for a package, or why there can be none. The checks run in the server's order (unit weight, lab
/// certificate and best-by, lab values, dose, strain) and every one that fails is reported (SM-D19); a check that
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
    // number, else worked out below from the unit weight and the label's own TPE, rounded up (AD-20, SM-D17)
    let name_dose = p.dose_mg.map(|d| d as f64).or_else(|| {
        search_not_after_digit(&p.description, &NAME_DOSE).and_then(|(_, _, d)| d.parse::<f64>().ok()).filter(|d| d.fract() == 0.0)
    });
    let per = p.weight_per_unit;
    let has_weight = per > 0.0;
    if !has_weight {
        blocked.push("the package has no unit weight".into());
    }
    let (fd, type_code) = match &p.subtype {
        Some(sub) => (sub.trim() == "Freeze dried", subtype_code(sub, &p.product_type)),
        None => (
            name.code.as_deref() == Some("FD"),
            name.code.clone().unwrap_or_else(|| subtype_code("", &p.product_type)),
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
        // TPE (SM-03: AD-18 as amended by SM-D14): the state's figure + factor x psilocin when the state has one,
        // else the lab's printed total, else the report's psilocybin + factor x psilocin
        let state_psilocybin = state.then_some(p.analyte_weight);
        tpe = crate::tpe::tpe(Some(psilocybin), Some(psilocin), s.lab_totals.get("tpe").copied(), state_psilocybin, TPE_FACTOR)
            .map(|t| round_to(t, 2));
    }
    let dose = match name_dose {
        Some(d) => Some(d as i64),
        // SM-D17: ceil(x - 1e-9), so 2.0 x 6.0 stays 12, not 13 through float noise
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
