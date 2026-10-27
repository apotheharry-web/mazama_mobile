import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/licenses_client.dart';

void main() {
  // fetchApplicableLicenses runs through fetchStateJson (state_client.dart), which loads
  // assets/flows/state_reads.yaml via rootBundle - that needs a binding, which plain test() (unlike
  // testWidgets()) never initializes on its own. Without this, every test below fails with "Binding has not
  // yet been initialized" before it ever reaches the MockClient.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses a real-shaped response and sends the bearer token', () async {
    final client = http_testing.MockClient((req) async {
      expect(req.url.toString(), 'https://psilocybin.oregon.gov/api/private/ProductTracking/GetApplicableLicenses');
      expect(req.headers['Authorization'], 'Bearer TEST-TOKEN');
      expect(req.headers['User-Agent'], startsWith('Mozilla/5.0')); // SM-20: state_reads.yaml's user_agent
      // The exact shape confirmed in a real captured HAR: one account with a manufacturer license and
      // several service-center licenses, not just one.
      return http.Response(
        jsonEncode([
          {'id': 294, 'licenseId': 'MF-1e72fc8f', 'licenseName': 'Mazama Mushrooms LLC', 'licenseType': 'Manufacturer'},
          {'id': 225, 'licenseId': 'SC-ac9ac56b', 'licenseName': 'Unstuck Psilocybin Treatment Center', 'licenseType': 'ServiceCenter'},
          {'id': 183, 'licenseId': 'SC-2a49b223', 'licenseName': 'EPIC Healing Eugene', 'licenseType': 'ServiceCenter'},
          {'id': 231, 'licenseId': 'SC-b1c7379a', 'licenseName': 'Bendable Service Center', 'licenseType': 'ServiceCenter'},
        ]),
        200,
      );
    });

    final licenses = await fetchApplicableLicenses('TEST-TOKEN', client: client);
    expect(licenses, hasLength(4));

    final centers = licenses.where((l) => l.isServiceCenter).toList();
    expect(centers.map((l) => l.id), [225, 183, 231]);
    expect(centers.every((l) => !l.isManufacturer), isTrue);

    final mfr = licenses.firstWhere((l) => l.isManufacturer);
    expect(mfr.id, 294);
    expect(mfr.licenseName, 'Mazama Mushrooms LLC');
  });

  test('a 401 is reported as a session problem, not a generic HTTP error', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 401));
    await expectLater(
      fetchApplicableLicenses('STALE-TOKEN', client: client),
      throwsA(isA<LicensesError>().having((e) => e.message, 'message', contains('sign in again'))),
    );
  });

  // SM-21: the same rule as the server's directory.service_centers.
  test('serviceCenters keeps usable ServiceCenter entries once each, and a string id or a junk entry is no crash', () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode([
            {'id': '225', 'licenseId': 'SC-a', 'licenseName': '  Unstuck  ', 'licenseType': 'ServiceCenter'},
            {'id': 225, 'licenseId': 'SC-b', 'licenseName': 'Again', 'licenseType': 'ServiceCenter'},
            {'id': 0, 'licenseId': 'SC-c', 'licenseName': 'Zero', 'licenseType': 'ServiceCenter'},
            {'id': 183, 'licenseId': '', 'licenseName': ' ', 'licenseType': 'ServiceCenter'},
            {'id': 294, 'licenseId': 'MF-1', 'licenseName': 'Maker', 'licenseType': 'Manufacturer'},
            'not an object',
          ]),
          200,
        ));
    final centers = serviceCenters(await fetchApplicableLicenses('TEST-TOKEN', client: client));
    expect([for (final c in centers) (c.id, c.licenseName, c.licenseId)],
        [(225, 'Unstuck', 'SC-a'), (183, 'Service center 183', '')]);
  });
}
