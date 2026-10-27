// MI-R1: the phone's stock mix (lib/stock_mix.dart) is held to the golden vectors generated from the server's own
// Python (../mazama_modules/stock/gen.py -> stockview.mix, and the texts charts.mix_view writes), read from this
// app's vendored copy, assets/shared/stock/vectors/mix.json (vendored_test.dart proves it equals the source).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/stock_mix.dart';
import 'package:yaml/yaml.dart';

List<Map<String, Object?>> _cases() =>
    (jsonDecode(File('assets/shared/stock/vectors/mix.json').readAsStringSync()) as List).cast<Map<String, Object?>>();

List<MixCell> _rows(Object? json) => [for (final r in json as List) MixCell.fromJson(Map<String, Object?>.from(r as Map))];

/// The result as JSON would carry it (records and tuples become plain lists and maps).
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

List<String> _keys(Object? pie) => [for (final s in ((pie as Map)['slices'] as List).cast<Map<String, Object?>>()) mixKeyText(s)];

void main() {
  final cases = _cases();

  test('there are mix vectors to check', () => expect(cases.length, greaterThanOrEqualTo(10)));

  for (final c in cases) {
    test('mix vector: ${c['name']}', () {
      final got = stockMix(_rows(c['rows']));
      final d = _diff(_plain(got), c['mix']);
      expect(d, isEmpty, reason: d);

      final texts = c['texts'] as Map;
      if ((got['total'] as num) <= 0) {
        expect(texts, isEmpty);
        return;
      }
      expect(formatMixMg(got['total'] as num), texts['total']);
      expect(_keys(got['by_strain']), texts['by_strain']);
      expect(_keys(got['by_type']), texts['by_type']);
      for (final cards in ['strain_cards', 'type_cards']) {
        final mine = [
          for (final card in (got[cards] as List).cast<Map<String, Object?>>())
            {'total': formatMixMg(card['total'] as num), 'keys': _keys(card['pie'])},
        ];
        expect(_plain(mine), texts[cards], reason: cards);
      }
    });
  }

  test('the type words are the vendored rules.yaml', () {
    final rules = loadYaml(File('assets/shared/stock/rules/rules.yaml').readAsStringSync()) as YamlMap;
    expect(Map<String, String>.from(rules['mix_type_words'] as Map), mixTypeWords);
  });

  test('mg texts round half to even and group thousands, as Python does', () {
    expect(formatMixMg(0.4), '0');
    expect(formatMixMg(2.5), '2');
    expect(formatMixMg(3.5), '4');
    expect(formatMixMg(999.5), '1,000');
    expect(formatMixMg(1234567.49), '1,234,567');
    expect(formatMixMg(100), '100');
  });
}
