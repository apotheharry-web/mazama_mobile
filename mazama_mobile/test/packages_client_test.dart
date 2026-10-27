import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/packages_client.dart';

void main() {
  test('parses the public endpoint\'s JSON rows into Packages, quantity included', () async {
    final client = http_testing.MockClient((req) async {
      expect(req.url.path, '/p/packages/231');
      return http.Response(
        jsonEncode([
          {'productGuid': 'G-1', 'productType': 'Extract', 'id': 7, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 12},
        ]),
        200,
      );
    });
    final packages = await fetchPackages(231, client: client);
    expect(packages, hasLength(1));
    expect(packages.single.productGuid, 'G-1');
    expect(packages.single.id, 7);
    expect(packages.single.weightPerUnit, 5.0);
    expect(packages.single.quantity, 12);
  });

  test('a row with no quantity (an older server, or a field genuinely missing) defaults to 0, not a crash', () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode([
            {'productGuid': 'G-1', 'productType': 'Extract', 'id': 7, 'weightPerUnit': 5.0, 'analyteWeight': 4.5},
          ]),
          200,
        ));
    final packages = await fetchPackages(231, client: client);
    expect(packages.single.quantity, 0);
  });

  test('a 404 (no such service center) is reported, not treated as a network error', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 404));
    await expectLater(
      fetchPackages(999, client: client),
      throwsA(isA<PackagesError>().having((e) => e.message, 'message', contains('999'))),
    );
  });

  test('a non-JSON body is reported clearly rather than throwing an opaque FormatException', () async {
    final client = http_testing.MockClient((req) async => http.Response('<html>not json</html>', 200));
    await expectLater(fetchPackages(231, client: client), throwsA(isA<PackagesError>()));
  });

  group('SP-R7: the stock page fields', () {
    final example = File('assets/shared/api/examples/packages.response.json').readAsStringSync();
    http.Client answering() => http_testing.MockClient((req) async => http.Response(example, 200));

    test('the example reply carries mazama, expired, the exact mg TPE and the product name', () async {
      final packages = await fetchPackages(225, client: answering());
      final first = packages.first;
      expect(first.mazama, isTrue);
      expect(first.expired, isFalse);
      expect(first.unitMgTpe, 4.992);
      expect(first.description, 'Golden Teacher 5 mg TPE DH (2027-06-01)');
      expect(packages.last.mazama, isFalse);
      expect(packages.last.unitMgTpe, isNull);
    });

    test("toStockRow gives the stock rules the server's figures", () async {
      final row = (await fetchPackages(225, client: answering())).first.toStockRow();
      expect(row.productGuid, 'PKPR-aaaa0001');
      expect(row.id, 6600);
      expect(row.quantity, 120);
      expect(row.mazama, isTrue);
      expect(row.expired, isFalse);
      expect(row.strain, 'Golden Teacher');
      expect(row.description, 'Golden Teacher 5 mg TPE DH (2027-06-01)');
      expect(row.unitMgTpe, 4.992);
      expect(row.weightPerUnit, 0.48);
      expect(row.analyteWeight, 10.4);
    });

    test('a quantity that is not whole is kept exactly for the stock page, whole for the cart', () {
      final p = Package.fromJson({'productGuid': 'G-1', 'productType': 'Extract', 'id': 7, 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
          'quantity': 2.5});
      expect([p.quantity, p.exactQuantity, p.toStockRow().quantity], [2, 2.5, 2.5]);
      expect(Package.fromJson(p.toJson()).exactQuantity, 2.5);
      expect(Package(productGuid: 'G', productType: 'X', id: 1, weightPerUnit: 1, analyteWeight: 1, quantity: 3).exactQuantity, 3);
    });

    test("SM-D31: which figure tpeMg is, and who filled it, survive a saved copy; the server's rows carry neither", () {
      final at = DateTime.utc(2026, 10, 21, 15);
      final phone = Package(productGuid: 'G-1', productType: 'Extract', id: 7, weightPerUnit: 5, analyteWeight: 1, tpeMg: 9,
          enrichedAt: at, enrichedBy: EnrichmentSource.phone);
      final server = Package(productGuid: 'G-1', productType: 'Extract', id: 7, weightPerUnit: 5, analyteWeight: 1, tpeMg: 9, enrichedAt: at);
      final stateOnly = Package(productGuid: 'G-2', productType: 'Extract', id: 8, weightPerUnit: 5, analyteWeight: 1, tpeMg: 5,
          stateEstimate: true);
      expect([Package.fromJson(phone.toJson()).enrichedBy, Package.fromJson(server.toJson()).enrichedBy],
          [EnrichmentSource.phone, EnrichmentSource.server]);
      expect(server.toJson().containsKey('enrichedBy'), isFalse);
      expect(Package(productGuid: 'G', productType: 'X', id: 1, weightPerUnit: 1, analyteWeight: 1).enrichedBy, isNull);
      expect([Package.fromJson(stateOnly.toJson()).mgFigure, phone.mgFigure], [MgFigure.psilocybin, MgFigure.tpe]);
      expect([PkprGroup([phone]).mgLabel, PkprGroup([phone, stateOnly]).mgLabel], ['mg TPE', 'mg psilocybin']);
    });

    test('a 404 says so in its status, so the stock page can tell "not set up" from "unreachable"', () async {
      await expectLater(fetchPackages(999, client: http_testing.MockClient((req) async => http.Response('', 404))),
          throwsA(isA<PackagesError>().having((e) => e.status, 'status', 404)));
      await expectLater(
          fetchPackages(999, client: http_testing.MockClient((req) async => throw const SocketException('offline'))),
          throwsA(isA<PackagesError>().having((e) => e.status, 'status', isNull)));
    });

    test('an older server leaves them false, null and empty, and they survive a saved cart', () {
      final old = Package.fromJson({'productGuid': 'G-1', 'productType': 'Extract', 'id': 7, 'weightPerUnit': 5.0, 'analyteWeight': 4.5});
      expect([old.mazama, old.expired, old.unitMgTpe, old.description], [false, false, null, '']);
      final p = Package.fromJson(Map<String, Object?>.from((jsonDecode(example) as List).first as Map));
      final back = Package.fromJson(p.toJson());
      expect([back.mazama, back.expired, back.unitMgTpe, back.description], [true, false, 4.992, 'Golden Teacher 5 mg TPE DH (2027-06-01)']);
    });
  });

  group("README R64: the server's label input", () {
    final input = <String, Object?>{
      'package': {'pkpr': 'PKPR-aaaa0001', 'lot': 'HB-1e72aa01'},
      'section': {'uid': 'HB-1e72aa01'},
      'settings': {'shelf_months': 12, 'fd_months': 24, 'shelf_days': null, 'fd_days': null},
      'test_date': '2026-08-27',
    };

    test('is read from the reply, null when the server has none or is older, and survives a saved copy', () {
      final p = Package.fromJson({'productGuid': 'G-1', 'productType': 'Extract', 'id': 7, 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
          'labelInput': input});
      expect(p.labelInput, input);
      expect(Package.fromJson(p.toJson()).labelInput, input);
      expect(Package.fromJson({'productGuid': 'G-1', 'productType': 'Extract', 'id': 7, 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
          'labelInput': null}).labelInput, isNull);
      final old = Package.fromJson({'productGuid': 'G-1', 'productType': 'Extract', 'id': 7, 'weightPerUnit': 5.0, 'analyteWeight': 4.5});
      expect(old.labelInput, isNull);
      expect(old.toJson().containsKey('labelInput'), isFalse);
    });

    test("a product's group takes the first record, in draw order, that has one", () {
      Package rec(int id, DateTime expires, Map<String, Object?>? li) => Package(
          productGuid: 'G-1', productType: 'Extract', id: id, weightPerUnit: 5, analyteWeight: 4.5, quantity: 3, expires: expires,
          labelInput: li);
      final later = {...input, 'test_date': '2026-09-01'};
      expect(PkprGroup([rec(1, DateTime(2027, 9, 1), later), rec(2, DateTime(2027, 3, 1), input)]).labelInput, input);
      expect(PkprGroup([rec(1, DateTime(2027, 9, 1), later), rec(2, DateTime(2027, 3, 1), null)]).labelInput, later);
      expect(PkprGroup([rec(1, DateTime(2027, 3, 1), null)]).labelInput, isNull);
    });
  });
}
