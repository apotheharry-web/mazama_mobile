//! AD-19 (specs/coa/decisions.md; SM-07): which section is a lot's value of record, when the report may have printed
//! another id. The state links a document to a lot; a lab sometimes prints the batch the lot was made from as the
//! UID (document 3092: PL-de20657a submitted as HB-597a95ef). Held to corpus/lots/cases.json.

use crate::lines::Line;
use crate::parse::{id_word, normalize_id};
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
    /// The report's chain of custody names the lot on the line numbered like the section's sample (AD-21).
    CustodyOrder,
    /// A section with no id whose sample name is the request item that carries the lot (AD-22).
    RequestName,
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
    (0..line.words.len())
        .map(|k| id_word(&line.words, k))
        .flat_map(|t| t.split(',').map(str::to_string).collect::<Vec<_>>())
        .filter_map(|t| normalize_id(&t, rules, id_re))
        .map(|(id, _)| id)
        .collect()
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

fn is_client(id: &str, rules: &Rules) -> bool {
    rules.anchor.client_prefixes.iter().any(|p| id.len() > p.len() && id[..p.len()].eq_ignore_ascii_case(p) && id[p.len()..].starts_with('-'))
}

/// AD-21: the (batch slot, lot slot) id pairs of the report's request items, any kind of id in either slot: "Batch
/// ID/METRC ID" then "Harvest Lot/Process Lot Number", each id on its label's line or the next. An empty slot is
/// None, never the previous item's id.
fn request_pairs(all: &[Line], rules: &Rules, id_re: &Regex) -> Vec<(Option<String>, Option<String>)> {
    let labels = &rules.lot_links;
    let mut out = Vec::new();
    let (mut batch, mut want_batch, mut want_lot): (Option<String>, bool, bool) = (None, false, false);
    for line in all {
        let text = line.text();
        let first = ids(line, rules, id_re).into_iter().next();
        let is_batch = has(&text, &labels.batch_labels) && !has(&text, &labels.custody_labels);
        let is_lot = has(&text, &labels.lot_labels);
        if want_lot {
            out.push((batch.take(), if is_batch || is_lot { None } else { first.clone() }));
        }
        if want_batch && !is_lot && !is_batch {
            batch = first.clone();
        }
        (want_batch, want_lot) = (false, false);
        if is_batch {
            batch = first.clone();
            want_batch = batch.is_none();
        }
        if is_lot {
            match first {
                Some(l) => out.push((batch.take(), Some(l))),
                None => want_lot = true,
            }
        }
    }
    out
}

/// AD-21: the section printed under a client's own id (HL-, CB-) that the report's request pairs with `lot`: the
/// one client id paired with it, when that id's value of record is a primary.
fn by_client_request(all: &[Line], result: &CoaParseResult, lot: &str, rules: &Rules, id_re: &Regex) -> Option<usize> {
    let mut paired: BTreeSet<String> = BTreeSet::new();
    for (b, l) in request_pairs(all, rules, id_re) {
        for (mine, other) in [(&b, &l), (&l, &b)] {
            if let (Some(m), Some(o)) = (mine, other) {
                if m.eq_ignore_ascii_case(lot) && is_client(o, rules) {
                    paired.insert(o.to_lowercase());
                }
            }
        }
    }
    if paired.len() != 1 {
        return None;
    }
    let i = *result.of_record.get(paired.iter().next()?)?;
    (!result.sections[i].is_fd).then_some(i)
}

/// AD-21: the section the chain of custody names `lot` for by number: "#N  Client Batch ID: HB-..." is the report's
/// Nth sample (work-order number ...-0N). Only when the custody lines are numbered 1..K, the report has exactly K
/// sections and prints their work-order numbers ...-01..-K in order, every custody line naming the lot is a section
/// under the same client id, and that id's value of record is a primary.
fn by_custody_order(all: &[Line], result: &CoaParseResult, lot: &str, rules: &Rules, id_re: &Regex) -> Option<usize> {
    let mut custody: Vec<(usize, Option<String>)> = Vec::new();
    for line in all {
        // "#2" or "# 2" (the text layer splits it) [RCL 2312001]
        let w: Vec<&str> = line.words.iter().take(2).map(|w| w.text.as_str()).collect();
        let n = match w.as_slice() {
            ["#", n, ..] => n.parse::<usize>().ok(),
            [h, ..] => h.strip_prefix('#').and_then(|n| n.parse().ok()),
            _ => None,
        };
        let Some(n) = n else { continue };
        if has(&line.text(), &rules.lot_links.custody_labels) {
            custody.push((n, ids(line, rules, id_re).into_iter().next()));
        }
    }
    let k = result.sections.len();
    if k == 0 || custody.len() != k || custody.iter().enumerate().any(|(i, (n, _))| *n != i + 1) {
        return None;
    }
    let pages: BTreeSet<usize> = result.sections.iter().map(|s| s.page).collect();
    let work = Regex::new(r"^\d{7}-(\d{2})$").unwrap();
    let samples: Vec<usize> = all
        .iter()
        .filter(|l| pages.contains(&l.page) && !l.repeated)
        .filter_map(|l| l.words.first().and_then(|w| work.captures(&w.text)).and_then(|c| c[1].parse().ok()))
        .collect();
    if samples != (1..=k).collect::<Vec<_>>() {
        return None;
    }
    let named: BTreeSet<String> = custody
        .iter()
        .enumerate()
        .filter(|(_, (_, id))| id.as_deref().is_some_and(|i| i.eq_ignore_ascii_case(lot)))
        .map(|(i, _)| result.sections[i].uid.to_lowercase())
        .collect();
    if named.len() != 1 {
        return None;
    }
    let uid = named.into_iter().next()?;
    if !is_client(&uid, rules) {
        return None;
    }
    let i = *result.of_record.get(&uid)?;
    (!result.sections[i].is_fd).then_some(i)
}

fn name_key(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// AD-22: the report's request items as (name, ids): "Item/Strain Name" with the name on the next line (running
/// headers and footers skipped: a page break can fall between them), then every id printed until the next item.
fn request_items(all: &[Line], rules: &Rules, id_re: &Regex) -> Vec<(String, BTreeSet<String>)> {
    let mut out: Vec<(String, BTreeSet<String>)> = Vec::new();
    let mut want_name = false;
    for line in all.iter().filter(|l| !l.repeated) {
        let text = line.text();
        if has(&text, &rules.lot_links.item_labels) {
            out.push((String::new(), BTreeSet::new()));
            want_name = true;
            continue;
        }
        let Some(item) = out.last_mut() else { continue };
        if want_name {
            item.0 = name_key(&text);
            want_name = false;
            continue;
        }
        item.1.extend(ids(line, rules, id_re).into_iter().map(|i| i.to_lowercase()));
    }
    out
}

/// AD-22: the section with no id (its UID blank or not an id) whose sample name is the name of the one request item
/// carrying `lot`, when no other request item has that name and no other primary section has it.
fn by_request_name(all: &[Line], result: &CoaParseResult, lot: &str, rules: &Rules, id_re: &Regex) -> Option<usize> {
    let items = request_items(all, rules, id_re);
    let lot = lot.to_lowercase();
    let carrying: Vec<&String> = items.iter().filter(|(_, ids)| ids.contains(&lot)).map(|(n, _)| n).collect();
    let [name] = carrying.as_slice() else { return None };
    if name.is_empty() || items.iter().filter(|(n, _)| n == *name).count() != 1 {
        return None;
    }
    let same: Vec<usize> = (0..result.sections.len())
        .filter(|&i| !result.sections[i].is_fd && name_key(&result.sections[i].sample) == **name)
        .collect();
    let [i] = same.as_slice() else { return None };
    result.sections[*i].uid.is_empty().then_some(*i)
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
    if !want.starts_with("HB-") && !want.starts_with("PL-") {
        return None; // only a state id is a lot; a client's own id (AD-21) never is
    }
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
    let all = crate::lines::lines(t);
    if let Some(i) = by_client_request(&all, result, &want, rules, &id_re) {
        return Some(at(i, Via::Request));
    }
    if let Some(i) = by_custody_order(&all, result, &want, rules, &id_re) {
        return Some(at(i, Via::CustodyOrder));
    }
    if let Some(i) = by_request_name(&all, result, &want, rules, &id_re) {
        return Some(at(i, Via::RequestName));
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
