// Cart-wide pricing: the two ways a worker can price an entire cart in one shot instead of typing a price for
// every line by hand ("each" mode, unchanged, still handled entirely inside cart_page.dart's own
// _showLineDialog) - "total" (one target price for the whole cart) and "perMg" (one $/mg rate applied to
// every line's own mg TPE). This mirrors mazama_sales' own server-side cart math (carts.py's build_cart,
// pricing.py, selling.py's group_of) closely on purpose, so a center that's used to how the real web app
// splits a cart total sees the same ratios and the same tax behavior here.
//
// Deliberately pure, plain Dart with no Flutter or CartLine dependency - `dart test` can exercise every branch
// in this file with no widget harness at all, and cart_page.dart maps its own CartLine list into
// CartPricingLine and back without this file ever needing to know what a CartLine even is.
import 'pricing.dart';

/// 'A' = edibles and extracts, 'B' = everything else (whole, dried, homogenized) - the exact split
/// mazama_sales' own selling.py group_of uses: a cart total is shared between the two per the manufacturer
/// agreement (see cartAgreementEdibleWeight/cartAgreementDriedWeight below), so every line has to land in
/// exactly one of them.
String groupOf(String productType) {
  final t = productType.toLowerCase();
  return groupAWords.any(t.contains) ? 'A' : 'B';
}

/// The product-type words that put a product in group A: rules.yaml pricing_modes.group_a_words (SM-14;
/// test/cart_vectors_test.dart holds this to the vendored rules).
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

/// The mode a new cart starts in, on both sides: rules.yaml pricing_modes.default (SM-D28).
const defaultCartPricingMode = CartPricingMode.total;

/// One line's inputs to the whole-cart split - just enough to group it and weight it, nothing CartLine-specific
/// (the caller computes [group] itself via [groupOf] so this file never needs to know what a productType even
/// looks like beyond that one string).
class CartPricingLine {
  final String group;
  final double mgTpe; // the line's own per-unit mg TPE (PkprGroup.tpeMg) - 0 when unknown
  final int qty;

  /// The line's own per-unit mg of RAW psilocybin (PkprGroup.weightPerUnit x PkprGroup.analyteWeight) - a
  /// wholly different number from mgTpe above, on purpose. mgTpe is a TPE-equivalent dose (1.3916 x psilocin +
  /// psilocybin, mazama_sales' own coa.py tpe()) that can run well above the raw psilocybin content alone; the
  /// Oregon 50mg-per-sale rule below is about raw psilocybin only, so it reads this field, never mgTpe. 0 when
  /// unknown, same convention as mgTpe - only analyteCapError reads this; priceWholeCart never multiplies a
  /// price against it (that would repeat the exact mistake packages_client.dart's own analyteWeight comment
  /// warns against).
  final double analyteMgPerUnit;

  CartPricingLine({required this.group, required this.mgTpe, this.analyteMgPerUnit = 0, required this.qty});
}

/// The Oregon rule that no single sale may contain more than this many mg of RAW psilocybin - distinct from
/// every dollar figure above, and distinct from mg TPE (a sale can run well over this in TPE and still be
/// fine; see CartPricingLine.analyteMgPerUnit's own comment for why those are two different numbers). "Sale"
/// here means the whole cart, the same scope the $10,000-per-unit price cap above is checked at: every line
/// goes up together in one state-system submission (cart_page.dart's _sell sends them all in a single
/// request, one shared saleNumber for all of them - see selling.dart's own file comment).
const double maxAnalyteMgPerSale = 50; // rules.yaml dose.max_psilocybin_mg_per_sale (SM-D11: the server enforces it too)

/// Total raw mg psilocybin [lines] would sell if sold together, summed across every line (each line's own
/// analyteMgPerUnit x its qty) - the figure maxAnalyteMgPerSale caps.
double totalAnalyteMg(List<CartPricingLine> lines) =>
    lines.fold<double>(0, (sum, l) => sum + l.analyteMgPerUnit * l.qty);

/// Null if [lines] would sell at or under maxAnalyteMgPerSale mg of raw psilocybin in total, else a message in
/// the same shape CartPricingResult.error already uses. Checked in every pricing mode, "each" included - unlike
/// priceWholeCart above, this has nothing to do with price - so cart_page.dart calls this on its own from
/// _recomputeCartPricing rather than from inside priceWholeCart.
String? analyteCapError(List<CartPricingLine> lines) {
  final total = totalAnalyteMg(lines);
  if (total <= maxAnalyteMgPerSale) return null;
  return 'This sale would total ${total.toStringAsFixed(1)} mg psilocybin - more than the '
      '${maxAnalyteMgPerSale.toStringAsFixed(0)} mg limit per sale (mg TPE is not subject to this cap).';
}

/// The service center's own administration-session minimum-duration table (a graduated scale the worker gave
/// this app, not something either file this app mirrors - mazama_sales/pricing.py has nothing like it): the
/// minimum length of a session for a client consuming [mgAnalyte] mg of RAW psilocybin analyte in one sitting.
/// Reads the same raw-psilocybin figure analyteCapError/maxAnalyteMgPerSale already read (never mg TPE - see
/// CartPricingLine.analyteMgPerUnit's own comment for why). Null above maxAnalyteMgPerSale: the table doesn't
/// go any higher, and a sale that high is refused outright by analyteCapError already, so there's nothing left
/// to show.
Duration? minSessionDuration(double mgAnalyte) {
  if (mgAnalyte < 0) return null;
  for (final row in sessionTable) {
    if (mgAnalyte < row.limitMg || (row.inclusive && mgAnalyte == row.limitMg)) return row.duration;
  }
  return null;
}

/// One row of [sessionTable]: the session length for a total below [limitMg] (or at most it, when [inclusive]).
class SessionRow {
  final double limitMg;
  final bool inclusive;
  final Duration duration;
  const SessionRow(this.limitMg, this.duration, {this.inclusive = false});
}

/// The minimum session length table, rules.yaml "dose.session_minutes" (SM-15, SM-D11: the server shows the same,
/// selling.py min_session_minutes); test/dose_limits_test.dart holds it to the vendored rules.
const sessionTable = [
  SessionRow(2.5, Duration(minutes: 30)),
  SessionRow(5, Duration(hours: 1)),
  SessionRow(10, Duration(hours: 2)),
  SessionRow(15, Duration(hours: 3)),
  SessionRow(25, Duration(hours: 4)),
  SessionRow(35, Duration(hours: 5)),
  SessionRow(maxAnalyteMgPerSale, Duration(hours: 6), inclusive: true),
];

/// [d] (always exactly 30 minutes or a whole number of hours in practice - the only values minSessionDuration
/// ever actually returns) -> the compact form shown next to the cart's own dose summary: "30 min", "1 hr",
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
  /// assets/shared/selling/vectors/cart.json): 'empty', 'total', 'rate', 'no_mg', 'unit_cap'. Null when priced.
  final String? errorCode;

  /// With 'no_mg': the lines (indexes) that have no mg TPE, so can't be priced per mg. Empty otherwise.
  final List<int> unpricedLines;

  /// The real total this produces (sum of priceCentsEach[i] * qty[i]). Can be a cent or two off the typed
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

/// Shares [totalCents] across [weights] in exact proportion, to the cent, so the parts always add up to
/// exactly [totalCents] - the integer "largest remainder" method (every share rounded down, the leftover cents
/// go to the biggest remainders, ties broken by earliest index) done with exact integer arithmetic throughout
/// (no double anywhere), so there's no floating-point drift to even worry about. A non-positive weight
/// anywhere falls back to splitting everyone equally - mirrors mazama_sales' own pricing.py share_total
/// exactly, including that fallback (its own comment: "no usable mg on some unit: split equally").
List<int> shareTotal(int totalCents, List<int> weights) {
  final n = weights.length;
  if (n == 0) return [];
  var w = weights;
  if (w.any((x) => x <= 0)) w = List.filled(n, 1);
  final sum = w.fold<int>(0, (a, b) => a + b);
  // A common numerator (totalCents * w[i]) over the same denominator (sum) keeps every comparison below in
  // that same integer space - Dart's native int is 64-bit on every platform this app ships to (it has no web
  // target), and totalCents/weights are already bounded well under 2^63 by pricing.dart's own ceilings, so
  // plain int multiplication here can't overflow.
  final numerators = [for (final x in w) totalCents * x];
  final parts = [for (final num in numerators) num ~/ sum];
  final remainders = [for (var i = 0; i < n; i++) numerators[i] - parts[i] * sum];
  final left = totalCents - parts.fold<int>(0, (a, b) => a + b);
  final order = List.generate(n, (i) => i)
    ..sort((a, b) {
      final c = remainders[b].compareTo(remainders[a]); // biggest remainder first
      return c != 0 ? c : a.compareTo(b); // tie -> earliest index first, deterministic
    });
  for (var k = 0; k < left; k++) {
    parts[order[k]] += 1;
  }
  return parts;
}

/// Rounds a line's own share of cents (possibly not evenly divisible by its own quantity) down to a single
/// per-unit price, half up - the same cents, qty >= 1 always (a line can't exist with qty 0).
int _roundHalfUpDiv(int cents, int qty) => (2 * cents + qty) ~/ (2 * qty);

/// Computes every line's own priceCentsEach for [mode], given whatever a worker typed at the cart level.
/// Lines keep their own input order throughout - the returned list lines up index-for-index with [lines].
/// [mode] must be [CartPricingMode.total] or [CartPricingMode.perMg] - "each" has nothing for this function to
/// compute, since every line already carries its own hand-typed price in that mode.
CartPricingResult priceWholeCart({
  required CartPricingMode mode,
  required List<CartPricingLine> lines,
  String totalText = '',
  String perMgText = '',
  CartTaxMode tax = CartTaxMode.included,
  int taxPercent = defaultCartTaxPercent,
  int agreementEdible = cartAgreementEdibleWeight,
  int agreementDried = cartAgreementDriedWeight,
}) {
  assert(mode != CartPricingMode.each, 'priceWholeCart has nothing to do in "each" mode');
  // The rule is the server's pricing.price_cart (SM-14), held to the same cases: test/cart_vectors_test.dart.
  if (lines.isEmpty) return CartPricingResult.err('empty', 'Add at least one line first.');

  final List<int> prices;
  if (mode == CartPricingMode.perMg) {
    final rateCents = perMgRateToCents(perMgText);
    if (rateCents == null) return CartPricingResult.err('rate', 'Enter a rate from \$0 to \$1,000 per mg.');
    // SM-D26: tax, if any, goes on the rate, rounded to whole cents per mg, before it prices any line - one
    // effective rate for the whole cart, as pricing.py's price_cart does.
    final effectiveRateCents = tax == CartTaxMode.addPercent ? withTax(rateCents, taxPercent) : rateCents;
    final unpriced = [for (var i = 0; i < lines.length; i++) if (lines[i].mgTpe <= 0) i];
    if (unpriced.isNotEmpty) {
      return CartPricingResult.err('no_mg', "No mg TPE is known for every product, so the cart can't be priced per mg.",
          unpricedLines: unpriced);
    }
    prices = [for (final l in lines) perMgPriceCentsEach(effectiveRateCents, l.mgTpe)];
  } else {
    // mode == CartPricingMode.total
    final target = totalToCents(totalText);
    if (target == null) return CartPricingResult.err('total', 'Enter the total price for the whole cart.');
    final grandTarget = tax == CartTaxMode.addPercent ? withTax(target, taxPercent) : target;

    final groups = (lines.map((l) => l.group).toSet().toList())..sort();
    final Map<String, int> groupTotals;
    if (groups.length == 2) {
      final shares = shareTotal(grandTarget, [agreementEdible, agreementDried]); // the server's split (SM-16), else 40:90
      groupTotals = {'A': shares[0], 'B': shares[1]};
    } else {
      groupTotals = {groups.first: grandTarget};
    }

    prices = List<int>.filled(lines.length, 0);
    for (final g in groupTotals.keys) {
      final idx = [for (var i = 0; i < lines.length; i++) if (lines[i].group == g) i];
      // Each line's weight is its own total mg (its per-unit mg TPE x its quantity); when any line in the group has
      // no mg, the group's part goes by units instead. SM-D27: every unit of a line then costs the line's share
      // divided by its quantity, rounded half up, so the cart may be a few cents off the typed total.
      final known = idx.every((i) => lines[i].mgTpe > 0);
      final weights = [for (final i in idx) known ? (lines[i].mgTpe * lines[i].qty).round() : lines[i].qty];
      final lineTotals = shareTotal(groupTotals[g]!, weights);
      for (var k = 0; k < idx.length; k++) {
        prices[idx[k]] = _roundHalfUpDiv(lineTotals[k], lines[idx[k]].qty);
      }
    }
  }
  if (prices.any((p) => p > maxUnitCents)) {
    return CartPricingResult.err('unit_cap', 'A single unit would cost more than \$10,000.');
  }
  return CartPricingResult.ok(prices, _grandTotal(prices, lines));
}

int _grandTotal(List<int> prices, List<CartPricingLine> lines) =>
    [for (var i = 0; i < lines.length; i++) prices[i] * lines[i].qty].fold<int>(0, (a, b) => a + b);

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
