//! coa_core: reads lab reports (certificates of analysis) into lab values, the same way on the server and the
//! phone. Input is `CoaText` (a platform's extracted words, [`text`]); output is `CoaParseResult` ([`result`]); the
//! reading rules are data ([`rules`], embedded from `mazama_modules/coa/rules/coa_rules.yaml`).
//! Design: specs/coa/03-architecture.md and 04-parsing.md.

pub mod id_patterns;
pub mod label;
pub mod lines;
pub mod lot;
pub mod names_table;
pub mod parse;
pub mod result;
pub mod rules;
pub mod scan;
pub mod select;
pub mod text;
pub mod tpe;

pub use label::{LabelInput, LabelOutcome, LabelSpec, build_label_spec, canonical_strain, clean_strain, parse_name};
pub use lines::{Line, lines};
pub use parse::{parse, parser_version};
pub use result::{Analytes, CoaParseResult, ReportInfo, Section, Status, Value};
pub use rules::{DEFAULT_RULES, Rules, RulesError};
pub use text::{CoaText, Page, Source, TextError, Word};

/// The whole pipeline on JSON, for bindings: CoaText JSON in, CoaParseResult JSON out, with the embedded rules
/// (or `rules_yaml` when given).
pub fn parse_json(coa_text_json: &str, rules_yaml: Option<&str>) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let rules = match rules_yaml {
        Some(y) => Rules::from_yaml(y).map_err(|e| e.to_string())?,
        None => Rules::default_rules(),
    };
    let text = CoaText::from_json(coa_text_json).map_err(|e| e.to_string())?;
    Ok(serde_json::to_string(&parse(&text, &rules))?)
}

/// AD-19 on JSON, for bindings (SM-07): `{"coa_text": CoaText, "lot": "PL-...", "state_psilocybin": 5.25 | null}` in,
/// `{"result": CoaParseResult, "found": {"section": i, "uid": "HB-...", "via": "own" | "request" | "state_psilocybin"} | null}`
/// out, with the embedded rules.
pub fn find_lot_json(request_json: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    #[derive(serde::Deserialize)]
    struct Request {
        coa_text: serde_json::Value,
        lot: String,
        #[serde(default)]
        state_psilocybin: Option<f64>,
    }
    let req: Request = serde_json::from_str(request_json)?;
    let rules = Rules::default_rules();
    let text = CoaText::from_json(&req.coa_text.to_string()).map_err(|e| e.to_string())?;
    let result = parse(&text, &rules);
    let found = lot::find_lot(&text, &result, &req.lot, req.state_psilocybin, &rules);
    Ok(serde_json::json!({"result": result, "found": found}).to_string())
}

/// A product name read for display (SM-19), on JSON, for bindings: `{"name": "GT 25 mg TPE FD (2027-01-31)"}` in,
/// `{"strain_raw", "strain", "code", "expiry"}` out: the strain as written, the strain cleaned and spelled the
/// built-in way (null when the name has no usable one), the type code and the ISO best-by date in the name.
pub fn name_json(input_json: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    #[derive(serde::Deserialize)]
    struct Input {
        name: String,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let info = parse_name(&input.name);
    let strain = info.strain.as_deref().filter(|raw| label::strain_ok(raw)).map(|raw| canonical_strain(&clean_strain(raw)));
    Ok(serde_json::json!({"strain_raw": info.strain, "strain": strain, "code": info.code, "expiry": info.expiry}).to_string())
}

/// Which documents to read for a lot, on JSON, for bindings (SM-06): a GetPackagedProductInfo reply and a JSON list
/// of document ids already fetched in, `[{"doc_id": 12, "date": "2026-03-04"}, ...]` out.
pub fn select_documents_json(info_json: &str, already_have_json: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let info: serde_json::Value = serde_json::from_str(info_json)?;
    let have: Vec<i64> = serde_json::from_str(already_have_json)?;
    Ok(serde_json::to_string(&select::select_documents(&info, &have))?)
}

/// The label spec on JSON, for bindings: LabelInput JSON in, LabelOutcome JSON out
/// ({"spec": ..., "warnings": [...]} or {"blocked": [...], "warnings": [...]}).
pub fn label_spec_json(input_json: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let input: LabelInput = serde_json::from_str(input_json)?;
    Ok(serde_json::to_string(&build_label_spec(&input)?)?)
}

/// Scan matching's first step on JSON, for bindings (scan.rs): `{"texts": [str], "guids": [str], "typed": bool}` in,
/// `{"matches": [{"guid", "hex", "dist", "line"}]}` out, best first: the package ids found in a label's text.
pub fn scan_find_ids_json(input_json: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
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
pub fn scan_closest_json(input_json: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    #[derive(serde::Deserialize)]
    struct Input {
        texts: Vec<String>,
        packages: Vec<scan::ScanPackage>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    Ok(serde_json::json!({"guesses": scan::closest(&input.texts, &input.packages)}).to_string())
}
