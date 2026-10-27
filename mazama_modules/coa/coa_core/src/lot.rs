//! AD-19 (specs/coa/decisions.md; SM-07): which section is a lot's value of record, when the report may have printed
//! another id. The state links a document to a lot; a lab sometimes prints the batch the lot was made from as the
//! UID (document 3092: PL-de20657a submitted as HB-597a95ef). Held to corpus/lots/cases.json.

use crate::lines::Line;
use crate::parse::normalize_id;
use crate::result::{CoaParseResult, Status};
use crate::rules::Rules;
use crate::text::CoaText;
use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

/// How a lot's section was found.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Via {
    /// A section has the lot's own UID.
    Own,
    /// The report's own request / chain of custody pairs the lot with the one batch whose UID it printed.
    Request,
    /// The one primary section whose psilocybin equals the state's figure at 3 significant figures.
    StatePsilocybin,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LotMatch {
    /// Index into the parse result's `sections`.
    pub section: usize,
    /// That section's UID (not the lot's own id unless `via` is `own`).
    pub uid: String,
    pub via: Via,
}

fn ids(line: &Line, rules: &Rules, id_re: &Regex) -> Vec<String> {
    // "HB-82fc6356,HB-c44c4da5," is one word on the page: each id in it counts, in order
    line.words.iter().flat_map(|w| w.text.split(',')).filter_map(|t| normalize_id(t, rules, id_re)).map(|(id, _)| id).collect()
}

fn has(line: &str, labels: &[String]) -> bool {
    let low = line.to_lowercase();
    labels.iter().any(|l| low.contains(&l.to_lowercase()))
}

/// {lot: {batches}} from the report's own request / chain of custody: a line with a batch label ("Client Batch ID:
/// HB-...", or "Batch ID/METRC ID" with the id on the next line), then a lot label ("Harvest Lot/Process Lot") with a
/// PL- id on the same line or the next. Ids are normalised (HB-/PL- upper case, hex lower case).
pub fn lot_links(all: &[Line], rules: &Rules) -> BTreeMap<String, BTreeSet<String>> {
    let id_re = Regex::new(&format!("^(?i:{})$", rules.anchor.id)).expect("checked when the rules were loaded");
    let labels = &rules.lot_links;
    let mut links: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let (mut batch, mut want_batch, mut want_lot): (Option<String>, bool, bool) = (None, false, false);
    for line in all {
        let found = ids(line, rules, &id_re);
        let hb = found.iter().find(|i| i.starts_with("HB-")).cloned();
        let pl = found.iter().find(|i| i.starts_with("PL-")).cloned();
        if want_lot {
            if let (Some(p), Some(b)) = (&pl, &batch) {
                links.entry(p.clone()).or_default().insert(b.clone());
            }
        }
        want_lot = false;
        if want_batch && hb.is_some() {
            batch = hb.clone();
        }
        want_batch = false;
        let text = line.text();
        if has(&text, &labels.batch_labels) {
            if hb.is_some() {
                batch = hb.clone();
            } else {
                want_batch = true;
            }
        }
        if has(&text, &labels.lot_labels) {
            match (&pl, &batch) {
                (Some(p), Some(b)) => {
                    links.entry(p.clone()).or_default().insert(b.clone());
                }
                (None, _) => want_lot = true,
                _ => {}
            }
        }
    }
    links
}

/// `x` rounded to 3 significant figures, as a lab prints it (exact decimal rounding of the binary value).
fn sig3(x: f64) -> f64 {
    format!("{x:.2e}").parse().unwrap_or(x)
}

/// The section that is `lot`'s value of record in this report, or None (AD-19): its own UID first; else the one
/// batch the report pairs it with, when that batch's section is a primary; else the one primary section (one UID)
/// whose psilocybin equals `state_psilocybin` (mg/g, ignored unless above 0) at 3 significant figures.
pub fn find_lot(t: &CoaText, result: &CoaParseResult, lot: &str, state_psilocybin: Option<f64>, rules: &Rules) -> Option<LotMatch> {
    let id_re = Regex::new(&format!("^(?i:{})$", rules.anchor.id)).expect("checked when the rules were loaded");
    let want = normalize_id(lot.trim(), rules, &id_re).map(|(id, _)| id)?;
    let at = |i: usize, via: Via| LotMatch { section: i, uid: result.sections[i].uid.clone(), via };
    if let Some(&i) = result.of_record.get(&want.to_lowercase()) {
        return Some(at(i, Via::Own));
    }
    let links = lot_links(&crate::lines::lines(t), rules);
    if let Some(batches) = links.get(&want) {
        if batches.len() == 1 {
            let b = batches.iter().next().unwrap().to_lowercase();
            if let Some(&i) = result.of_record.get(&b) {
                if !result.sections[i].is_fd {
                    return Some(at(i, Via::Request));
                }
            }
        }
    }
    let target = state_psilocybin.filter(|s| s.is_finite() && *s > 0.0).map(sig3)?;
    let same: Vec<usize> = (0..result.sections.len())
        .filter(|&i| {
            let s = &result.sections[i];
            !s.is_fd && s.status != Status::Failed && s.analytes.psilocybin.amount().is_some_and(|v| v > 0.0 && sig3(v) == target)
        })
        .collect();
    let uids: BTreeSet<String> = same.iter().map(|&i| result.sections[i].uid.to_lowercase()).collect();
    if uids.len() == 1 {
        let uid = uids.into_iter().next().unwrap();
        let i = result.of_record.get(&uid).copied().filter(|i| same.contains(i)).unwrap_or(same[0]);
        return Some(at(i, Via::StatePsilocybin));
    }
    None
}
