// SM-09: the phone's id checks and "which batch/lot a package came from", held to the cases the server's own Python
// computed (../mazama_modules/ids/gen.py -> idpatterns.LOT_ID / PACKAGE_ID, stockdata.product_source). The
// patterns themselves are generated into lib/id_patterns.g.dart from ../mazama_modules/ids/ids.yaml.
//
// Read from this app's vendored copy, assets/shared/ids/vectors/ (tool/sync_flows.sh; vendored_test.dart proves it
// equals the source). The server needs no copy: its own code is what generates the cases.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/package_ids.dart';

final _cases = jsonDecode(File('assets/shared/ids/vectors/ids.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  test('there are cases to check', () {
    expect((_cases['ids'] as List).length, greaterThanOrEqualTo(30));
    expect((_cases['package_source'] as List).length, greaterThanOrEqualTo(10));
  });

  for (final c in (_cases['ids'] as List).cast<Map<String, Object?>>()) {
    test('"${c['id']}": lot id ${c['lot_id']}, package id ${c['package_id']}', () {
      expect(isLotId(c['id'] as String), c['lot_id']);
      expect(isPackageId(c['id'] as String), c['package_id']);
    });
  }

  for (final c in (_cases['package_source'] as List).cast<Map<String, Object?>>()) {
    test('package source: ${c['name']}', () {
      expect(packageSource(c['record'] as Map<String, Object?>), c['source']);
    });
  }
}
