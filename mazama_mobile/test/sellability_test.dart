// SM-10: the phone's sellability rule is held to the golden vectors generated from the server's own rule
// (../mazama_modules/selling/gen.py -> stockdata.unsellable_reason), reason text included, so the two can't drift.
// Read from this app's vendored copy, assets/shared/selling/vectors/ (tool/sync_flows.sh; vendored_test.dart proves
// it equals the source). mazama_sales/tests/unit/test_golden_vectors.py proves the source is a fresh generation.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/sellability.dart';

void main() {
  final cases = (jsonDecode(File('assets/shared/selling/vectors/sellability.json').readAsStringSync()) as List)
      .cast<Map<String, Object?>>();

  test('the vectors are there to test against', () {
    expect(cases.length, greaterThanOrEqualTo(20));
  });

  for (final c in cases) {
    test('vector: ${c['name']}', () {
      final record = Map<String, Object?>.from(c['record'] as Map);
      expect(unsellableReason(record, qty: c['qty'] as int), c['reason']);
      expect(isSellable(record, qty: c['qty'] as int), c['reason'] == null);
    });
  }
}
