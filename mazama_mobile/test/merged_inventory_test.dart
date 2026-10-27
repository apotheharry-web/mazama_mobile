// merged_inventory.dart: the server's list joined with the state's live one. SM-17: only the server knows a record's
// expiry date, so the merge keeps it - a sale draws from the record that expires first (SM-D29).
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/merged_inventory.dart';
import 'package:mazama_mobile/packages_client.dart';

void main() {
  test("a record both sides know keeps the server's expiry date; one only the state knows has none", () async {
    final result = await fetchMergedInventory(
      231,
      accessToken: 'TEST-TOKEN',
      fetchMazama: (id) async => [
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, quantity: 4,
            expires: DateTime(2027, 3, 1)),
      ],
      fetchRawState: (id, {required accessToken}) async => [
        {'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5, 'analyteWeight': 1, 'quantity': 4},
        {'id': 102, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5, 'analyteWeight': 1, 'quantity': 2},
      ],
    );
    final byId = {for (final p in result.packages) p.id: p};
    expect(byId[101]!.expires, DateTime(2027, 3, 1));
    expect(byId[102]!.expires, isNull);
    // and a sale of 5 draws the dated record first, then the undated one
    expect([for (final (lot, n) in allocateLots(result.packages, 5)!) (lot.id, n)], [(101, 4), (102, 1)]);
  });

  test("SP-D10: a merged row keeps the server's mazama, expired, mg TPE and name, with the state's exact quantity", () async {
    final server = [
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, quantity: 9,
          mazama: true, expired: true, unitMgTpe: 4.992, description: 'GT 5 mg TPE EX (2026-01-01)'),
    ];
    final result = await fetchMergedInventory(
      231,
      accessToken: 'TEST-TOKEN',
      fetchMazama: (id) async => server,
      fetchRawState: (id, {required accessToken}) async => [
        {'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5, 'analyteWeight': 1, 'quantity': 2.5},
        {'id': 102, 'productGuid': 'PKPR-zz', 'productType': 'Extract', 'weightPerUnit': 5, 'analyteWeight': 1, 'quantity': 2},
      ],
    );
    final p = result.packages.firstWhere((p) => p.id == 101);
    expect([p.mazama, p.expired, p.unitMgTpe, p.description], [true, true, 4.992, 'GT 5 mg TPE EX (2026-01-01)']);
    expect(p.exactQuantity, 2.5); // the state's, fraction kept for the stock page
    expect(p.quantity, 2); // whole units for the cart, as before
    final stateOnly = result.packages.firstWhere((p) => p.id == 102);
    expect([stateOnly.mazama, stateOnly.unitMgTpe, stateOnly.description], [false, null, '']);
    expect(result.mazamaPackages, same(server)); // which lots the server returned (SP-D9)
  });

  test("README R64: a merged row keeps the server's label input; one only the state knows has none", () async {
    final input = <String, Object?>{'package': {'pkpr': 'PKPR-ab12c'}, 'section': null, 'settings': <String, Object?>{}};
    final result = await fetchMergedInventory(
      231,
      accessToken: 'TEST-TOKEN',
      fetchMazama: (id) async => [
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, quantity: 4,
            labelInput: input),
      ],
      fetchRawState: (id, {required accessToken}) async => [
        {'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5, 'analyteWeight': 1, 'quantity': 4},
        {'id': 102, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5, 'analyteWeight': 1, 'quantity': 2},
      ],
    );
    final byId = {for (final p in result.packages) p.id: p};
    expect(byId[101]!.labelInput, input);
    expect(byId[102]!.labelInput, isNull);
  });
}
