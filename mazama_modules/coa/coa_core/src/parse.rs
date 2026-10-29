//! Steps 2–9 of the parsing algorithm (specs/coa/04-parsing.md): lines -> sections -> values -> checks.
//!
//! The line stream comes from [`crate::lines`]; running headers and footers are skipped for sections but used for
//! report-level fields. Everything a lab can spell differently comes from [`Rules`].

use crate::lines::{Line, lines};
use crate::result::{Analytes, CoaParseResult, ReportInfo, Section, Status, Value};
use crate::rules::{ANALYTES, LabProfile, Rules};
use crate::text::{CoaText, Word};
use regex::Regex;
use std::collections::BTreeMap;

/// OCR words below this confidence in a value make the section `needs_review`.
const LOW_CONFIDENCE: f64 = 0.6;
/// Header words closer than this fraction of their height belong to one cell ("Result (mg/g)").
const CELL_GAP: f64 = 0.6;
/// How many lines above a UID line may hold its sample name (a lab profile can say more).
const ABOVE_LINES: usize = 3;

/// What a lab profile changes in how sections are found (the rest it changes through [`LabProfile::apply`]).
#[derive(Default)]
struct Layout<'a> {
    anchor_alone: bool,
    above_lines: Option<usize>,
    result_unit: Option<&'a str>,
}

pub fn parser_version(rules: &Rules) -> String {
    format!("coa_core {} / rules {}", env!("CARGO_PKG_VERSION"), rules.version)
}

fn eq(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}

fn round(v: f64, places: u32) -> f64 {
    let f = 10f64.powi(places as i32);
    (v * f).round() / f
}

// ---------------------------------------------------------------------------------------------- ids and dates

/// "HB-3449C265" -> ("HB-3449c265", folded=false); "HB-3449cZ65" -> ("HB-3449c265", true); None if not an id.
pub(crate) fn normalize_id(raw: &str, rules: &Rules, id_re: &Regex) -> Option<(String, bool)> {
    let raw = raw.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '-');
    // a client's own id ("HL-766FBD69", AD-21): `anchor.id` is the shared lot-id pattern, so these are matched here
    let client = raw.split_once('-').is_some_and(|(p, t)| {
        rules.anchor.client_prefixes.iter().any(|c| eq(c, p)) && (5..=8).contains(&t.len()) && t.chars().all(|c| c.is_ascii_alphanumeric())
    });
    if !client && !id_re.is_match(raw) {
        // printed without its hyphen, "HBF5653BF9" [RCL 2610107]: only exact hex digits, never folded, since with no
        // hyphen there is nothing else to tell an id from a word
        let (prefix, tail) = (raw.get(..2)?, raw.get(2..)?);
        let prefix = prefix.to_ascii_uppercase();
        if (prefix == "HB" || prefix == "PL") && (5..=8).contains(&tail.len()) && tail.chars().all(|c| c.is_ascii_hexdigit()) {
            return Some((format!("{prefix}-{}", tail.to_ascii_lowercase()), false));
        }
        return None;
    }
    let (prefix, tail) = raw.split_once('-')?;
    let prefix = prefix.to_ascii_uppercase();
    if prefix != "HB" && prefix != "PL" && !rules.anchor.client_prefixes.iter().any(|p| eq(p, &prefix)) {
        return None;
    }
    let tail = tail.to_ascii_lowercase();
    if (5..=8).contains(&tail.len()) && tail.chars().all(|c| c.is_ascii_hexdigit()) {
        return Some((format!("{prefix}-{tail}"), false));
    }
    let folded: String = tail.chars().map(|c| *rules.confusables.get(&c).unwrap_or(&c)).collect();
    if (5..=8).contains(&folded.len()) && folded.chars().all(|c| c.is_ascii_hexdigit()) {
        return Some((format!("{prefix}-{folded}"), true));
    }
    None
}

/// The word at `k` as an id candidate ("" past the end), joined with the next word when the id was printed as two:
/// "Hb 675561c3" -> "Hb-675561c3" [RCL 2410226]. Only a bare two-letter prefix followed by 5 to 8 hex digits is
/// joined; `normalize_id` still decides whether the result is an id.
pub(crate) fn id_word(words: &[Word], k: usize) -> String {
    let Some(w) = words.get(k) else { return String::new() };
    let hex = |t: &str| (5..=8).contains(&t.len()) && t.chars().all(|c| c.is_ascii_hexdigit());
    match words.get(k + 1) {
        Some(n) if w.text.len() == 2 && w.text.chars().all(|c| c.is_ascii_alphabetic()) && hex(&n.text) => format!("{}-{}", w.text, n.text),
        _ => w.text.clone(),
    }
}

/// "05/23/2025" -> "2025-05-23" for the rules' date formats; None if it isn't a real date.
fn parse_date(s: &str, rules: &Rules) -> Option<String> {
    let parts: Vec<&str> = s.split('/').collect();
    if parts.len() != 3 || !parts.iter().all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit())) {
        return None;
    }
    let (m, d): (u32, u32) = (parts[0].parse().ok()?, parts[1].parse().ok()?);
    let y: u32 = match parts[2].len() {
        4 if rules.report.date_formats.iter().any(|f| f == "%m/%d/%Y") => parts[2].parse().ok()?,
        2 if rules.report.date_formats.iter().any(|f| f == "%m/%d/%y") => 2000 + parts[2].parse::<u32>().ok()?,
        _ => return None,
    };
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let days = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if !(1..=12).contains(&m) || d == 0 || d > days[(m - 1) as usize] {
        return None;
    }
    Some(format!("{y:04}-{m:02}-{d:02}"))
}

// ---------------------------------------------------------------------------------------------- anchors

struct Anchor {
    line: usize,
    uid: String,
    folded: bool,
    /// index of the anchor label word in the line, so a sample name on the same line ends before it
    label_word: usize,
}

fn find_anchor(line: &Line, i: usize, rules: &Rules, id_re: &Regex, alone: bool) -> Option<Anchor> {
    // a lab that prints the id with no label, on a line of its own [ChemHistory], or followed by the strain after a
    // dash: "HB-c900fd97 - Ecuador" [CH, 2404CH0177]
    let dash = |w: &Word| matches!(w.text.as_str(), "-" | "\u{2013}" | "\u{2014}");
    if alone && (line.words.len() == 1 || line.words.get(1).is_some_and(dash)) {
        if let Some((uid, folded)) = normalize_id(&line.words[0].text, rules, id_re) {
            return Some(Anchor { line: i, uid, folded, label_word: 0 });
        }
    }
    for (k, w) in line.words.iter().enumerate() {
        for label in &rules.anchor.labels {
            let next = id_word(&line.words, k + 1);
            let candidate = if eq(&w.text, label) {
                (!next.is_empty()).then_some(next.as_str())
            } else if w.text.len() > label.len() && w.text[..label.len()].eq_ignore_ascii_case(label) {
                Some(&w.text[label.len()..]) // glued: "UID:HB-3449c265"
            } else {
                None
            };
            // a lot made from several batches can print them all: "UID: HB-82fc6356,HB-c44c4da5, HB-90be23cf" [RCL];
            // the section is the first one's (lot::lot_links pairs the lot with that first batch too)
            let first = candidate.and_then(|c| c.split(',').next());
            if let Some((uid, folded)) = first.and_then(|c| normalize_id(c, rules, id_re)) {
                return Some(Anchor { line: i, uid, folded, label_word: k });
            }
            // AD-22: "Sample: Melange X   UID:" with the UID blank, or not an id ("UID: Big Foot") [RCL 2411143,
            // 2501074]: a section with no id, kept only when results follow it (find_sections), never a lot's own,
            // found only through the request form's item of the same name (lot::find_lot)
            if eq(&w.text, label) && has_sample_label(line, rules) {
                return Some(Anchor { line: i, uid: String::new(), folded: false, label_word: k });
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------------------------- rows

#[derive(Clone, Copy, PartialEq)]
enum RowKind {
    Analyte(usize),
    Total(usize),
}

/// Does the line start with this (possibly multi-word) name, not followed by another plain word?
/// "Psilocybin 9.54 ..." yes; "Psilocybin Potency" (a heading) no.
/// A following word that is itself a value ("ND", "BQL") doesn't make the line a heading.
fn starts_with_name(words: &[Word], name: &str, rules: &Rules) -> Option<usize> {
    let tokens: Vec<&str> = name.split_whitespace().collect();
    if words.len() < tokens.len() || !tokens.iter().zip(words).all(|(t, w)| eq(t, &w.text)) {
        return None;
    }
    match words.get(tokens.len()) {
        Some(next) if next.text.chars().all(|c| c.is_alphabetic()) && token(&next.text, rules).is_none() => None,
        _ => Some(tokens.len()),
    }
}

/// Which analyte or lab total a line is a row of, and how many words its name takes.
fn row_kind(line: &Line, rules: &Rules, total_keys: &[String]) -> Option<(RowKind, usize)> {
    let mut best: Option<(RowKind, usize)> = None;
    let mut consider = |kind: RowKind, names: &[String]| {
        for n in names {
            if let Some(len) = starts_with_name(&line.words, n, rules) {
                if best.is_none_or(|(_, b)| len > b) {
                    best = Some((kind, len));
                }
            }
        }
    };
    for (i, key) in total_keys.iter().enumerate() {
        consider(RowKind::Total(i), &rules.lab_totals[key]);
    }
    for (i, a) in ANALYTES.iter().enumerate() {
        consider(RowKind::Analyte(i), &rules.analytes[*a]);
    }
    match best {
        // an analyte name inside a line that also carries an excluded word ("Total ...") is never a value row
        Some((RowKind::Analyte(_), len))
            if line.words[..len].iter().any(|w| rules.row_exclude_words.iter().any(|x| eq(x, &w.text))) =>
        {
            None
        }
        b => b,
    }
}

// ---------------------------------------------------------------------------------------------- table header

#[derive(Debug, Clone)]
struct Cell {
    text: String,
    x0: f64,
    x1: f64,
}

impl Cell {
    fn center(&self) -> f64 {
        (self.x0 + self.x1) / 2.0
    }
}

#[derive(Debug, Clone, Default)]
struct Columns {
    /// x ranges of the result, LOQ, unit and date columns
    result: Option<(f64, f64)>,
    loq: Option<(f64, f64)>,
    unit: Option<(f64, f64)>,
    date: Option<(f64, f64)>,
    /// a unit printed in the header, e.g. "Result (mg/g)" -> "mg/g"
    header_unit: Option<String>,
}

fn cells(line: &Line) -> Vec<Cell> {
    let mut out: Vec<Cell> = Vec::new();
    for w in &line.words {
        match out.last_mut() {
            Some(c) if w.x0 - c.x1 < CELL_GAP * w.height().max(1.0) => {
                c.text.push(' ');
                c.text.push_str(&w.text);
                c.x1 = w.x1;
            }
            _ => out.push(Cell { text: w.text.clone(), x0: w.x0, x1: w.x1 }),
        }
    }
    out
}

fn parenthesized_unit(text: &str) -> Option<String> {
    let start = text.find('(')?;
    let end = text[start..].find(')')? + start;
    let u = text[start + 1..end].trim();
    (!u.is_empty()).then(|| u.to_string())
}

/// Column ranges from a table header line, or None when the line is not a header. With `want_unit` (a lab profile's
/// result_unit), the result column is the result-header cell with that unit printed under it on `next`, the line
/// below; a header without it isn't the table's.
fn header_columns(line: &Line, rules: &Rules, next: Option<&Line>, want_unit: Option<&str>) -> Option<Columns> {
    let cs = cells(line);
    let first_word = |c: &Cell| c.text.split_whitespace().next().unwrap_or("").trim_matches(|ch: char| !ch.is_alphanumeric()).to_string();
    let is = |c: &Cell, names: &[String]| c.text.split_whitespace().any(|t| names.iter().any(|n| eq(n, t.trim_matches(|ch: char| !ch.is_alphanumeric())))) ;
    if cs.len() < 2 {
        return None;
    }
    let range = |i: usize| {
        let left = if i == 0 { f64::NEG_INFINITY } else { (cs[i - 1].center() + cs[i].center()) / 2.0 };
        let right = if i + 1 == cs.len() { f64::INFINITY } else { (cs[i].center() + cs[i + 1].center()) / 2.0 };
        (left, right)
    };
    let is_result = |c: &Cell| rules.table.result_headers.iter().any(|n| eq(n, &first_word(c)));
    let (result_idx, header_unit) = match want_unit {
        None => {
            let i = cs.iter().position(is_result)?;
            (i, parenthesized_unit(&cs[i].text).or_else(|| cs.iter().find_map(|c| parenthesized_unit(&c.text))))
        }
        Some(unit) => {
            let under = next?;
            let i = (0..cs.len()).find(|&i| {
                is_result(&cs[i]) && {
                    let (l, r) = range(i);
                    under.words.iter().any(|w| eq(&w.text, unit) && w.center_x() >= l && w.center_x() < r)
                }
            })?;
            (i, Some(unit.to_string()))
        }
    };
    let find = |names: &[String]| cs.iter().position(|c| is(c, names)).map(range);
    Some(Columns {
        result: Some(range(result_idx)),
        loq: find(&rules.table.loq_headers),
        unit: find(&rules.table.unit_headers),
        date: find(&rules.table.date_headers),
        header_unit,
    })
}

/// The words of a row (after its name) whose centre falls in a column's x range.
fn in_column<'a>(row: &'a [Word], range: (f64, f64)) -> Vec<&'a Word> {
    row.iter().filter(|w| w.center_x() >= range.0 && w.center_x() < range.1).collect()
}

// ---------------------------------------------------------------------------------------------- values

fn number(s: &str) -> Option<f64> {
    let t = s.trim();
    if t.is_empty() || !t.chars().all(|c| c.is_ascii_digit() || c == '.') || t.chars().filter(|&c| c == '.').count() > 1 {
        return None;
    }
    t.parse().ok()
}

enum Token {
    Num(f64),
    Nd,
    BelowLoq(Option<f64>),
}

fn token(s: &str, rules: &Rules) -> Option<Token> {
    if let Some(n) = number(s) {
        return Some(Token::Num(n));
    }
    if rules.values.nd.iter().any(|x| eq(x, s)) {
        return Some(Token::Nd);
    }
    if rules.values.below_loq.iter().any(|x| eq(x, s)) {
        return Some(Token::BelowLoq(None));
    }
    if let Some(rest) = s.strip_prefix('<') {
        if let Some(n) = number(rest) {
            return Some(Token::BelowLoq(Some(n)));
        }
    }
    None
}

/// The unit's factor to mg/g, if the rules know it.
fn factor(unit: &str, rules: &Rules) -> Option<f64> {
    rules.units.iter().find(|(k, _)| eq(k, unit)).map(|(_, f)| *f)
}

struct RowRead {
    value: Value,
    unit: Option<String>,
    date: Option<String>,
    low_confidence: bool,
}

fn read_row(row: &[Word], cols: &Columns, rules: &Rules) -> RowRead {
    let unit = cols
        .unit
        .and_then(|r| in_column(row, r).first().map(|w| w.text.clone()))
        .or_else(|| cols.header_unit.clone());
    let f = unit.as_deref().and_then(|u| factor(u, rules)).unwrap_or(1.0);
    let scale = |v: f64| round(v * f, 6);
    let loq = cols.loq.and_then(|r| in_column(row, r).iter().find_map(|w| number(&w.text))).map(scale);
    let date = cols.date.and_then(|r| in_column(row, r).iter().find_map(|w| parse_date(&w.text, rules)));
    let mut cell: Vec<&Word> = match cols.result {
        Some(r) => in_column(row, r),
        // no header: a row with exactly one value-like word is unambiguous
        None => row.iter().filter(|w| token(&w.text, rules).is_some()).collect(),
    };
    cell.retain(|w| !w.text.trim().is_empty());
    let low_confidence = cell.iter().any(|w| w.conf.is_some_and(|c| c < LOW_CONFIDENCE));
    let tokens: Vec<(&Word, Option<Token>)> = cell.iter().map(|w| (*w, token(&w.text, rules))).collect();
    let valued: Vec<&(&Word, Option<Token>)> = tokens.iter().filter(|(_, t)| t.is_some()).collect();
    let value = match (valued.len(), tokens.len()) {
        (0, 0) => Value::Missing,
        (1, _) => match valued[0].1.as_ref().unwrap() {
            Token::Num(n) => Value::Number { value: scale(*n), loq },
            Token::Nd => Value::Nd { loq },
            Token::BelowLoq(l) => Value::BelowLoq { loq: l.map(scale).or(loq) },
        },
        _ => Value::Ambiguous { candidates: cell.iter().map(|w| w.text.clone()).collect() },
    };
    RowRead { value, unit, date, low_confidence }
}

// ---------------------------------------------------------------------------------------------- sections

struct Raw {
    anchor: Anchor,
    page: usize,
    sample: String,
    is_fd: bool,
    rows: Vec<(RowKind, usize)>, // (kind, line index)
    columns: Option<Columns>,
}

/// The sample name on a line: the words after a sample label, up to the anchor label (or the end of the line).
fn sample_on(line: &Line, rules: &Rules, stop_at: Option<usize>) -> Option<Vec<String>> {
    let k = line.words.iter().position(|w| rules.sample.labels.iter().any(|l| eq(l, &w.text)))?;
    let end = stop_at.filter(|&s| s > k).unwrap_or(line.words.len());
    Some(line.words[k + 1..end].iter().map(|w| w.text.clone()).collect())
}

fn has_sample_label(line: &Line, rules: &Rules) -> bool {
    line.words.iter().any(|w| rules.sample.labels.iter().any(|l| eq(l, &w.text)))
}

/// Splits a trailing field-duplicate marker off a sample name.
fn split_fd(words: Vec<String>, rules: &Rules) -> (String, bool) {
    let text = words.join(" ");
    for m in &rules.sample.fd_markers {
        if text.len() >= m.len() && text.to_lowercase().ends_with(&m.to_lowercase()) {
            let head = &text[..text.len() - m.len()];
            if head.is_empty() || head.ends_with(' ') {
                return (head.trim().to_string(), true);
            }
        }
    }
    (text, false)
}

fn stops(line: &Line, rules: &Rules) -> bool {
    let t = line.text();
    rules.section_stop.iter().any(|s| t.contains(s.as_str()))
}

fn find_sections(all: &[Line], body: &[&Line], rules: &Rules, id_re: &Regex, total_keys: &[String], layout: &Layout) -> Vec<Raw> {
    let anchors: Vec<Anchor> =
        body.iter().enumerate().filter_map(|(i, l)| find_anchor(l, i, rules, id_re, layout.anchor_alone)).collect();
    let anchor_lines: Vec<usize> = anchors.iter().map(|a| a.line).collect();
    let mut out: Vec<Raw> = Vec::new();
    let mut prev_end: Option<usize> = None;
    for anchor in anchors {
        let a = anchor.line;
        let page = body[a].page;
        // forward: header, rows, until the next anchor, a stop line, or another sample's label after our rows
        let mut rows = Vec::new();
        let mut columns: Option<Columns> = None;
        let mut below_sample: Option<Vec<String>> = None;
        let mut j = a + 1;
        while j < body.len() && !anchor_lines.contains(&j) && !stops(body[j], rules) {
            let line = body[j];
            if has_sample_label(line, rules) {
                if !rows.is_empty() {
                    break; // the next section's sample name, printed above its UID
                }
                if below_sample.is_none() {
                    below_sample = sample_on(line, rules, None);
                }
            } else if let Some((kind, _)) = row_kind(line, rules, total_keys) {
                rows.push((kind, j));
            } else if rows.is_empty() {
                if let Some(c) = header_columns(line, rules, body.get(j + 1).copied(), layout.result_unit) {
                    columns = Some(c);
                }
            }
            j += 1;
        }
        // sample name: on the UID line, else below it before the table, else just above it on the same page
        let on_line = sample_on(body[a], rules, Some(anchor.label_word));
        let above = || match layout.above_lines {
            None => {
                let floor = prev_end.map_or(0, |e| e + 1).max(a.saturating_sub(ABOVE_LINES));
                (floor..a).rev().filter(|&i| body[i].page == page).find_map(|i| sample_on(body[i], rules, None))
            }
            // a lab profile's sample name may sit in the page's running header, which `body` leaves out [ChemHistory]:
            // the nearest of the `n` lines above the anchor on its page, headers included
            Some(n) => all
                .iter()
                .filter(|l| l.page == page && l.y1 <= body[a].y0)
                .rev()
                .take(n)
                .find_map(|l| sample_on(l, rules, None)),
        };
        // a page's repeated client block holds the id again, with no results under it [CH: every page after the
        // first]: not a section of its own
        if layout.anchor_alone && rows.is_empty() && out.iter().any(|r| r.anchor.uid == anchor.uid) {
            continue;
        }
        if anchor.uid.is_empty() && rows.is_empty() {
            continue; // an unnamed anchor with no results under it is not a section
        }
        let words = on_line.or(below_sample).or_else(above).unwrap_or_default();
        let (sample, is_fd) = split_fd(words, rules);
        prev_end = Some(rows.last().map_or(a, |&(_, i)| i));
        out.push(Raw { anchor, page, sample, is_fd, rows, columns });
    }
    out
}

fn build_section(raw: &Raw, body: &[&Line], rules: &Rules, total_keys: &[String]) -> Section {
    let mut values: BTreeMap<&str, Value> = ANALYTES.iter().map(|a| (*a, Value::Missing)).collect();
    let mut lab_totals = BTreeMap::new();
    let mut units_seen: Vec<String> = Vec::new();
    let mut dates: Vec<(usize, String)> = Vec::new();
    let mut low_confidence = false;
    let cols = raw.columns.clone().unwrap_or_default();
    for &(kind, li) in &raw.rows {
        let line = body[li];
        let name_len = match kind {
            RowKind::Analyte(i) => starts_with_name(&line.words, rules.analytes[ANALYTES[i]].iter().find(|n| starts_with_name(&line.words, n, rules).is_some()).unwrap(), rules),
            RowKind::Total(i) => starts_with_name(&line.words, rules.lab_totals[&total_keys[i]].iter().find(|n| starts_with_name(&line.words, n, rules).is_some()).unwrap(), rules),
        }
        .unwrap_or(0);
        let read = read_row(&line.words[name_len..], &cols, rules);
        low_confidence |= read.low_confidence;
        if let Some(u) = &read.unit {
            if !units_seen.contains(u) {
                units_seen.push(u.clone());
            }
        }
        match kind {
            RowKind::Analyte(i) => {
                if let Some(d) = read.date {
                    dates.push((i, d));
                }
                let slot = values.get_mut(ANALYTES[i]).unwrap();
                if matches!(slot, Value::Missing) {
                    *slot = read.value; // the first row for an analyte wins
                }
            }
            RowKind::Total(i) => {
                if let Value::Number { value, .. } = read.value {
                    lab_totals.entry(total_keys[i].clone()).or_insert(value);
                }
            }
        }
    }
    let take = |k: &str| values.get(k).cloned().unwrap_or(Value::Missing);
    let analytes = Analytes {
        psilocybin: take("psilocybin"),
        psilocin: take("psilocin"),
        baeocystin: take("baeocystin"),
        norbaeocystin: take("norbaeocystin"),
        norpsilocin: take("norpsilocin"),
        aeruginascin: take("aeruginascin"),
    };
    // SM-D13: the section's TPE is AD-18's (the printed total, else the formula); the parser has no state figure.
    // `formula` is kept apart for the check that a printed total agrees with the report's own values.
    let (psilocybin, psilocin) = (analytes.psilocybin.amount(), analytes.psilocin.amount());
    let formula = crate::tpe::tpe(psilocybin, psilocin, None, None, rules.tpe.psilocin_factor).map(|t| round(t, rules.tpe.round));
    let tpe = crate::tpe::tpe(psilocybin, psilocin, lab_totals.get("tpe").copied(), None, rules.tpe.psilocin_factor)
        .map(|t| round(t, rules.tpe.round));
    // the analysed date of record: the psilocybin row's, else the first row's
    let analyzed_date = dates.iter().find(|(i, _)| *i == 0).or(dates.first()).map(|(_, d)| d.clone());
    let unit_found = units_seen.first().cloned().or_else(|| cols.header_unit.clone());

    let mut reasons = Vec::new();
    let analyte_rows = raw.rows.iter().filter(|(k, _)| matches!(k, RowKind::Analyte(_))).count();
    for key in ["psilocybin", "psilocin"] {
        if !analytes.get(key).unwrap().is_known() {
            reasons.push(format!("{key}_missing"));
        }
    }
    if analyte_rows > 0 && !units_seen.iter().chain(cols.header_unit.iter()).any(|u| factor(u, rules).is_some()) {
        reasons.push("unknown_unit".into());
    }
    for (key, v) in analytes.all() {
        if let (Value::Number { value, .. }, Some([lo, hi])) = (v, rules.review_ranges_mg_g.get(key)) {
            if value < lo || value > hi {
                reasons.push(format!("out_of_range:{key}"));
            }
        }
    }
    if let (Some(lab), Some(t)) = (lab_totals.get("tpe"), formula) {
        if (lab - t).abs() > rules.tpe.lab_total_tolerance * lab.max(0.01) {
            reasons.push("lab_total_mismatch".into());
        }
    }
    if raw.anchor.folded {
        reasons.push("uid_folded".into());
    }
    if low_confidence {
        reasons.push("low_ocr_confidence".into());
    }
    if analyte_rows > 0 && analytes.all().iter().all(|(_, v)| v.amount().is_none_or(|a| a <= 0.0)) {
        reasons.push("all_zero".into());
    }
    let status = if analyte_rows == 0 {
        Status::Failed
    } else if reasons.is_empty() {
        Status::Ok
    } else {
        Status::NeedsReview
    };
    if analyte_rows == 0 {
        reasons.push("no_analyte_rows".into());
    }
    Section {
        uid: raw.anchor.uid.clone(),
        uid_folded: raw.anchor.folded,
        page: raw.page,
        is_fd: raw.is_fd,
        sample: raw.sample.clone(),
        unit_found,
        analytes,
        lab_totals,
        tpe,
        analyzed_date,
        status,
        reasons,
    }
}

/// AD-9: flag the primary when a field duplicate disagrees with it beyond the tolerance.
fn compare_duplicates(sections: &mut [Section], rules: &Rules) {
    let fd = &rules.field_duplicate;
    for p in 0..sections.len() {
        if sections[p].is_fd {
            continue;
        }
        // with no id (AD-22) a duplicate is the one with the same sample name
        let same = |d: usize| eq(&sections[d].uid, &sections[p].uid) && (!sections[p].uid.is_empty() || sections[d].sample == sections[p].sample);
        let dups: Vec<usize> = (0..sections.len()).filter(|&d| sections[d].is_fd && same(d)).collect();
        for d in dups {
            let (a, b) = (&sections[p], &sections[d]);
            let mut disagree = matches!((a.tpe, b.tpe), (Some(x), Some(y)) if x > 0.0 && (x - y).abs() / x > fd.tpe_tolerance);
            for key in ANALYTES {
                let (va, vb) = (a.analytes.get(key).unwrap(), b.analytes.get(key).unwrap());
                let detected_only = |x: &Value, y: &Value| match (x, y) {
                    (Value::Number { value, loq: Some(l) }, Value::Nd { .. } | Value::BelowLoq { .. }) => *value > fd.detection_loq_multiple * l,
                    _ => false,
                };
                disagree |= detected_only(va, vb) || detected_only(vb, va);
            }
            if disagree && !sections[p].reasons.iter().any(|r| r == "field_duplicate_disagrees") {
                let s = &mut sections[p];
                s.reasons.push("field_duplicate_disagrees".into());
                if s.status == Status::Ok {
                    s.status = Status::NeedsReview;
                }
            }
        }
    }
}

fn of_record(sections: &[Section]) -> BTreeMap<String, usize> {
    let mut out = BTreeMap::new();
    // a section with no id (AD-22) is no lot's value of record
    let mut uids: Vec<String> = sections.iter().map(|s| s.uid.to_lowercase()).filter(|u| !u.is_empty()).collect();
    uids.dedup();
    for uid in uids {
        let mine: Vec<usize> = (0..sections.len()).filter(|&i| sections[i].uid.to_lowercase() == uid).collect();
        let pick = mine
            .iter()
            .find(|&&i| !sections[i].is_fd && sections[i].status == Status::Ok)
            .or_else(|| mine.iter().find(|&&i| !sections[i].is_fd))
            .or(mine.first());
        if let Some(&i) = pick {
            out.insert(uid, i);
        }
    }
    out
}

// ---------------------------------------------------------------------------------------------- report fields

/// The first lab profile any of whose `detect` strings occurs in the report.
fn profile_of<'a>(all: &[Line], rules: &'a Rules) -> Option<&'a LabProfile> {
    let whole: String = all.iter().map(Line::text).collect::<Vec<_>>().join("\n");
    rules.lab_profiles.iter().find(|p| p.detect.iter().any(|d| whole.contains(d.as_str())))
}

fn report_info(all: &[Line], rules: &Rules, profile: Option<&LabProfile>) -> ReportInfo {
    let licensee = profile.and_then(|p| p.licensee_left_of.as_ref()).and_then(|label| {
        all.iter().find_map(|l| {
            let k = l.words.iter().position(|w| eq(&w.text, label))?;
            let left: Vec<&str> = l.words[..k].iter().map(|w| w.text.as_str()).collect();
            (!left.is_empty()).then(|| left.join(" "))
        })
    });
    let reported_date = all.iter().enumerate().find_map(|(i, l)| {
        let k = l.words.iter().position(|w| rules.report.reported_labels.iter().any(|r| eq(r, &w.text)))?;
        let label = &l.words[k];
        // on the same line, to the right of the label...
        if let Some(d) = l.words[k + 1..].iter().find_map(|w| parse_date(&w.text, rules)) {
            return Some(d);
        }
        // ...or on the next lines of the same page, under the label
        all[i + 1..]
            .iter()
            .take_while(|n| n.page == l.page)
            .take(3)
            .find_map(|n| n.words.iter().filter(|w| w.x0 >= label.x0 - 60.0 && w.x0 <= label.x1 + 80.0).find_map(|w| parse_date(&w.text, rules)))
    });
    ReportInfo { lab: profile.map(|p| p.name.clone()), licensee, reported_date }
}

// ---------------------------------------------------------------------------------------------- entry point

/// Reads every section of a lab report.
pub fn parse(t: &CoaText, rules: &Rules) -> CoaParseResult {
    let id_re = Regex::new(&format!("^(?i:{})$", rules.anchor.id)).expect("checked when the rules were loaded");
    let total_keys: Vec<String> = rules.lab_totals.keys().cloned().collect();
    let all = lines(t);
    let body: Vec<&Line> = all.iter().filter(|l| !l.repeated).collect();
    // a lab profile replaces some of the rules for its reports (specs/coa/04-parsing.md step 13; ChemHistory)
    let profile = profile_of(&all, rules);
    let own = profile.map(|p| p.apply(rules));
    let rules = own.as_ref().unwrap_or(rules);
    let layout = profile.map_or_else(Layout::default, |p| Layout {
        anchor_alone: p.anchor_alone,
        above_lines: p.sample_lines_above,
        result_unit: p.result_unit.as_deref(),
    });
    let raws = find_sections(&all, &body, rules, &id_re, &total_keys, &layout);
    let mut sections: Vec<Section> = raws.iter().map(|r| build_section(r, &body, rules, &total_keys)).collect();
    compare_duplicates(&mut sections, rules);
    CoaParseResult {
        version: 1,
        parser_version: parser_version(rules),
        source_sha256: t.source_sha256.clone(),
        report: report_info(&all, rules, profile),
        of_record: of_record(&sections),
        sections,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules() -> Rules {
        Rules::default_rules()
    }

    #[test]
    fn ids_are_normalized_and_confusables_folded_only_when_needed() {
        let r = rules();
        let re = Regex::new(&format!("^(?i:{})$", r.anchor.id)).unwrap();
        assert_eq!(normalize_id("hb-3449C265", &r, &re), Some(("HB-3449c265".into(), false)));
        assert_eq!(normalize_id("HB-9c564cf", &r, &re), Some(("HB-9c564cf".into(), false)));
        assert_eq!(normalize_id("PL-7c737a9z", &r, &re), Some(("PL-7c737a92".into(), true)));
        assert_eq!(normalize_id("HB-xyzxyz", &r, &re), None);
        assert_eq!(normalize_id("PKPR-8a05632f", &r, &re), None);
    }

    #[test]
    fn an_id_printed_without_its_hyphen_is_read_only_when_its_digits_are_exact() {
        let r = rules();
        let re = Regex::new(&format!("^(?i:{})$", r.anchor.id)).unwrap();
        assert_eq!(normalize_id("HBF5653BF9", &r, &re), Some(("HB-f5653bf9".into(), false)));   // RCL 2610107
        assert_eq!(normalize_id("pl9c564cf", &r, &re), Some(("PL-9c564cf".into(), false)));
        assert_eq!(normalize_id("HBF5653BFZ", &r, &re), None);   // no confusable folding without the hyphen
        assert_eq!(normalize_id("PLATES", &r, &re), None);
        assert_eq!(normalize_id("HB123", &r, &re), None);
    }

    #[test]
    fn an_id_printed_as_two_words_is_joined() {
        let w = |t: &str| Word { text: t.into(), x0: 0.0, y0: 0.0, x1: 1.0, y1: 1.0, conf: None };
        let line = [w("UID:"), w("Hb"), w("675561c3"), w("x")];
        assert_eq!(id_word(&line, 1), "Hb-675561c3");                // RCL 2410226: "UID: Hb 675561c3"
        assert_eq!(id_word(&line, 2), "675561c3");
        assert_eq!(id_word(&[w("PL"), w("Potency")], 0), "PL");      // not hex: left alone
        assert_eq!(id_word(&[w("HB"), w("123")], 0), "HB");          // too short to be an id
        assert_eq!(id_word(&[w("HB-1")], 3), "");
    }

    #[test]
    fn dates_parse_and_impossible_ones_are_refused() {
        let r = rules();
        assert_eq!(parse_date("05/23/2025", &r).as_deref(), Some("2025-05-23"));
        assert_eq!(parse_date("1/7/26", &r).as_deref(), Some("2026-01-07"));
        assert_eq!(parse_date("02/30/2026", &r), None);
        assert_eq!(parse_date("B25E164", &r), None);
    }

    #[test]
    fn headings_that_start_with_an_analyte_name_are_not_rows() {
        let r = rules();
        let w = |t: &str| Word { text: t.into(), x0: 0.0, y0: 0.0, x1: 1.0, y1: 1.0, conf: None };
        assert_eq!(starts_with_name(&[w("Psilocybin"), w("9.54")], "Psilocybin", &r), Some(1));
        assert_eq!(starts_with_name(&[w("Psilocybin"), w("Potency")], "Psilocybin", &r), None);
        assert_eq!(starts_with_name(&[w("Psilocin"), w("ND")], "Psilocin", &r), Some(1));        // a value, not a heading
        assert_eq!(starts_with_name(&[w("Psilocin")], "Psilocin", &r), Some(1));
        assert_eq!(starts_with_name(&[w("Baeocystine"), w("1")], "Baeocystin", &r), None);
    }

    #[test]
    fn a_field_duplicate_marker_is_split_off_the_sample_name() {
        let r = rules();
        let s = |t: &str| t.split(' ').map(String::from).collect::<Vec<_>>();
        assert_eq!(split_fd(s("Huatla Chocolates FD"), &r), ("Huatla Chocolates".into(), true));
        assert_eq!(split_fd(s("Shakti"), &r), ("Shakti".into(), false));
        assert_eq!(split_fd(s("GoldenTeacher Field Duplicate"), &r), ("GoldenTeacher".into(), true));
        assert_eq!(split_fd(s("BFD"), &r), ("BFD".into(), false));
    }
}
