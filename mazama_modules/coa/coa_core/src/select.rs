//! Which lab-report documents to read for a lot (SM-06; COA-R1, COA-D9, COA-D12), from the state system's
//! GetPackagedProductInfo reply: every non-deprecated .pdf document of an accepted Potency test, not already
//! fetched, newest test first (undated last; equal dates keep the reply's order), each document once, at its newest
//! test's date. Held to corpus/select/cases.json, which the server and the phone (native Dart) run too.
use serde::Serialize;
use serde_json::Value;

use crate::label::{days_from_civil, civil_from_days};

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Document {
    pub doc_id: i64,
    /// ISO date of the test the document belongs to; `None` when the state gave no readable date.
    pub date: Option<String>,
}

/// A state-site date: MM/DD/YYYY (one-digit month or day allowed; anything after a space ignored) or ISO
/// YYYY-MM-DD (a time after it ignored). An impossible date (13/45/2026, 02/30/2026) is `None`, never rolled over.
pub fn state_date(s: &str) -> Option<(i32, u32, u32)> {
    let s = s.trim();
    let head = s.split([' ', 'T']).next().unwrap_or("");
    if !head.chars().all(|c| c.is_ascii_digit() || c == '/' || c == '-') {
        return None; // "+5" would parse as 5
    }
    let (y, m, d) = if let [m, d, y] = head.split('/').collect::<Vec<_>>()[..] {
        if !(1..=2).contains(&m.len()) || !(1..=2).contains(&d.len()) || y.len() != 4 {
            return None;
        }
        (y.parse().ok()?, m.parse().ok()?, d.parse().ok()?)
    } else if let [y, m, d] = head.split('-').collect::<Vec<_>>()[..] {
        if y.len() != 4 || m.len() != 2 || d.len() != 2 {
            return None;
        }
        (y.parse().ok()?, m.parse().ok()?, d.parse().ok()?)
    } else {
        return None;
    };
    if !(1..=12).contains(&m) || d == 0 {
        return None;
    }
    (civil_from_days(days_from_civil(y, m, d)) == (y, m, d)).then_some((y, m, d))
}

/// The documents to read, in order.
pub fn select_documents(info: &Value, already_have: &[i64]) -> Vec<Document> {
    let mut found: Vec<(Option<i64>, i64, Option<String>)> = Vec::new(); // (sort key: days, doc id, ISO date)
    let tests = info.get("testResults").and_then(Value::as_array).cloned().unwrap_or_default();
    for t in &tests {
        if t.get("test").and_then(Value::as_str) != Some("Potency") || t.get("status").and_then(Value::as_str) != Some("Accepted") {
            continue;
        }
        let day = t.get("dateCompleted").and_then(Value::as_str).and_then(state_date);
        let docs = t.get("testingManifest").and_then(|m| m.get("documents")).and_then(Value::as_array).cloned().unwrap_or_default();
        for d in &docs {
            let Some(id) = d.get("id").and_then(Value::as_i64) else { continue };
            let pdf = d.get("extension").and_then(Value::as_str).is_some_and(|e| e.eq_ignore_ascii_case(".pdf"));
            let deprecated = d.get("deprecated").and_then(Value::as_bool).unwrap_or(false);
            if !pdf || deprecated || already_have.contains(&id) {
                continue;
            }
            let key = day.map(|(y, m, dd)| days_from_civil(y, m, dd));
            found.push((key, id, day.map(|(y, m, dd)| format!("{y:04}-{m:02}-{dd:02}"))));
        }
    }
    // newest first, undated last; sort_by is stable, so equal dates keep the reply's order
    found.sort_by(|a, b| match (a.0, b.0) {
        (Some(x), Some(y)) => y.cmp(&x),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
    let mut out: Vec<Document> = Vec::new();
    for (_, doc_id, date) in found {
        if !out.iter().any(|d| d.doc_id == doc_id) {
            out.push(Document { doc_id, date });
        }
    }
    out
}
