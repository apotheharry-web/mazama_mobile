// The phone reads the state's packaged-product and license records by the same rule as the server - the shared
// core's (records.package_keys, records.service_centers, records.licenses_of_type), through the real library
// (support/core.dart) - held to the case tables frozen from the server's Python (../mazama_modules/contracts/gen.py).
//
// Read from this app's vendored copy, assets/shared/contracts/vectors/ (tool/sync_flows.sh; vendored_test.dart proves
// it equals the source). The server needs no copy: its own code is what generates the cases.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/state_records.dart';

import 'support/core.dart';

List<Map<String, Object?>> _cases(String name) =>
    (jsonDecode(File('assets/shared/contracts/vectors/$name').readAsStringSync()) as List).cast<Map<String, Object?>>();

void main() {
  group('packaged product records', () {
    final cases = _cases('packaged_product.json');
    test('there are cases', () => expect(cases.length, greaterThanOrEqualTo(15)));
    for (final c in cases) {
      test(c['name'] as String, () {
        final core = loadTestCore();
        final got = core.recordsPackageKeys({'records': [c['record']]}).single as Map;
        expect(got['problem'], c['problem']);
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

  group('licenses of one type from GetApplicableLicenses (the picker\'s manufacturers)', () {
    final cases = _cases('licenses_of_type.json');
    test('there are cases of both types', () {
      expect(cases.length, greaterThanOrEqualTo(70));
      expect({for (final c in cases) c['license_type']}, {'ServiceCenter', 'Manufacturer'});
    });
    for (final c in cases) {
      test('${c['name']} (${c['license_type']})', () {
        final kept = licensesOfType(licensesFromJson(c['licenses'] as List<Object?>), c['license_type'] as String);
        expect([
          for (final l in kept) {'state_id': l.id, 'name': l.licenseName, 'license': l.licenseId.isEmpty ? null : l.licenseId}
        ], c['kept']);
        expect(kept.every((l) => l.licenseType == c['license_type']), isTrue);
      });
    }
  });

  test('a license type the core does not take lists nothing', () {
    loadTestCore();
    final maker = License(id: 294, licenseId: 'MF-1', licenseName: '', licenseType: 'Laboratory');
    expect(licensesOfType([maker], 'Laboratory'), isEmpty);
    final named = licensesOfType([License(id: 294, licenseId: 'MF-1', licenseName: ' ', licenseType: 'Manufacturer')], 'Manufacturer');
    expect([for (final l in named) (l.id, l.licenseName, l.licenseId, l.isManufacturer)], [(294, 'Manufacturer 294', 'MF-1', true)]);
  });

  test('a License made by hand is judged by its four fields, and an entry kept raw by what the state sent', () {
    loadTestCore();
    final byHand = License(id: 7, licenseId: 'SC-7', licenseName: '', licenseType: 'ServiceCenter');
    final sent = License.fromJson({'id': ' 8 ', 'licenseId': 'SC-8', 'licenseName': ' Eight ', 'licenseType': 'ServiceCenter'});
    expect([for (final c in serviceCenters([byHand, sent])) (c.id, c.licenseName, c.licenseId)],
        [(7, 'Service center 7', 'SC-7'), (8, 'Eight', 'SC-8')]);
  });

  test('wholeNumber reads whole numbers the way the server does', () {
    expect([for (final v in [1389, '1389', 12.0, 12.5, null, 'x', true, '', double.nan, double.infinity]) wholeNumber(v)],
        [1389, 1389, 12, null, null, null, null, null, null, null]);
  });
}
