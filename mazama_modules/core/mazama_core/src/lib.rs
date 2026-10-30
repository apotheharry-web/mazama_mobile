//! mazama_core: the rules both apps share, implemented once (specs/core). The lab-report reader is [`coa`]; label
//! specs, TPE, scan matching, the names table and the id patterns are top-level modules. Bindings: Python
//! (`mazama_core_py`, import `mazama_core`) and C for the phone (`mazama_core_ffi`), JSON in and out.

pub mod api;
mod api_table;
pub mod coa;
pub mod contracts;
pub mod id_patterns;
pub mod label;
pub mod manufacturing;
pub mod names;
pub mod names_table;
pub mod records;
pub mod scan;
pub mod stock;
pub mod stock_order;
pub mod tpe;

pub use coa::parser_version;
pub use names::name_json;
pub use label::{LabelInput, LabelOutcome, LabelSpec, build_label_spec, canonical_strain, clean_strain, parse_name};

/// The label spec on JSON, for bindings: LabelInput JSON in, LabelOutcome JSON out
/// ({"spec": ..., "warnings": [...]} or {"blocked": [...], "warnings": [...]}).
pub fn label_spec_json(input_json: &str) -> Result<String, crate::api::Error> {
    let input: LabelInput = serde_json::from_str(input_json)?;
    Ok(serde_json::to_string(&build_label_spec(&input)?)?)
}

/// Scan matching's first step on JSON, for bindings (scan.rs): `{"texts": [str], "guids": [str], "typed": bool}` in,
/// `{"matches": [{"guid", "hex", "dist", "line"}]}` out, best first: the package ids found in a label's text.
pub fn scan_find_ids_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(serde::Deserialize)]
    struct Input {
        texts: Vec<String>,
        guids: Vec<String>,
        #[serde(default)]
        typed: bool,
    }
    let input: Input = serde_json::from_str(input_json)?;
    Ok(serde_json::json!({"matches": scan::find_ids(&input.texts, &input.guids, input.typed)}).to_string())
}

/// Scan matching's second step on JSON, for bindings (scan.rs): `{"texts": [str], "packages": [{"guid", "records":
/// [{"weightPerUnit", "analyteWeight", "description", "quantity", "expires": "YYYY-MM-DD" | null}]}]}` in (only
/// records that can be sold), `{"guesses": [{"guid", "score", "why", "weight", "mg", "record", "stock"}]}` out, best
/// first: the packages the rest of a label fits when no id was found.
pub fn scan_closest_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(serde::Deserialize)]
    struct Input {
        texts: Vec<String>,
        packages: Vec<scan::ScanPackage>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    Ok(serde_json::json!({"guesses": scan::closest(&input.texts, &input.packages)}).to_string())
}
