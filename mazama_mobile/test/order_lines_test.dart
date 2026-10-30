// specs/core row 9: the order form's lines are the shared core's (stock.order_form), held to the shared cases
// (assets/shared/stock/order_form/cases.json, vendored from mazama_modules/stock/order_form/) and to the Dart the page
// ran before the move (test/support/old_order_form.dart), over those cases and a generated grid.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/order_lines.dart';
import 'package:mazama_mobile/stock_summary.dart';

import 'support/core.dart';
import 'support/old_order_form.dart';

List<ParLevel> _levels(Object? json) => [
      for (final l in json as List)
        ParLevel(strain: (l as Map)['strain'] as String, size: l['size'] as int, par: l['par'] as int?),
    ];

List<(String, int, int)> _core(List<ParLevel> levels) =>
    [for (final l in orderFormLines(levels, core: loadTestCore())) (l.strain, l.size, l.par)];

void main() {
  final cases = ((jsonDecode(File('assets/shared/stock/order_form/cases.json').readAsStringSync()) as Map)['cases'] as List)
      .cast<Map<String, Object?>>();

  test('there are cases', () => expect(cases.length, greaterThanOrEqualTo(10)));

  for (final c in cases) {
    test('case: ${c['name']}', () {
      final levels = _levels(c['levels']);
      final want = [for (final l in c['lines'] as List) ((l as Map)['strain'] as String, l['size'] as int, l['par'] as int)];
      expect(oldOrderFormLines(levels), want, reason: 'the cases are what the old Dart built');
      expect(_core(levels), want);
    });
  }

  test('the core builds what the old Dart built, over a generated grid', () {
    const names = ['Avery', 'avery', 'Bluey', ' bluey ', 'Zeta', 'Éclair', 'ábc', 'All strains', 'all  STRAINS',
        'Chocolate', ' gummy', 'gummy', 'HONEY', '\uFEFFhoney', 'x\uFEFF', '', ' ', 'Golden Teacher'];
    const sizes = [25, 20, 15, 10, 5, 0, -1, -2, 7];
    final rnd = Random(20261030);
    for (var n = 0; n < 400; n++) {
      final levels = [
        for (var i = rnd.nextInt(12); i > 0; i--)
          ParLevel(strain: names[rnd.nextInt(names.length)], size: sizes[rnd.nextInt(sizes.length)],
              par: rnd.nextInt(6) == 0 ? null : rnd.nextInt(30)),
      ];
      expect(_core(levels), oldOrderFormLines(levels), reason: '${[for (final l in levels) l.toJson()]}');
    }
  });

  test('a reply that isn\'t lines is an error, not an empty form', () {
    expect(() => orderFormLines(const [], core: _OddCore()), throwsA(isA<Exception>()));
  });
}

class _OddCore implements CoreFunctions {
  @override
  List<Object?> stockOrderForm(Map<String, Object?> input) => [
        {'strain': 'Avery', 'size': '25', 'par': 1},
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
