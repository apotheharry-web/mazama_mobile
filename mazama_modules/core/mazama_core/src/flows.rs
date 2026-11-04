//! The sign-in pure rules, shared by the server and the phone: which URLs a flow may reach, which spec versions are
//! newer, which signed host lists and sign-in specs are good, and whether a signature is the owner's. Held to the
//! shared contracts in `mazama_modules/flows/contracts/` and the frozen vectors in `mazama_modules/signin/vectors/`.
//! This is security code: where a rule could be read two ways, it takes the stricter one.
//!
//! - [`host_allowed_json`]: one strict grammar for a URL's host (the flow interpreters, every request and redirect).
//! - [`compare_spec_versions_json`]: `YYYY-MM-DD.N` ordering.
//! - [`parse_host_list_json`]: the owner's signed list of extra sign-in hosts.
//! - [`verify_signature_json`], [`public_key_json`]: the owner's Ed25519 signature, checked with `verify_strict`.
//! - [`usable_login_spec_json`]: whether a sign-in spec the app has read may be used (SPEC.md "A usable sign-in spec").
//!   The core never reads YAML: each side reads the text with its own loader and hands the core the tree it will run, so
//!   what is checked is exactly what runs.
use std::collections::BTreeSet;
use std::sync::LazyLock;

use ed25519_dalek::{Signature, VerifyingKey};
use regex::Regex;
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::api::Error;

/// The two hosts a sign-in may use besides a signed list's: the state's site and its own B2C tenant. Exact names, never
/// a suffix match (no other `*.b2clogin.com`).
pub const BUILT_IN_HOSTS: [&str; 2] = ["psilocybin.oregon.gov", "oregonpsilocybinprodb2c.b2clogin.com"];
/// The state's API: the password is never sent there.
const STATE_API_HOST: &str = "psilocybin.oregon.gov";
/// Hosts the app reads its signed files and updates from: never sign-in hosts.
const GITHUB_HOSTS: [&str; 4] =
    ["raw.githubusercontent.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"];
const MAX_HOST_LIST_BYTES: usize = 65_536;
const MAX_LISTED_HOSTS: usize = 10;
const MAX_TIMEOUT_SECONDS: f64 = 120.0;

fn rx(p: &str) -> Regex {
    Regex::new(p).expect("flows regex")
}

// ---------------------------------------------------------------------------------------------------------------
// The host allowlist

static URL_RE: LazyLock<Regex> = LazyLock::new(|| rx(r"^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)"));
static HOST_RE: LazyLock<Regex> = LazyLock::new(|| rx(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$"));

/// True when `url` is https, its host is on `allowed` and nothing about the URL is ambiguous: no backslash anywhere and
/// no `@` in the authority; the port, if written, exactly 443; the host, minus one trailing dot, ASCII letters, digits
/// and hyphens in non-empty dot-separated labels (so no `%`, Unicode, `..` or IPv6 literal), compared in lower case.
/// An entry of `allowed` is a host, or `.suffix` for any host ending in it.
pub fn host_allowed(url: &str, allowed: &[String]) -> bool {
    if url.contains('\\') {
        return false;
    }
    let Some(m) = URL_RE.captures(url) else { return false };
    if !m[1].eq_ignore_ascii_case("https") {
        return false;
    }
    let authority = &m[2];
    if authority.contains('@') {
        return false;
    }
    let (host, port) = match authority.split_once(':') {
        Some((h, p)) => (h, Some(p)),
        None => (authority, None),
    };
    if port.is_some_and(|p| p != "443") {
        return false;
    }
    let host = host.strip_suffix('.').unwrap_or(host);
    if !HOST_RE.is_match(host) {
        return false;
    }
    let host = host.to_ascii_lowercase();
    allowed.iter().any(|raw| {
        let entry = raw.to_lowercase();
        if entry.starts_with('.') { host.ends_with(&entry) && host.len() > entry.len() } else { host == entry }
    })
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default()
}

/// `{url, allowed}` -> `{allowed}`.
pub fn host_allowed_json(input: &str) -> Result<String, Error> {
    let v: Value = serde_json::from_str(input)?;
    let url = v.get("url").and_then(Value::as_str).ok_or("url must be text")?;
    let allowed = v.get("allowed").map(strings).unwrap_or_default();
    Ok(json!({ "allowed": host_allowed(url, &allowed) }).to_string())
}

// ---------------------------------------------------------------------------------------------------------------
// Spec versions

static VERSION_RE: LazyLock<Regex> = LazyLock::new(|| rx(r"^([0-9]{4}-[0-9]{2}-[0-9]{2})\.([0-9]+)$"));

/// (date, the whole number without leading zeros), or None for a missing or malformed version.
fn version_key(v: &Value) -> Option<(String, String)> {
    let m = VERSION_RE.captures(v.as_str()?)?;
    Some((m[1].to_string(), m[2].trim_start_matches('0').to_string()))
}

/// True when `v` is a well-formed spec_version, YYYY-MM-DD.N.
pub fn is_spec_version(v: &Value) -> bool {
    version_key(v).is_some()
}

/// -1, 0 or 1: `a` older than, equal to, or newer than `b`; by date, then by N as a whole number (".2" < ".10"); a missing
/// or malformed one sorts below every valid one (and two of those are equal).
pub fn compare_spec_versions(a: &Value, b: &Value) -> i64 {
    match (version_key(a), version_key(b)) {
        (None, None) => 0,
        (None, Some(_)) => -1,
        (Some(_), None) => 1,
        (Some(x), Some(y)) => {
            let x = (x.0, x.1.len(), x.1);
            let y = (y.0, y.1.len(), y.1);
            match x.cmp(&y) {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Equal => 0,
                std::cmp::Ordering::Greater => 1,
            }
        }
    }
}

/// `{a, b}` (each text or anything else, which is malformed) -> `{order, a_valid, b_valid}`.
pub fn compare_spec_versions_json(input: &str) -> Result<String, Error> {
    let v: Value = serde_json::from_str(input)?;
    let (Some(a), Some(b)) = (v.get("a"), v.get("b")) else { return Err("a and b are required (null for none)".into()) };
    Ok(json!({ "order": compare_spec_versions(a, b), "a_valid": is_spec_version(a), "b_valid": is_spec_version(b) }).to_string())
}

// ---------------------------------------------------------------------------------------------------------------
// The signed host list

static LISTED_HOST_RE: LazyLock<Regex> = LazyLock::new(|| rx(r"^[a-z0-9-]+(\.[a-z0-9-]+)+$"));
static NUMBER_LABEL_RE: LazyLock<Regex> = LazyLock::new(|| rx(r"^([0-9]+|0x[0-9a-f]*)$"));

/// One exact host as a list may name it: lower-case ASCII letters, digits and hyphens in two or more dot-separated labels
/// of 1-63 characters, none starting or ending with a hyphen, at most 253 characters, and a last label that is not a
/// number (no IP address literal). No dot at either end, no `*`, port, scheme or path, and never a GitHub host.
pub fn valid_listed_host(host: &str) -> bool {
    if host.len() > 253 || !LISTED_HOST_RE.is_match(host) || GITHUB_HOSTS.contains(&host) {
        return false;
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.iter().any(|l| l.len() > 63 || l.starts_with('-') || l.ends_with('-')) {
        return false;
    }
    !NUMBER_LABEL_RE.is_match(labels[labels.len() - 1])
}

/// The top-level pairs of a JSON object in file order, repeats kept (a repeated key is refused, not "last wins").
struct Pairs(Vec<(String, Value)>);

impl<'de> Deserialize<'de> for Pairs {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> serde::de::Visitor<'de> for V {
            type Value = Pairs;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("an object")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(self, mut m: A) -> Result<Pairs, A::Error> {
                let mut out = Vec::new();
                while let Some(kv) = m.next_entry::<String, Value>()? {
                    out.push(kv);
                }
                Ok(Pairs(out))
            }
        }
        d.deserialize_map(V)
    }
}

/// (version, hosts in the file's order) of a host list's text, or None when it is not a valid one: at most 64 KiB of JSON,
/// an object with exactly "version" (a spec_version) and "hosts" (at most 10 different valid hosts), no key repeated.
pub fn parse_host_list(text: &str) -> Option<(String, Vec<String>)> {
    if text.len() > MAX_HOST_LIST_BYTES {
        return None;
    }
    let Pairs(pairs) = serde_json::from_str(text).ok()?;
    let keys: BTreeSet<&str> = pairs.iter().map(|(k, _)| k.as_str()).collect();
    if pairs.len() != 2 || keys != BTreeSet::from(["hosts", "version"]) {
        return None;
    }
    let get = |k: &str| pairs.iter().find(|(key, _)| key == k).map(|(_, v)| v);
    let version = get("version")?;
    if !is_spec_version(version) {
        return None;
    }
    let hosts = get("hosts")?.as_array()?;
    if hosts.len() > MAX_LISTED_HOSTS {
        return None;
    }
    let mut listed = Vec::new();
    for h in hosts {
        let h = h.as_str()?;
        if !valid_listed_host(h) {
            return None;
        }
        listed.push(h.to_string());
    }
    let distinct: BTreeSet<&String> = listed.iter().collect();
    if distinct.len() != listed.len() {
        return None;
    }
    Some((version.as_str()?.to_string(), listed))
}

/// `{text}` -> `{valid, version, hosts}`.
pub fn parse_host_list_json(input: &str) -> Result<String, Error> {
    let v: Value = serde_json::from_str(input)?;
    let text = v.get("text").and_then(Value::as_str).ok_or("text must be text")?;
    Ok(match parse_host_list(text) {
        Some((version, hosts)) => json!({ "valid": true, "version": version, "hosts": hosts }),
        None => json!({ "valid": false, "version": null, "hosts": [] }),
    }
    .to_string())
}

// ---------------------------------------------------------------------------------------------------------------
// Signatures

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64_encode(raw: &[u8]) -> String {
    let mut out = String::new();
    for chunk in raw.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |acc, (i, b)| acc | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(B64[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Standard, padded, canonical base64 (no URL-safe alphabet, no missing padding, no stray bits); anything else None.
fn b64_decode_strict(text: &str) -> Option<Vec<u8>> {
    if !text.is_ascii() || text.len() % 4 != 0 {
        return None;
    }
    let bytes = text.as_bytes();
    let pad = bytes.iter().rev().take_while(|b| **b == b'=').count();
    if pad > 2 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let mut n = 0u32;
        for (i, b) in chunk.iter().enumerate() {
            let v = if *b == b'=' { 0 } else { B64.iter().position(|c| c == b)? as u32 };
            n |= v << (18 - 6 * i);
        }
        out.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8, n as u8]);
    }
    out.truncate(out.len() - pad);
    (b64_encode(&out) == text).then_some(out)
}

/// The single line of a `.sig` / `signing.pub` text: ASCII, one trailing line feed allowed, no CR, tab or space, not empty.
fn one_line(text: &str) -> Option<&str> {
    let line = text.strip_suffix('\n').unwrap_or(text);
    (!line.is_empty() && line.is_ascii() && !line.bytes().any(|b| matches!(b, b'\r' | b'\n' | b'\t' | b' '))).then_some(line)
}

/// The 32 raw bytes a `signing.pub` text names, or None for `none` or anything malformed.
pub fn public_key_bytes(text: &str) -> Option<[u8; 32]> {
    let line = one_line(text)?;
    if line == "none" {
        return None;
    }
    b64_decode_strict(line)?.try_into().ok()
}

/// True only when `signature` (a `.sig` text) is a good Ed25519 signature of exactly `payload` under `public_key` (a
/// `signing.pub` text), checked strictly: S below the group order, no small-order key or R, a point that is on the curve.
pub fn verify_signature(payload: &[u8], signature: &str, public_key: &str) -> bool {
    let Some(key) = public_key_bytes(public_key) else { return false };
    let Some(sig) = one_line(signature).and_then(b64_decode_strict) else { return false };
    let Ok(sig): Result<[u8; 64], _> = sig.try_into() else { return false };
    let Ok(key) = VerifyingKey::from_bytes(&key) else { return false };
    key.verify_strict(payload, &Signature::from_bytes(&sig)).is_ok()
}

/// `{payload_b64, signature, public_key}` (all text) -> `{valid}`; a payload that is not canonical base64 is no payload.
pub fn verify_signature_json(input: &str) -> Result<String, Error> {
    let v: Value = serde_json::from_str(input)?;
    let text = |k: &str| v.get(k).and_then(Value::as_str).ok_or_else(|| format!("{k} must be text"));
    let (payload, signature, key) = (text("payload_b64")?, text("signature")?, text("public_key")?);
    let valid = b64_decode_strict(payload).is_some_and(|payload| verify_signature(&payload, signature, key));
    Ok(json!({ "valid": valid }).to_string())
}

/// `{text}` (a `signing.pub` text) -> `{key_b64}`: the key as one line of base64, or null for `none` or anything malformed.
pub fn public_key_json(input: &str) -> Result<String, Error> {
    let v: Value = serde_json::from_str(input)?;
    let text = v.get("text").and_then(Value::as_str).ok_or("text must be text")?;
    Ok(json!({ "key_b64": public_key_bytes(text).map(|k| b64_encode(&k)) }).to_string())
}

// ---------------------------------------------------------------------------------------------------------------
// The usable sign-in spec

/// What each sign-in flow is given at run time.
const FLOW_INPUTS: [(&str, &[&str]); 2] = [("login", &["email", "password"]), ("renew", &["refresh_token"])];
const SECRET_INPUTS: [&str; 3] = ["email", "password", "refresh_token"];
const STEP_TYPES: [&str; 5] = ["generate", "assert", "request", "await_input", "open_browser"];
const URL_SOURCES: [&str; 2] = ["url_fragment", "url_query"];
const PLAIN_MAPS: [&str; 3] = ["params", "headers", "form"];

static TARGET_RE: LazyLock<Regex> = LazyLock::new(|| rx(r"^[A-Za-z0-9_]+$"));
static SECONDS_RE: LazyLock<Regex> = LazyLock::new(|| rx(r"^[0-9]+(\.[0-9]+)?$"));
static WITH_PATH_RE: LazyLock<Regex> = LazyLock::new(|| rx(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*/"));

fn is_target(v: Option<&Value>) -> bool {
    v.and_then(Value::as_str).is_some_and(|s| TARGET_RE.is_match(s))
}


/// The `{{name}}` words of `s`, left to right, non-overlapping: (start, end, name) with name in `[A-Za-z0-9_]+`.
fn templates(s: &str) -> Vec<(usize, usize, &str)> {
    let b = s.as_bytes();
    let (mut out, mut i) = (Vec::new(), 0);
    while i + 1 < b.len() {
        if b[i] == b'{' && b[i + 1] == b'{' {
            let mut j = i + 2;
            while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'_') {
                j += 1;
            }
            if j > i + 2 && j + 1 < b.len() && b[j] == b'}' && b[j + 1] == b'}' {
                out.push((i, j + 2, &s[i + 2..j]));
                i = j + 2;
                continue;
            }
        }
        i += 1;
    }
    out
}

/// `s` with each `{{name}}` that `vars` names replaced by its value; any other is left as it is.
fn fill(s: &str, vars: &Map<String, Value>) -> String {
    let (mut out, mut at) = (String::new(), 0);
    for (start, end, name) in templates(s) {
        out.push_str(&s[at..start]);
        match vars.get(name).and_then(Value::as_str) {
            Some(value) => out.push_str(value),
            None => out.push_str(&s[start..end]),
        }
        at = end;
    }
    out.push_str(&s[at..]);
    out
}

/// True when some `{{ ... }}` of `s` holds a non-ASCII character. Python reads a template name with a Unicode `\w` and
/// Dart with an ASCII one, so a spec that spells one is read two ways: not usable.
fn has_unicode_template(s: &str) -> bool {
    let mut at = 0;
    while let Some(i) = s[at..].find("{{") {
        let open = at + i + 2;
        match s[open..].find("}}") {
            Some(j) => {
                if !s[open..open + j].is_ascii() {
                    return true;
                }
                at = open;
            }
            None => return false,
        }
    }
    false
}

fn any_unicode_template(v: &Value) -> bool {
    match v {
        Value::String(s) => has_unicode_template(s),
        Value::Array(a) => a.iter().any(any_unicode_template),
        Value::Object(m) => m.iter().any(|(k, x)| has_unicode_template(k) || any_unicode_template(x)),
        _ => false,
    }
}

/// `text` in any text under `node`, keys and values, at any depth.
fn has_text(node: &Value, text: &str) -> bool {
    match node {
        Value::String(s) => s.contains(text),
        Value::Object(m) => m.iter().any(|(k, v)| k.contains(text) || has_text(v, text)),
        Value::Array(a) => a.iter().any(|v| has_text(v, text)),
        _ => false,
    }
}

/// Every `{{name}}` in the text values under `node` (keys are not read).
fn names_in(node: &Value, out: &mut BTreeSet<String>) {
    match node {
        Value::String(s) => out.extend(templates(s).into_iter().map(|(_, _, n)| n.to_string())),
        Value::Object(m) => m.values().for_each(|v| names_in(v, out)),
        Value::Array(a) => a.iter().for_each(|v| names_in(v, out)),
        _ => {}
    }
}

/// The host of `url` as the password rule compares it: the text between `://` and the first `/`, `?` or `#`, minus a
/// `:port`, minus one trailing dot, in lower case ("" with no `://`).
fn url_host(url: &str) -> String {
    let Some((_, rest)) = url.split_once("://") else { return String::new() };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.split(':').next().unwrap_or("");
    host.strip_suffix('.').unwrap_or(host).to_lowercase()
}

/// Every dict under `node`, `node` included, with its `type`: a request or an open_browser (a step at any depth).
fn walk_dicts<'a>(node: &'a Value, f: &mut dyn FnMut(&'a Map<String, Value>) -> bool) -> bool {
    match node {
        Value::Object(m) => f(m) && m.values().all(|v| walk_dicts(v, f)),
        Value::Array(a) => a.iter().all(|v| walk_dicts(v, f)),
        _ => true,
    }
}

fn type_is(m: &Map<String, Value>, t: &str) -> bool {
    m.get("type").and_then(Value::as_str) == Some(t)
}

/// A step's text for a url field: "" when absent; a value that is not text is never a usable url (None).
fn url_field<'a>(m: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    match m.get(key) {
        None => Some(""),
        Some(Value::String(s)) => Some(s),
        Some(_) => None,
    }
}

// --- regexes: the syntax Python's `re` and Dart's `RegExp` read the same way, and nothing else -----------------------

const ESCAPABLE_LETTERS: &str = "dDwWsSbBnrtfvxu";

fn escape_shared(c: Option<char>) -> bool {
    match c {
        None => false,
        Some(c) if c.is_ascii_alphanumeric() => ESCAPABLE_LETTERS.contains(c),
        Some(_) => true,
    }
}

/// How many characters the escape starting at `at` (a backslash) takes, or 0 when it is refused: `\x` needs exactly two
/// hex digits and `\u` exactly four, `\B` is refused inside a class, any other letter or a digit is refused.
fn escape_length(p: &[char], at: usize, in_class: bool) -> usize {
    let c = p.get(at + 1).copied();
    if matches!(c, Some('x') | Some('u')) {
        let width = if c == Some('x') { 2 } else { 4 };
        let digits = p.get(at + 2..at + 2 + width);
        return match digits {
            Some(d) if d.iter().all(|x| x.is_ascii_hexdigit()) => 2 + width,
            _ => 0,
        };
    }
    if in_class && c == Some('B') {
        return 0;
    }
    if escape_shared(c) { 2 } else { 0 }
}

const GROUP_OPENERS: [&str; 5] = [":", "=", "!", "<=", "<!"];

/// Python's `shared_regex_syntax` (flowspec.py), as the phone's `sharedRegexSyntax` scans it: see SPEC.md "Regex syntax
/// both sides read".
fn shared_regex_syntax(p: &[char]) -> bool {
    let n = p.len();
    let (mut i, mut quantified, mut after_lookbehind) = (0, false, false);
    let mut groups: Vec<bool> = Vec::new();
    let starts = |at: usize, s: &str| s.chars().enumerate().all(|(k, c)| p.get(at + k) == Some(&c));
    while i < n {
        let c = p[i];
        if c == '\\' {
            let w = escape_length(p, i, false);
            if w == 0 {
                return false;
            }
            (i, quantified, after_lookbehind) = (i + w, false, false);
            continue;
        }
        if c == '[' {
            let mut j = if p.get(i + 1) == Some(&'^') { i + 2 } else { i + 1 };
            if p.get(j) == Some(&']') {
                return false;
            }
            while j < n && p[j] != ']' {
                if p[j] == '\\' {
                    let w = escape_length(p, j, true);
                    if w == 0 {
                        return false;
                    }
                    j += w;
                } else {
                    j += 1;
                }
            }
            (i, quantified, after_lookbehind) = (j + 1, false, false);
            continue;
        }
        if c == '(' {
            if starts(i, "(?") {
                let Some(opener) = GROUP_OPENERS.iter().find(|o| starts(i + 2, o)) else { return false };
                groups.push(*opener == "<=" || *opener == "<!");
                i += 2 + opener.len();
            } else {
                groups.push(false);
                i += 1;
            }
            (quantified, after_lookbehind) = (false, false);
            continue;
        }
        if c == ')' {
            after_lookbehind = groups.pop().unwrap_or(false);
            quantified = false;
            i += 1;
            continue;
        }
        if "*+?{".contains(c) && after_lookbehind {
            return false;
        }
        if "*+?{|".contains(c) && groups.iter().any(|g| *g) {
            return false;
        }
        if c == '+' && quantified {
            return false;
        }
        if c == '{' && p.get(i + 1) == Some(&',') {
            return false;
        }
        quantified = "*+?}".contains(c);
        after_lookbehind = false;
        i += 1;
    }
    true
}

/// The number of capturing groups of `pattern` when both Python and Dart compile it (None when not, or when the core is not
/// sure: a pattern is refused unless it keeps to the shared syntax AND to a grammar this function can follow completely).
/// Stricter than both languages on purpose: ASCII only, balanced groups, a quantifier only after something it can repeat
/// and never twice, `{n,m}` with n <= m and each at most 1000, classes closed with plain ranges, no nested `[`.
fn regex_groups(pattern: &str) -> Option<usize> {
    if !pattern.is_ascii() {
        return None;
    }
    let p: Vec<char> = pattern.chars().collect();
    if !shared_regex_syntax(&p) {
        return None;
    }
    let n = p.len();
    let (mut i, mut captures) = (0, 0usize);
    // whether each open group is a look-around (a quantifier after its `)` is refused), innermost last
    let mut looks: Vec<bool> = Vec::new();
    // whether the last thing parsed can be repeated, whether a quantifier was just written (then only one lazy `?` may
    // follow), and whether that lazy `?` was used
    let (mut repeatable, mut just_quantified, mut lazy_used) = (false, false, false);
    while i < n {
        let c = p[i];
        match c {
            '\\' => {
                let w = escape_length(&p, i, false);
                // \b and \B are assertions: nothing to repeat
                repeatable = !matches!(p[i + 1], 'b' | 'B');
                i += w;
            }
            '[' => {
                let (end, ok) = class_end(&p, i);
                if !ok {
                    return None;
                }
                repeatable = true;
                i = end;
            }
            '(' => {
                if p.get(i + 1) == Some(&'?') {
                    // (?: (?= (?! (?<= (?<!  -- the scanner has checked the opener
                    looks.push(p.get(i + 2) != Some(&':'));
                    i += if p.get(i + 2) == Some(&'<') { 4 } else { 3 };
                } else {
                    looks.push(false);
                    captures += 1;
                    i += 1;
                }
                repeatable = false;
            }
            ')' => {
                repeatable = !looks.pop()?;
                i += 1;
            }
            '|' | '^' | '$' => {
                repeatable = false;
                i += 1;
            }
            '*' | '+' | '?' => {
                if just_quantified {
                    if c != '?' || lazy_used {
                        return None;
                    }
                    lazy_used = true;
                } else {
                    if !repeatable {
                        return None;
                    }
                    just_quantified = true;
                }
                i += 1;
                continue;
            }
            '{' => {
                if let Some((len, lo, hi)) = brace_quantifier(&p, i) {
                    if just_quantified || !repeatable || lo > 1000 || hi.is_some_and(|h| h > 1000 || h < lo) {
                        return None;
                    }
                    just_quantified = true;
                    i += len;
                    continue;
                }
                // a `{` that is not a quantifier is a plain character in both languages
                repeatable = true;
                i += 1;
            }
            _ => {
                repeatable = true;
                i += 1;
            }
        }
        just_quantified = false;
        lazy_used = false;
    }
    looks.is_empty().then_some(captures)
}

/// `{n}`, `{n,}` or `{n,m}` at `at`: (its length, n, m), else None (then `{` is a plain character).
fn brace_quantifier(p: &[char], at: usize) -> Option<(usize, usize, Option<usize>)> {
    let mut j = at + 1;
    let digits = |j: &mut usize| -> Option<usize> {
        let start = *j;
        while *j < p.len() && p[*j].is_ascii_digit() {
            *j += 1;
        }
        if *j == start || *j - start > 6 {
            return None;
        }
        p[start..*j].iter().collect::<String>().parse().ok()
    };
    let lo = digits(&mut j)?;
    match p.get(j)? {
        '}' => Some((j + 1 - at, lo, Some(lo))),
        ',' => {
            j += 1;
            if p.get(j) == Some(&'}') {
                return Some((j + 1 - at, lo, None));
            }
            let hi = digits(&mut j)?;
            (p.get(j) == Some(&'}')).then_some((j + 1 - at, lo, Some(hi)))
        }
        _ => None,
    }
}

/// The index just past the class starting at `at` (`[`), and whether it is one this function can vouch for: closed, no
/// nested `[`, no `&&`, `||`, `~~`, `--` (Python warns of set operations), ranges between single characters in order.
fn class_end(p: &[char], at: usize) -> (usize, bool) {
    let n = p.len();
    let mut j = if p.get(at + 1) == Some(&'^') { at + 2 } else { at + 1 };
    // items: Some(code point) for a single character, None for a class escape (\d \w \s ...)
    let mut prev: Option<Option<u32>> = None;
    let mut after_range = false;
    while j < n && p[j] != ']' {
        let c = p[j];
        if c == '[' {
            return (n, false);
        }
        if matches!(c, '&' | '|' | '~') && p.get(j + 1) == Some(&c) {
            return (n, false);
        }
        // a single item at j
        let (item, len): (Option<u32>, usize) = if c == '\\' {
            let w = escape_length(p, j, true);
            let e = p[j + 1];
            let value = match e {
                'd' | 'D' | 'w' | 'W' | 's' | 'S' => None,
                'x' | 'u' => u32::from_str_radix(&p[j + 2..j + w].iter().collect::<String>(), 16).ok(),
                'n' => Some(10),
                'r' => Some(13),
                't' => Some(9),
                'f' => Some(12),
                'v' => Some(11),
                'b' => Some(8),
                other => Some(other as u32),
            };
            (value, w)
        } else {
            (Some(c as u32), 1)
        };
        if c == '-' && prev.is_some() && p.get(j + 1) != Some(&']') && !after_range {
            // a range prev - next
            let mut k = j + 1;
            if k >= n {
                return (n, false);
            }
            let (end_item, end_len): (Option<u32>, usize) = if p[k] == '\\' {
                let w = escape_length(p, k, true);
                if w == 0 {
                    return (n, false);
                }
                let e = p[k + 1];
                let value = match e {
                    'd' | 'D' | 'w' | 'W' | 's' | 'S' => None,
                    'x' | 'u' => u32::from_str_radix(&p[k + 2..k + w].iter().collect::<String>(), 16).ok(),
                    'n' => Some(10),
                    'r' => Some(13),
                    't' => Some(9),
                    'f' => Some(12),
                    'v' => Some(11),
                    'b' => Some(8),
                    other => Some(other as u32),
                };
                (value, w)
            } else if p[k] == '[' {
                return (n, false);
            } else {
                (Some(p[k] as u32), 1)
            };
            match (prev, end_item) {
                (Some(Some(lo)), Some(hi)) if lo <= hi => {}
                _ => return (n, false),
            }
            k += end_len;
            j = k;
            prev = None;
            after_range = true;
            continue;
        }
        if c == '-' && after_range && p.get(j + 1) != Some(&']') {
            return (n, false);
        }
        after_range = false;
        prev = Some(item);
        j += len;
    }
    if j >= n { (n, false) } else { (j + 1, true) }
}

/// An extract rule's `regex`: one text, or a non-empty list of text; every pattern compiles in the shared syntax and has a
/// group to take. None when not.
fn regex_value_ok(v: &Value) -> bool {
    match v {
        Value::String(s) => regex_groups(s).is_some_and(|g| g >= 1),
        Value::Array(a) => !a.is_empty() && a.iter().all(|x| x.as_str().is_some_and(|s| regex_groups(s).is_some_and(|g| g >= 1))),
        _ => false,
    }
}

// --- the checks ----------------------------------------------------------------------------------------------------

/// A `when` is exactly {var}, {var, equals} or {var, matches}, all text, and a `matches` that compiles in the shared syntax.
fn check_when(when: Option<&Value>) -> bool {
    let Some(m) = when.and_then(Value::as_object) else { return false };
    if m.get("var").and_then(Value::as_str).is_none() {
        return false;
    }
    let extra: Vec<&String> = m.keys().filter(|k| *k != "var").collect();
    match extra.as_slice() {
        [] => true,
        [k] if *k == "equals" => m["equals"].is_string(),
        [k] if *k == "matches" => m["matches"].as_str().is_some_and(|s| regex_groups(s).is_some()),
        _ => false,
    }
}

/// An `await_input` step has text `into` and `prompt`, and `secret` true/false or absent.
fn check_await_input(step: &Map<String, Value>) -> bool {
    step.get("into").is_some_and(Value::is_string)
        && step.get("prompt").is_some_and(Value::is_string)
        && step.get("secret").is_none_or(Value::is_boolean)
}

/// An `open_browser` step has text `url` (with no `?`) and `until`, `params` a mapping or absent, `then_require` a list or
/// absent, no `require` or `capture_on_fail`, and `extract` absent or a list of rules each with a text `var`, a `source`
/// of url_fragment or url_query, and a text `name`.
fn check_open_browser(step: &Map<String, Value>) -> bool {
    let rules_ok = match step.get("extract") {
        None | Some(Value::Null) => true,
        Some(Value::Array(rules)) => rules.iter().all(|r| {
            r.as_object().is_some_and(|r| {
                r.get("var").is_some_and(Value::is_string)
                    && r.get("source").and_then(Value::as_str).is_some_and(|s| URL_SOURCES.contains(&s))
                    && r.get("name").is_some_and(Value::is_string)
            })
        }),
        Some(_) => false,
    };
    step.get("url").and_then(Value::as_str).is_some_and(|u| !u.contains('?'))
        && step.get("until").is_some_and(Value::is_string)
        && step.get("params").is_none_or(|p| p.is_null() || p.is_object())
        && step.get("then_require").is_none_or(|t| t.is_null() || t.is_array())
        && !step.contains_key("require")
        && !step.contains_key("capture_on_fail")
        && rules_ok
}

fn steps_of<'a>(flows: &'a Map<String, Value>) -> impl Iterator<Item = (&'a str, &'a Map<String, Value>)> {
    flows.iter().flat_map(|(name, steps)| {
        steps.as_array().into_iter().flatten().filter_map(move |s| s.as_object().map(|m| (name.as_str(), m)))
    })
}

fn list_or_empty(v: Option<&Value>) -> &[Value] {
    v.and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

/// Every step of every flow has the right kinds of fields, and the spec declares the format its features need.
fn check_steps(flows: &Map<String, Value>, declared: i64) -> bool {
    let mut needs = 1;
    for (name, step) in steps_of(flows) {
        if step.contains_key("id") && !step["id"].is_string() {
            return false;
        }
        if !step.get("type").and_then(Value::as_str).is_some_and(|t| STEP_TYPES.contains(&t)) {
            return false;
        }
        let kind = step["type"].as_str().unwrap_or("");
        if step.get("method").is_some_and(|m| !m.is_string()) {
            return false;
        }
        if step.get("follow_redirects").is_some_and(|m| !m.is_boolean()) {
            return false;
        }
        if step.contains_key("when") {
            needs = needs.max(2);
            if !check_when(step.get("when")) {
                return false;
            }
        }
        if kind == "open_browser" {
            needs = 3;
            if name != "login" || !check_open_browser(step) {
                return false;
            }
        }
        for key in ["require", "then_require"] {
            for chk in list_or_empty(step.get(key)) {
                if chk.get("check").and_then(Value::as_str) == Some("vars_equal") {
                    needs = 3;
                    let names = chk.get("vars").and_then(Value::as_array);
                    let ok = names.is_some_and(|n| n.len() == 2 && n.iter().all(|x| is_target(Some(x))));
                    if !ok {
                        return false;
                    }
                }
            }
        }
        if kind == "await_input" {
            needs = needs.max(2);
            if name != "login" || !check_await_input(step) || !is_target(step.get("into")) {
                return false;
            }
        }
        if kind == "generate" && !step.get("into").and_then(Value::as_array).is_some_and(|a| a.iter().all(|x| is_target(Some(x)))) {
            return false;
        }
        for key in ["extract", "capture_on_fail"] {
            for rule in list_or_empty(step.get(key)) {
                let Some(rule) = rule.as_object() else { return false };
                if !is_target(rule.get("var")) {
                    return false;
                }
                if rule.get("source").and_then(Value::as_str).is_some_and(|s| URL_SOURCES.contains(&s)) && kind != "open_browser" {
                    return false;
                }
                if let Some(regex) = rule.get("regex") {
                    if regex.is_array() {
                        needs = needs.max(2);
                    }
                    if !regex_value_ok(regex) {
                        return false;
                    }
                }
            }
        }
    }
    needs <= declared
}

/// The urls every request and open_browser step names, filled in with the spec's vars: (type, url, until).
fn each_url(flows: &Value, vars: &Map<String, Value>, f: &mut dyn FnMut(&str, &str, &str) -> bool) -> bool {
    walk_dicts(flows, &mut |m| {
        let kind = m.get("type").and_then(Value::as_str);
        if kind == Some("request") || kind == Some("open_browser") {
            let Some(url) = url_field(m, "url") else { return false };
            // only an open_browser's `until` is a url (another step may carry a key of that name for its own use)
            let until = if kind == Some("open_browser") { url_field(m, "until") } else { Some("") };
            let Some(until) = until else { return false };
            return f(kind.unwrap_or(""), &fill(url, vars), &fill(until, vars));
        }
        true
    })
}

fn typed_names(flows: &Map<String, Value>) -> BTreeSet<String> {
    let mut names = BTreeSet::from(["password".to_string()]);
    for (_, step) in steps_of(flows) {
        if step.get("type").and_then(Value::as_str) == Some("await_input") {
            if let Some(into) = step.get("into").and_then(Value::as_str) {
                names.insert(into.to_string());
            }
        }
    }
    names
}

/// The `form` fields of `step` allowed to be exactly `template`: every such field, when `step` is a `request` whose `method`
/// is exactly `POST` and whose url host, filled in, is not the state's API; else none.
fn typed_form_fields<'a>(step: &'a Map<String, Value>, vars: &Map<String, Value>, template: &str) -> BTreeSet<&'a str> {
    let form = step.get("form").and_then(Value::as_object);
    if !type_is(step, "request") || step.get("method").and_then(Value::as_str) != Some("POST") || form.is_none() {
        return BTreeSet::new();
    }
    let url = fill(url_field(step, "url").unwrap_or(""), vars);
    if url_host(&url) == STATE_API_HOST {
        return BTreeSet::new();
    }
    form.map(|f| f.iter().filter(|(_, v)| v.as_str() == Some(template)).map(|(k, _)| k.as_str()).collect()).unwrap_or_default()
}

/// What the worker types goes only where it is meant to.
fn check_secrets(flows: &Map<String, Value>, vars: &Map<String, Value>) -> bool {
    if vars.keys().any(|k| SECRET_INPUTS.contains(&k.as_str())) {
        return false;
    }
    let typed = typed_names(flows);
    let vars_value = Value::Object(vars.clone());
    for name in &typed {
        let template = format!("{{{{{name}}}}}");
        if has_text(&vars_value, &template) || flows.keys().any(|f| f.contains(&template)) {
            return false;
        }
        for (_, step) in steps_of(flows) {
            let allowed = typed_form_fields(step, vars, &template);
            for (key, value) in step {
                if key.contains(&template) {
                    return false;
                }
                if key == "form" && value.is_object() {
                    let form = value.as_object().unwrap();
                    if form.iter().any(|(k, v)| !allowed.contains(k.as_str()) && has_text(v, &template)) {
                        return false;
                    }
                } else if has_text(value, &template) {
                    return false;
                }
            }
        }
    }
    let untestable: BTreeSet<&str> = typed.iter().map(String::as_str).chain(SECRET_INPUTS).collect();
    for (_, step) in steps_of(flows) {
        if let Some(when) = step.get("when").and_then(Value::as_object) {
            match when.get("var") {
                Some(Value::String(s)) if untestable.contains(s.as_str()) => return false,
                Some(Value::Array(_)) | Some(Value::Object(_)) => return false,
                _ => {}
            }
        }
        match step.get("json_var") {
            Some(Value::String(s)) if untestable.contains(s.as_str()) => return false,
            Some(Value::Array(_)) | Some(Value::Object(_)) => return false,
            _ => {}
        }
        for key in ["require", "then_require"] {
            for chk in list_or_empty(step.get(key)) {
                let names = chk.as_object().and_then(|c| c.get("vars")).and_then(Value::as_array);
                if names.is_some_and(|n| n.iter().any(|x| x.as_str().is_some_and(|s| typed.contains(s)))) {
                    return false;
                }
            }
        }
    }
    true
}

/// Every `params`, `headers` and `form` a step has is a mapping whose every value is text and none of whose keys has `{{`.
fn check_plain_maps(flows: &Map<String, Value>) -> bool {
    steps_of(flows).all(|(_, step)| {
        PLAIN_MAPS.iter().all(|field| match step.get(*field) {
            None => true,
            Some(Value::Object(m)) => m.iter().all(|(k, v)| v.is_string() && !k.contains("{{")),
            Some(_) => false,
        })
    })
}

/// (how, name) for every name `step` sets.
fn set_names(step: &Map<String, Value>) -> Vec<(&'static str, Option<&Value>)> {
    let mut out = Vec::new();
    for key in ["extract", "capture_on_fail"] {
        for rule in list_or_empty(step.get(key)) {
            if let Some(r) = rule.as_object() {
                out.push((key, r.get("var")));
            }
        }
    }
    if type_is(step, "generate") {
        for n in list_or_empty(step.get("into")) {
            out.push(("generate", Some(n)));
        }
    }
    if type_is(step, "await_input") {
        out.push(("await_input", step.get("into")));
    }
    out
}

/// No step sets a name that is a var of the spec or an input of its flow, except a `renew` request's `extract` of
/// `refresh_token`.
fn check_set_names(flows: &Map<String, Value>, vars: &Map<String, Value>) -> bool {
    for (flow, steps) in flows {
        let inputs: &[&str] = FLOW_INPUTS.iter().find(|(n, _)| n == flow).map(|(_, i)| *i).unwrap_or(&[]);
        for step in steps.as_array().into_iter().flatten().filter_map(Value::as_object) {
            for (how, name) in set_names(step) {
                match name {
                    Some(Value::String(s)) => {
                        if !(vars.contains_key(s) || inputs.contains(&s.as_str())) {
                            continue;
                        }
                        if flow == "renew" && how == "extract" && s == "refresh_token" && type_is(step, "request") {
                            continue;
                        }
                        return false;
                    }
                    Some(Value::Array(_)) | Some(Value::Object(_)) => return false,
                    _ => {}
                }
            }
        }
    }
    true
}

/// Unset, or a positive number of seconds (digits, optionally a fraction) no more than `most`.
fn check_seconds(vars: &Map<String, Value>, name: &str, most: Option<f64>) -> bool {
    let Some(raw) = vars.get(name) else { return true };
    let Some(raw) = raw.as_str() else { return false };
    if !SECONDS_RE.is_match(raw) {
        return false;
    }
    let seconds: f64 = raw.parse().unwrap_or(0.0);
    seconds > 0.0 && most.is_none_or(|m| seconds <= m)
}

/// The var names a list of extract rules sets; None when `rules` is neither absent nor a list.
fn captures(rules: Option<&Value>) -> Option<BTreeSet<String>> {
    match rules {
        None | Some(Value::Null) => Some(BTreeSet::new()),
        Some(Value::Array(a)) => Some(
            a.iter().filter_map(|r| r.as_object()).filter_map(|r| r.get("var").and_then(Value::as_str)).map(str::to_string).collect(),
        ),
        Some(_) => None,
    }
}

/// `flow` extracts access_token, and each `{{name}}` is set before it is used (see SPEC.md "A usable sign-in spec").
fn check_names(steps: &[Value], known: &BTreeSet<String>) -> bool {
    let mut known = known.clone();
    let mut has_token = false;
    for step in steps.iter().filter_map(Value::as_object) {
        let (Some(extract), Some(on_fail)) = (captures(step.get("extract")), captures(step.get("capture_on_fail"))) else {
            return false;
        };
        has_token = has_token || extract.contains("access_token");
        let mut built = BTreeSet::new();
        for k in ["url", "params", "headers", "form", "prompt", "until"] {
            if let Some(v) = step.get(k) {
                names_in(v, &mut built);
            }
        }
        if !built.is_subset(&known) {
            return false;
        }
        let mut with_fail = known.clone();
        with_fail.extend(on_fail.iter().cloned());
        let mut with_extract = with_fail.clone();
        with_extract.extend(extract.iter().cloned());
        for (key, allowed) in [("require", &with_fail), ("then_require", &with_extract)] {
            let mut used = BTreeSet::new();
            if let Some(v) = step.get(key) {
                names_in(v, &mut used);
            }
            if !used.is_subset(allowed) {
                return false;
            }
        }
        if type_is(step, "generate") {
            let Some(into) = step.get("into").and_then(Value::as_array) else { return false };
            known.extend(into.iter().filter_map(Value::as_str).map(str::to_string));
        }
        if type_is(step, "await_input") {
            match step.get("into").and_then(Value::as_str) {
                Some(n) => {
                    known.insert(n.to_string());
                }
                None => return false,
            }
        }
        known.extend(extract);
    }
    has_token
}

/// Whether the tree of a sign-in spec the app has read is usable by a reader of `reader_format` under `extra_hosts` (the
/// built-in two hosts are always allowed; an extra one counts only if a signed list could name it), in served mode `served`.
/// Returns the spec's `spec_version` when it is, else a short fixed reason (it names no part of the spec's text, at most a
/// var, a format number or a key the rule itself names), for the log.
pub fn usable_login_spec(
    declared: &Value,
    reader_format: i64,
    vars: &Value,
    flows: &Value,
    extra_hosts: &[String],
    served: Option<&str>,
) -> Result<String, String> {
    fn no<T>(why: &str) -> Result<T, String> {
        Err(why.to_string())
    }
    let Some(declared) = declared.as_i64().filter(|d| *d >= 1 && *d <= reader_format) else {
        return no("the format is not a whole number from 1 to the reader's");
    };
    let Some(vars) = vars.as_object().filter(|v| v.values().all(Value::is_string)) else { return no("vars is not a mapping of text") };
    let flows_value = flows;
    let Some(flows) = flows.as_object() else { return no("flows is not a mapping") };
    if flows.values().any(|steps| !steps.as_array().is_some_and(|a| a.iter().all(Value::is_object))) {
        return no("a flow is not a list of steps");
    }
    if any_unicode_template(flows_value) || vars.iter().any(|(k, v)| has_unicode_template(k) || any_unicode_template(v)) {
        return no("a {{ }} word holds a character the two languages read differently");
    }
    for (name, _) in FLOW_INPUTS {
        if !flows.get(name).and_then(Value::as_array).is_some_and(|a| !a.is_empty()) {
            return Err(format!("{name} is not a non-empty list of steps"));
        }
    }
    if !walk_dicts(flows_value, &mut |m| !type_is(m, "request") || m.get("url").is_some_and(Value::is_string)) {
        return no("a request step has no url");
    }
    if !check_steps(flows, declared) {
        return no("a step has a field of the wrong kind, or the spec uses a feature of a later format than it declares");
    }
    let Some(version) = vars.get("spec_version").filter(|v| is_spec_version(v)) else { return no("bad spec_version") };
    let mut allowed: Vec<String> = BUILT_IN_HOSTS.iter().map(|h| h.to_string()).collect();
    allowed.extend(extra_hosts.iter().filter(|h| valid_listed_host(h)).cloned());
    // every url's host is allowed; none has a query (an open_browser's `until` has a path); none is the state's API
    let urls_ok = each_url(flows_value, vars, &mut |kind, url, until| {
        if !host_allowed(url, &allowed) || url.contains('?') || url_host(url) == STATE_API_HOST {
            return false;
        }
        kind != "open_browser" || (host_allowed(until, &allowed) && WITH_PATH_RE.is_match(until))
    });
    if !urls_ok {
        return no("a url is not on an allowed https host, has a query, or reaches the state's API");
    }
    if !check_plain_maps(flows) {
        return no("a params, headers or form is not a mapping of text, or a key of one has a template");
    }
    if !check_secrets(flows, vars) {
        return no("something the worker types is somewhere it may not be, or a var is named like a sign-in input");
    }
    if !check_set_names(flows, vars) {
        return no("a step sets a name that is a var or an input of its flow");
    }
    for (name, most) in [("refresh_margin_seconds", None), ("timeout_seconds", Some(MAX_TIMEOUT_SECONDS))] {
        if !check_seconds(vars, name, most) {
            return Err(format!("{name} is not a positive number of seconds (at most 120 for the timeout)"));
        }
    }
    for (name, inputs) in FLOW_INPUTS {
        let mut known: BTreeSet<String> = vars.keys().cloned().collect();
        known.extend(inputs.iter().map(|s| s.to_string()));
        if !check_names(flows.get(name).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]), &known) {
            return Err(format!("{name} uses a name before anything sets it, or has no extract rule for access_token"));
        }
    }
    let opens_browser = |steps: &Value| steps.as_array().into_iter().flatten().filter_map(Value::as_object).any(|s| type_is(s, "open_browser"));
    match served {
        None => {}
        Some("login") if flows.values().any(opens_browser) => return no("a spec served as the password sign-in has no open_browser"),
        Some("login") => {}
        Some("browser") if !opens_browser(&flows["login"]) => return no("a spec served as the browser sign-in has an open_browser in login"),
        Some("browser") => {}
        Some(_) => return no("unknown served mode"),
    }
    version.as_str().map(str::to_string).ok_or_else(|| "bad spec_version".to_string())
}

/// `{format, reader_format, vars, flows, allowed_hosts, served}` -> `{usable, spec_version, why}`.
pub fn usable_login_spec_json(input: &str) -> Result<String, Error> {
    let v: Value = serde_json::from_str(input)?;
    let null = Value::Null;
    let reader_format = v.get("reader_format").and_then(Value::as_i64).ok_or("reader_format must be a whole number")?;
    let served = match v.get("served") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s.as_str()),
        Some(_) => return Ok(json!({ "usable": false, "spec_version": null, "why": "unknown served mode" }).to_string()),
    };
    let found = usable_login_spec(
        v.get("format").unwrap_or(&null),
        reader_format,
        v.get("vars").unwrap_or(&null),
        v.get("flows").unwrap_or(&null),
        &v.get("allowed_hosts").map(strings).unwrap_or_default(),
        served,
    );
    Ok(match found {
        Ok(version) => json!({ "usable": true, "spec_version": version, "why": null }),
        Err(why) => json!({ "usable": false, "spec_version": null, "why": why }),
    }
    .to_string())
}
