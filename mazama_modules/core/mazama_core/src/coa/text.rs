//! `CoaText`: the words of one lab report with their boxes, as a platform's extractor hands them over.
//! Mirrors `mazama_modules/coa/schema/coa_text.schema.json` (version 1). Coordinates are PDF points from the
//! top-left corner of the page.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CoaText {
    pub version: u32,
    pub source_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extractor: Option<String>,
    pub pages: Vec<Page>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    TextLayer,
    Ocr,
    None,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Page {
    pub index: usize,
    pub width: f64,
    pub height: f64,
    pub source: Source,
    pub engine: String,
    pub words: Vec<Word>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Word {
    pub text: String,
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
    #[serde(default)]
    pub conf: Option<f64>,
}

impl Word {
    pub fn height(&self) -> f64 {
        (self.y1 - self.y0).max(0.0)
    }
    pub fn center_x(&self) -> f64 {
        (self.x0 + self.x1) / 2.0
    }
    pub fn center_y(&self) -> f64 {
        (self.y0 + self.y1) / 2.0
    }
}

#[derive(Debug)]
pub enum TextError {
    Json(serde_json::Error),
    Version(u32),
}

impl std::fmt::Display for TextError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TextError::Json(e) => write!(f, "not a CoaText document: {e}"),
            TextError::Version(v) => write!(f, "CoaText version {v} is not supported (expected 1)"),
        }
    }
}

impl std::error::Error for TextError {}

impl CoaText {
    /// Reads a CoaText JSON document, refusing unknown fields and versions.
    pub fn from_json(s: &str) -> Result<CoaText, TextError> {
        let t: CoaText = serde_json::from_str(s).map_err(TextError::Json)?;
        if t.version != 1 {
            return Err(TextError::Version(t.version));
        }
        Ok(t)
    }
}
