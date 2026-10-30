//! `CoaParseResult`: what the parser returns. Mirrors `mazama_modules/coa/schema/coa_parse_result.schema.json`.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One analyte's reading, in mg/g.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Value {
    Number {
        value: f64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loq: Option<f64>,
    },
    Nd {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loq: Option<f64>,
    },
    BelowLoq {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loq: Option<f64>,
    },
    Missing,
    Ambiguous { candidates: Vec<String> },
}

impl Value {
    /// The amount to count in a total: a number, or 0 for not detected / below the LOQ; None when unknown.
    pub fn amount(&self) -> Option<f64> {
        match self {
            Value::Number { value, .. } => Some(*value),
            Value::Nd { .. } | Value::BelowLoq { .. } => Some(0.0),
            Value::Missing | Value::Ambiguous { .. } => None,
        }
    }
    pub fn is_known(&self) -> bool {
        self.amount().is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Analytes {
    pub psilocybin: Value,
    pub psilocin: Value,
    pub baeocystin: Value,
    pub norbaeocystin: Value,
    pub norpsilocin: Value,
    pub aeruginascin: Value,
}

impl Analytes {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match key {
            "psilocybin" => Some(&self.psilocybin),
            "psilocin" => Some(&self.psilocin),
            "baeocystin" => Some(&self.baeocystin),
            "norbaeocystin" => Some(&self.norbaeocystin),
            "norpsilocin" => Some(&self.norpsilocin),
            "aeruginascin" => Some(&self.aeruginascin),
            _ => None,
        }
    }
    pub fn all(&self) -> [(&'static str, &Value); 6] {
        [
            ("psilocybin", &self.psilocybin),
            ("psilocin", &self.psilocin),
            ("baeocystin", &self.baeocystin),
            ("norbaeocystin", &self.norbaeocystin),
            ("norpsilocin", &self.norpsilocin),
            ("aeruginascin", &self.aeruginascin),
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Ok,
    NeedsReview,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Section {
    pub uid: String,
    pub uid_folded: bool,
    /// 0-based page of the section's UID line.
    pub page: usize,
    pub is_fd: bool,
    pub sample: String,
    pub unit_found: Option<String>,
    pub analytes: Analytes,
    pub lab_totals: BTreeMap<String, f64>,
    pub tpe: Option<f64>,
    pub analyzed_date: Option<String>,
    pub status: Status,
    pub reasons: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReportInfo {
    pub lab: Option<String>,
    pub licensee: Option<String>,
    pub reported_date: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CoaParseResult {
    pub version: u32,
    pub parser_version: String,
    pub source_sha256: String,
    pub report: ReportInfo,
    pub sections: Vec<Section>,
    /// lower-case lot id -> index into `sections` of its value of record.
    pub of_record: BTreeMap<String, usize>,
}

impl CoaParseResult {
    /// The value-of-record section for a lot id (any case).
    pub fn of_record_for(&self, uid: &str) -> Option<&Section> {
        self.of_record.get(&uid.to_lowercase()).map(|&i| &self.sections[i])
    }
}
