// SM-19: a package read straight from the state system gets the strain written in its name, read by coa_core the
// way the server's names.py reads it (product_names.dart). The cases are the app's vendored copy of
// mazama_modules/names/vectors/names.json (tool/sync_flows.sh), computed from the server's Python. CI builds the
// library and passes it as COA_CORE_FFI_LIB; without it the library tests skip, and the strain is '' as before.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/coa_core_ffi.dart';
import 'package:mazama_mobile/product_names.dart';
import 'package:mazama_mobile/state_packages_client.dart';

final String? _lib = Platform.environment['COA_CORE_FFI_LIB'];
final String? _skip = _lib == null ? 'COA_CORE_FFI_LIB is not set (CI sets it after building coa_core_ffi)' : null;

Map<String, Object?> _vectors() =>
    jsonDecode(File('assets/shared/names/vectors/names.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  test('without the library the strain is blank, not an error', () {
    expect(strainFromName('GT 25 mg TPE FD (2027-01-31)', null), '');
    expect(strainFromName(null, null), '');
  });

  group('through the library', () {
    late CoaCore core;
    setUpAll(() {
      if (_lib != null) core = CoaCore.tryLoad(path: _lib)!;
    });

    test('every shared product name gives the server\'s strain', () {
      final cases = (_vectors()['product_names'] as List).cast<Map<String, Object?>>();
      expect(cases.length, greaterThanOrEqualTo(20));
      for (final c in cases) {
        final name = c['name'] as String;
        expect(strainFromName(name, core), (c['strain'] as String?) ?? '', reason: name);
        final read = core.parseName(name);
        if (c['status'] != 'unparsed') {
          expect([read['code'], read['expiry']], [c['code'], c['expiry']], reason: name);
        }
      }
    }, skip: _skip);

    test('a package read from the state system carries the strain in its name', () {
      final packages = mapRawPackagesFromState([
        {'id': 5, 'productGuid': 'PKPR-aaaaa', 'description': 'gt 25 mg TPE FD (2027-01-31)', 'productType': 'Whole Fungi',
         'weightPerUnit': 3.4, 'analyteWeight': 7.25, 'quantity': 2},
        {'id': 6, 'productGuid': 'PKPR-bbbbb', 'description': 'Golden Teacher chocolates', 'productType': 'Edible',
         'weightPerUnit': 1.0, 'analyteWeight': 5.0, 'quantity': 1},
      ], core: core);
      expect([for (final p in packages) p.strain], ['Golden Teacher', '']);
    }, skip: _skip);
  });
}
