// SM-21: the phone reads the state's packaged-product and license records by the same rule as the server, held to
// the case tables the server's own Python computed (../mazama_modules/contracts/gen.py ->
// state/mapping.py packaged_product, directory.service_centers).
//
// Read from this app's vendored copy, assets/shared/contracts/vectors/ (tool/sync_flows.sh; vendored_test.dart proves
// it equals the source). The server needs no copy: its own code is what generates the cases.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/state_records.dart';

List<Map<String, Object?>> _cases(String name) =>
    (jsonDecode(File('assets/shared/contracts/vectors/$name').readAsStringSync()) as List).cast<Map<String, Object?>>();

void main() {
  group('packaged product records', () {
    final cases = _cases('packaged_product.json');
    test('there are cases', () => expect(cases.length, greaterThanOrEqualTo(15)));
    for (final c in cases) {
      test(c['name'] as String, () {
        final key = packagedProductKey(c['record'] as Map<String, Object?>);
        expect(key != null, c['accepted']);
        if (key != null) {
          expect(key.stateId, c['state_id']);
          expect(key.pkpr, c['pkpr']);
        }
      });
    }
  });

  group('service centers from GetApplicableLicenses', () {
    final cases = _cases('service_centers.json');
    test('there are cases', () => expect(cases.length, greaterThanOrEqualTo(20)));
    for (final c in cases) {
      test(c['name'] as String, () {
        final centers = serviceCenters(licensesFromJson(c['licenses'] as List<Object?>));
        expect([
          for (final l in centers) {'state_id': l.id, 'name': l.licenseName, 'license': l.licenseId.isEmpty ? null : l.licenseId}
        ], c['centers']);
      });
    }
  });

  test('wholeNumber reads whole numbers the way the server does', () {
    expect([for (final v in [1389, '1389', 12.0, 12.5, null, 'x', true, '', double.nan, double.infinity]) wholeNumber(v)],
        [1389, 1389, 12, null, null, null, null, null, null, null]);
  });
}
