//! C interface to coa_core for the phone app (dart:ffi): UTF-8 JSON in, UTF-8 JSON out. Every returned string is
//! owned by this library and must be released with `coa_free`. Nothing panics across the boundary: any failure,
//! including a null or non-UTF-8 argument, comes back as `{"error": "..."}`.
//!
//! ```c
//! char *coa_parse_json(const char *coa_text_json);   // -> CoaParseResult JSON
//! char *coa_label_spec_json(const char *input_json); // -> {"spec": ..., "warnings": [...]} or {"blocked": [...], ...}
//! char *coa_scan_find_ids_json(const char *input_json); // -> {"matches": [...]}: ids found in a label's text
//! char *coa_scan_closest_json(const char *input_json);  // -> {"guesses": [...]}: packages the rest of it fits
//! char *coa_version(void);                            // "coa_core 0.x / rules ..."
//! void  coa_free(char *s);
//! ```
//!
//! Design: specs/coa/08-phone-label-debug.md.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

type Outcome = Result<String, Box<dyn std::error::Error + Send + Sync>>;

fn to_c(s: String) -> *mut c_char {
    // JSON never contains a NUL byte, but never trust that across a boundary
    CString::new(s).unwrap_or_else(|_| CString::new(r#"{"error":"output contained a NUL byte"}"#).unwrap()).into_raw()
}

fn error(msg: &str) -> *mut c_char {
    to_c(serde_json::json!({ "error": msg }).to_string())
}

/// Read the argument, run `f`, turn every failure (including a panic) into an error object.
fn run(arg: *const c_char, f: fn(&str) -> Outcome) -> *mut c_char {
    if arg.is_null() {
        return error("null argument");
    }
    // SAFETY: the caller passes a NUL-terminated string that stays valid for the duration of the call.
    let input = match unsafe { CStr::from_ptr(arg) }.to_str() {
        Ok(s) => s,
        Err(_) => return error("the argument is not UTF-8"),
    };
    match catch_unwind(AssertUnwindSafe(|| f(input))) {
        Ok(Ok(json)) => to_c(json),
        Ok(Err(e)) => error(&e.to_string()),
        Err(_) => error("coa_core panicked"),
    }
}

/// CoaText JSON -> CoaParseResult JSON (built-in rules).
#[unsafe(no_mangle)]
pub extern "C" fn coa_parse_json(coa_text_json: *const c_char) -> *mut c_char {
    run(coa_text_json, |s| coa_core::parse_json(s, None))
}

/// LabelInput JSON -> LabelOutcome JSON.
#[unsafe(no_mangle)]
pub extern "C" fn coa_label_spec_json(input_json: *const c_char) -> *mut c_char {
    run(input_json, coa_core::label_spec_json)
}

/// {"coa_text", "lot", "state_psilocybin"} JSON -> {"result", "found"} JSON: a lot's section of record (AD-19).
#[unsafe(no_mangle)]
pub extern "C" fn coa_find_lot_json(request_json: *const c_char) -> *mut c_char {
    run(request_json, coa_core::find_lot_json)
}

/// {"name"} JSON -> {"strain_raw", "strain", "code", "expiry"} JSON: a product name read for display (SM-19).
#[unsafe(no_mangle)]
pub extern "C" fn coa_name_json(input_json: *const c_char) -> *mut c_char {
    run(input_json, coa_core::name_json)
}

/// {"texts", "guids", "typed"} JSON -> {"matches": [{"guid", "hex", "dist", "line"}]} JSON: the package ids found in
/// a label's text (coa_core::scan::find_ids).
#[unsafe(no_mangle)]
pub extern "C" fn coa_scan_find_ids_json(input_json: *const c_char) -> *mut c_char {
    run(input_json, coa_core::scan_find_ids_json)
}

/// {"texts", "packages": [{"guid", "records"}]} JSON -> {"guesses": [{"guid", "score", "why", "weight", "mg",
/// "record", "stock"}]} JSON: the packages the rest of a label fits when no id was found (coa_core::scan::closest).
#[unsafe(no_mangle)]
pub extern "C" fn coa_scan_closest_json(input_json: *const c_char) -> *mut c_char {
    run(input_json, coa_core::scan_closest_json)
}

/// "coa_core <version> / rules <version>".
#[unsafe(no_mangle)]
pub extern "C" fn coa_version() -> *mut c_char {
    to_c(coa_core::parser_version(&coa_core::Rules::default_rules()))
}

/// Release a string returned by this library. Null is ignored.
///
/// # Safety
/// `s` must be null or a pointer returned by one of this library's functions, not freed before.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn coa_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: per the contract above, `s` came from CString::into_raw in this library.
        drop(unsafe { CString::from_raw(s) });
    }
}
