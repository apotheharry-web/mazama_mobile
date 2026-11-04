// The cart's totals, the cap fallback's strongest lot and the date pickers' bounds are the shared core's
// (cart_pricing.dart's cartTotals, dose.dart's highestLot, selling.dart's saleDateBounds), held to the frozen vectors
// (assets/shared/selling/vectors/cart_totals.json, sale_date_bounds.json, assets/shared/dose/vectors/highest_lot.json).
// The Dart they replaced is kept here only, as an oracle: on every case it gives the vectors' answers, except that a
// cart whose figures pass 64 bits (where the Dart wrapped) is refused by the core. Each fails closed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/cart_pricing.dart';
import 'package:mazama_mobile/dose.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/selling.dart';

import 'support/core.dart';

List<Map<String, Object?>> _cases(String path) =>
    ((jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>)['cases'] as List).cast<Map<String, Object?>>();

final _totals = _cases('assets/shared/selling/vectors/cart_totals.json');
final _bounds = _cases('assets/shared/selling/vectors/sale_date_bounds.json');
final _highestCases = _cases('assets/shared/dose/vectors/highest_lot.json');

List<CartTotalLine> _lines(Map<String, Object?> input) => [
      for (final l in (input['lines'] as List).cast<Map<String, Object?>>())
        (qty: l['qty'] as int, priceCentsEach: l['price_cents'] as int, group: l['group'] as String?),
    ];

// --- the old Dart, test-only ---------------------------------------------------------------------------------------

/// cart_page.dart's sums as they were: CartLine.totalCents = qty * priceCentsEach, folded for the cart, its groups and
/// its units, and the bulk sell's perSaleCents * n (Dart ints: they wrap past 64 bits).
Map<String, Object?> _oldTotals(List<CartTotalLine> lines, int n) {
  final each = [for (final l in lines) l.qty * l.priceCentsEach];
  var total = 0, units = 0, a = 0, b = 0;
  for (var i = 0; i < lines.length; i++) {
    total += each[i];
    units += lines[i].qty;
    if (lines[i].group == 'A') a += each[i];
    if (lines[i].group == 'B') b += each[i];
  }
  return {
    'all_total': total * n,
    'all_units': units * n,
    'group_totals': {'A': a, 'B': b},
    'line_totals': each,
    'total': total,
    'units': units,
  };
}

/// Whether any figure of [lines] sold [n] times passes 64 bits when worked out exactly.
bool _passes64Bits(List<CartTotalLine> lines, int n) {
  final lo = BigInt.from(-1) << 63, hi = (BigInt.one << 63) - BigInt.one;
  bool out(BigInt x) => x < lo || x > hi;
  final each = [for (final l in lines) BigInt.from(l.qty) * BigInt.from(l.priceCentsEach)];
  var total = BigInt.zero, units = BigInt.zero, a = BigInt.zero, b = BigInt.zero;
  for (var i = 0; i < lines.length; i++) {
    total += each[i];
    units += BigInt.from(lines[i].qty);
    if (lines[i].group == 'A') a += each[i];
    if (lines[i].group == 'B') b += each[i];
  }
  final nn = BigInt.from(n);
  return [...each, total, units, a, b, total * nn, units * nn].any(out);
}

/// bulk_sale.dart's _highest as it was, as the index of the lot it picked.
int _oldHighest(List<Package> lots) {
  int rank(Package l) {
    final w = l.weightPerUnit, a = l.analyteWeight;
    if (!w.isFinite || !a.isFinite || w < 0 || a < 0) return 2;
    return w == 0 || a == 0 ? 1 : 0;
  }

  var best = 0;
  for (var i = 1; i < lots.length; i++) {
    final (rb, rl) = (rank(lots[best]), rank(lots[i]));
    if (rl > rb ||
        (rl == rb && rl == 0 && lots[i].weightPerUnit * lots[i].analyteWeight > lots[best].weightPerUnit * lots[best].analyteWeight)) {
      best = i;
    }
  }
  return best;
}

double _figure(Object? v) => switch (v) {
      'NaN' => double.nan,
      'Infinity' => double.infinity,
      '-Infinity' => double.negativeInfinity,
      final num x => x.toDouble(),
      _ => throw ArgumentError.value(v),
    };

List<Package> _lots(Map<String, Object?> input) => [
      for (final (i, l) in (input['lots'] as List).cast<Map<String, Object?>>().indexed)
        Package(
            productGuid: 'PKPR-ab12c',
            productType: 'Extract',
            id: i + 1,
            weightPerUnit: _figure(l['weightPerUnit']),
            analyteWeight: _figure(l['analyteWeight']),
            quantity: 1),
    ];

DateTime _day(String iso) {
  final p = iso.split('-').map(int.parse).toList();
  return DateTime.utc(p[0], p[1], p[2]);
}

/// A core that throws for everything.
class _Failing implements CoreFunctions {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('no core');
}

/// A core that answers [reply] for everything.
class _Says implements CoreFunctions {
  _Says(this.reply);
  final Object? reply;
  @override
  dynamic noSuchMethod(Invocation invocation) => reply;
}

/// The real core but for dose.highest_lot, which throws.
class _NoHighest implements CoreFunctions {
  CoreFunctions get _real => MazamaCore.instance;
  @override
  Map<String, Object?> sellingAllocateSale(Map<String, Object?> input) => _real.sellingAllocateSale(input);
  @override
  Map<String, Object?> sellingAllocate(Map<String, Object?> input) => _real.sellingAllocate(input);
  @override
  List<Object?> doseSaleLimits(Map<String, Object?> input) => _real.doseSaleLimits(input);
  @override
  Map<String, Object?> doseHighestLot(Map<String, Object?> input) => throw const MazamaCoreError('no');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(loadTestCore);

  group("PRICE-11: the cart's totals are the core's", () {
    test('every frozen cart, through cartTotals', () {
      for (final c in _totals) {
        final input = c['input'] as Map<String, Object?>;
        final got = cartTotals(_lines(input), sales: input['sales'] as int);
        if (c['rejects'] == true) {
          expect(got, isNull, reason: '${c['name']}');
          continue;
        }
        final want = c['answer'] as Map<String, Object?>;
        final groups = want['group_totals'] as Map<String, Object?>;
        expect(
            [got!.lineTotals, got.total, got.groupA, got.groupB, got.units, got.allTotal, got.allUnits],
            [want['line_totals'], want['total'], groups['A'], groups['B'], want['units'], want['all_total'], want['all_units']],
            reason: '${c['name']}');
      }
    });

    test("the old Dart gave the same totals on every cart, except where it wrapped past 64 bits", () {
      var same = 0, wrapped = 0;
      for (final c in _totals) {
        final input = c['input'] as Map<String, Object?>;
        final lines = _lines(input), n = input['sales'] as int;
        if (c['rejects'] == true) {
          expect(_passes64Bits(lines, n), isTrue, reason: '${c['name']}: refused, though nothing passes 64 bits');
          wrapped++;
        } else {
          expect(_oldTotals(lines, n), c['answer'], reason: '${c['name']}');
          same++;
        }
      }
      expect(same + wrapped, _totals.length);
      expect(same, greaterThan(600));
    });

    test('a priced cart reports the total its prices come to, from the same function', () {
      final r = priceWholeCart(
          mode: CartPricingMode.total,
          lines: [CartPricingLine(group: 'A', mgTpe: 5, qty: 2), CartPricingLine(group: 'B', mgTpe: 9, qty: 3)],
          totalText: '130');
      final again = cartTotals([
        (qty: 2, priceCentsEach: r.priceCentsEach![0], group: 'A'),
        (qty: 3, priceCentsEach: r.priceCentsEach![1], group: 'B'),
      ]);
      expect(r.grandTotalCents, again!.total);
    });

    test('fails closed: no core, a refusal or a reply of the wrong shape is no total (PRICE-8)', () {
      final one = <CartTotalLine>[(qty: 1, priceCentsEach: 100, group: 'A')];
      expect(cartTotals(one, core: _Failing()), isNull);
      for (final reply in <Object?>[
        <String, Object?>{},
        {'line_totals': [100, 1], 'total': 100, 'group_totals': {'A': 100, 'B': 0}, 'units': 1, 'all_total': 100, 'all_units': 1},
        {'line_totals': [100], 'total': 100.5, 'group_totals': {'A': 100, 'B': 0}, 'units': 1, 'all_total': 100, 'all_units': 1},
        {'line_totals': [100], 'total': 100, 'group_totals': {'A': 100}, 'units': 1, 'all_total': 100, 'all_units': 1},
        {'line_totals': [100], 'total': 100, 'group_totals': {'A': 100, 'B': 0}, 'units': 1, 'all_total': null, 'all_units': 1},
        [1, 2],
      ]) {
        expect(cartTotals(one, core: _Says(reply)), isNull, reason: '$reply');
      }
      expect(cartTotals(one, sales: 0), isNull); // the core refuses n below 1
      expect(
          priceWholeCart(
                  mode: CartPricingMode.total, lines: [CartPricingLine(group: 'A', mgTpe: 5, qty: 2)], totalText: '10', core: _Says({}))
              .errorCode,
          'core');
    });
  });

  group("DOSE-24: the cap fallback's strongest lot is the core's", () {
    test('every frozen product, through highestLot, and the old Dart picked the same lot', () {
      for (final c in _highestCases) {
        final lots = _lots(c['input'] as Map<String, Object?>);
        final want = (c['answer'] as Map<String, Object?>)['index'];
        expect(highestLot(lots), want, reason: '${c['name']}');
        if (lots.isNotEmpty) expect(_oldHighest(lots), want, reason: '${c['name']}');
      }
    });

    test("fails closed: a core that can't pick refuses the cart's cap (DOSE-7)", () {
      final lots = [
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 1, weightPerUnit: 1, analyteWeight: 5, quantity: 2),
      ];
      expect(highestLot(lots, core: _Failing()), isNull);
      expect(highestLot(lots, core: _Says({'index': 1})), isNull); // no such lot
      expect(highestLot(lots, core: _Says({'index': '0'})), isNull);
      // 3 units of the 2: the line is counted on its strongest lot, which this core can't pick
      final r = cartDrawLimits([(lots: lots, qty: 3, dose: doseInitial)], 1, core: _NoHighest());
      expect((r.perSale, r.shortLine), (null, 0));
      expect(identical(r.limits.single, SaleLimits.failed), isTrue);
    });
  });

  group("SALE-19: the date pickers' bounds are the core's", () {
    test('every frozen today, through saleDateBounds, and the old 365 days back in UTC', () {
      for (final c in _bounds) {
        final today = (c['input'] as Map<String, Object?>)['today'] as String;
        if (c['rejects'] == true) continue; // not a date the phone can have
        final b = saleDateBounds(_day(today));
        final want = c['answer'] as Map<String, Object?>;
        expect((b.earliest, b.latest), (_day(want['earliest'] as String), _day(want['latest'] as String)), reason: today);
        expect(b.earliest, _day(today).subtract(const Duration(days: 365)), reason: today);
      }
    });

    test('the earliest day is one check_sale_date allows, the day before it one it refuses', () {
      final today = DateTime.utc(2026, 3, 9);
      final b = saleDateBounds(today);
      expect(checkSaleDate(b.earliest, today), isNull);
      expect(checkSaleDate(b.latest, today), isNull);
      expect(checkSaleDate(b.earliest.subtract(const Duration(days: 1)), today), 'too_old');
    });

    test("fails closed: a core that can't answer is a StateError", () {
      final today = DateTime.utc(2026, 11, 1);
      expect(() => saleDateBounds(today, core: _Failing()), throwsStateError);
      expect(() => saleDateBounds(today, core: _Says({'earliest': 5, 'latest': '2026-11-01'})), throwsStateError);
      expect(() => saleDateBounds(today, core: _Says({'earliest': 'soon', 'latest': '2026-11-01'})), throwsStateError);
    });
  });
}
