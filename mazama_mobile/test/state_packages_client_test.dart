import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/state_packages_client.dart';

void main() {
  // fetchPackagesFromState runs through fetchStateJson (state_client.dart), which loads
  // assets/flows/state_reads.yaml via rootBundle - that needs a binding, which plain test() (unlike
  // testWidgets()) never initializes on its own. Without this, every test below fails with "Binding has not
  // yet been initialized" before it ever reaches the MockClient - see licenses_client_test.dart's own comment.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hits GetPackagedProducts/{id}/ServiceCenter with the bearer token, same header shape as licenses_client', () async {
    final client = http_testing.MockClient((req) async {
      expect(req.url.toString(), 'https://psilocybin.oregon.gov/api/private/ProductTracking/GetPackagedProducts/225/ServiceCenter');
      expect(req.headers['Authorization'], 'Bearer TEST-TOKEN');
      expect(req.headers['Accept'], 'application/json');
      expect(req.headers['User-Agent'], startsWith('Mozilla/5.0')); // SM-20: state_reads.yaml's user_agent
      return http.Response(
        jsonEncode([
          {'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'id': 101, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10, 'zeroOut': false},
        ]),
        200,
      );
    });
    final packages = await fetchPackagesFromState(225, accessToken: 'TEST-TOKEN', client: client);
    expect(packages, hasLength(1));
    expect(packages.single.productGuid, 'PKPR-ab12c');
  });

  test('tpeMg is weightPerUnit x analyteWeight, rounded up - the no-COA-override base case of mg_of', () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode([
            {'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'id': 101, 'weightPerUnit': 5.0, 'analyteWeight': 1.01, 'quantity': 10},
          ]),
          200,
        ));
    final packages = await fetchPackagesFromState(225, accessToken: 'T', client: client);
    expect(packages.single.tpeMg, 6); // 5.0 * 1.01 = 5.05, ceil -> 6
  });

  test('a record with no name has a blank strain - only the name says one here (SM-19, product_names_test.dart)', () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode([
            {'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'id': 101, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10},
          ]),
          200,
        ));
    final packages = await fetchPackagesFromState(225, accessToken: 'T', client: client);
    expect(packages.single.strain, '');
  });

  test('a zeroed-out or sold-out lot is dropped, same rule stockdata.in_stock applies server-side', () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode([
            {'productGuid': 'PKPR-aaaaa', 'productType': 'Extract', 'id': 1, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 0},
            {'productGuid': 'PKPR-bbbbb', 'productType': 'Extract', 'id': 2, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10, 'zeroOut': true},
            {'productGuid': 'PKPR-ccccc', 'productType': 'Extract', 'id': 3, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10, 'zeroOut': false},
          ]),
          200,
        ));
    final packages = await fetchPackagesFromState(225, accessToken: 'T', client: client);
    expect(packages.map((p) => p.productGuid), ['PKPR-ccccc']);
  });

  test('locked, flagged and pending-transfer packages are dropped too, the server\'s own unsellable_reason (SM-10)', () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode([
            {'productGuid': 'PKPR-aaaaa', 'productType': 'Extract', 'id': 1, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10, 'locked': true},
            {'productGuid': 'PKPR-bbbbb', 'productType': 'Extract', 'id': 2, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10, 'flagged': true},
            {'productGuid': 'PKPR-ccccc', 'productType': 'Extract', 'id': 3, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10, 'pendingTransfer': true},
            {'productGuid': 'PKPR-ddddd', 'productType': 'Extract', 'id': 4, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10,
              'locked': false, 'flagged': false, 'pendingTransfer': false},
          ]),
          200,
        ));
    final packages = await fetchPackagesFromState(225, accessToken: 'T', client: client);
    expect(packages.map((p) => p.productGuid), ['PKPR-ddddd']);
  });

  test('lotGuid is the first of harvestBatchGuid, processLotGuid that is a lot id (SM-09, the server\'s product_source) - '
      'the raw state fields coa_data_resolver.dart keys the whole adhoc-COA flow off of, free of any extra round trip',
      () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode([
            {
              'productGuid': 'PKPR-aaaaa', 'productType': 'Extract', 'id': 1, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10,
              'harvestBatchGuid': 'HB-1a2b3c4d', 'processLotGuid': 'PL-de20657a',
            },
            {
              'productGuid': 'PKPR-bbbbb', 'productType': 'Extract', 'id': 2, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10,
              'harvestBatchGuid': '', 'processLotGuid': 'PL-00000002',
            },
            {
              'productGuid': 'PKPR-ccccc', 'productType': 'Extract', 'id': 3, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10,
            },
            {
              // Not an id the server would accept (/p/coa-data/parse answers 400): skipped for the lot that is one.
              'productGuid': 'PKPR-ddddd', 'productType': 'Extract', 'id': 4, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10,
              'harvestBatchGuid': 'HARVEST-1', 'processLotGuid': 'PL-00000004',
            },
            {
              'productGuid': 'PKPR-eeeee', 'productType': 'Extract', 'id': 5, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10,
              'harvestBatchGuid': 'HARVEST-1',
            },
          ]),
          200,
        ));
    final packages = await fetchPackagesFromState(225, accessToken: 'T', client: client);
    expect(packages.firstWhere((p) => p.productGuid == 'PKPR-aaaaa').lotGuid, 'HB-1a2b3c4d');
    expect(packages.firstWhere((p) => p.productGuid == 'PKPR-bbbbb').lotGuid, 'PL-00000002');
    expect(packages.firstWhere((p) => p.productGuid == 'PKPR-ccccc').lotGuid, isNull);
    expect(packages.firstWhere((p) => p.productGuid == 'PKPR-ddddd').lotGuid, 'PL-00000004');
    expect(packages.firstWhere((p) => p.productGuid == 'PKPR-eeeee').lotGuid, isNull);
  });

  test('a row with no productGuid at all is dropped too', () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode([
            {'productType': 'Extract', 'id': 1, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10},
          ]),
          200,
        ));
    final packages = await fetchPackagesFromState(225, accessToken: 'T', client: client);
    expect(packages, isEmpty);
  });

  test('a 401 is reported as a session problem, not a generic HTTP error', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 401));
    await expectLater(
      fetchPackagesFromState(225, accessToken: 'STALE', client: client),
      throwsA(isA<StatePackagesError>().having((e) => e.message, 'message', contains('sign in again'))),
    );
  });

  test('a network failure is reported with the host name, not a raw exception', () async {
    final client = http_testing.MockClient((req) async => throw Exception('boom'));
    await expectLater(
      fetchPackagesFromState(225, accessToken: 'T', client: client),
      throwsA(isA<StatePackagesError>().having((e) => e.message, 'message', contains('psilocybin.oregon.gov'))),
    );
  });

  test('a non-200 that is not 401 is reported with its status code', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 500));
    await expectLater(
      fetchPackagesFromState(225, accessToken: 'T', client: client),
      throwsA(isA<StatePackagesError>().having((e) => e.message, 'message', contains('500'))),
    );
  });

  test('non-JSON body is reported plainly', () async {
    final client = http_testing.MockClient((req) async => http.Response('<html>nope</html>', 200));
    await expectLater(
      fetchPackagesFromState(225, accessToken: 'T', client: client),
      throwsA(isA<StatePackagesError>().having((e) => e.message, 'message', contains('JSON'))),
    );
  });

  // SM-21: the server's own rule (state/mapping.py packaged_product): a record without a whole-number id or a PKPR
  // is skipped, and an id written as a string is read, not a crash.
  test('records the server would skip are skipped, and a string id is read', () {
    Map<String, Object?> row(Object? id, Object? guid) => {
          if (id != null) 'id': id,
          if (guid != null) 'productGuid': guid,
          'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10,
        };
    final packages = mapRawPackagesFromState([
      row('6600', 'PKPR-aaaaa'),
      row(null, 'PKPR-bbbbb'),
      row(7.5, 'PKPR-ccccc'),
      row(8, '   '),
      row(9, ' PKPR-ddddd '),
    ]);
    expect([for (final p in packages) (p.id, p.productGuid)], [(6600, 'PKPR-aaaaa'), (9, 'PKPR-ddddd')]);
  });
}
