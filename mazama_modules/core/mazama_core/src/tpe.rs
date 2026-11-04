//! TPE, total equivalent psilocybin (mg/g): the one rule, used by the parser (a section's `tpe`, with no state
//! figure) and the label module (with the package's state figure). The server's `coa.tpe` is held to the same cases
//! (corpus/tpe/cases.json). 284.25 / 204.27 is the ratio of psilocybin's molar mass to psilocin's, so a mg of
//! psilocin counts as the psilocybin it is equivalent to.

/// TPE from what is known, unrounded; `None` when it can't be worked out (a missing value is never taken as zero).
/// ND and below-LOQ values come in as 0 (`Value::amount`): they are measured as none, not missing.
/// - a state psilocybin figure (the state record's `analyteWeight`) and a psilocin value: state + `psilocin_factor` x
///   psilocin (a printed total is ignored: the state's psilocybin wins over the lab report's);
/// - else the lab's printed Total Equivalent Psilocybin, when it is a number >= 0;
/// - else, with no state figure, the report's psilocybin + `psilocin_factor` x psilocin;
/// - else (a state figure but no psilocin, and no printed total) `None`.
///
/// `psilocin_factor` is the rules' (284.25 / 204.27).
pub fn tpe(
    psilocybin: Option<f64>,
    psilocin: Option<f64>,
    lab_total: Option<f64>,
    state_psilocybin: Option<f64>,
    psilocin_factor: f64,
) -> Option<f64> {
    if let (Some(state), Some(c)) = (state_psilocybin, psilocin) {
        return Some(state + psilocin_factor * c);
    }
    if let Some(lab) = lab_total.filter(|v| v.is_finite() && *v >= 0.0) {
        return Some(lab);
    }
    match (state_psilocybin, psilocybin, psilocin) {
        (None, Some(p), Some(c)) => Some(p + psilocin_factor * c),
        _ => None,
    }
}

/// `v` rounded to `places` decimals, halves away from zero (as the parser and the label module round).
pub fn round(v: f64, places: i32) -> f64 {
    let f = 10f64.powi(places);
    (v * f).round() / f
}
