//! C interface to mazama_core for the phone app (dart:ffi): UTF-8 JSON in, UTF-8 JSON out. Every returned string is
//! owned by this library and must be released with `mz_free`. Nothing panics across the boundary: any failure,
//! including a null or non-UTF-8 argument, comes back as `{"error": "..."}`.
//!
//! ```c
//! char *mz_<area>_<name>_json(const char *input_json); // one per function in mazama_modules/core/functions.yaml
//! char *mz_version(void);                               // "mazama_core 0.x / rules ..."
//! void  mz_free(char *s);
//! ```
//!
//! The table's functions are generated into `exports.rs` (mazama_modules/core/gen.py). Design: specs/core CR-R2.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

mod exports;
pub use exports::*;

type Outcome = Result<String, mazama_core::api::Error>;

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
        Err(_) => error("mazama_core panicked"),
    }
}

/// "mazama_core <version> / rules <version>".
#[unsafe(no_mangle)]
pub extern "C" fn mz_version() -> *mut c_char {
    to_c(mazama_core::parser_version(&mazama_core::coa::Rules::default_rules()))
}

/// Release a string returned by this library. Null is ignored.
///
/// # Safety
/// `s` must be null or a pointer returned by one of this library's functions, not freed before.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mz_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: per the contract above, `s` came from CString::into_raw in this library.
        drop(unsafe { CString::from_raw(s) });
    }
}
