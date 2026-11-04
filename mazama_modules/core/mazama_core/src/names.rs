//! Names: strain spellings, product and batch/lot names read into fields, a product's type code, all from the
//! shared names table ([`crate::names_table`]). The one reader both apps use: the server's mirror stores what
//! [`parse_product`] and [`parse_source`] answer for every record (`names.parse`), the phone reads a name for display
//! (`names.name`), and labels read the strain, code and best-by in a package's name ([`crate::label`]).
//!
//! The rules were the server's Python `re` patterns, and they are read exactly as Python read them: whitespace is
//! Python's (`\s` and `str.strip()` include U+001C..U+001F), a word boundary is between a letter, digit or `_` and
//! anything else (Python's `\b`), a case-blind `i` also matches `İ` and `ı`, digits are any Unicode decimal digit
//! (their value read as Python's `int()` does), and a date in a product name is read as `date.fromisoformat`.
//! Vectors: `mazama_modules/names/vectors/names.json` (the shared cases) and `names/frozen/names_server_old.json` (the
//! server's Python over a generated grid, frozen when the rule moved here).

use regex::Regex;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use crate::names_table::{self, CODE_WORDS, STRAIN_MAX};

// --- Python's reading of text ----------------------------------------------------------------------------------

/// Python's `str.isspace()` (and `\s`): Unicode White_Space plus U+001C..U+001F.
pub fn py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// Python's `str.strip()`.
pub fn py_strip(s: &str) -> &str {
    s.trim_matches(py_space)
}

static PY_WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[\p{L}\p{N}_]$").unwrap());
static ND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\p{Nd}$").unwrap());

/// A character of Python's `\w`: `str.isalnum()` (a letter or a number of any kind) or `_`.
fn py_word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || (!c.is_ascii() && PY_WORD.is_match(c.encode_utf8(&mut [0; 4])))
}

pub(crate) fn is_nd(c: char) -> bool {
    c.is_ascii_digit() || (!c.is_ascii() && ND.is_match(c.encode_utf8(&mut [0; 4])))
}

/// The value of a Unicode decimal digit, as Python's `int()` reads it: every set of decimal digits is ten code
/// points in a row, 0 to 9, and sets sit next to each other only whole, so the value is the distance from the start
/// of its run, modulo 10.
pub(crate) fn nd_value(c: char) -> u32 {
    if let Some(d) = c.to_digit(10) {
        return d;
    }
    let mut start = c as u32;
    while let Some(p) = start.checked_sub(1).and_then(char::from_u32).filter(|&p| is_nd(p)) {
        start = p as u32;
    }
    (c as u32 - start) % 10
}

/// Python's `int()` of text made of decimal digits (none of it is anything else).
fn nd_int(s: &str) -> Option<i64> {
    if s.is_empty() {
        return None;
    }
    s.chars().try_fold(0i64, |a, c| a.checked_mul(10)?.checked_add(i64::from(nd_value(c))))
}

/// Python's `\b` at byte offset `i` of `s`.
fn boundary(s: &str, i: usize) -> bool {
    let before = s[..i].chars().next_back().is_some_and(py_word);
    let after = s[i..].chars().next().is_some_and(py_word);
    before != after
}

/// A Python pattern written for Rust's `regex`: `\s` as Python's whitespace.
fn py_pattern(p: &str) -> String {
    p.replace(r"\s", r"[\s\x1c-\x1f]")
}

/// A literal word, matched ignoring case as Python's `re.I` does (an `i` also matches `İ` and `ı`); a space is any
/// run of whitespace.
fn py_ci_literal(word: &str) -> String {
    word.chars()
        .map(|c| match c {
            'i' | 'I' => "[iIİı]".to_string(),
            ' ' => r"\s+".to_string(),
            c => regex::escape(&c.to_string()),
        })
        .collect()
}

fn re(p: &str) -> Regex {
    Regex::new(&py_pattern(p)).unwrap()
}

/// Python's `re.search(r"\b(?:alt1|alt2|...)\b", s[from..])` for anchored alternatives (each starts with `^`),
/// tried in order at each position: -> (start, end).
fn find_bounded(s: &str, from: usize, alts: &[Regex]) -> Option<(usize, usize)> {
    let positions = s[from..].char_indices().map(|(i, _)| from + i).chain(std::iter::once(s.len()));
    for p in positions {
        if !boundary(s, p) {
            continue;
        }
        for alt in alts {
            if let Some(m) = alt.find(&s[p..]) {
                if boundary(s, p + m.end()) {
                    return Some((p, p + m.end()));
                }
            }
        }
    }
    None
}

/// Python's `re.sub` of a `\b(...)\b` pattern: every match, left to right, replaced by `with(matched text)`.
fn sub_bounded(s: &str, alts: &[Regex], with: impl Fn(&str) -> String) -> String {
    let mut out = String::new();
    let mut at = 0;
    while let Some((start, end)) = find_bounded(s, at, alts) {
        out.push_str(&s[at..start]);
        out.push_str(&with(&s[start..end]));
        at = end;
        if start == end {
            break;
        }
    }
    out.push_str(&s[at..]);
    out
}

// --- strains -------------------------------------------------------------------------------------------------------

static MISSPELT: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    let words: Vec<String> = names_table::MISSPELLINGS.iter().map(|(w, _)| py_ci_literal(w)).collect();
    vec![Regex::new(&py_pattern(&format!("(?i)^(?:{})", words.join("|")))).unwrap()]
});
static STRAIN_BAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!("[^{}]", names_table::STRAIN_ALLOWED)).unwrap());

/// A strain's key: lower case, every run of characters other than `a-z0-9` one space, no space at either end.
pub fn strain_key(name: &str) -> String {
    let lower = name.to_lowercase();
    let mut out = String::new();
    for part in lower.split(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit())).filter(|p| !p.is_empty()) {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(part);
    }
    out
}

/// A misspelt word ("Mazatapec") spelled right ("Maztapec"), wherever it is a whole word.
pub fn fix_spelling(s: &str) -> String {
    sub_bounded(s, &MISSPELT, |w| {
        let w = w.to_lowercase();
        names_table::MISSPELLINGS.iter().find(|(m, _)| *m == w).map_or(w.clone(), |(_, right)| right.to_string())
    })
}

/// Only safe characters survive (the strain is also part of label file names), "Mazatapec" spelled "Maztapec", no
/// spaces or dots at either end, at most 30 characters.
pub fn clean_strain(s: &str) -> String {
    let fixed = fix_spelling(s);
    let safe = STRAIN_BAD.replace_all(&fixed, "");
    let trimmed = safe.trim_matches(|c| c == ' ' || c == '.');
    trimmed.chars().take(STRAIN_MAX).collect::<String>().trim().to_string()
}

fn builtin_strain(key: &str) -> Option<String> {
    names_table::BUILTIN_ALIASES
        .iter()
        .find(|(canon, aliases)| strain_key(canon) == key || aliases.iter().any(|a| strain_key(a) == key))
        .map(|(canon, _)| canon.to_string())
}

/// The built-in spellings only ('GT' / 'golden' -> 'Golden Teacher'); a name it doesn't know comes back unchanged.
pub fn canonical_strain(name: &str) -> String {
    builtin_strain(&strain_key(name)).unwrap_or_else(|| name.to_string())
}

/// With the Strains page's (spelling, name to show) pairs: they come first (a later pair for the same spelling wins),
/// and the name they point to is itself looked up among the built-in ones, so 'Hua' -> 'Huautla' stays one strain
/// whichever way it is entered.
pub fn canonical_strain_with(name: &str, extras: &[(String, String)]) -> String {
    let key = strain_key(name);
    let mut chosen: Option<&String> = None;
    for (spelling, shown) in extras {
        let k = strain_key(spelling);
        if !k.is_empty() && k == key {
            chosen = Some(shown);
        }
    }
    match chosen {
        Some(shown) => builtin_strain(&strain_key(shown)).unwrap_or_else(|| shown.clone()),
        None => canonical_strain(name),
    }
}

/// -> (the strain cleaned and spelled the usual way, or None, and a note). A strain with characters that are not
/// allowed is not guessed at.
fn strain_of(raw: &str, aliases: &[(String, String)]) -> (Option<String>, Option<String>) {
    let raw = py_strip(raw);
    let mut bad: Vec<char> = STRAIN_BAD.find_iter(&fix_spelling(raw)).flat_map(|m| m.as_str().chars()).collect();
    bad.sort_unstable();
    bad.dedup();
    if !bad.is_empty() {
        let list: Vec<String> = bad.iter().map(char::to_string).collect();
        return (None, Some(format!("the strain name has characters that are not allowed: {}", list.join(" "))));
    }
    let cleaned = clean_strain(raw);
    if cleaned.is_empty() || !cleaned.chars().any(|c| c.is_ascii_alphabetic()) {
        return (None, Some("no strain name".into()));
    }
    let note = (raw.trim_matches(|c| c == ' ' || c == '.').chars().count() > STRAIN_MAX)
        .then(|| format!("the strain name is longer than {STRAIN_MAX} characters and was shortened"));
    (Some(canonical_strain_with(&cleaned, aliases)), note)
}

// --- product and batch/lot names --------------------------------------------------------------------------------

pub const OK: &str = "ok";
pub const PARTIAL: &str = "partial";
pub const UNPARSED: &str = "unparsed";

/// A name read into fields; `dose_text` is the dose as written, [`Parsed::dose`] the same number as plain decimal
/// text (`"7.5"`, `"25"`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Parsed {
    pub status: &'static str,
    pub strain_raw: Option<String>,
    pub strain: Option<String>,
    pub dose_text: Option<String>,
    pub code: Option<String>,
    /// ISO date.
    pub expiry: Option<String>,
    pub label: Option<String>,
    pub note: Option<String>,
}

impl Parsed {
    fn unparsed(note: &str) -> Parsed {
        Parsed { status: UNPARSED, note: Some(note.into()), ..Default::default() }
    }

    /// The dose as Python's `str(Decimal(dose_text))` writes it, when the text is digits with at most a decimal point.
    pub fn dose(&self) -> Option<String> {
        self.dose_text.as_deref().and_then(plain_decimal)
    }

    pub fn to_value(&self) -> Value {
        json!({"status": self.status, "strain_raw": self.strain_raw, "strain": self.strain, "dose": self.dose(),
               "dose_text": self.dose_text, "code": self.code, "expiry": self.expiry, "label": self.label, "note": self.note})
    }
}

/// Decimal text as Python's `str(Decimal(text))` writes it, for digits with an optional fraction: ASCII digits, no
/// leading zeros before the point (one kept), the fraction as written. None for anything else, or a value so small
/// that Python would write it with an exponent.
fn plain_decimal(text: &str) -> Option<String> {
    let (int, frac) = match text.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (text, None),
    };
    let digits = |s: &str| !s.is_empty() && s.chars().all(is_nd);
    if !digits(int) || frac.is_some_and(|f| !digits(f)) {
        return None;
    }
    let ascii = |s: &str| s.chars().map(|c| char::from_digit(nd_value(c), 10).unwrap()).collect::<String>();
    let int = ascii(int);
    let int = int.trim_start_matches('0');
    let int = if int.is_empty() { "0" } else { int };
    let Some(frac) = frac.map(ascii) else { return Some(int.to_string()) };
    let coefficient = format!("{int}{frac}");
    let significant = coefficient.trim_start_matches('0').len().max(1) as i64;
    if significant - 1 - (frac.len() as i64) < -6 {
        return None;
    }
    Some(format!("{int}.{frac}"))
}

const DOSE: &str = r"(?P<dose>\d{1,4}(?:\.\d{1,2})?)";
const MDY: &str = r"\d{1,2}/\d{1,2}(?:/\d{2}(?:\d{2})?)?";

static CANONICAL: LazyLock<Regex> = LazyLock::new(|| {
    re(&format!(
        r"(?i)^(?P<strain>.+?)\s+{DOSE}\s*mg(?:\s+TPE)?(?:\s+(?P<code>{CODE_WORDS}))?(?:\s*\((?P<exp>\d{{4}}-\d\d-\d\d)\))?$"
    ))
});
static DOSE_HERE: LazyLock<Regex> = LazyLock::new(|| re(&format!(r"(?i)^{DOSE}\s*mg")));
static TRAILING_EXPIRY: LazyLock<Regex> = LazyLock::new(|| re(r"\(\s*(\d{4}-\d\d-\d\d)\s*\)\s*$"));
static TRAILING_CODE: LazyLock<Regex> = LazyLock::new(|| re(&format!(r"(?i)\s+(?P<code>{CODE_WORDS})$")));
static TRAILING_NUMBER: LazyLock<Regex> = LazyLock::new(|| re(r"\s+(?P<label>[0-9][0-9.]*)$"));
static TRAILING_EXP: LazyLock<Regex> = LazyLock::new(|| re(&format!(r"(?i)\s+exp\.?\s*(?P<exp>{MDY})$")));
static TRAILING_DATE: LazyLock<Regex> = LazyLock::new(|| re(&format!(r"\s+(?P<label>{MDY})$")));
static TRAILING_HASH: LazyLock<Regex> = LazyLock::new(|| re(r"\s+#\s*(?P<n>\d+)$"));
static LEADING_DOSE: LazyLock<Regex> = LazyLock::new(|| re(&format!(r"(?i)^{DOSE}\s*mg\s+")));
static LEADING_NUMBER: LazyLock<Regex> = LazyLock::new(|| re(r"^(?P<label>[0-9][0-9.]*)(?P<ws>\s+)"));
static PACKAGING: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    names_table::PACKAGING_WORDS.iter().map(|w| Regex::new(&py_pattern(&format!("(?i)^{}", py_ci_literal(w)))).unwrap()).collect()
});
static JOINER: LazyLock<Regex> = LazyLock::new(|| re(r"^\s*[/&]\s*"));
static SPACES: LazyLock<Regex> = LazyLock::new(|| re(r"\s+"));

fn code_word(word: Option<&str>) -> Option<String> {
    let w = word?.to_uppercase();
    names_table::CODES.iter().find(|(spelling, _)| *spelling == w).map(|(_, code)| code.to_string())
}

/// `date.fromisoformat(text)` -> (ISO date, or None and a note).
fn iso_expiry(text: &str) -> (Option<String>, Option<String>) {
    match crate::selling::sale::iso_date(text) {
        Some(z) => {
            let (y, m, d) = crate::label::civil_from_days(z);
            (Some(format!("{y:04}-{m:02}-{d:02}")), None)
        }
        None => (None, Some(format!("{text} is not a real date"))),
    }
}

/// "4/21/27" -> 2027-04-21 (a two-digit year is 20xx), when it is a real date; a month and day alone is none.
fn mdy_expiry(text: &str) -> (Option<String>, Option<String>) {
    let bad = || (None, Some(format!("{text} is not a real date")));
    let parts: Vec<&str> = text.split('/').collect();
    if parts.len() != 3 {
        return bad();
    }
    let (Some(m), Some(d), Some(y)) = (nd_int(parts[0]), nd_int(parts[1]), nd_int(parts[2])) else { return bad() };
    let y = if y < 100 { 2000 + y } else { y };
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days = match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => 0,
    };
    if !(1..=9999).contains(&y) || d < 1 || d > month_days {
        return bad();
    }
    (Some(format!("{y:04}-{m:02}-{d:02}")), None)
}

/// `\s*[/&]\s*` between two ASCII letters or digits ("white/brown", "SN & SK") -> (start, end) of each.
fn joiners(t: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut p = 0;
    while p < t.len() {
        if t[..p].chars().next_back().is_some_and(|c| c.is_ascii_alphanumeric()) {
            if let Some(m) = JOINER.find(&t[p..]) {
                let end = p + m.end();
                if t[end..].chars().next().is_some_and(|c| c.is_ascii_alphanumeric()) {
                    out.push((p, end));
                    p = end;
                    continue;
                }
            }
        }
        p += t[p..].chars().next().map_or(1, char::len_utf8);
    }
    out
}

/// A match's reading (the default pattern's, or a manufacturer's own with the same group names).
fn from_match(m: &regex::Captures, aliases: &[(String, String)]) -> Result<Parsed, String> {
    let (Some(strain_m), Some(dose_m)) = (m.name("strain"), m.name("dose")) else {
        return Err("the name format matched without a strain or a dose".into());
    };
    let raw = py_strip(strain_m.as_str()).to_string();
    let (strain, strain_note) = strain_of(&raw, aliases);
    if strain.is_none() {
        return Ok(Parsed { status: UNPARSED, strain_raw: Some(raw), note: strain_note, ..Default::default() });
    }
    let exp_text = m.name("exp").map(|e| e.as_str()).filter(|e| !e.is_empty());
    let (expiry, exp_note) = exp_text.map_or((None, None), iso_expiry);
    let mut notes: Vec<String> = [strain_note, exp_note].into_iter().flatten().collect();
    if exp_text.is_none() {
        notes.push("no expiration date in the name".into());
    }
    Ok(Parsed {
        status: if notes.is_empty() { OK } else { PARTIAL },
        strain_raw: Some(raw),
        strain,
        dose_text: Some(dose_m.as_str().to_string()),
        code: code_word(m.name("code").map(|c| c.as_str()).filter(|c| !c.is_empty())),
        expiry,
        label: None,
        note: (!notes.is_empty()).then(|| notes.join("; ")),
    })
}

/// The first `<n> mg` (a word boundary after it) not right after a digit or a dot -> (start, end, the dose).
fn dose_anywhere(t: &str) -> Option<(usize, usize, String)> {
    let mut prev: Option<char> = None;
    for (i, c) in t.char_indices() {
        if !matches!(prev, Some(p) if p.is_ascii_digit() || p == '.') {
            if let Some(m) = DOSE_HERE.captures(&t[i..]) {
                let end = i + m.get(0).unwrap().end();
                if boundary(t, end) {
                    return Some((i, end, m["dose"].to_string()));
                }
            }
        }
        prev = Some(c);
    }
    None
}

/// A manufacturer's pattern read as Python's `re.I` read it: `\s` (in a class too) and `\S` with Python's whitespace
/// (U+001C..U+001F too), and a class holding `i` or `I` (alone or in a range) also holding `İ` and `ı`.
fn py_format_pattern(p: &str) -> String {
    let chars: Vec<char> = p.chars().collect();
    let mut out = String::with_capacity(p.len() + 16);
    let (mut i, mut in_class, mut class_start) = (0, false, false);
    while i < chars.len() {
        let c = chars[i];
        let starting = class_start;
        class_start = false;
        if c == '\\' {
            match chars.get(i + 1) {
                Some('s') if in_class => out.push_str(r"\s\x1c-\x1f"),
                Some('s') => out.push_str(r"[\s\x1c-\x1f]"),
                Some('S') if !in_class => out.push_str(r"[^\s\x1c-\x1f]"),
                Some(n) => {
                    out.push('\\');
                    out.push(*n);
                }
                None => out.push('\\'),
            }
            i += 2;
            continue;
        }
        if !in_class {
            out.push(c);
            if c == '[' {
                in_class = true;
                class_start = true;
                if chars.get(i + 1) == Some(&'^') {
                    out.push('^');
                    i += 1;
                }
            }
            i += 1;
            continue;
        }
        if c == ']' && !starting {
            in_class = false;
            out.push(']');
            i += 1;
            continue;
        }
        // a class member: a range `c-d`, or one character
        let (lo, hi, used) = match (chars.get(i + 1), chars.get(i + 2)) {
            (Some('-'), Some(&d)) if d != ']' && d != '\\' => (c, d, 3),
            _ => (c, c, 1),
        };
        out.extend(&chars[i..i + used]);
        if (lo..=hi).contains(&'i') || (lo..=hi).contains(&'I') {
            out.push_str("İı");
        }
        i += used;
    }
    out
}

static FORMATS: LazyLock<Mutex<HashMap<String, Regex>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// A manufacturer's own name pattern, matched ignoring case, with the groups `strain` and `dose` (and optionally
/// `code` and `exp`); an error when the core's regular expressions can't read it. Compiled once per process.
pub fn name_format(pattern: &str) -> Result<Regex, String> {
    let mut cache = FORMATS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(r) = cache.get(pattern) {
        return Ok(r.clone());
    }
    let r = Regex::new(&format!("(?i){}", py_format_pattern(pattern)))
        .map_err(|e| format!("the name format is not a regular expression the core can read: {e}"))?;
    let names: Vec<&str> = r.capture_names().flatten().collect();
    for g in ["strain", "dose"] {
        if !names.contains(&g) {
            return Err(format!("the name format must name the group {g:?}"));
        }
    }
    if cache.len() >= 256 {
        cache.clear();
    }
    cache.insert(pattern.to_string(), r.clone());
    Ok(r)
}

/// A packaged product's name: `"<strain> <dose> mg TPE[ <code>] (<YYYY-MM-DD>)"`, or the manufacturer's own pattern
/// first when one is given (a name it doesn't fit is read the default way); a name that only has `<n> mg` somewhere
/// is partial; one without is unparsed.
pub fn parse_product(text: &str, aliases: &[(String, String)], format: Option<&str>) -> Result<Parsed, String> {
    let t = py_strip(text);
    if t.is_empty() {
        return Ok(Parsed::unparsed("the name is empty"));
    }
    if let Some(pattern) = format.filter(|p| !p.is_empty()) {
        if let Some(m) = name_format(pattern)?.captures(t).filter(|m| m.get(0).unwrap().start() == 0) {
            return from_match(&m, aliases);
        }
    }
    if let Some(m) = CANONICAL.captures(t) {
        return from_match(&m, aliases);
    }
    let Some((start, end, dose)) = dose_anywhere(t) else {
        return Ok(Parsed::unparsed("no dose in mg found in the name"));
    };
    let raw = py_strip(&t[..start]).to_string();
    let (strain, strain_note) = strain_of(&raw, aliases);
    if strain.is_none() {
        let strain_raw = (!raw.is_empty()).then_some(raw);
        return Ok(Parsed { status: UNPARSED, strain_raw, dose_text: Some(dose), note: strain_note, ..Default::default() });
    }
    let rest = &t[end..];
    let (expiry, exp_note) = TRAILING_EXPIRY.captures(rest).map_or((None, None), |c| iso_expiry(&c[1]));
    let without_date = TRAILING_EXPIRY.replace(rest, "");
    let code = TRAILING_CODE.captures(without_date.trim_end_matches(py_space)).and_then(|c| code_word(Some(&c["code"])));
    let mut notes = vec!["the name does not follow '<strain> <mg> mg TPE <code> (<date>)'".to_string()];
    notes.extend([strain_note, exp_note].into_iter().flatten());
    Ok(Parsed { status: PARTIAL, strain_raw: Some(raw), strain, dose_text: Some(dose), code, expiry, label: None, note: Some(notes.join("; ")) })
}

/// A harvest batch's or process lot's name: `"<strain>[ <code>][ <number>]"`, and as people also write them: one
/// named like a product (with its date) is read like one; a trailing date ("11/25/25", "7/25") or "#1" and a leading
/// harvest number ("6.25") are its label; "exp <date>" its expiry; a leading "<n>mg" its dose; packaging words
/// ("Plastic Jars") are dropped; "/" and "&" between words are read as "+" (noted: a person should look).
pub fn parse_source(text: &str, aliases: &[(String, String)]) -> Parsed {
    let mut t = py_strip(text).to_string();
    if t.is_empty() {
        return Parsed::unparsed("the name is empty");
    }
    if let Some(m) = CANONICAL.captures(&t) {
        if m.name("exp").is_some_and(|e| !e.as_str().is_empty()) {
            return from_match(&m, aliases).expect("the default pattern has a strain and a dose");
        }
    }
    let mut notes: Vec<String> = Vec::new();
    let (mut expiry, mut dose) = (None, None);
    if let Some(e) = TRAILING_EXP.captures(&t) {
        let (x, bad) = mdy_expiry(&e["exp"]);
        expiry = x;
        notes.extend(bad);
        t = py_strip(&t[..e.get(0).unwrap().start()]).to_string();
    }
    let mut labels: Vec<String> = Vec::new();
    if let Some(h) = TRAILING_HASH.captures(&t) {
        labels.push(format!("#{}", &h["n"]));
        t = py_strip(&t[..h.get(0).unwrap().start()]).to_string();
    }
    if let Some(d) = TRAILING_DATE.captures(&t) {
        labels.insert(0, d["label"].to_string());
        t = py_strip(&t[..d.get(0).unwrap().start()]).to_string();
    } else if let Some(n) = TRAILING_NUMBER.captures(&t) {
        labels.insert(0, n["label"].to_string());
        t = py_strip(&t[..n.get(0).unwrap().start()]).to_string();
    }
    if let Some(ld) = LEADING_DOSE.captures(&t) {
        dose = Some(ld["dose"].to_string());
        t = py_strip(&t[ld.get(0).unwrap().end()..]).to_string();
    } else if let Some(ln) = LEADING_NUMBER.captures(&t) {
        // `^([0-9][0-9.]*)\s+(?=\D)`: the whitespace run, less its last character when a digit follows it
        let ws = ln.name("ws").unwrap();
        let end = match t[ws.end()..].chars().next() {
            Some(c) if !is_nd(c) => Some(ws.end()),
            _ if ws.as_str().chars().count() >= 2 => Some(ws.end() - ws.as_str().chars().next_back().unwrap().len_utf8()),
            _ => None,
        };
        if let Some(end) = end {
            labels.insert(0, ln["label"].to_string());
            t = py_strip(&t[end..]).to_string();
        }
    }
    let label = (!labels.is_empty()).then(|| labels.join(" "));
    let mut code = None;
    if let Some(c) = TRAILING_CODE.captures(&t) {
        code = code_word(Some(&c["code"]));
        t = py_strip(&t[..c.get(0).unwrap().start()]).to_string();
    }
    let unpacked = sub_bounded(&t, &PACKAGING, |_| " ".into());
    t = py_strip(&SPACES.replace_all(&unpacked, " ")).to_string();
    let raw = t.clone();
    let joins = joiners(&t);
    if !joins.is_empty() {
        let mut out = String::new();
        let mut at = 0;
        for (s, e) in joins {
            out.push_str(&t[at..s]);
            out.push_str(if t[s..e].contains(' ') { " + " } else { "+" });
            at = e;
        }
        out.push_str(&t[at..]);
        t = out;
        notes.insert(0, "'/' and '&' are read as '+'".into());
    }
    let (strain, note) = strain_of(&t, aliases);
    if strain.is_none() {
        let strain_raw = (!raw.is_empty()).then_some(raw);
        return Parsed { status: UNPARSED, strain_raw, strain: None, dose_text: dose, code, expiry, label, note };
    }
    notes.extend(note);
    Parsed {
        status: if notes.is_empty() { OK } else { PARTIAL },
        strain_raw: Some(raw),
        strain,
        dose_text: dose,
        code,
        expiry,
        label,
        note: (!notes.is_empty()).then(|| notes.join("; ")),
    }
}

// --- type codes -----------------------------------------------------------------------------------------------------

static NAME_CODE: LazyLock<Vec<Regex>> = LazyLock::new(|| vec![re(r"^TPE\s+(?P<code>[A-Z]{2})")]);

/// The two-letter product type: the code written in the name ("... TPE CH (2027-02-03)"), else the certificate's
/// subtype code, else a word in the name ("chocolate microdoses" -> CH); "" when none is known.
pub fn code_of(description: &str, coa_code: &str) -> String {
    if let Some((start, _)) = find_bounded(description, 0, &NAME_CODE) {
        return NAME_CODE[0].captures(&description[start..]).unwrap()["code"].to_string();
    }
    if !coa_code.is_empty() {
        return coa_code.to_string();
    }
    let low = description.to_lowercase();
    names_table::NAME_KEYWORDS.iter().find(|(w, _)| low.contains(w)).map_or(String::new(), |(_, c)| c.to_string())
}

/// A certificate subtype's code ("Freeze dried" -> "FD"), "HG" for a homogenized product without one, else "".
pub fn type_code(subtype: &str, product_type: &str) -> String {
    let sub = py_strip(subtype);
    let sub = if sub.is_empty() && product_type.to_lowercase().contains("homogenized") { "Homogenized" } else { sub };
    names_table::SUBTYPE_CODE.iter().find(|(s, _)| *s == sub).map_or(String::new(), |(_, c)| c.to_string())
}

// --- JSON -----------------------------------------------------------------------------------------------------------

/// `{items: [{text, kind: "product" | "source", license?}], aliases?: [[spelling, shown]], formats?: {license:
/// pattern}}` -> `[Parsed]`, one per item in order.
pub fn parse_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Item {
        text: Option<String>,
        kind: String,
        license: Option<String>,
    }
    #[derive(Deserialize)]
    struct Input {
        items: Vec<Item>,
        aliases: Option<Vec<(String, String)>>,
        formats: Option<HashMap<String, String>>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let aliases = input.aliases.unwrap_or_default();
    let formats = input.formats.unwrap_or_default();
    let mut out = Vec::with_capacity(input.items.len());
    for it in &input.items {
        let text = it.text.as_deref().unwrap_or("");
        let parsed = match it.kind.as_str() {
            "product" => {
                let format = it.license.as_deref().filter(|l| !l.is_empty()).and_then(|l| formats.get(l)).map(String::as_str);
                parse_product(text, &aliases, format)?
            }
            "source" => parse_source(text, &aliases),
            k => return Err(format!("kind must be product or source, not {k:?}").into()),
        };
        out.push(parsed.to_value());
    }
    Ok(Value::Array(out).to_string())
}

/// `{texts: [str], aliases?: [[spelling, shown]]}` -> `[{key, spelled, clean, canonical}]`: each text's key, its
/// spelling fixed, cleaned, and spelled the usual way (the Strains page's pairs first).
pub fn strains_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Input {
        texts: Vec<String>,
        aliases: Option<Vec<(String, String)>>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let aliases = input.aliases.unwrap_or_default();
    let out: Vec<Value> = input
        .texts
        .iter()
        .map(|t| json!({"key": strain_key(t), "spelled": fix_spelling(t), "clean": clean_strain(t), "canonical": canonical_strain_with(t, &aliases)}))
        .collect();
    Ok(Value::Array(out).to_string())
}

/// `{items: [{description, coa_code?}]}` -> `[code]`.
pub fn code_of_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Item {
        description: Option<String>,
        coa_code: Option<String>,
    }
    #[derive(Deserialize)]
    struct Input {
        items: Vec<Item>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let out: Vec<String> =
        input.items.iter().map(|i| code_of(i.description.as_deref().unwrap_or(""), i.coa_code.as_deref().unwrap_or(""))).collect();
    Ok(serde_json::to_string(&out)?)
}

/// `{items: [{subtype, product_type?}]}` -> `[code]`.
pub fn type_code_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Item {
        subtype: Option<String>,
        product_type: Option<String>,
    }
    #[derive(Deserialize)]
    struct Input {
        items: Vec<Item>,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let out: Vec<String> =
        input.items.iter().map(|i| type_code(i.subtype.as_deref().unwrap_or(""), i.product_type.as_deref().unwrap_or(""))).collect();
    Ok(serde_json::to_string(&out)?)
}

/// A product name read for display, on JSON, for bindings: `{"name": "GT 25 mg TPE FD (2027-01-31)"}` in,
/// `{"strain_raw", "strain", "code", "expiry"}` out: the strain as written, the strain cleaned and spelled the
/// built-in way (null when the name has no usable one), the type code and the ISO best-by date in the name.
pub fn name_json(input_json: &str) -> Result<String, crate::api::Error> {
    #[derive(Deserialize)]
    struct Input {
        name: String,
    }
    let input: Input = serde_json::from_str(input_json)?;
    let p = parse_product(&input.name, &[], None)?;
    Ok(json!({"strain_raw": p.strain_raw, "strain": p.strain, "code": p.code, "expiry": p.expiry}).to_string())
}

const NAME_MAX: usize = 100;
const NO_STRAIN: &str = "there is no strain name yet (it comes from the COA)";
const NO_SUBTYPE: &str = "choose the product subtype in the certificate form first";
/// `payloads.SUBTYPE_ABBR`: the short spelling of a subtype in a product name (a homogenized lot carries none).
const SUBTYPE_ABBR: [(&str, &str); 4] = [("Freeze dried", "FD"), ("Dehydrated", "DH"), ("Chocolate", "choc"), ("Honey", "hn")];

/// `payloads.product_name`: `(name, None)` or `(None, why not)`. "Golden Teacher" + "Dehydrated"
/// -> "Golden Teacher DH"; a homogenized lot is just the strain.
pub fn product_name(strain: &str, subtype: &str, kind: &str, product_type: &str) -> (Option<String>, Option<&'static str>) {
    let st = clean_strain(&canonical_strain(strain));
    if st.is_empty() {
        return (None, Some(NO_STRAIN));
    }
    let sub = py_strip(subtype);
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
    #[derive(Deserialize)]
    struct Input {
        strain: Option<String>,
        subtype: Option<String>,
        kind: String,
        product_type: Option<String>,
    }
    let i: Input = serde_json::from_str(input_json)?;
    let (name, why) = product_name(i.strain.as_deref().unwrap_or(""), i.subtype.as_deref().unwrap_or(""), &i.kind, i.product_type.as_deref().unwrap_or(""));
    Ok(json!({"name": name, "why": why}).to_string())
}
