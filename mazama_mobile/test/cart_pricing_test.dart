// cart_pricing.dart is plain Dart with no Flutter dependency, so every branch here is exercised directly -
// no widget harness needed, unlike the cart_page_*_test.dart files' own exercise of the same logic through the UI.
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_pricing.dart';

void main() {
  group('groupOf', () {
    test('edibles and extracts are group A, everything else is group B', () {
      expect(groupOf('Edible Psilocybin Product'), 'A');
      expect(groupOf('Psilocybin Extract'), 'A');
      expect(groupOf('extract'), 'A'); // case-insensitive
      expect(groupOf('Whole Fungi'), 'B');
      expect(groupOf('Dried Psilocybin Product'), 'B');
      expect(groupOf('Homogenized Psilocybin Product'), 'B');
      expect(groupOf(''), 'B'); // an unknown/blank productType falls on the "everything else" side, not A
    });
  });

  group('shareTotal', () {
    test('splits evenly with no remainder', () {
      expect(shareTotal(100, [1, 1]), [50, 50]);
    });

    test('an odd total gives the extra cent to the biggest remainder, earliest index on a tie', () {
      // Equal weights -> equal remainders -> the tie-break (earliest index) is all that decides this.
      expect(shareTotal(101, [1, 1]), [51, 50]);
    });

    test('splits proportionally to unequal weights, to the exact cent', () {
      final parts = shareTotal(13000, [40, 90]);
      expect(parts, [4000, 9000]); // the exact 40:90 manufacturer-agreement ratio of $130
      expect(parts[0] + parts[1], 13000);
    });

    test('a non-positive weight anywhere falls back to splitting everyone equally', () {
      expect(shareTotal(100, [1, 0]), [50, 50]); // not weighted 100:0 - the 0 poisons the whole split
      expect(shareTotal(100, [1, -5]), [50, 50]);
    });

    test('an empty list of weights shares nothing', () {
      expect(shareTotal(100, []), <int>[]);
    });
  });

  group('priceWholeCart: total mode', () {
    test('a cart with both groups splits exactly 40:90 between them', () {
      final result = priceWholeCart(
        mode: CartPricingMode.total,
        lines: [
          CartPricingLine(group: 'A', mgTpe: 5, qty: 1), // edibles/extracts
          CartPricingLine(group: 'B', mgTpe: 90, qty: 1), // whole/dried/homogenized
        ],
        totalText: '130.00',
      );
      expect(result.error, isNull);
      expect(result.priceCentsEach, [4000, 9000]); // $40.00 and $90.00 of the $130 total
      expect(result.grandTotalCents, 13000);
    });

    test('a single-group cart gets the whole total, shared within the group by mg TPE content', () {
      final result = priceWholeCart(
        mode: CartPricingMode.total,
        lines: [
          CartPricingLine(group: 'B', mgTpe: 5, qty: 1),
          CartPricingLine(group: 'B', mgTpe: 10, qty: 1),
        ],
        totalText: '100.00',
      );
      expect(result.error, isNull);
      // 5mg vs 10mg -> roughly a 1:2 split of $100 (10000c), to the exact cent via largest remainder.
      expect(result.priceCentsEach, [3333, 6667]);
      expect(result.grandTotalCents, 10000);
    });

    test('a line with more units gets proportionally more of its group\'s share', () {
      final result = priceWholeCart(
        mode: CartPricingMode.total,
        lines: [
          CartPricingLine(group: 'B', mgTpe: 5, qty: 1), // 5mg total
          CartPricingLine(group: 'B', mgTpe: 5, qty: 2), // 10mg total - twice the first line's mg content
        ],
        totalText: '90.00',
      );
      expect(result.error, isNull);
      // Line totals split 1:2 (3000:6000 of 9000c), then each line's own total divided by its own qty.
      expect(result.priceCentsEach, [3000, 3000]); // $30 each unit either way, but the second line sells 2 of them
      expect(result.grandTotalCents, 9000); // divides evenly here, so no rounding slack at all
    });

    test('adding the 15% tax multiplies the shared total before the group split, not after', () {
      final result = priceWholeCart(
        mode: CartPricingMode.total,
        lines: [
          CartPricingLine(group: 'A', mgTpe: 5, qty: 1),
          CartPricingLine(group: 'B', mgTpe: 90, qty: 1),
        ],
        totalText: '100.00',
        tax: CartTaxMode.addPercent,
      );
      expect(result.error, isNull);
      expect(result.grandTotalCents, 11500); // $100 x 1.15
      expect(result.priceCentsEach![0] + result.priceCentsEach![1], 11500);
      // Still exactly the 40:90 ratio of the TAXED total, not the typed one.
      expect(result.priceCentsEach, [3538, 7962]);
    });

    test('an unknown mg TPE on some line in a group shares that group by units instead (SM-14, as the server)', () {
      final result = priceWholeCart(
        mode: CartPricingMode.total,
        lines: [
          CartPricingLine(group: 'B', mgTpe: 0, qty: 3), // mg unknown
          CartPricingLine(group: 'B', mgTpe: 5, qty: 1),
        ],
        totalText: '40',
      );
      expect(result.error, isNull);
      expect(result.priceCentsEach, [1000, 1000]); // 4 units share $40: never one equal share per line
    });

    test('a blank total is an error, not a crash', () {
      final result = priceWholeCart(mode: CartPricingMode.total, lines: [CartPricingLine(group: 'A', mgTpe: 5, qty: 1)], totalText: '');
      expect(result.error, 'Enter the total price for the whole cart.');
      expect(result.priceCentsEach, isNull);
    });

    test('an empty cart cannot be priced this way at all', () {
      final result = priceWholeCart(mode: CartPricingMode.total, lines: [], totalText: '100.00');
      expect(result.error, 'Add at least one line first.');
    });

    test('a per-unit price over the \$10,000 cap is refused', () {
      final result = priceWholeCart(
        mode: CartPricingMode.total,
        lines: [CartPricingLine(group: 'A', mgTpe: 5, qty: 1)],
        totalText: '20000.00',
      );
      expect(result.error, 'A single unit would cost more than \$10,000.');
    });
  });

  group('priceWholeCart: perMg mode', () {
    test('every line is priced at the same rate times its own mg TPE', () {
      final result = priceWholeCart(
        mode: CartPricingMode.perMg,
        lines: [
          CartPricingLine(group: 'A', mgTpe: 5, qty: 2),
          CartPricingLine(group: 'B', mgTpe: 90, qty: 1),
        ],
        perMgText: '0.10',
      );
      expect(result.error, isNull);
      expect(result.priceCentsEach, [50, 900]); // 10c/mg x 5mg, and 10c/mg x 90mg
      expect(result.grandTotalCents, 50 * 2 + 900);
    });

    test('tax is folded into the rate itself before it is applied to any line', () {
      final result = priceWholeCart(
        mode: CartPricingMode.perMg,
        lines: [CartPricingLine(group: 'A', mgTpe: 5, qty: 1)],
        perMgText: '0.10',
        tax: CartTaxMode.addPercent,
      );
      expect(result.error, isNull);
      // 10c/mg x 1.15 -> 11.5c, rounded to 12c/mg (same rounding toCents/withTax use elsewhere) x 5mg = 60c.
      expect(result.priceCentsEach, [60]);
    });

    test('a line with no mg TPE is refused, never priced at nothing (SM-14, as the server)', () {
      final result = priceWholeCart(
        mode: CartPricingMode.perMg,
        lines: [CartPricingLine(group: 'A', mgTpe: 5, qty: 1), CartPricingLine(group: 'B', mgTpe: 0, qty: 2)],
        perMgText: '2',
      );
      expect(result.errorCode, 'no_mg');
      expect(result.unpricedLines, [1]);
      expect(result.priceCentsEach, isNull);
    });

    test('an out-of-range rate is refused the same way the per-line dialog refuses one', () {
      final result = priceWholeCart(mode: CartPricingMode.perMg, lines: [CartPricingLine(group: 'A', mgTpe: 5, qty: 1)], perMgText: '1001');
      expect(result.error, 'Enter a rate from \$0 to \$1,000 per mg.');
    });
  });

  // The 50 mg cap and the session table are the shared core's now (specs/core row 5): test/dose_limits_test.dart.

  group('formatSessionDuration', () {
    test('minutes under an hour', () {
      expect(formatSessionDuration(const Duration(minutes: 30)), '30 min');
    });

    test('exactly one hour is singular', () {
      expect(formatSessionDuration(const Duration(hours: 1)), '1 hr');
    });

    test('more than one hour is plural', () {
      expect(formatSessionDuration(const Duration(hours: 6)), '6 hrs');
    });
  });

  group('formatElapsed', () {
    test('seconds and minutes, zero-padded, with no hours component under an hour', () {
      expect(formatElapsed(const Duration(seconds: 0)), '00:00');
      expect(formatElapsed(const Duration(seconds: 5)), '00:05');
      expect(formatElapsed(const Duration(minutes: 1, seconds: 2)), '01:02');
      expect(formatElapsed(const Duration(minutes: 12, seconds: 34)), '12:34');
    });

    test('includes an hours component, unpadded, at or past one hour', () {
      expect(formatElapsed(const Duration(hours: 1)), '1:00:00');
      expect(formatElapsed(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
      expect(formatElapsed(const Duration(hours: 11, minutes: 59, seconds: 59)), '11:59:59');
    });
  });

  // SM-16: the agreement split comes from the server's settings (/p/center-status), not only the built-in 40:90.
  test('priceWholeCart shares a total by the agreement weights it is given', () {
    final r = priceWholeCart(
      mode: CartPricingMode.total,
      lines: [
        CartPricingLine(group: 'A', mgTpe: 5, qty: 1),
        CartPricingLine(group: 'B', mgTpe: 5, qty: 1),
      ],
      totalText: '100',
      agreementEdible: 1,
      agreementDried: 3,
    );
    expect(r.priceCentsEach, [2500, 7500]);
  });
}
