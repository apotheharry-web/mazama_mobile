//! Python's semantics over JSON values, shared by the rules that read records the way Python does (records, selling):
//! truthiness, and for sellability an exact reading of a JSON text ([`Py`]: an integer keeps its digits at any size, as
//! Python's `json` reads it) with the one rendering of a value in a refusal's text ([`show`]).
use std::cmp::Ordering;
use std::collections::HashMap;

use serde_json::Value;

/// Python's truthiness of a JSON value: `null`, `false`, `0`, `""`, `[]` and `{}` are false.
pub(crate) fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// An integer of any size: its sign and its decimal digits (no leading zeros; zero is `"0"`, never negative).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Int {
    neg: bool,
    digits: String,
}

impl Int {
    fn new(neg: bool, digits: &str) -> Int {
        let d = digits.trim_start_matches('0');
        if d.is_empty() { Int { neg: false, digits: "0".into() } } else { Int { neg, digits: d.into() } }
    }

    /// The integer an integral, finite float is, exactly.
    fn of_integral(x: f64) -> Int {
        let s = format!("{:.0}", x.abs());
        Int::new(x < 0.0, &s)
    }

    pub(crate) fn one() -> Int {
        Int::new(false, "1")
    }

    /// Its decimal digits, with a minus sign when negative (Python's `str()` of the int).
    pub(crate) fn text(&self) -> String {
        if self.neg { format!("-{}", self.digits) } else { self.digits.clone() }
    }

    /// An integer within i128.
    pub(crate) fn of_i128(n: i128) -> Int {
        Int::new(n < 0, &n.unsigned_abs().to_string())
    }

    /// Whether it is negative (zero never is).
    pub(crate) fn is_negative(&self) -> bool {
        self.neg
    }

    pub(crate) fn as_i128(&self) -> Option<i128> {
        self.text().parse().ok()
    }

    pub(crate) fn as_i64(&self) -> Option<i64> {
        self.text().parse().ok()
    }

    /// Python's `float(n)`, correctly rounded (infinite past the largest double, where Python raises OverflowError).
    pub(crate) fn as_f64(&self) -> f64 {
        self.text().parse().unwrap_or(f64::NAN)
    }

    fn is_zero(&self) -> bool {
        self.digits == "0"
    }

    fn cmp_abs(&self, o: &Int) -> Ordering {
        self.digits.len().cmp(&o.digits.len()).then_with(|| self.digits.cmp(&o.digits))
    }
}

impl Ord for Int {
    fn cmp(&self, o: &Int) -> Ordering {
        match (self.neg, o.neg) {
            (false, true) => Ordering::Greater,
            (true, false) => Ordering::Less,
            (false, false) => self.cmp_abs(o),
            (true, true) => o.cmp_abs(self),
        }
    }
}

impl PartialOrd for Int {
    fn partial_cmp(&self, o: &Int) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}

/// A JSON value as Python's `json.loads` gives it: an integer is an int of any size, any other number a float (an
/// exponent past the largest double is infinite); a key given twice keeps its last value.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Py {
    Null,
    Bool(bool),
    Int(Int),
    Float(f64),
    Str(String),
    List(Vec<Py>),
    Obj(Vec<(String, Py)>),
}

impl Py {
    /// Read a JSON text: an error when it isn't JSON (serde_json's own checks, nesting depth included).
    pub(crate) fn parse(text: &str) -> Result<Py, crate::api::Error> {
        serde_json::from_str::<serde::de::IgnoredAny>(text)?;
        let mut r = Reader { s: text, i: 0, depth: 0 };
        r.value()
    }

    pub(crate) fn get(&self, key: &str) -> &Py {
        match self {
            Py::Obj(kv) => kv.iter().find(|(k, _)| k == key).map_or(&NULL, |(_, v)| v),
            _ => &NULL,
        }
    }

    pub(crate) fn truthy(&self) -> bool {
        match self {
            Py::Null => false,
            Py::Bool(b) => *b,
            Py::Int(n) => !n.is_zero(),
            Py::Float(x) => *x != 0.0,
            Py::Str(s) => !s.is_empty(),
            Py::List(a) => !a.is_empty(),
            Py::Obj(o) => !o.is_empty(),
        }
    }
}

static NULL: Py = Py::Null;

/// A reader of a JSON text serde_json has already checked, so it can assume the grammar holds. serde_json's check
/// (IgnoredAny) doesn't limit nesting, so the reader does, at serde_json's own limit: deeper input is an error, never a
/// stack overflow.
struct Reader<'a> {
    s: &'a str,
    i: usize,
    depth: usize,
}

/// The most lists and objects one inside another, as every other table function (serde_json's recursion limit).
const MAX_DEPTH: usize = 127;

impl Reader<'_> {
    fn ws(&mut self) {
        let b = self.s.as_bytes();
        while self.i < b.len() && matches!(b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn peek(&self) -> u8 {
        self.s.as_bytes()[self.i]
    }

    fn value(&mut self) -> Result<Py, crate::api::Error> {
        self.ws();
        if matches!(self.peek(), b'[' | b'{') {
            self.depth += 1;
            if self.depth > MAX_DEPTH {
                return Err(format!("recursion limit exceeded at byte {}", self.i).into());
            }
        }
        let v = self.container_or_scalar()?;
        if matches!(v, Py::List(_) | Py::Obj(_)) {
            self.depth -= 1;
        }
        Ok(v)
    }

    fn container_or_scalar(&mut self) -> Result<Py, crate::api::Error> {
        let v = match self.peek() {
            b'n' => {
                self.i += 4;
                Py::Null
            }
            b't' => {
                self.i += 4;
                Py::Bool(true)
            }
            b'f' => {
                self.i += 5;
                Py::Bool(false)
            }
            b'"' => Py::Str(self.string()?),
            b'[' => {
                self.i += 1;
                let mut out = Vec::new();
                self.ws();
                if self.peek() == b']' {
                    self.i += 1;
                } else {
                    loop {
                        out.push(self.value()?);
                        self.ws();
                        let c = self.peek();
                        self.i += 1;
                        if c == b']' {
                            break;
                        }
                    }
                }
                Py::List(out)
            }
            b'{' => {
                self.i += 1;
                let mut out: Vec<(String, Py)> = Vec::new();
                let mut at: HashMap<String, usize> = HashMap::new(); // a key's place, so a big object reads in linear time
                self.ws();
                if self.peek() == b'}' {
                    self.i += 1;
                } else {
                    loop {
                        self.ws();
                        let k = self.string()?;
                        self.ws();
                        self.i += 1; // ':'
                        let v = self.value()?;
                        match at.get(&k) {
                            Some(&i) => out[i].1 = v, // Python's dict: the last value, at the first key's place
                            None => {
                                at.insert(k.clone(), out.len());
                                out.push((k, v));
                            }
                        }
                        self.ws();
                        let c = self.peek();
                        self.i += 1;
                        if c == b'}' {
                            break;
                        }
                    }
                }
                Py::Obj(out)
            }
            _ => self.number(),
        };
        Ok(v)
    }

    fn string(&mut self) -> Result<String, crate::api::Error> {
        let b = self.s.as_bytes();
        let start = self.i;
        self.i += 1;
        while b[self.i] != b'"' {
            self.i += if b[self.i] == b'\\' { 2 } else { 1 };
        }
        self.i += 1;
        Ok(serde_json::from_str::<String>(&self.s[start..self.i])?)
    }

    fn number(&mut self) -> Py {
        let b = self.s.as_bytes();
        let start = self.i;
        while self.i < b.len() && matches!(b[self.i], b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9') {
            self.i += 1;
        }
        let t = &self.s[start..self.i];
        if t.bytes().any(|c| matches!(c, b'.' | b'e' | b'E')) {
            Py::Float(t.parse().unwrap_or(f64::NAN))
        } else {
            let (neg, digits) = t.strip_prefix('-').map_or((false, t), |d| (true, d));
            Py::Int(Int::new(neg, digits))
        }
    }
}

/// `units < n` exactly, as Python compares an int or a float with an int (a non-number counts as 0 units).
pub(crate) fn less_than(units: &Py, n: &Int) -> bool {
    match units {
        Py::Int(u) => u < n,
        Py::Float(x) if x.is_nan() => false,
        Py::Float(x) if x.is_infinite() => *x < 0.0,
        // for an integer n and a float x: x < n exactly when floor(x) < n
        Py::Float(x) => Int::of_integral(x.floor()) < *n,
        _ => Int::new(false, "0") < *n,
    }
}

/// The integer a value is, when it is one (an int, not a bool and not a float).
pub(crate) fn as_int(v: &Py) -> Option<&Int> {
    match v {
        Py::Int(n) => Some(n),
        _ => None,
    }
}

/// A number as a refusal shows it: an integer within 64 bits as its digits; any other number as Python's `repr()` of
/// the float it is; an integer past the largest double shows as `inf` (this only changes a refusal's wording).
fn num_text(v: &Py) -> String {
    match v {
        Py::Int(n) => n.as_i64().map_or_else(|| py_float_repr(n.as_f64()), |i| i.to_string()),
        Py::Float(x) => py_float_repr(*x),
        _ => unreachable!("num_text of a number"),
    }
}

/// How a refusal shows a value: null `None`, true/false `True`/`False`, text as itself, a
/// number by [`num_text`], a list or an object as compact JSON with keys sorted ([`json_text`]).
pub(crate) fn show(v: &Py) -> String {
    match v {
        Py::Null => "None".into(),
        Py::Bool(b) => (if *b { "True" } else { "False" }).into(),
        Py::Str(s) => s.clone(),
        Py::Int(_) | Py::Float(_) => num_text(v),
        Py::List(_) | Py::Obj(_) => json_text(v),
    }
}

/// Compact JSON, keys sorted, text JSON-quoted as Python's `json.dumps(ensure_ascii=False)` does (not `\u`-escaped
/// beyond the control characters), numbers by [`num_text`].
fn json_text(v: &Py) -> String {
    match v {
        Py::Null => "null".into(),
        Py::Bool(b) => (if *b { "true" } else { "false" }).into(),
        Py::Int(_) | Py::Float(_) => num_text(v),
        Py::Str(s) => quoted(s),
        Py::List(a) => format!("[{}]", a.iter().map(json_text).collect::<Vec<_>>().join(",")),
        Py::Obj(o) => {
            let mut kv: Vec<&(String, Py)> = o.iter().collect();
            kv.sort_by(|a, b| a.0.cmp(&b.0)); // code point order, as Python's sorted() of str
            format!("{{{}}}", kv.iter().map(|(k, v)| format!("{}:{}", quoted(k), json_text(v))).collect::<Vec<_>>().join(","))
        }
    }
}

pub(crate) fn quoted(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Python's `repr()` of a float: the shortest digits that read back as it, in fixed notation while the decimal point
/// falls within -4 < position <= 16 (an integral value with ".0"), else as `1e-07` / `1.5e+300`.
pub fn py_float_repr(x: f64) -> String {
    if x.is_nan() {
        return "nan".into();
    }
    if x.is_infinite() {
        return (if x > 0.0 { "inf" } else { "-inf" }).into();
    }
    let sign = if x.is_sign_negative() { "-" } else { "" };
    if x == 0.0 {
        return format!("{sign}0.0");
    }
    let e = format!("{:e}", x.abs()); // shortest round-trip digits: "1.2345e-7"
    let (mant, exp) = e.split_once('e').expect("{:e} has an exponent");
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let exp: i32 = exp.parse().expect("an integer exponent");
    let decpt = exp + 1;
    let n = digits.len() as i32;
    if decpt <= -4 || decpt > 16 {
        let rest = if n > 1 { format!(".{}", &digits[1..]) } else { String::new() };
        let e = decpt - 1;
        format!("{sign}{}{rest}e{}{:02}", &digits[..1], if e < 0 { '-' } else { '+' }, e.abs())
    } else if decpt <= 0 {
        format!("{sign}0.{}{digits}", "0".repeat((-decpt) as usize))
    } else if decpt >= n {
        format!("{sign}{digits}{}.0", "0".repeat((decpt - n) as usize))
    } else {
        format!("{sign}{}.{}", &digits[..decpt as usize], &digits[decpt as usize..])
    }
}
