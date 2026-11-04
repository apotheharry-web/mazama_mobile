// Cart-wide pricing: the two ways a worker can price an entire cart in one shot instead of typing a price for
// every line by hand ("each" mode: the line dialog, [linePrice]) - "total" (one target price for the whole cart) and
// "perMg" (one $/mg rate applied to every line's own mg TPE). The rule is the shared core's
// (mazama_core::selling::cart), the one the server's carts.build_cart calls through its Python
// binding: one core call per cart change, held to assets/shared/selling/vectors/cart.json and
// pricing_cases.json (test/cart_vectors_test.dart). Nothing of the rule is written here.
//
// Fails closed: when the core can't answer, or answers in a shape that isn't a price for every line, the
// cart can't be priced ([coreFailedPriceMessage]) and Sell stays off. A cart whose center's tax and split
// this phone doesn't know yet (the server never answered and nothing is kept) can't add tax or share a total between
// the two groups ([settingsUnknownMessage]).
//
// Deliberately free of Flutter and CartLine: cart_page.dart maps its own CartLine list into CartPricingLine and back.
import 'mazama_core.dart';
import 'pricing.dart';

/// 'A' = edibles and extracts, 'B' = everything else (whole, dried, homogenized) - the exact split
/// mazama_sales' own selling.py group_of uses: a cart total is shared between the two per the manufacturer
/// agreement (see cartAgreementEdibleWeight/cartAgreementDriedWeight below), so every line has to land in
/// exactly one of them. The shared core's group_of; null when the core can't answer (such a cart can't be
/// priced as a whole).
String? groupOf(String productType, {CoreFunctions? core}) {
  try {
    final g = (core ?? MazamaCore.instance).sellingGroupOf({'product_type': productType})['group'];
    return g == 'A' || g == 'B' ? g as String : null;
  } catch (_) {
    return null;
  }
}

/// The product-type words that put a product in group A: rules.yaml pricing_modes.group_a_words, as the core
/// holds them (test/cart_vectors_test.dart holds this to the vendored rules). Read only by tests: [groupOf] is the core's.
const groupAWords = ['edible', 'extract'];

/// The manufacturer-agreement split of a cart's revenue: $40 of every $130 to edibles/extracts, $90 to
/// everything else. Only the ratio (40:90, i.e. 4:9) actually matters - these are shared out as weights, not
/// literal dollars, so a cart totalling anything else still splits in the same proportion. Matches
/// mazama_sales' own config.py defaults (cart_agreement_edible/cart_agreement_dried) exactly.
const int cartAgreementEdibleWeight = 40;
const int cartAgreementDriedWeight = 90;

/// mazama_sales' own config.py cart_tax_percent default - the state's own sale record has no separate tax
/// field, so "add tax" means baking it into the unit prices this computes, same as the real web app does.
const int defaultCartTaxPercent = 15;

/// Whether a cart-wide typed price/rate already has tax baked in, or needs [defaultCartTaxPercent] added on
/// top before it's shared out. Only meaningful for [CartPricingMode.total] and [CartPricingMode.perMg] -
/// pricing a line by hand has no separate tax step at all.
enum CartTaxMode { included, addPercent }

enum CartPricingMode { each, total, perMg }

/// The mode a new cart starts in, on both sides: rules.yaml pricing_modes.default.
const defaultCartPricingMode = CartPricingMode.total;

/// One line's inputs to the whole-cart split - just enough to group it and weight it, nothing CartLine-specific
/// (the caller computes [group] itself via [groupOf] so this file never needs to know what a productType even
/// looks like beyond that one string).
class CartPricingLine {
  final String group;
  final double mgTpe; // the line's own per-unit mg TPE (PkprGroup.tpeMg) - 0 when unknown
  final int qty;

  CartPricingLine({required this.group, required this.mgTpe, required this.qty});
}

// The 50 mg of raw psilocybin per sale and the session lengths are the shared core's (lib/dose.dart's saleLimits,
// mazama_core::dose): never mg TPE, and nothing to do with price.

/// [d] (always exactly 30 minutes or a whole number of hours in practice - the only lengths the session table, the
/// core's, ever gives) -> the compact form shown next to the cart's own dose summary: "30 min", "1 hr",
/// "6 hrs".
String formatSessionDuration(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final hours = d.inMinutes ~/ 60;
  return hours == 1 ? '1 hr' : '$hours hrs';
}

/// The outcome of trying to price a whole cart this way: either one priceCentsEach per line (same order and
/// length as the lines that went in), or a reason it couldn't be done yet - the same shape mazama_sales' own
/// carts.py build_cart returns as `perr`, so a worker sees the same kind of message the web app would show for
/// the same mistake (an empty/invalid total, say).
class CartPricingResult {
  final List<int>? priceCentsEach;
  final String? error;

  /// Why it couldn't be priced, the same codes as the server's pricing.price_cart (and
  /// assets/shared/selling/vectors/cart.json): 'empty', 'total', 'rate', 'no_mg', 'unit_cap'; on the phone also 'core'
  /// (its shared core couldn't answer) and 'settings' (the center's tax and split unknown). Null when
  /// priced.
  final String? errorCode;

  /// With 'no_mg': the lines (indexes) that have no mg TPE, so can't be priced per mg. Empty otherwise.
  final List<int> unpricedLines;

  /// The real total this produces (the core's cart_total over priceCentsEach and the lines' qty). Can be a cent or two off the typed
  /// target when a line's own quantity doesn't evenly divide its share of a group's total - CartLine (unlike
  /// the server's own cart_line rows, one per physical unit) only ever stores a single price for every unit in
  /// a line, so a group's cents can't always be spread across a line's units and still land on one exact
  /// shared price. That's a visible, bounded rounding slack of at most a few cents on a cart that can run into
  /// the thousands, not a silent discrepancy - the cart screen always shows this real total, never the typed
  /// target pretending to be exact.
  final int? grandTotalCents;

  CartPricingResult.ok(this.priceCentsEach, this.grandTotalCents)
      : error = null,
        errorCode = null,
        unpricedLines = const [];
  CartPricingResult.err(this.errorCode, this.error, {this.unpricedLines = const []})
      : priceCentsEach = null,
        grandTotalCents = null;
}

/// Shares [totalCents] across [weights] in exact proportion, to the cent, so the parts always add up to exactly
/// [totalCents] (the core's share_total: largest remainder in exact integers, ties to the earlier weight; a weight of 0
/// or less anywhere: shared equally). Throws StateError when the core can't answer.
List<int> shareTotal(int totalCents, List<int> weights, {CoreFunctions? core}) {
  try {
    final parts = (core ?? MazamaCore.instance).sellingShareTotal({'total_cents': totalCents, 'weights': weights})['parts'];
    if (parts is! List || parts.length != weights.length || parts.any((p) => p is! int)) {
      throw StateError('mazama_core answered share_total with ${parts.runtimeType}');
    }
    return List<int>.from(parts);
  } on StateError {
    rethrow;
  } catch (e) {
    throw StateError('mazama_core could not share a total: $e');
  }
}

/// The reason a cart can't add tax or split a total between the groups.
const settingsUnknownMessage = "this phone doesn't know this center's tax and split yet";

const _errorText = {
  'empty': 'Add at least one line first.',
  'total': 'Enter the total price for the whole cart.',
  'rate': 'Enter a rate from \$0 to \$1,000 per mg.',
  'no_mg': "No mg TPE is known for every product, so the cart can't be priced per mg.",
  'unit_cap': 'A single unit would cost more than \$10,000.',
};

/// Computes every line's own priceCentsEach for [mode], given whatever a worker typed at the cart level, in one call
/// to the core ([core], default this app's). Lines keep their own input order: the returned list lines up
/// index-for-index with [lines]. [mode] must be [CartPricingMode.total] or [CartPricingMode.perMg] ("each" has
/// nothing to compute: every line carries its own price, [linePrice]). [settingsKnown] false: the center's tax and
/// split are only the built-in ones. Never throws: a core that can't answer is the refusal 'core'.
CartPricingResult priceWholeCart({
  required CartPricingMode mode,
  required List<CartPricingLine> lines,
  String totalText = '',
  String perMgText = '',
  CartTaxMode tax = CartTaxMode.included,
  int taxPercent = defaultCartTaxPercent,
  int agreementEdible = cartAgreementEdibleWeight,
  int agreementDried = cartAgreementDriedWeight,
  bool settingsKnown = true,
  CoreFunctions? core,
}) {
  assert(mode != CartPricingMode.each, 'priceWholeCart has nothing to do in "each" mode');
  if (lines.isEmpty) return CartPricingResult.err('empty', _errorText['empty']!);
  final addTax = tax == CartTaxMode.addPercent;
  final twoGroups = lines.any((l) => l.group == 'A') && lines.any((l) => l.group == 'B');
  if (!settingsKnown && (addTax || (mode == CartPricingMode.total && twoGroups))) {
    return CartPricingResult.err('settings', settingsUnknownMessage);
  }
  final Map<String, Object?> reply;
  try {
    reply = (core ?? MazamaCore.instance).sellingPriceCart({
      'mode': mode == CartPricingMode.perMg ? 'per_mg' : 'total',
      'lines': [
        for (final l in lines)
          {'group': l.group, 'mg': l.mgTpe == l.mgTpe.roundToDouble() ? l.mgTpe.toInt() : l.mgTpe, 'qty': l.qty},
      ],
      'total': totalText,
      'per_mg': perMgText,
      'tax': addTax,
      'tax_percent': taxPercent,
      'agreement': [agreementEdible, agreementDried],
    });
  } catch (_) {
    // StateError (no core loaded), MazamaCoreError (an input it can't take), or anything else: no price
    return CartPricingResult.err('core', coreFailedPriceMessage);
  }
  return _read(reply, lines, core) ?? CartPricingResult.err('core', coreFailedPriceMessage);
}

/// The core's answer as a result, or null when it isn't one of the right shape: a price of 0 or more, at
/// most the unit cap, for every line, or one of the core's own error codes with its line errors.
CartPricingResult? _read(Map<String, Object?> reply, List<CartPricingLine> lines, CoreFunctions? core) {
  final n = lines.length;
  final error = reply['error'];
  final each = reply['each'];
  final lineErrors = reply['line_errors'];
  if (lineErrors is! List || lineErrors.length != n || lineErrors.any((e) => e != null && e != 'no_mg')) return null;
  if (error == null) {
    if (each is! List || each.length != n || each.any((c) => c is! int || c < 0 || c > maxUnitCents)) return null;
    final prices = List<int>.from(each);
    final totals = cartTotals([
      for (var i = 0; i < n; i++) (qty: lines[i].qty, priceCentsEach: prices[i], group: lines[i].group),
    ], core: core);
    return totals == null ? null : CartPricingResult.ok(prices, totals.total);
  }
  if (each != null || error is! String || !_errorText.containsKey(error)) return null;
  final unpriced = [for (var i = 0; i < n; i++) if (lineErrors[i] == 'no_mg') i];
  if ((error == 'no_mg') != unpriced.isNotEmpty) return null;
  return CartPricingResult.err(error, _errorText[error]!, unpricedLines: unpriced);
}

/// One line priced on its own (the line dialog): a price each ([perMg] false), or a rate per mg times the line's
/// whole [mg] a unit, which must stay within the $10,000 unit cap - the core's line_price. [error] is null
/// with [cents], else 'price', 'rate', 'no_mg', 'unit_cap' or 'core' (the core couldn't answer).
({int? cents, String? error}) linePrice({required bool perMg, required String text, required int mg, CoreFunctions? core}) {
  const failed = (cents: null, error: 'core');
  try {
    final reply = (core ?? MazamaCore.instance).sellingLinePrice({'mode': perMg ? 'per_mg' : 'each', 'text': text, 'mg': mg});
    final cents = reply['cents'];
    final error = reply['error'];
    if (error == null) return cents is int && cents >= 0 && cents <= maxUnitCents ? (cents: cents, error: null) : failed;
    const codes = {'price', 'rate', 'no_mg', 'unit_cap'};
    return cents == null && codes.contains(error) ? (cents: null, error: error as String) : failed;
  } catch (_) {
    return failed;
  }
}

/// One cart line as its totals read it: its units, its price each in cents, and its group ('A', 'B', or null when the
/// core couldn't give one: it counts in neither group's total).
typedef CartTotalLine = ({int qty, int priceCentsEach, String? group});

/// A cart's totals, the core's (selling.cart_total): each line's, the cart's, each group's, its units, and [sales]
/// sales of it (a bulk sell), in whole cents.
class CartTotals {
  final List<int> lineTotals;
  final int total;
  final int groupA;
  final int groupB;
  final int units;
  final int sales;
  final int allTotal;
  final int allUnits;

  const CartTotals({
    required this.lineTotals,
    required this.total,
    required this.groupA,
    required this.groupB,
    required this.units,
    required this.sales,
    required this.allTotal,
    required this.allUnits,
  });
}

/// Why a cart shows no total and can't be sold: this phone's core couldn't add it up.
const coreFailedTotalMessage = "this phone can't add up this cart (its shared core failed), so it can't be sold here";

/// The totals of [lines] sold [sales] times (1: one sale), in one call to the core ([core], default this app's): exact,
/// in whole cents. Null when the core can't answer, refuses a figure (one past 64 bits) or answers in a shape that isn't
/// a total for every line: the cart then shows no total and can't be sold. Never throws.
CartTotals? cartTotals(List<CartTotalLine> lines, {int sales = 1, CoreFunctions? core}) {
  try {
    final r = (core ?? MazamaCore.instance).sellingCartTotal({
      'lines': [
        for (final l in lines)
          {'qty': l.qty, 'price_cents': l.priceCentsEach, 'group': l.group == 'A' || l.group == 'B' ? l.group : null},
      ],
      'sales': sales,
    });
    final each = r['line_totals'], groups = r['group_totals'];
    final total = r['total'], units = r['units'], allTotal = r['all_total'], allUnits = r['all_units'];
    if (each is! List || each.length != lines.length || each.any((t) => t is! int)) return null;
    if (groups is! Map || groups['A'] is! int || groups['B'] is! int) return null;
    if (total is! int || units is! int || allTotal is! int || allUnits is! int) return null;
    return CartTotals(
        lineTotals: List<int>.from(each),
        total: total,
        groupA: groups['A'] as int,
        groupB: groups['B'] as int,
        units: units,
        sales: sales,
        allTotal: allTotal,
        allUnits: allUnits);
  } catch (_) {
    return null; // StateError (no core loaded), MazamaCoreError (a figure it refuses), or anything else: no total
  }
}

/// [d] as a stopwatch-style running clock for the cart's own session timer (cart_page.dart's
/// _sessionTimerRow) - "12:34" under an hour, "1:02:34" at or past one hour. Unlike formatSessionDuration
/// above (which only ever renders a handful of fixed bracket values), this needs to tick smoothly every
/// second, so it always shows minutes and seconds, zero-padded, and never rounds away to a bracket label.
String formatElapsed(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
