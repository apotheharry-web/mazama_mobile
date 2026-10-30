//! The lab-report reader (certificates of analysis): input is `CoaText` (a platform's extracted words, [`text`]);
//! output is `CoaParseResult` ([`result`]); the reading rules are data ([`rules`], embedded from
//! `mazama_modules/coa/rules/coa_rules.yaml`). Design: specs/coa/03-architecture.md and 04-parsing.md.

pub mod lines;
pub mod lot;
pub mod parse;
pub mod result;
pub mod rules;
pub mod select;
pub mod text;

pub use lines::{Line, lines};
pub use parse::{parse, parser_version};
pub use result::{Analytes, CoaParseResult, ReportInfo, Section, Status, Value};
pub use rules::{DEFAULT_RULES, Rules, RulesError};
pub use text::{CoaText, Page, Source, TextError, Word};

/// The whole pipeline on JSON, for bindings: CoaText JSON in, CoaParseResult JSON out, with the embedded rules
/// (or `rules_yaml` when given).
pub fn parse_json(coa_text_json: &str, rules_yaml: Option<&str>) -> Result<String, crate::api::Error> {
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
pub fn find_lot_json(request_json: &str) -> Result<String, crate::api::Error> {
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

/// Which documents to read for a lot, on JSON, for bindings (SM-06): a GetPackagedProductInfo reply and a JSON list
/// of document ids already fetched in, `[{"doc_id": 12, "date": "2026-03-04"}, ...]` out.
pub fn select_documents_json(info_json: &str, already_have_json: &str) -> Result<String, crate::api::Error> {
    let info: serde_json::Value = serde_json::from_str(info_json)?;
    let have: Vec<i64> = serde_json::from_str(already_have_json)?;
    Ok(serde_json::to_string(&select::select_documents(&info, &have))?)
}

/// [`parse_json`] with the built-in rules, as the function table calls it (`coa.parse`): CoaText JSON in,
/// CoaParseResult JSON out.
pub fn parse_default_json(coa_text_json: &str) -> Result<String, crate::api::Error> {
    parse_json(coa_text_json, None)
}

/// [`parse_json`] with a rules file of the caller's, as the function table calls it (`coa.parse_with_rules`):
/// `{"coa_text": CoaText, "rules_yaml": "..."}` in, CoaParseResult JSON out.
pub fn parse_with_rules_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Input {
        coa_text: serde_json::Value,
        rules_yaml: String,
    }
    let input: Input = serde_json::from_str(input_json)?;
    parse_json(&input.coa_text.to_string(), Some(&input.rules_yaml))
}

/// [`select_documents_json`] on one JSON object, as the function table calls it (`coa.select_documents`):
/// `{"info": GetPackagedProductInfo reply, "already_have": [doc id, ...]}` in, `[{"doc_id", "date"}]` out.
pub fn select_documents_one_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(serde::Deserialize)]
    struct Input {
        info: serde_json::Value,
        already_have: Vec<i64>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    Ok(serde_json::to_string(&select::select_documents(&input.info, &input.already_have))?)
}
