// specs/multi-cart MC-D10, MC-R3: which lots every copy of a bulk sale draws from.
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/packages_client.dart';

Package _lot(int id, int quantity, {String guid = 'PKPR-ab12c', DateTime? expires}) => Package(
    productGuid: guid, productType: 'Extract', id: id, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: quantity, expires: expires);

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
}
