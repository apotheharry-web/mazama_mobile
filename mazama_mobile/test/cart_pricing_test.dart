// cart_pricing.dart is plain Dart with no Flutter dependency, so every branch here is exercised directly -
// no widget harness needed, unlike cart_page_test.dart's own exercise of the same logic through the UI.
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

  group('the 50mg-psilocybin-per-sale cap', () {
    test('totalAnalyteMg sums each line\'s own per-unit mg times its qty', () {
      final lines = [
        CartPricingLine(group: 'A', mgTpe: 5, analyteMgPerUnit: 4.5, qty: 2), // 9mg
        CartPricingLine(group: 'B', mgTpe: 90, analyteMgPerUnit: 9.0, qty: 1), // 9mg
      ];
      expect(totalAnalyteMg(lines), 18.0);
    });

    test('a line with analyteMgPerUnit left at its default (unknown) contributes nothing to the total', () {
      // Same "0 when unknown" convention mgTpe already uses - a package whose state-system potency isn't
      // known yet shouldn't make every sale look like it is over the cap.
      final lines = [CartPricingLine(group: 'A', mgTpe: 5, qty: 1)];
      expect(totalAnalyteMg(lines), 0.0);
      expect(analyteCapError(lines), isNull);
    });

    test('exactly maxAnalyteMgPerSale is allowed - the cap is "more than", not "at least"', () {
      final lines = [CartPricingLine(group: 'A', mgTpe: 5, analyteMgPerUnit: 25, qty: 2)]; // exactly 50mg
      expect(totalAnalyteMg(lines), maxAnalyteMgPerSale);
      expect(analyteCapError(lines), isNull);
    });

    test('a hair over the cap is refused, with the actual total mg in the message', () {
      final lines = [CartPricingLine(group: 'A', mgTpe: 5, analyteMgPerUnit: 25.1, qty: 2)]; // 50.2mg
      expect(analyteCapError(lines), contains('50.2 mg psilocybin'));
      expect(analyteCapError(lines), contains('50 mg limit per sale'));
    });

    test('the cap sums across every line in the cart, not just the biggest one', () {
      final lines = [
        CartPricingLine(group: 'A', mgTpe: 5, analyteMgPerUnit: 30, qty: 1), // 30mg, under the cap alone
        CartPricingLine(group: 'B', mgTpe: 90, analyteMgPerUnit: 30, qty: 1), // 30mg, under the cap alone
      ];
      // 60mg combined - over the cap even though neither line is, on its own, since a "sale" is the whole cart.
      expect(analyteCapError(lines), isNotNull);
    });

    test('mg TPE alone, however high, is never subject to this cap - only analyteMgPerUnit is', () {
      // The user's own distinction: more than 50mg TPE is fine. mgTpe here is 500 (way over 50) but
      // analyteMgPerUnit (the only field this cap reads) is left at its default of 0.
      final lines = [CartPricingLine(group: 'A', mgTpe: 500, qty: 1)];
      expect(analyteCapError(lines), isNull);
    });
  });

  group('minSessionDuration', () {
    test('each bracket of the administration-session table, at its own lower boundary', () {
      expect(minSessionDuration(0), const Duration(minutes: 30)); // (a) under 2.5mg
      expect(minSessionDuration(2.5), const Duration(hours: 1)); // (b) 2.5mg up to under 5mg
      expect(minSessionDuration(5), const Duration(hours: 2)); // (c) 5mg up to under 10mg
      expect(minSessionDuration(10), const Duration(hours: 3)); // (d) 10mg up to under 15mg
      expect(minSessionDuration(15), const Duration(hours: 4)); // (e) 15mg up to under 25mg
      expect(minSessionDuration(25), const Duration(hours: 5)); // (f) 25mg up to under 35mg
      expect(minSessionDuration(35), const Duration(hours: 6)); // (g) 35mg up to and including 50mg
    });

    test('just under each upper boundary still falls in the lower bracket', () {
      expect(minSessionDuration(2.4999), const Duration(minutes: 30));
      expect(minSessionDuration(4.9999), const Duration(hours: 1));
      expect(minSessionDuration(9.9999), const Duration(hours: 2));
    });

    test('exactly the 50mg cap is still the top bracket - "up to 50mg" is inclusive', () {
      expect(minSessionDuration(50), const Duration(hours: 6));
      expect(minSessionDuration(maxAnalyteMgPerSale), const Duration(hours: 6));
    });

    test('above the 50mg cap has nothing to show - that sale is already refused outright', () {
      expect(minSessionDuration(50.1), isNull);
    });

    test('a negative figure (never a real input, but not a value the table covers either) is null', () {
      expect(minSessionDuration(-1), isNull);
    });
  });

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
