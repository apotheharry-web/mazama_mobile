//! The core's one JSON API (specs/core CR-R2): every function the apps call is `fn(&str) -> Result<String, Error>`,
//! listed once in `mazama_modules/core/functions.yaml`. `gen.py` writes the table below ([`FUNCTIONS`], in
//! `api_table.rs`) and the Python, C and Dart exports from that list, so they can't disagree.

/// What every table function returns on failure: its text is what the bindings hand back (`{"error": ...}` from C,
/// `ValueError` in Python).
pub type Error = Box<dyn std::error::Error + Send + Sync>;

/// One table function: JSON in, JSON out.
pub type Function = fn(&str) -> Result<String, Error>;

pub use crate::api_table::FUNCTIONS;

/// The table function `area.name` (`coa.parse`, `scan.closest`, ...), if there is one.
pub fn function(area: &str, name: &str) -> Option<Function> {
    FUNCTIONS.iter().find(|(a, n, _)| *a == area && *n == name).map(|(_, _, f)| *f)
}

/// Run the table function `area.name` on `input`; an unknown name is an error, like any other.
pub fn call(area: &str, name: &str, input: &str) -> Result<String, Error> {
    match function(area, name) {
        Some(f) => f(input),
        None => Err(format!("mazama_core has no function {area}.{name}").into()),
    }
}
