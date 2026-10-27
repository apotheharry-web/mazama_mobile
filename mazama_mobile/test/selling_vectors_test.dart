// SM-11: the phone's sale record and sale-date rules are held to the golden vectors generated from the server's
// own Python (../mazama_modules/selling/gen.py -> selling.build_sale, parse_sale_date, pacific_midnight_utc), so
// the two sides send the same state record for the same sale. Read from this app's vendored copy,
// assets/shared/selling/vectors/ (tool/sync_flows.sh; vendored_test.dart proves it equals the source);
// mazama_sales/tests/unit/test_golden_vectors.py proves the source is a fresh generation.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/selling.dart';

Object? _vectors(String name) => jsonDecode(File('assets/shared/selling/vectors/$name').readAsStringSync());

DateTime _day(String iso) {
  final p = iso.split('-').map(int.parse).toList();
  return DateTime.utc(p[0], p[1], p[2]);
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  group('sale_record.json: buildSale sends exactly what the server sends', () {
    final cases = (_vectors('sale_record.json') as List).cast<Map<String, Object?>>();
    test('the vectors are there', () => expect(cases.length, greaterThanOrEqualTo(10)));
    for (final c in cases) {
      test(c['name'] as String, () {
        final got = buildSale(Map<String, Object?>.from(c['item'] as Map), c['price_cents'] as int, _day(c['sale_date'] as String),
            dose: c['dose'] as String, qty: c['qty'] as int);
        expect(got, equals(c['record']));
        // Same JSON on the wire, not just equal numbers: 40.0 and 40 are both "40.0"/"40" depending on the side.
        expect(jsonDecode(jsonEncode(got)), equals(c['record']));
      });
    }
  });

  group('sale_date.json', () {
    final v = _vectors('sale_date.json') as Map<String, Object?>;
    final today = _day(v['today'] as String);
    for (final c in (v['parse'] as List).cast<Map<String, Object?>>()) {
      test('parseSaleDate(${jsonEncode(c['text'])}) -> ${c['result']}', () {
        final want = c['result'] as String;
        if (want == 'bad' || want == 'future') {
          expect(() => parseSaleDate(c['text'] as String, today),
              throwsA(isA<FormatException>().having((e) => e.message, 'message', want)));
        } else {
          expect(_iso(parseSaleDate(c['text'] as String, today)), want);
        }
      });
    }
    test('pacificMidnightUtc around every daylight-saving switch 2024-2030', () {
      final cases = (v['pacific_midnight_utc'] as List).cast<Map<String, Object?>>();
      expect(cases.length, greaterThanOrEqualTo(56));
      for (final c in cases) {
        expect(pacificMidnightUtc(_day(c['date'] as String)), c['utc'], reason: c['date'] as String);
      }
    });
  });
}
