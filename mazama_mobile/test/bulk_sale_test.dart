// Which lots every copy of a bulk sale draws from.
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/packages_client.dart';

Package _lot(int id, int quantity,
        {String guid = 'PKPR-ab12c', DateTime? expires, double weightPerUnit = 5.0, double analyteWeight = 4.5}) =>
    Package(
        productGuid: guid,
        productType: 'Extract',
        id: id,
        weightPerUnit: weightPerUnit,
        analyteWeight: analyteWeight,
        quantity: quantity,
        expires: expires);

class _Unnamed implements Exception {}

/// A core whose draw throws [error], or answers [answer].
class _Core implements CoreFunctions {
  final Object? error;
  final Map<String, Object?>? answer;
  _Core({this.error, this.answer});
  @override
  Map<String, Object?> sellingAllocateSale(Map<String, Object?> input) {
    if (error != null) throw error!;
    return answer!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<List<(int, int)>> _ids(List<List<(Package, int)>> sale) => [
      for (final line in sale) [for (final (lot, take) in line) (lot.id, take)]
    ];

void main() {
  test('one lot covering every copy: each copy takes its units from it', () {
    final r = allocateBulkSales([(lots: [_lot(1, 10)], qty: 2)], 3);
    expect(r.shortLine, isNull);
    expect(r.perSale!.map(_ids), [
      [[(1, 2)]],
      [[(1, 2)]],
      [[(1, 2)]],
    ]);
  });

  test('later copies take from what earlier ones left, moving to the next lot in draw order', () {
    // drawOrder: the earlier expiry first, so lot 2 (expires sooner) gives first even though it is larger.
    final lots = [_lot(1, 3, expires: DateTime(2027, 6, 1)), _lot(2, 4, expires: DateTime(2027, 1, 1))];
    final r = allocateBulkSales([(lots: lots, qty: 3)], 2);
    expect(r.perSale!.map(_ids), [
      [[(2, 3)]],
      [[(2, 1), (1, 2)]],
    ]);
  });

  test('two lines of the same package share its lots', () {
    // 2 + 1 units a copy from one 5-unit lot: one copy fits, two need 6 and the second line runs short
    List<BulkLine> lines() => [(lots: [_lot(1, 5)], qty: 2), (lots: [_lot(1, 5)], qty: 1)];
    expect(allocateBulkSales(lines(), 1).perSale!.map(_ids), [
      [[(1, 2)], [(1, 1)]],
    ]);
    final two = allocateBulkSales(lines(), 2);
    expect(two.perSale, isNull);
    expect(two.shortLine, 1);
  });

  test('too little stock names the first line that runs short, and draws nothing', () {
    final r = allocateBulkSales([
      (lots: [_lot(1, 100)], qty: 1),
      (lots: [_lot(2, 5, guid: 'PKPR-ff99aa')], qty: 2),
    ], 3);
    expect(r.perSale, isNull);
    expect(r.shortLine, 1);
  });

  test('never draws a lot past what it holds', () {
    final lots = [_lot(1, 2), _lot(2, 3), _lot(3, 4)];
    final r = allocateBulkSales([(lots: lots, qty: 3)], 3);
    final drawn = bulkDrawPerLot(r.perSale!);
    expect({for (final d in drawn) d.lot.id: d.units}, {1: 2, 2: 3, 3: 4});
    expect(allocateBulkSales([(lots: lots, qty: 3)], 4).shortLine, 0);
  });

  test('fewer than one sale is refused', () {
    expect(() => allocateBulkSales([(lots: [_lot(1, 1)], qty: 1)], 0), throwsArgumentError);
  });

  group('DOSE-17: every copy within the cap on the lots it draws', () {
    // lot 1 (drawn first, the smaller): 1.0 g x 10 mg/g = 10 mg a unit; lot 2: 2.0 g x 12 mg/g = 24 mg a unit
    List<Package> lots() =>
        [_lot(1, 3, weightPerUnit: 1.0, analyteWeight: 10.0), _lot(2, 10, weightPerUnit: 2.0, analyteWeight: 12.0)];

    test("each copy's mg is counted on its own draw, not the cart's first lot", () {
      final r = allocateBulkSales([(lots: lots(), qty: 3)], 2);
      expect(bulkCopyAnalyteMg(r.perSale!), [30.0, 72.0]);
    });

    test('a later copy over the cap refuses the bulk sale, naming the copy and its mg', () {
      final r = allocateBulkSales([(lots: lots(), qty: 3)], 2);
      expect(bulkCapRefusal(r.perSale!),
          'Sale 2 of 2 draws later lots and would total 72.0 mg psilocybin - more than the 50 mg limit per sale '
          '(mg TPE is not subject to this cap).');
      // one copy draws only lot 1: 30 mg, allowed as before
      expect(bulkCapRefusal(allocateBulkSales([(lots: lots(), qty: 3)], 1).perSale!), isNull);
    });

    test('a copy at exactly the cap is allowed, every line of it counted', () {
      final strong = [_lot(1, 10, weightPerUnit: 2.5, analyteWeight: 10.0)];
      final r = allocateBulkSales([(lots: strong, qty: 1), (lots: [_lot(2, 10, guid: 'PKPR-ff99aa')], qty: 1)], 2);
      // 25 + 22.5 a copy
      expect(bulkCopyAnalyteMg(r.perSale!), [47.5, 47.5]);
      expect(bulkCapRefusal(r.perSale!), isNull);
      final atCap = allocateBulkSales([(lots: strong, qty: 2)], 3);
      expect(bulkCopyAnalyteMg(atCap.perSale!), [50.0, 50.0, 50.0]);
      expect(bulkCapRefusal(atCap.perSale!), isNull);
    });

    test("a copy split over lots with the first lot's figures comes to the cart's own figure", () {
      final same = [_lot(1, 1, weightPerUnit: 1.1, analyteWeight: 9.7), _lot(2, 10, weightPerUnit: 1.1, analyteWeight: 9.7)];
      final r = allocateBulkSales([(lots: same, qty: 3)], 2);
      expect(r.perSale!.first.single, hasLength(2)); // copy 1 takes from both lots
      expect(bulkCopyAnalyteMg(r.perSale!), [1.1 * 9.7 * 3, 1.1 * 9.7 * 3]);
    });
  });

  group('a single sale on the lots it draws (one copy, every line sharing its lots)', () {
    // lot 1 (drawn first, the smaller): 2 units of 1.0 g x 10 mg/g; lot 2: 2.0 g x 12 mg/g = 24 mg a unit
    List<Package> lots({double strongerWeight = 2.0}) =>
        [_lot(1, 2, weightPerUnit: 1.0, analyteWeight: 10.0), _lot(2, 10, weightPerUnit: strongerWeight, analyteWeight: 12.0)];

    test('a line that spills onto a stronger lot is counted on both lots, and refused over the cap', () {
      final sale = allocateBulkSales([(lots: lots(), qty: 4)], 1).perSale!.single;
      expect(bulkCopyAnalyteMg([sale]), [68.0]); // 2 x 10 + 2 x 24, where the first lot alone says 40
      expect(saleCapRefusal(sale),
          'This sale draws later lots and would total 68.0 mg psilocybin - more than the 50 mg limit per sale '
          '(mg TPE is not subject to this cap).');
    });

    test('within the cap on the lots it draws: no refusal', () {
      final sale = allocateBulkSales([(lots: lots(strongerWeight: 1.0), qty: 4)], 1).perSale!.single;
      expect(bulkCopyAnalyteMg([sale]), [44.0]);
      expect(saleCapRefusal(sale), isNull);
    });

    test("two lines of one product share its lots: the second takes what the first left", () {
      final two = [_lot(1, 3), _lot(2, 3)];
      final r = allocateBulkSales([(lots: two, qty: 3), (lots: two, qty: 3)], 1);
      expect(r.perSale!.map(_ids), [
        [[(1, 3)], [(2, 3)]],
      ]);
      final one = allocateBulkSales([(lots: [_lot(1, 3)], qty: 3), (lots: [_lot(1, 3)], qty: 3)], 1);
      expect(one.perSale, isNull);
      expect(one.shortLine, 1);
    });
  });

  group('specs/core row 7: the draw is the core\'s, and fails closed (SALE-4, SALE-14)', () {
    final lines = <BulkLine>[(lots: [_lot(1, 10)], qty: 2)];
    test('a core that fails draws nothing', () {
      for (final error in [StateError('no core'), const MazamaCoreError('failed'), _Unnamed()]) {
        final r = allocateBulkSales(lines, 2, core: _Core(error: error));
        expect((r.perSale, r.shortLine, r.coreFailed), (null, 0, true), reason: error.runtimeType.toString());
      }
    });
    test('an answer of the wrong shape, or one that draws more than a lot holds, draws nothing', () {
      for (final answer in <Map<String, Object?>>[
        {},
        {'draws': null, 'short': null},
        {'draws': [[0, 1, 2]], 'short': null}, // one copy drawn of two
        {'draws': [[0, 1, 6], [1, 1, 6]], 'short': null}, // 12 from a lot of 10
        {'draws': [[0, 9, 2], [1, 9, 2]], 'short': null}, // a lot the line doesn't have
        {'draws': [[0, 1, 2.0], [1, 1, 2]], 'short': null},
      ]) {
        final r = allocateBulkSales(lines, 2, core: _Core(answer: answer));
        expect((r.perSale, r.coreFailed), (null, true), reason: '$answer');
      }
      final short = allocateBulkSales(lines, 2, core: _Core(answer: {'draws': null, 'short': 1}));
      expect((short.shortLine, short.coreFailed), (0, false)); // really short: the stock's words, not the core's failure
      expect(drawCoreFailedText, contains('shared core failed'));
    });
  });
}
