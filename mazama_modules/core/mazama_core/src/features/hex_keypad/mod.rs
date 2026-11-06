//! The cart's PKPR keypad (specs/hex-keypad): for what the worker has typed and the PKPRs in the center's stock,
//! which of the sixteen keys can come next, which PKPRs match and whether exactly one is left. A PKPR matches when
//! the typed text appears anywhere in its hex part (the part after `PKPR-`, any case), as the cart's suggestions do;
//! a key is lit when the typed text followed by that key still appears in at least one.
use serde::Deserialize;
use serde_json::json;

/// The keypad's keys, in the order they are shown and listed.
pub const KEYS: &str = "1234567890abcdef";

/// A PKPR's hex part, or what was typed for one: trimmed, lower case, without a leading `pkpr-`.
fn hex_part(text: &str) -> String {
    let lower = text.trim().to_lowercase();
    match lower.strip_prefix("pkpr-") {
        Some(rest) => rest.to_string(),
        None => lower,
    }
}

/// What the keypad shows for [typed] against the stock's [pkprs].
#[derive(Debug, PartialEq, Eq)]
pub struct Keys {
    /// The keys that can come next, in [KEYS] order.
    pub keys: Vec<char>,
    /// The PKPRs that match, as given, in stock order, each once.
    pub matches: Vec<String>,
    /// The one PKPR left when exactly one matches.
    pub only: Option<String>,
}

pub fn keys(typed: &str, pkprs: &[String]) -> Keys {
    let needle = hex_part(typed);
    let mut matches: Vec<String> = Vec::new();
    let mut hexes: Vec<String> = Vec::new();
    for p in pkprs {
        let hex = hex_part(p);
        if hex.contains(&needle) && !matches.contains(p) {
            matches.push(p.clone());
            hexes.push(hex);
        }
    }
    let keys = KEYS
        .chars()
        .filter(|k| {
            let next = format!("{needle}{k}");
            hexes.iter().any(|h| h.contains(&next))
        })
        .collect();
    let only = if matches.len() == 1 { matches.first().cloned() } else { None };
    Keys { keys, matches, only }
}

/// `keypad.keys`: `{typed, pkprs}` -> `{keys, matches, only}`.
pub fn keys_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Input {
        typed: String,
        pkprs: Vec<String>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let k = keys(&input.typed, &input.pkprs);
    let keys: Vec<String> = k.keys.iter().map(|c| c.to_string()).collect();
    Ok(json!({"keys": keys, "matches": k.matches, "only": k.only}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const VECTORS: &str = include_str!("../../../../../features_vectors/hex_keypad/keys.json");

    #[test]
    fn every_shared_case() {
        let doc: serde_json::Value = serde_json::from_str(VECTORS).unwrap();
        let cases = doc["cases"].as_array().unwrap();
        assert!(cases.len() >= 10);
        for c in cases {
            let input = json!({"typed": c["typed"], "pkprs": c["pkprs"]}).to_string();
            let out: serde_json::Value = serde_json::from_str(&keys_json(&input).unwrap()).unwrap();
            assert_eq!(out["keys"], c["keys"], "{}", c["why"]);
            assert_eq!(out["matches"], c["matches"], "{}", c["why"]);
            assert_eq!(out["only"], c["only"], "{}", c["why"]);
        }
    }

    #[test]
    fn a_malformed_input_is_an_error_not_a_panic() {
        assert!(keys_json("{}").is_err());
        assert!(keys_json("not json").is_err());
        assert!(keys_json(r#"{"typed": 1, "pkprs": []}"#).is_err());
    }

    #[test]
    fn the_keys_are_the_sixteen_hex_characters() {
        let mut sorted: Vec<char> = KEYS.chars().collect();
        sorted.sort();
        assert_eq!(sorted.iter().collect::<String>(), "0123456789abcdef");
    }
}
