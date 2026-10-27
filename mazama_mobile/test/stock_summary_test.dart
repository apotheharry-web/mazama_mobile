// SP-R10: the phone's stock rules (lib/stock_summary.dart) are held to the golden vectors generated from the server's
// own Python (../mazama_modules/stock/gen.py -> stockview.filter_rows, summarize, pies, par_table), so the phone's
// stock page draws the same pies and par table as the server's center page. Read from this app's vendored copy,
// assets/shared/stock/vectors/ (tool/sync_flows.sh; vendored_test.dart proves it equals the source);
// mazama_sales/tests/unit/test_golden_vectors.py proves the source is a fresh generation.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/stock_summary.dart';
import 'package:yaml/yaml.dart';

List<Map<String, Object?>> _cases(String name) =>
    (jsonDecode(File('assets/shared/stock/vectors/$name').readAsStringSync()) as List).cast<Map<String, Object?>>();

List<StockRow> _rows(Object? json) =>
    [for (final r in json as List) StockRow.fromJson(Map<String, Object?>.from(r as Map))];

List<ParLevel> _levels(Object? json) =>
    [for (final l in json as List) ParLevel.fromJson(Map<String, Object?>.from(l as Map))];

/// The result as JSON would carry it (StockRow objects become their maps).
Object? _plain(Object? v) => jsonDecode(jsonEncode(v));

/// Where [got] differs from [want] ('' when equal): same keys, same list lengths, strings and bools exactly, numbers
/// within 1e-9 (an int and a double of the same value are equal: JSON can't tell 75 from 75.0 on every side).
String _diff(Object? got, Object? want, [String at = r'$']) {
  if (got is num && want is num) return (got - want).abs() <= 1e-9 ? '' : '$at: $got != $want';
  if (got is Map && want is Map) {
    final keys = {...got.keys, ...want.keys};
    for (final k in keys) {
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

void _same(Object? got, Object? want) {
  final d = _diff(_plain(got), want);
  expect(d, isEmpty, reason: d);
}

void main() {
  group('every stock vector', () {
    final filters = _cases('filter.json');
    final summaries = _cases('summary.json');
    final pieCases = _cases('pies.json');
    final pars = _cases('par.json');

    test('the vectors are there', () {
      expect(filters.length, greaterThanOrEqualTo(8));
      expect(summaries.length, greaterThanOrEqualTo(10));
      expect(pieCases.length, greaterThanOrEqualTo(10));
      expect(pars.length, greaterThanOrEqualTo(8));
    });
    for (final c in filters) {
      test('filter: ${c['name']}', () => _same(filterRows(_rows(c['rows']), c['makers'] as String), c['result']));
    }
    for (final c in summaries) {
      test('summary: ${c['name']}', () => _same(summarize(_rows(c['rows']), c['mg_mode'] as String), c['summary']));
    }
    for (final c in pieCases) {
      test('pies: ${c['name']}', () => _same(pies(Map<String, Object?>.from(c['summary'] as Map)), c['pies']));
    }
    for (final c in pars) {
      test('par: ${c['name']}', () {
        _same(parTable(Map<String, Object?>.from(c['summary'] as Map), _levels(c['levels'])), c['par']);
      });
    }
    // The page chains them: rows -> filter -> summary -> pies, as the server's center page does.
    for (final c in summaries) {
      test('summary then pies: ${c['name']}', () {
        final mine = summarize(_rows(c['rows']), c['mg_mode'] as String);
        _same(pies(mine), _plain(pies(Map<String, Object?>.from(c['summary'] as Map))));
      });
    }
  });

  test('percent rounds half to even', () {
    expect(roundHalfEven(12.5), 12);
    expect(roundHalfEven(13.5), 14);
    expect(roundHalfEven(87.5), 88);
    expect(roundHalfEven(86.5), 86);
    expect(roundHalfEven(2.4999), 2);
    expect(stockPercent(1, 8), 12);
    expect(stockPercent(27, 200), 14);
  });

  test('2-decimal rounding and %g formatting are Python\'s', () {
    expect(roundTo2(0.125), 0.12);
    expect(roundTo2(0.375), 0.38);
    expect(roundTo2(2.675), 2.67);           // 2.67499999... in binary
    expect(roundTo2(1.005), 1.0);
    expect(roundTo2(0.005), 0.01);
    expect(formatG(25), '25');
    expect(formatG(1.5), '1.5');
    expect(formatG(8117.125), '8117.12');
    expect(formatG(1000000), '1e+06');
    expect(formatG(1234565), '1.23456e+06');
    expect(formatG(0.0001), '0.0001');
  });

  test('StockRow round-trips JSON', () {
    final j = <String, Object?>{
      'productGuid': 'PKPR-0001', 'id': 7, 'quantity': 2.5, 'zeroOut': false, 'expired': true, 'mazama': true,
      'strain': 'Bluey', 'description': 'Bluey 25 mg TPE', 'unitMgTpe': 24.71, 'weightPerUnit': null,
      'analyteWeight': 19.37,
    };
    expect(StockRow.fromJson(j).toJson(), j);
    final l = <String, Object?>{'strain': 'Bluey', 'size': 0, 'par': 4};
    expect(ParLevel.fromJson(l).toJson(), l);
    final typed = <String, Object?>{...j, 'type': 'CH'};                // specs/edibles ED-R2: kept when sent
    expect(StockRow.fromJson(typed).toJson(), typed);
  });

  test('bad filter and mg mode names are refused', () {
    expect(() => filterRows(const [], 'ours'), throwsArgumentError);
    expect(() => summarize(const [], 'mg'), throwsArgumentError);
  });

  test('the constants are the vendored rules.yaml', () {
    final rules = loadYaml(File('assets/shared/stock/rules/rules.yaml').readAsStringSync()) as YamlMap;
    expect(rules['serving_sizes'], stockServingSizes);
    expect(rules['other_size'], stockOtherSize);
    expect(rules['par_columns'], stockParColumns);
    expect(rules['all_strains'], stockAllStrains);
    expect(rules['strain_slots'], stockStrainSlots);
    expect(rules['strain_rows'], stockMaxStrainRows);
    expect(rules['filters'], stockFilters);
    expect(rules['default_filter'], stockFilters.first);
    expect(rules['mg_modes'], stockMgModes);
    // specs/edibles ED-R1
    final edibles = rules['edibles'] as YamlMap;
    expect(Map<String, String>.from(edibles['products'] as YamlMap), stockEdibles);
    expect(edibles['booster_from_mg'], stockBoosterFromMg);
    expect({
      for (final e in (edibles['sizes'] as YamlMap).entries)
        e.key as String: ((e.value as YamlMap)['code'] as int, (e.value as YamlMap)['word'] as String, (e.value as YamlMap)['slot'] as String),
    }, stockEdibleSizes);
    expect([for (final k in rules['name_keywords'] as YamlList) ((k as YamlList)[0] as String, k[1] as String)], stockNameKeywords);
    expect(List<String>.from(rules['size_order'] as YamlList), stockSizeOrder);
  });

  group('edibles (specs/edibles)', () {
    StockRow row(int id, String desc, {String? type, num? mg, String strain = 'GT', num q = 1}) =>
        StockRow(productGuid: 'P$id', id: id, quantity: q, strain: strain, description: desc, unitMgTpe: mg, type: type);

    test('an edible counts under its product, by type, by the code in its name or a keyword', () {
      final sm = summarize([
        row(1, 'GT 5 mg TPE CH (2027-02-03)', q: 3),
        row(2, 'Bluey Gummies 1 mg', q: 2),
        row(3, 'Avery honey sticks', type: 'HN', mg: 12),
        row(4, 'Avery extract 10 mg', type: 'EX', strain: 'Avery'),
        row(5, 'Chocolate Thunder 20 mg TPE FD', type: 'FD', strain: 'Chocolate Thunder'),
      ], 'tpe');
      final got = {for (final s in sm['strains'] as List) (s as Map)['name']: s['sizes']};
      expect(got, {
        'Chocolate': {'booster': 3},
        'Gummy': {'micro': 2},
        'Honey': {'booster': 1},
        'Avery': {'10': 1},
        'Chocolate Thunder': {'20': 1},
      });
    });

    test('Microdose below 3 mg, Booster from 3 mg; the name first, else mg per unit; none is other', () {
      String key(String desc, {num? mg}) => stockRowSizeKey(row(1, desc, type: 'CH', mg: mg), 'tpe');
      expect([key('x 2.99 mg'), key('x 3 mg'), key('x 3.01 mg'), key('bar', mg: 2.5), key('bar', mg: 40), key('bar'), key('x 2 mg', mg: 150)],
          ['micro', 'booster', 'booster', 'micro', 'booster', 'other', 'micro']);
    });

    test('which sizes a par or order row takes', () {
      expect(stockSizesFor('chocolate'), [-1, -2, 0]);
      expect(stockSizesFor('Bluey'), [25, 20, 15, 10, 5, 0]);
      expect([stockSizeWord(-1), stockSizeWord(-2), stockSizeWord(0), stockSizeWord(25)], ['Booster', 'Microdose', 'Other', '25 mg']);
      expect([stockProductWord('gummy'), stockProductCode('Gummy'), stockProductCode('Bluey')], ['Gummy', 'GM', null]);
    });

    test('the combined row takes the strain sizes, under any spelling', () {
      expect(stockSizesFor(stockAllStrains), [25, 20, 15, 10, 5, 0]);
      expect(stockIsAll('all  STRAINS '), isTrue);
      expect(stockIsAll('All strain'), isFalse);
      expect(stockIsAll(''), isFalse);
    });

    test('a par level with no size is in no column', () {
      expect(ParLevel.fromJson(const {'strain': 'Chocolate', 'par': 3}).size, isNot(isIn(stockParColumns)));
    });
  });
}
