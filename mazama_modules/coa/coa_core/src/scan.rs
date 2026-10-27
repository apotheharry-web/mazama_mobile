//! Scan matching: which of a service center's packages a label's text names. The text is what a phone's own text
//! recognizer (or the server's Tesseract) read off a label, or what a worker typed. Two steps:
//!
//! - [`find_ids`]: the package ids (the `Lot: 579b4701` a label prints, `PKPR-579b4701` in the state system) found
//!   in the text, exactly or with a character or two misread;
//! - [`closest`]: when no id was found, the packages the rest of the label fits best (net weight, psilocybin, best-by
//!   date, strain, a lot number a few characters off).
//!
//! This was the server's `mazama_sales/src/mazama_sales/ocr.py` (`find_ids`, `closest`) and is a line-for-line port of
//! it, held to the cases that Python wrote (`mazama_modules/coa/corpus/scan/cases.json`). The server calls it
//! through the binding; the phone calls it through the FFI when the server can't be reached. Python's own text
//! rules are kept where they decide an answer: its `str.splitlines` line breaks, its `str.strip` whitespace, its `\d`
//! (every Unicode decimal digit, [`DIGIT_ZEROS`]) and its `$`, which also matches before a final newline.

use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::id_patterns;

/// Characters that may be wrong (wrong, missing or extra) in a full 8-digit id.
pub const MAX_MISREAD: usize = 2;
/// A label shows two decimals, so a printed weight or amount matches within a hundredth.
pub const MATCH_G: f64 = 0.011;
/// Points a package needs to be offered by [`closest`].
pub const MIN_SCORE: i64 = 3;
/// At most this many packages are offered by [`closest`].
pub const MAX_GUESSES: usize = 6;

/// What Tesseract tends to read for a hex digit: letters that are not hex digits become the digit they look like.
const CONFUSED: [(char, char); 8] = [('o', '0'), ('q', '0'), ('i', '1'), ('l', '1'), ('s', '5'), ('z', '2'), ('g', '9'), ('t', '7')];

/// The line labels [`read_values`] recognises (normalised to letters only), and what each is.
const KEYS: [(&str, Kind); 5] = [
    ("netwt", Kind::Weight),
    ("netweight", Kind::Weight),
    ("psilocybin", Kind::Psilocybin),
    ("psilocin", Kind::Psilocin),
    ("bestby", Kind::BestBy),
];

/// Words in a product's name that say what it is rather than which strain: they don't count as a strain match.
const STOP_WORDS: [&str; 18] = [
    "whole", "fungi", "edible", "psilocybin", "product", "freeze", "dried", "dehydrated", "homogenized", "chocolate", "honey",
    "extract", "gummy", "gummies", "microdose", "microdoses", "equiv", "disc",
];

/// The first code point of every run of ten Unicode decimal digits (category Nd) as Python 3.13 (Unicode 15.1) reads
/// them: Python's `\d` matches each, and `float()` reads each as its digit. Written out rather than taken from the
/// `regex` crate, whose Unicode version differs, so both sides read the same digits.
pub const DIGIT_ZEROS: [u32; 68] = [
    0x30, 0x660, 0x6f0, 0x7c0, 0x966, 0x9e6, 0xa66, 0xae6, 0xb66, 0xbe6, 0xc66, 0xce6, 0xd66, 0xde6, 0xe50, 0xed0, 0xf20,
    0x1040, 0x1090, 0x17e0, 0x1810, 0x1946, 0x19d0, 0x1a80, 0x1a90, 0x1b50, 0x1bb0, 0x1c40, 0x1c50, 0xa620, 0xa8d0, 0xa900,
    0xa9d0, 0xa9f0, 0xaa50, 0xabf0, 0xff10, 0x104a0, 0x10d30, 0x11066, 0x110f0, 0x11136, 0x111d0, 0x112f0, 0x11450, 0x114d0,
    0x11650, 0x116c0, 0x11730, 0x118e0, 0x11950, 0x11c50, 0x11d50, 0x11da0, 0x11f50, 0x16a60, 0x16ac0, 0x16b50, 0x1d7ce,
    0x1d7d8, 0x1d7e2, 0x1d7ec, 0x1d7f6, 0x1e140, 0x1e2f0, 0x1e4f0, 0x1e950, 0x1fbf0,
];

static HEX_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(id_patterns::PACKAGE_ID_OCR_HEX).expect("PACKAGE_ID_OCR_HEX"));

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Weight,
    Psilocybin,
    Psilocin,
    BestBy,
}

// --- Python's text rules ---------------------------------------------------------------------------------------------

/// The digit `c` stands for, when it is a decimal digit Python's `\d` matches.
fn digit_value(c: char) -> Option<u32> {
    let c = c as u32;
    let i = DIGIT_ZEROS.partition_point(|&z| z <= c);
    (i > 0 && c - DIGIT_ZEROS[i - 1] < 10).then(|| c - DIGIT_ZEROS[i - 1])
}

/// Python's `str.splitlines()`: lines split at \n, \r, \r\n, \v, \f, \x1c, \x1d, \x1e, \x85, U+2028 and U+2029, the
/// break left out, no empty line after a final break.
pub fn split_lines(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        if matches!(c, '\n' | '\r' | '\x0b' | '\x0c' | '\x1c' | '\x1d' | '\x1e' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            out.push(&text[start..i]);
            let mut end = i + c.len_utf8();
            if c == '\r' && chars.peek().is_some_and(|&(_, n)| n == '\n') {
                chars.next();
                end += 1;
            }
            start = end;
        }
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

/// Python's `str.strip()`: Unicode white space, and the separators \x1c to \x1f Python counts as space too.
fn py_strip(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() || ('\x1c'..='\x1f').contains(&c))
}

/// Python's `re.match` of PACKAGE_ID_OCR_HEX: its `$` also matches before one final newline.
fn hex_ok(h: &str) -> bool {
    HEX_RE.is_match(h.strip_suffix('\n').unwrap_or(h))
}

/// The hex digits after PKPR- (any case), lower-cased, as `ocr.id_index` took them.
fn package_hex(guid: &str) -> String {
    let lower = guid.to_lowercase();
    lower.strip_prefix("pkpr-").map(str::to_owned).unwrap_or(lower)
}

/// A line made comparable to an id: lower case, look-alike letters read as the digits they look like, and nothing
/// but 0-9 a-z kept.
pub fn norm(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .map(|c| CONFUSED.iter().find(|(from, _)| *from == c).map_or(c, |&(_, to)| to))
        .filter(|c| c.is_ascii_digit() || c.is_ascii_lowercase())
        .collect()
}

/// The first `n` characters of a normalised (ASCII) line.
fn head(s: &str, n: usize) -> &str {
    &s[..s.len().min(n)]
}

/// Levenshtein distance (characters wrong, missing or extra).
pub fn lev(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut cur = Vec::with_capacity(b.len() + 1);
        cur.push(i + 1);
        for (j, &cb) in b.iter().enumerate() {
            cur.push((prev[j + 1] + 1).min(cur[j] + 1).min(prev[j] + usize::from(ca != cb)));
        }
        prev = cur;
    }
    prev[b.len()]
}

/// Does this (normalised) line start like 'Lot: ...'? ('lot' normalises to '107'; one misread letter is allowed.)
pub fn lot_line(n: &str) -> bool {
    lev(head(n, 3), "107") <= 1
}

// --- find_ids --------------------------------------------------------------------------------------------------------

/// One id found in the text.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct IdMatch {
    pub guid: String,
    /// The id's hex digits as looked for (lower case, without PKPR-).
    pub hex: String,
    /// 0: every digit was there; 1 or 2: that many characters wrong, missing or extra.
    pub dist: usize,
    /// The line it was found on, as read (white space at either end left out).
    pub line: String,
}

/// The `guids` (package ids) found in `texts`. Each line is searched on its own, with look-alike letters fixed. Only
/// ids that look like PKPR-<5 to 8 hex digits> are looked for. An id counts as seen EXACTLY (dist 0) if all its digits
/// are there. A full 8-digit id is also found with up to [`MAX_MISREAD`] digits wrong, missing or extra (dist 1, 2);
/// ids of 5-7 digits must be exact. Two wrong digits are only believed on a 'Lot:' line (or in text a person typed,
/// `typed`), because with two digits free a stray number elsewhere on the label could look like an id. Best first,
/// then by id.
pub fn find_ids<S: AsRef<str>, G: AsRef<str>>(texts: &[S], guids: &[G], typed: bool) -> Vec<IdMatch> {
    // {hex digits: package id}, in first-seen order; a later id with the same digits replaces the earlier one
    let mut index: Vec<(String, String)> = Vec::new();
    for g in guids {
        let g = g.as_ref();
        let h = package_hex(g);
        if g.to_uppercase().starts_with("PKPR-") && hex_ok(&h) {
            match index.iter_mut().find(|(k, _)| *k == h) {
                Some(slot) => slot.1 = g.to_owned(),
                None => index.push((h, g.to_owned())),
            }
        }
    }
    // with <= 2 wrong digits one of the three pieces is always intact
    let pieces: Vec<(&str, &str, [&str; 3])> = index
        .iter()
        .filter(|(h, _)| h.chars().count() == 8)
        .map(|(h, g)| {
            let (a, rest) = h.split_at(3);
            let (b, c) = rest.split_at(3);
            (h.as_str(), g.as_str(), [a, b, c])
        })
        .collect();
    let mut best: HashMap<&str, IdMatch> = HashMap::new();
    for text in texts {
        for line in split_lines(text.as_ref()) {
            let normalised = norm(line);
            let n = head(&normalised, 80);
            if n.len() < 5 {
                continue;
            }
            for (h, g) in &index {
                if n.contains(h.as_str()) {
                    best.insert(h, IdMatch { guid: g.clone(), hex: h.clone(), dist: 0, line: py_strip(line).to_owned() });
                }
            }
            for (h, g, ps) in &pieces {
                if best.get(h).is_some_and(|m| m.dist == 0) || !ps.iter().any(|p| n.contains(p)) {
                    continue;
                }
                let mut d = 9;
                for w in (8 - MAX_MISREAD)..(9 + MAX_MISREAD) {
                    for i in 0..n.len().saturating_sub(w).saturating_add(1).max(1) {
                        let end = (i + w).min(n.len());
                        d = d.min(lev(&n[i.min(n.len())..end], h));
                    }
                }
                if (d <= 1 || (d <= MAX_MISREAD && (typed || lot_line(n)))) && d < best.get(h).map_or(9, |m| m.dist) {
                    best.insert(h, IdMatch { guid: (*g).to_owned(), hex: (*h).to_owned(), dist: d, line: py_strip(line).to_owned() });
                }
            }
        }
    }
    let mut out: Vec<IdMatch> = best.into_values().collect();
    out.sort_by(|a, b| (a.dist, &a.guid).cmp(&(b.dist, &b.guid)));
    out
}

// --- closest ---------------------------------------------------------------------------------------------------------

/// What a label's text says, whatever was made of the lot line.
#[derive(Debug, Default, PartialEq)]
pub struct LabelValues {
    /// From the 'Net wt' line (its label may be misread by a letter or two); None without one.
    pub weight: Option<f64>,
    /// From the 'Psilocybin' line ('Psilocin' is told apart); None without one.
    pub psilocybin: Option<f64>,
    /// Every YYYY-MM-DD (or / or . between) seen, as written, with - between.
    pub dates: Vec<String>,
    /// Every decimal seen (1-4 digits, a point or comma, 1-3 digits).
    pub numbers: Vec<f64>,
    /// Every run of 4 or more letters a-z in the lower-cased text.
    pub words: Vec<String>,
}

fn is_ascii_digit_at(chars: &[char], i: usize) -> bool {
    chars.get(i).is_some_and(char::is_ascii_digit)
}

/// The run of decimal digits (Python's `\d`) starting at chars[i], as their ASCII digits.
fn digits_from(chars: &[char], i: usize, max: usize) -> String {
    chars[i..].iter().take_while(|c| digit_value(**c).is_some()).take(max).map(|c| char::from_digit(digit_value(*c).unwrap(), 10).unwrap()).collect()
}

/// Python's `re.finditer(r"(?<![0-9])(\d{1,4})[.,](\d{1,3})(?![0-9])", line)`, each as float(f"{whole}.{fraction}").
fn decimals(line: &str) -> Vec<f64> {
    let chars: Vec<char> = line.chars().collect();
    let mut out = Vec::new();
    let mut p = 0;
    while p < chars.len() {
        if let Some((value, end)) = decimal_at(&chars, p) {
            out.push(value);
            p = end;
        } else {
            p += 1;
        }
    }
    out
}

fn decimal_at(chars: &[char], p: usize) -> Option<(f64, usize)> {
    if p > 0 && is_ascii_digit_at(chars, p - 1) {
        return None;
    }
    let run = chars[p..].iter().take_while(|c| digit_value(**c).is_some()).count();
    if run == 0 || run > 4 || !matches!(chars.get(p + run), Some('.' | ',')) {
        return None; // \d{1,4} backs off only into digits, which are never [.,]
    }
    let f = p + run + 1;
    let frac = chars[f..].iter().take_while(|c| digit_value(**c).is_some()).count();
    // \d{1,3} backs off until the next character isn't an ASCII digit
    let take = (1..=frac.min(3)).rev().find(|&j| !is_ascii_digit_at(chars, f + j))?;
    let text = format!("{}.{}", digits_from(chars, p, run), digits_from(chars, f, take));
    Some((text.parse().ok()?, f + take))
}

/// Python's `re.finditer(r"(?<![0-9])(\d{4})[-/.](\d{2})[-/.](\d{2})(?![0-9])", line)`, each as "-".join(groups).
fn dates(line: &str) -> Vec<String> {
    let chars: Vec<char> = line.chars().collect();
    let digit = |i: usize| chars.get(i).is_some_and(|c| digit_value(*c).is_some());
    let sep = |i: usize| matches!(chars.get(i), Some('-' | '/' | '.'));
    let mut out = Vec::new();
    let mut p = 0;
    while p + 10 <= chars.len() {
        let ok = !(p > 0 && is_ascii_digit_at(&chars, p - 1))
            && (p..p + 4).all(digit)
            && sep(p + 4)
            && digit(p + 5)
            && digit(p + 6)
            && sep(p + 7)
            && digit(p + 8)
            && digit(p + 9)
            && !is_ascii_digit_at(&chars, p + 10);
        if ok {
            let s = |a: usize, b: usize| chars[a..b].iter().collect::<String>();
            out.push(format!("{}-{}-{}", s(p, p + 4), s(p + 5, p + 7), s(p + 8, p + 10)));
            p += 10;
        } else {
            p += 1;
        }
    }
    out
}

/// Python's `re.findall(r"[a-z]{4,}", s.lower())`.
fn words(s: &str) -> Vec<String> {
    let lower = s.to_lowercase();
    let mut out = Vec::new();
    let mut cur = String::new();
    for c in lower.chars().chain(std::iter::once(' ')) {
        if c.is_ascii_lowercase() {
            cur.push(c);
        } else {
            if cur.len() >= 4 {
                out.push(std::mem::take(&mut cur));
            }
            cur.clear();
        }
    }
    out
}

/// What a label's text says (see [`LabelValues`]). weight and psilocybin come from the first 'Net wt' and
/// 'Psilocybin' lines that have a number: the line's label (before its first ':', letters only) must be within 2
/// characters of one of [`KEYS`] and not equally near two that mean different things.
pub fn read_values<S: AsRef<str>>(texts: &[S]) -> LabelValues {
    let mut out = LabelValues::default();
    for text in texts {
        for line in split_lines(text.as_ref()) {
            let ms = decimals(line);
            out.numbers.extend(&ms);
            out.dates.extend(dates(line));
            for w in words(line) {
                if !out.words.contains(&w) {
                    out.words.push(w);
                }
            }
            let label: String = line.split(':').next().unwrap_or("").to_lowercase().chars().filter(char::is_ascii_lowercase).collect();
            if ms.is_empty() || label.len() < 4 {
                continue;
            }
            let mut ranked: Vec<(usize, &str, Kind)> = KEYS.iter().map(|&(k, kind)| (lev(&label, k), k, kind)).collect();
            ranked.sort_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)));
            if ranked[0].0 > 2 || (ranked[0].0 == ranked[1].0 && ranked[0].2 != ranked[1].2) {
                continue;
            }
            match ranked[0].2 {
                Kind::Weight if out.weight.is_none() => out.weight = Some(ms[0]),
                Kind::Psilocybin if out.psilocybin.is_none() => out.psilocybin = Some(ms[0]),
                _ => {}
            }
        }
    }
    out
}

/// How far the nearest 8-character stretch of the (normalised) lines is from the lot digits h (9 if nothing is
/// close). Stretches that share fewer than 4 of the characters are skipped without working out the distance.
pub fn lot_distance(lines: &[String], h: &str) -> usize {
    let mut want: HashMap<char, usize> = HashMap::new();
    for c in h.chars() {
        *want.entry(c).or_default() += 1;
    }
    let mut best = 9;
    for n in lines.iter().take(12) {
        for i in 0..n.len().saturating_sub(7).max(1) {
            let w = &n[i..(i + 8).min(n.len())];
            let mut have: HashMap<char, usize> = HashMap::new();
            for c in w.chars() {
                *have.entry(c).or_default() += 1;
            }
            let shared: usize = have.iter().map(|(c, k)| (*k).min(want.get(c).copied().unwrap_or(0))).sum();
            if shared >= 4 {
                best = best.min(lev(w, h));
            }
        }
    }
    best
}

/// One inventory record of a package, as [`closest`] reads it. Other fields are ignored.
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ScanRecord {
    /// Grams per unit (null: 0).
    #[serde(default)]
    pub weight_per_unit: Option<f64>,
    /// The state's psilocybin, mg per gram (null: 0); a unit's psilocybin is weight_per_unit x this.
    #[serde(default)]
    pub analyte_weight: Option<f64>,
    /// The product's name, for its strain words.
    #[serde(default)]
    pub description: Option<String>,
    /// Units in stock (null: 0).
    #[serde(default)]
    pub quantity: Option<f64>,
    /// The record's best-by date, YYYY-MM-DD, when known.
    #[serde(default)]
    pub expires: Option<String>,
}

/// A package and its inventory records (only records that can be sold: the caller filters them).
#[derive(Deserialize, Clone, Debug)]
pub struct ScanPackage {
    pub guid: String,
    pub records: Vec<ScanRecord>,
}

/// One package [`closest`] offers.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Guess {
    pub guid: String,
    pub score: i64,
    /// Why, in words, in the order the points were given.
    pub why: Vec<String>,
    /// The record's grams per unit and mg psilocybin per unit, as the label prints them.
    pub weight: f64,
    pub mg: f64,
    /// Which of the package's records the score is for (the first with the highest score).
    pub record: usize,
    /// Units in stock over all the package's records.
    pub stock: f64,
}

/// When no lot number was found: the packages that best fit the rest of the label, best first. A weight or
/// psilocybin amount that is READ from its line must match the record (within [`MATCH_G`]) or the record is out.
/// Points: 3 for the weight matching, 3 for the psilocybin amount matching (1 each if the number is only somewhere in
/// the text), 2 for the best-by date, 1 for each strain word (up to 3), 2 for a lot number that is a few characters
/// off. At least [`MIN_SCORE`] to be offered, and the weight or the psilocybin amount must be on the label. At most
/// [`MAX_GUESSES`]. A package listed twice counts as its last listing.
pub fn closest<S: AsRef<str>>(texts: &[S], packages: &[ScanPackage]) -> Vec<Guess> {
    let v = read_values(texts);
    let lines: Vec<String> = texts
        .iter()
        .flat_map(|t| split_lines(t.as_ref()))
        .map(norm)
        .filter(|n| n.len() >= 5)
        .map(|n| head(&n, 80).to_owned())
        .collect();
    let mut last: HashMap<&str, usize> = HashMap::new();
    for (i, p) in packages.iter().enumerate() {
        last.insert(p.guid.as_str(), i);
    }
    let mut out = Vec::new();
    for (i, pkg) in packages.iter().enumerate() {
        if last[pkg.guid.as_str()] != i {
            continue;
        }
        let stock: f64 = pkg.records.iter().map(|r| r.quantity.unwrap_or(0.0)).sum();
        let mut best: Option<Guess> = None;
        for (ri, r) in pkg.records.iter().enumerate() {
            let w = r.weight_per_unit.unwrap_or(0.0);
            let mg = w * r.analyte_weight.unwrap_or(0.0);
            let (mut score, mut why, mut numeric) = (0i64, Vec::new(), false);
            if let Some(read) = v.weight {
                if (read - w).abs() > MATCH_G {
                    continue;
                }
                score += 3;
                why.push(format!("net weight {w:.2} g"));
                numeric = true;
            } else if v.numbers.iter().any(|n| (n - w).abs() <= MATCH_G) && w > 0.0 {
                score += 1;
                why.push(format!("{w:.2} g appears on the label"));
                numeric = true;
            }
            if let Some(read) = v.psilocybin {
                if (read - mg).abs() > MATCH_G {
                    continue;
                }
                score += 3;
                why.push(format!("psilocybin {mg:.2} mg"));
                numeric = true;
            } else if v.numbers.iter().any(|n| (n - mg).abs() <= MATCH_G) && mg > 0.0 {
                score += 1;
                why.push(format!("{mg:.2} mg appears on the label"));
                numeric = true;
            }
            if let Some(exp) = r.expires.as_deref().filter(|e| v.dates.iter().any(|d| d == e)) {
                score += 2;
                why.push(format!("best by {exp}"));
            }
            let strain: Vec<String> = words(r.description.as_deref().unwrap_or(""))
                .into_iter()
                .filter(|x| !STOP_WORDS.contains(&x.as_str()) && v.words.contains(x))
                .collect();
            if !strain.is_empty() {
                score += strain.len().min(3) as i64;
                let mut named: Vec<&str> = Vec::new();
                for s in &strain {
                    if !named.contains(&s.as_str()) {
                        named.push(s);
                    }
                }
                why.push(format!("name has {}", named.join(", ")));
            }
            let h = package_hex(&pkg.guid);
            if hex_ok(&h) && h.chars().count() == 8 {
                let d = lot_distance(&lines, &h);
                if d <= 4 {
                    score += 2;
                    why.push(format!("lot number {d} characters away"));
                }
            }
            if !numeric {
                continue; // a date and a name alone is too weak a reason
            }
            if best.as_ref().is_none_or(|b| score > b.score) {
                best = Some(Guess { guid: pkg.guid.clone(), score, why, weight: w, mg, record: ri, stock });
            }
        }
        if let Some(b) = best.filter(|b| b.score >= MIN_SCORE) {
            out.push(b);
        }
    }
    out.sort_by(|a, b| (-a.score, &a.guid).cmp(&(-b.score, &b.guid)));
    out.truncate(MAX_GUESSES);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digits_are_the_ones_python_reads() {
        assert_eq!(digit_value('7'), Some(7));
        assert_eq!(digit_value('\u{665}'), Some(5)); // Arabic-Indic five
        assert_eq!(digit_value('\u{1fbf9}'), Some(9)); // the last block
        assert_eq!(digit_value('a'), None);
        assert_eq!(digit_value('\u{2155}'), None); // a vulgar fraction is not a decimal digit
        assert!(DIGIT_ZEROS.windows(2).all(|w| w[0] + 10 <= w[1]));
    }

    #[test]
    fn lines_split_as_python_splits_them() {
        assert_eq!(split_lines("a\r\nb\rc\n"), ["a", "b", "c"]);
        assert_eq!(split_lines("\n\n"), ["", ""]);
        assert!(split_lines("").is_empty());
        assert_eq!(split_lines("a\x1fb\u{85}c"), ["a\x1fb", "c"]);
        assert_eq!(py_strip("\x1f a \u{3000}"), "a");
    }

    #[test]
    fn decimals_back_off_as_python_regex_does() {
        assert_eq!(decimals("Net wt: 0.50 g (1,25)"), [0.5, 1.25]);
        assert_eq!(decimals("12345.5 0.5000 1.234"), [1.234]);
        assert_eq!(decimals("2027.06.01"), [2027.06]);
        assert_eq!(decimals("\u{660}.\u{665}\u{660}"), [0.5]);
        assert_eq!(decimals("1.2\u{663}4"), [1.234]);
        assert_eq!(decimals("1.2\u{663}45"), [1.2]); // \\d{1,3} backs off only to a place no ASCII digit follows
        assert_eq!(dates("x2027/06/01 and 12027-06-01"), ["2027-06-01"]);
    }
}
