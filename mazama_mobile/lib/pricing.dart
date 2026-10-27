// The Dart twin of mazama_sales/src/mazama_sales/pricing.py, held to the same cases
// (mazama_modules/selling/vectors/pricing.json, generated from pricing.py; test/pricing_vectors_test.dart) and the
// same ceilings (mazama_modules/selling/rules.yaml, vendored at assets/shared/selling/rules/). SM-13.
//
// Deliberately NOT using double/float arithmetic for anything a worker types: a price typed as text is parsed
// straight into integer cents by string manipulation, so there's no floating-point rounding risk for the typed figure
// itself - the project's "money in whole cents" rule. SM-D9: only a plain decimal is a price (digits with at most one
// '.' or ','). SM-D10: a $-per-mg rate is whole cents when typed, and a unit's price is that rate times its mg,
// worked in whole hundredths of a mg (perMgPriceCentsEach) rather than by multiplying doubles.

final RegExp _priceRe = RegExp(r'^(\d*)\.?(\d*)$');

/// The $10,000-per-unit ceiling, in cents: mazama_modules/selling/rules.yaml's max_unit_cents, as pricing.py reads it
/// (test/pricing_vectors_test.dart holds this to the vendored rules).
const int maxUnitCents = 10000 * 100;

/// The ceiling on a whole-cart total: max_unit_cents x max_total_units (1000) in rules.yaml - pricing.py's
/// MAX_TOTAL_CENTS.
const int maxTotalCents = maxUnitCents * 1000;

/// A price typed by a worker -> cents (rounded half up), or null when it isn't a valid price (blank, negative,
/// not a plain decimal - SM-D9: digits with at most one '.' or ',' - or above [maxCents]). Held to
/// mazama_modules/selling/vectors/pricing.json (test/pricing_vectors_test.dart). Mirrors pricing.py's to_cents exactly, including its ROUND_HALF_UP tie
/// break - verified against it directly, case by case, before this was written.
int? toCents(String text, {int maxCents = maxUnitCents}) {
  final t = text.trim().replaceAll(',', '.');
  final m = _priceRe.firstMatch(t);
  if (m == null) return null;
  final intPart = m.group(1) ?? '';
  final fracRaw = m.group(2) ?? '';
  if (intPart.isEmpty && fracRaw.isEmpty) return null; // "" or "." alone
  final frac = fracRaw.padRight(3, '0');
  final centsDigits = frac.substring(0, 2);
  final rest = frac.substring(2);
  var cents = int.parse(intPart.isEmpty ? '0' : intPart) * 100 + int.parse(centsDigits);
  // Comparing only the first remaining digit against '5' is sufficient for round-half-up: if it's < '5' the
  // true remainder is always < 0.5 of a cent (whatever digits follow); if it's >= '5' the remainder is always
  // >= 0.5. No need to consider the rest of the string.
  // The exact typed value must be within the cap before rounding, as pricing.py's to_dec checks it: "10000.004" is
  // over $10,000 even though it rounds to exactly $10,000.00 (SM-13).
  if (cents > maxCents || (cents == maxCents && rest.runes.any((r) => r != 0x30))) return null;
  if (rest.isNotEmpty && rest.codeUnitAt(0) >= '5'.codeUnitAt(0)) cents += 1;
  return cents;
}

/// The $1,000-per-mg ceiling on a typed per-mg rate - same bound pricing.py's MAX_PER_MG enforces for its
/// per_mg_prices pricing mode.
const int maxPerMgCents = 1000 * 100;

/// A $-per-mg (TPE) rate typed by a worker -> cents, parsed exactly the same way toCents parses a flat price
/// (so the rate itself carries no float-rounding risk) but bounded to pricing.py's own per-mg ceiling instead
/// of the per-unit one.
int? perMgRateToCents(String text) => toCents(text, maxCents: maxPerMgCents);

/// pricing.py's per_mg_prices, scoped to pricing one package type at a time (a CartLine's own priceCentsEach
/// already applies the result to every unit in the line, so unlike the server's version - which prices a whole
/// sale's worth of differently-weighted units in one call - this only ever needs the single-unit figure):
/// (rate per mg, in cents) x (mg TPE per unit) -> cents for one unit, rounded half up to the cent.
///
/// Worked in whole hundredths of a mg (a unit's mg has at most two decimals: selling.py unit_mg), never by multiplying
/// doubles: 10c/mg on 0.35 mg is 3.5c, which a double holds as 3.4999... and rounds to 3, where the server gives 4.
int perMgPriceCentsEach(int rateCentsPerMg, double mgPerUnit) {
  final hundredths = (mgPerUnit * 100).round();
  return (rateCentsPerMg * hundredths * 2 + 100) ~/ 200; // rate x mg, rounded half up to the cent
}

/// A cart-wide total price typed by a worker -> cents (rounded half up), or null when invalid - the same shape
/// [toCents] already has, just with a 1000x higher ceiling: pricing.py's own total_to_cents (the per-unit
/// $10,000 cap, times up to 1000 units in one cart).
int? totalToCents(String text) => toCents(text, maxCents: maxTotalCents);

/// cents, plus [percent] per cent on top, rounded half up to the cent - pricing.py's with_tax, used only for
/// cart_pricing.dart's two cart-wide modes (a total for the whole cart, or a single $/mg rate), never for
/// pricing one line by hand: the real web app's own cart.html says so directly ("Not used when pricing each
/// product") because a flat per-line price already has whatever tax a worker meant baked into it.
int withTax(int cents, num percent) => ((cents * (100 + percent)) / 100).round();

/// cents -> "$12.50", the same formatting pricing.py's money() produces. Never actually fed a negative amount
/// in this app (toCents already rejects negative input), but matches Python's own "$-12.50" sign placement
/// (the `$` before the minus) rather than "-$12.50" if it ever is - cross-checked against money() directly.
String money(int cents) {
  final sign = cents < 0 ? '-' : '';
  final abs = cents.abs();
  final dollars = abs ~/ 100;
  final rem = abs % 100;
  final dollarsText = _withThousands(dollars);
  return '\$$sign$dollarsText.${rem.toString().padLeft(2, '0')}';
}

String _withThousands(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
