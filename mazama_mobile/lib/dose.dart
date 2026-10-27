// The mg TPE in one unit, where the phone works it out itself (SM-04; owner decisions SM-D16, SM-D17): the state-only
// path (state_packages_client.dart) and a lab result's TPE from the server (coa_data_resolver.dart). The same rule as
// mazama_sales' dose.py, held to the vectors it generates (mazama_modules/dose/vectors/, test/dose_test.dart). The
// server's /p/packages already sends tpeMg worked out this way.

/// Only floating-point noise is forgiven when rounding an mg figure up (0.56 g x 12.5 = 7.000000000000001 is 7).
const double mgNoise = 1e-9;

/// [x] rounded up to a whole mg: ceil(x - 1e-9), so a figure shown or sold is never below what the unit holds.
int ceilMg(double x) => (x - mgNoise).ceil();

/// mg TPE per gram: the lot's [tpe] when known, else the state's psilocybin figure (0 or null = none), else null.
double? tpePerGram(double? statePsilocybin, double? tpe) {
  if (tpe != null) return tpe;
  if (statePsilocybin != null && statePsilocybin != 0) return statePsilocybin;
  return null;
}

/// The mg TPE in one unit, rounded up to a whole mg; null when no potency is known.
int? unitTpeMg(double weightPerUnit, double? statePsilocybin, double? tpe) {
  final perG = tpePerGram(statePsilocybin, tpe);
  return perG == null ? null : ceilMg(weightPerUnit * perG);
}
