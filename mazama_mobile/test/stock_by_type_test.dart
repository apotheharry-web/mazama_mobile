// specs/web-charts WC-D1, WC-D10: the phone's center By type pie (lib/stock_mix.dart stockByType) is held to the
// golden vectors generated from the server's own Python (stockview.by_type, ../mazama_modules/stock/README.md § 6),
// read from this app's vendored copy, assets/shared/stock/vectors/by_type.json (vendored_test.dart proves it equals the
// source).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/stock_mix.dart';
import 'package:mazama_mobile/stock_summary.dart';

List<Map<String, Object?>> _cases() =>
    (jsonDecode(File('assets/shared/stock/vectors/by_type.json').readAsStringSync()) as List)
        .cast<Map<String, Object?>>();

List<StockRow> _rows(Object? json) =>
    [for (final r in json as List) StockRow.fromJson(Map<String, Object?>.from(r as Map))];

/// The result as JSON would carry it.
Object? _plain(Object? v) => jsonDecode(jsonEncode(v));

/// Where [got] differs from [want] ('' when equal): same keys, same list lengths, strings, bools and nulls exactly,
/// numbers within 1e-9 (JSON can't tell 75 from 75.0 on every side).
String _diff(Object? got, Object? want, [String at = r'$']) {
  if (got is num && want is num) return (got - want).abs() <= 1e-9 ? '' : '$at: $got != $want';
  if (got is Map && want is Map) {
    for (final k in {...got.keys, ...want.keys}) {
      if (!got.containsKey(k) || !want.containsKey(k)) return '$at.$k: present on one side only';
      final d = _diff(got[k], want[k], '$at.$k');
      if (d.isNotEmpty) return d;
    }
    return '';
  }
  if (got is List && want is List) {
    if (got.length != want.length) return '$at: length ${got.length} != ${want.length}';
    for (var i = 0; i < got.length; i++) {
      final d = _diff(got[i], want[i], '$at[$i]');
      if (d.isNotEmpty) return d;
    }
    return '';
  }
  return got == want ? '' : '$at: ${jsonEncode(got)} != ${jsonEncode(want)}';
}

void main() {
  final cases = _cases();

  test('there are by_type vectors to check', () => expect(cases.length, greaterThanOrEqualTo(10)));

  for (final c in cases) {
    test('by_type vector: ${c['name']}', () {
      final got = stockByType(_rows(c['rows']), c['mg_mode'] as String);
      final want = c['by_type'];
      if (want == null) {
        expect(got, isNull);
        return;
      }
      expect(got, isNotNull);
      final d = _diff(_plain(got), want);
      expect(d, isEmpty, reason: d);
    });
  }

  test('a pick can name every type weighed, those folded into "Other (n)" too', () {
    final many = cases.firstWhere((c) => c['name'] == 'more than 7 types');
    final rows = _rows(many['rows']);
    final words = stockByTypeWords(rows, many['mg_mode'] as String);
    final slices = (stockByType(rows, many['mg_mode'] as String)!['slices'] as List).cast<Map<String, Object?>>();
    final named = {for (final s in slices) if (s['slot'] != 'oth') s['name'] as String};
    expect(words.containsAll(named), isTrue);
    expect(words.length, named.length + 2); // "Other (2)"
  });
}
