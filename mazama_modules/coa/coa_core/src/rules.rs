//! The reading rules: `mazama_modules/coa/rules/coa_rules.yaml`, embedded at build time so every platform carries
//! the same copy. Unknown keys are refused, so a typo in the file fails loudly instead of being ignored.

use serde::Deserialize;
use std::collections::BTreeMap;

/// The rules file this crate was built with.
pub const DEFAULT_RULES: &str = include_str!("../../rules/coa_rules.yaml");

/// The analytes every result reports, in output order.
pub const ANALYTES: [&str; 6] = ["psilocybin", "psilocin", "baeocystin", "norbaeocystin", "norpsilocin", "aeruginascin"];

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rules {
    pub version: String,
    pub anchor: Anchor,
    pub confusables: BTreeMap<char, char>,
    pub sample: Sample,
    pub analytes: BTreeMap<String, Vec<String>>,
    pub lab_totals: BTreeMap<String, Vec<String>>,
    pub row_exclude_words: Vec<String>,
    pub table: Table,
    pub values: Values,
    pub units: BTreeMap<String, f64>,
    pub section_stop: Vec<String>,
    pub report: Report,
    pub tpe: Tpe,
    pub field_duplicate: FieldDuplicate,
    pub review_ranges_mg_g: BTreeMap<String, [f64; 2]>,
    pub lab_profiles: Vec<LabProfile>,
    pub lot_links: LotLinks,
}

/// AD-19: the labels on a report's request / chain of custody that pair a lot with the batch id the lab printed.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LotLinks {
    pub batch_labels: Vec<String>,
    pub lot_labels: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Anchor {
    pub labels: Vec<String>,
    pub id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sample {
    pub labels: Vec<String>,
    pub fd_markers: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Table {
    pub result_headers: Vec<String>,
    pub loq_headers: Vec<String>,
    pub unit_headers: Vec<String>,
    pub date_headers: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Values {
    pub nd: Vec<String>,
    pub below_loq: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Report {
    pub reported_labels: Vec<String>,
    pub date_formats: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tpe {
    pub psilocin_factor: f64,
    pub round: u32,
    pub lab_total_tolerance: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FieldDuplicate {
    pub tpe_tolerance: f64,
    pub detection_loq_multiple: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LabProfile {
    pub name: String,
    pub detect: Vec<String>,
    #[serde(default)]
    pub licensee_left_of: Option<String>,
    /// A batch/lot id alone on its line starts a section, as well as one after an anchor label (ChemHistory prints
    /// the id under the client's address with no label).
    #[serde(default)]
    pub anchor_alone: bool,
    /// Replace `sample.labels` for this lab ("Strain:" on ChemHistory reports, whose "Sample:" is the lab's own id).
    #[serde(default)]
    pub sample_labels: Option<Vec<String>>,
    /// How many lines above the anchor may hold the sample name (default 3).
    #[serde(default)]
    pub sample_lines_above: Option<usize>,
    /// Replace `table.result_headers` for this lab.
    #[serde(default)]
    pub result_headers: Option<Vec<String>>,
    /// The unit printed under the result column's header on the next line; picks that column when several headers
    /// share a name ("Mass" over "%" and "Mass" over "mg/g" on ChemHistory reports), and is the column's unit.
    #[serde(default)]
    pub result_unit: Option<String>,
    /// Replace `report.reported_labels` for this lab.
    #[serde(default)]
    pub reported_labels: Option<Vec<String>>,
    /// Replace `section_stop` for this lab (ChemHistory's "METRC Batch:" line, right under the id, isn't a QC page).
    #[serde(default)]
    pub section_stop: Option<Vec<String>>,
}

impl LabProfile {
    /// The rules with this lab's replacements applied.
    pub fn apply(&self, rules: &Rules) -> Rules {
        let mut r = rules.clone();
        if let Some(l) = &self.sample_labels {
            r.sample.labels = l.clone();
        }
        if let Some(h) = &self.result_headers {
            r.table.result_headers = h.clone();
        }
        if let Some(l) = &self.reported_labels {
            r.report.reported_labels = l.clone();
        }
        if let Some(l) = &self.section_stop {
            r.section_stop = l.clone();
        }
        r
    }
}

#[derive(Debug)]
pub struct RulesError(pub String);

impl std::fmt::Display for RulesError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "bad rules file: {}", self.0)
    }
}

impl std::error::Error for RulesError {}

impl Rules {
    pub fn from_yaml(s: &str) -> Result<Rules, RulesError> {
        let r: Rules = serde_yaml::from_str(s).map_err(|e| RulesError(e.to_string()))?;
        for a in ANALYTES {
            if !r.analytes.contains_key(a) {
                return Err(RulesError(format!("analytes: {a} is missing")));
            }
        }
        if let Some(extra) = r.analytes.keys().find(|k| !ANALYTES.contains(&k.as_str())) {
            return Err(RulesError(format!("analytes: {extra} is not a known analyte")));
        }
        regex::Regex::new(&r.anchor.id).map_err(|e| RulesError(format!("anchor.id: {e}")))?;
        for f in &r.report.date_formats {
            if !matches!(f.as_str(), "%m/%d/%Y" | "%m/%d/%y") {
                return Err(RulesError(format!("report.date_formats: {f} is not supported (only %m/%d/%Y and %m/%d/%y)")));
            }
        }
        Ok(r)
    }

    /// The rules this crate was built with.
    pub fn default_rules() -> Rules {
        Rules::from_yaml(DEFAULT_RULES).expect("the embedded rules file is valid (checked by the crate's tests)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_rules_load() {
        let r = Rules::default_rules();
        assert_eq!(r.units["%"], 10.0);
        assert_eq!(r.confusables[&'o'], '0');
        assert!(r.analytes["aeruginascin"].contains(&"Aeruginascin".to_string()));
        assert_eq!(r.lab_profiles[0].licensee_left_of.as_deref(), Some("Project:"));
    }

    #[test]
    fn a_typo_in_the_rules_is_refused() {
        let bad = DEFAULT_RULES.replace("section_stop:", "section_stops:");
        assert!(Rules::from_yaml(&bad).unwrap_err().0.contains("section_stops"));
    }

    #[test]
    fn an_unknown_analyte_is_refused() {
        let bad = DEFAULT_RULES.replace("  aeruginascin:  [", "  aeruginosin:  [");
        assert!(Rules::from_yaml(&bad).is_err());
    }
}
