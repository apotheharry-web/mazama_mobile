// Prices in whole cents: the shared core's rule (mazama_core::selling::pricing), the same one the
// server's pricing.py calls through its Python binding. Held to mazama_modules/selling/vectors/pricing.json and
// pricing_cases.json (the cases the owner decided; test/pricing_vectors_test.dart) and the ceilings
// in mazama_modules/selling/rules.yaml (vendored at assets/shared/selling/rules/). Nothing of the rule is written here:
// a typed figure is read by the core digit by digit (no 64-bit overflow), with only white space trimmed from its ends
// (a figure carrying any other control character is refused), and rounded half up to the cent.
//
// Fails closed: when the core can't answer (not loaded, an error, a reply of the wrong shape), a typed figure
// reads as no price ([toCents] null) and the functions that compute a price throw [StateError]; the cart turns either
// into "this phone can't price this cart" (cart_pricing.dart). [money] only formats an amount for the screen: it stays
// here, held to the same vectors.
import 'mazama_core.dart';

/// The $10,000-per-unit ceiling, in cents: mazama_modules/selling/rules.yaml's max_unit_cents, as the core holds it
/// (test/pricing_vectors_test.dart holds this to the vendored rules).
const int maxUnitCents = 10000 * 100;

/// The ceiling on a whole-cart total: max_unit_cents x max_total_units (1000) in rules.yaml.
const int maxTotalCents = maxUnitCents * 1000;

/// The $1,000-per-mg ceiling on a typed per-mg rate.
const int maxPerMgCents = 1000 * 100;

/// The core's name for each cap [toCents] reads to.
const _caps = {maxUnitCents: 'unit', maxTotalCents: 'total', maxPerMgCents: 'per_mg'};

/// The reason shown when this phone's core can't price.
const coreFailedPriceMessage = "this phone can't price this cart (its shared core failed), so it can't be sold here";

CoreFunctions _core(CoreFunctions? core) => core ?? MazamaCore.instance;

/// The core's whole-number answer [key] of [reply]: an integer of 0 or more, else a StateError.
int coreCents(Map<String, Object?> reply, String key) {
  final v = reply[key];
  if (v is! int || v < 0) throw StateError('mazama_core answered $key with ${v.runtimeType}');
  return v;
}

/// A price typed by a worker -> cents (rounded half up), or null when it isn't a valid price (blank, negative, not a
/// plain decimal - or above [maxCents], which is one of [maxUnitCents], [maxTotalCents], [maxPerMgCents]), or
/// when the core can't answer (no price).
int? toCents(String text, {int maxCents = maxUnitCents, CoreFunctions? core}) {
  final cap = _caps[maxCents];
  assert(cap != null, 'toCents reads to the unit, total or per-mg cap only; $maxCents is none of them');
  if (cap == null) return null;
  try {
    final reply = _core(core).sellingParsePrice({'text': text, 'max': cap});
    if (reply['cents'] == null) return null;
    final c = coreCents(reply, 'cents');
    return c <= maxCents ? c : null;
  } catch (_) {
    return null; // StateError (no core loaded), MazamaCoreError, a reply of the wrong shape, or anything else
  }
}

/// A $-per-mg (TPE) rate typed by a worker -> cents, or null (the core's reader, bounded to $1,000 per mg).
int? perMgRateToCents(String text, {CoreFunctions? core}) => toCents(text, maxCents: maxPerMgCents, core: core);

/// A cart-wide total typed by a worker -> cents, or null (bounded to $10,000,000).
int? totalToCents(String text, {CoreFunctions? core}) => toCents(text, maxCents: maxTotalCents, core: core);

/// (rate per mg, in cents) x (mg per unit, at most two decimals) -> cents for one unit, rounded half up (the core's
/// per_mg_price). Throws StateError when the core can't answer.
int perMgPriceCentsEach(int rateCentsPerMg, double mgPerUnit, {CoreFunctions? core}) {
  try {
    final hundredths = (mgPerUnit * 100).round(); // the mg as the two-decimal figure it is written as (NaN: refused)
    final mg = '${hundredths ~/ 100}.${(hundredths % 100).toString().padLeft(2, '0')}';
    return coreCents(_core(core).sellingPerMgPrice({'rate_cents': rateCentsPerMg, 'mg': mg}), 'cents');
  } on StateError {
    rethrow;
  } catch (e) {
    throw StateError('mazama_core could not price per mg: $e');
  }
}

/// cents, plus [percent] (a whole percent, 0..100) on top, rounded half up to the cent (the core's with_tax). Throws
/// StateError when the core can't answer.
int withTax(int cents, num percent, {CoreFunctions? core}) {
  try {
    if (percent != percent.roundToDouble()) throw ArgumentError.value(percent, 'percent', 'not a whole percent');
    return coreCents(_core(core).sellingWithTax({'cents': cents, 'percent': percent.toInt()}), 'cents');
  } on StateError {
    rethrow;
  } catch (e) {
    throw StateError('mazama_core could not add tax: $e');
  }
}

/// cents -> "$12.50", as the server's pages show it (the core's money, held to pricing.json by
/// test/pricing_vectors_test.dart): only a formatting for the screen, never a price, so it stays here and never fails.
/// A negative amount shows as "$-12.50", the server's way.
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
