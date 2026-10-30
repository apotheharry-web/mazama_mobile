//! Product names read for display (SM-19), with the shared names table ([`crate::names_table`]) through
//! [`crate::label`]'s name reader.

use crate::label::{self, canonical_strain, clean_strain, parse_name};

/// A product name read for display (SM-19), on JSON, for bindings: `{"name": "GT 25 mg TPE FD (2027-01-31)"}` in,
/// `{"strain_raw", "strain", "code", "expiry"}` out: the strain as written, the strain cleaned and spelled the
/// built-in way (null when the name has no usable one), the type code and the ISO best-by date in the name.
pub fn name_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(serde::Deserialize)]
    struct Input {
        name: String,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let info = parse_name(&input.name);
    let strain = info.strain.as_deref().filter(|raw| label::strain_ok(raw)).map(|raw| canonical_strain(&clean_strain(raw)));
    Ok(serde_json::json!({"strain_raw": info.strain, "strain": strain, "code": info.code, "expiry": info.expiry}).to_string())
}

const NAME_MAX: usize = 100;
const NO_STRAIN: &str = "there is no strain name yet (it comes from the COA)";
const NO_SUBTYPE: &str = "choose the product subtype in the certificate form first";
/// `payloads.SUBTYPE_ABBR`: the short spelling of a subtype in a product name (a homogenized lot carries none).
const SUBTYPE_ABBR: [(&str, &str); 4] = [("Freeze dried", "FD"), ("Dehydrated", "DH"), ("Chocolate", "choc"), ("Honey", "hn")];

/// `payloads.product_name` (specs/core row 12, FM-11): `(name, None)` or `(None, why not)`. "Golden Teacher" + "Dehydrated"
/// -> "Golden Teacher DH"; a homogenized lot is just the strain.
pub fn product_name(strain: &str, subtype: &str, kind: &str, product_type: &str) -> (Option<String>, Option<&'static str>) {
    let st = clean_strain(&canonical_strain(strain));
    if st.is_empty() {
        return (None, Some(NO_STRAIN));
    }
    let sub = crate::stock::py_strip(subtype);
    if sub == "Homogenized" || (kind == "lot" && sub.is_empty() && product_type.to_lowercase().contains("homogenized")) {
        return (Some(st.chars().take(NAME_MAX).collect()), None);
    }
    if sub.is_empty() {
        return (None, Some(NO_SUBTYPE));
    }
    let abbr = SUBTYPE_ABBR.iter().find(|(k, _)| *k == sub).map_or(sub, |(_, v)| v);
    (Some(format!("{st} {abbr}").chars().take(NAME_MAX).collect()), None)
}

/// `{strain, subtype, kind, product_type}` -> `{name, why}`.
pub fn product_name_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(serde::Deserialize)]
    struct Input {
        strain: Option<String>,
        subtype: Option<String>,
        kind: String,
        product_type: Option<String>,
    }
    let i: Input = serde_json::from_str(input_json)?;
    let (name, why) = product_name(i.strain.as_deref().unwrap_or(""), i.subtype.as_deref().unwrap_or(""), &i.kind, i.product_type.as_deref().unwrap_or(""));
    Ok(serde_json::json!({"name": name, "why": why}).to_string())
}
