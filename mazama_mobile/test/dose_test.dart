// SM-04: the mg TPE of a unit where the phone works it out itself (the state-only path, and a lab result's TPE from
// the server), held to the vectors the server's own Python computed (../mazama_modules/dose/gen.py ->
// mazama_sales/dose.py), from this app's vendored copy (assets/shared/dose/vectors/, tool/sync_flows.sh). Owner
// decisions SM-D16 (the TPE, else the state's psilocybin) and SM-D17 (ceil(x - 1e-9)).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/dose.dart';

List<Map<String, Object?>> _vectors(String name) =>
    (jsonDecode(File('assets/shared/dose/vectors/$name').readAsStringSync()) as List).cast<Map<String, Object?>>();

double? _d(Object? v) => (v as num?)?.toDouble();

void main() {
  test('every unit_mg vector', () {
    final cases = _vectors('unit_mg.json');
    expect(cases.length, greaterThanOrEqualTo(12));
    for (final c in cases) {
      final w = _d(c['weight_per_unit'])!, s = _d(c['state_psilocybin']), t = _d(c['tpe']);
      expect(tpePerGram(s, t), _d(c['tpe_per_g']), reason: '${c['name']}');
      expect(unitTpeMg(w, s, t), c['tpe_mg'], reason: '${c['name']}');
    }
  });

  test('every ceil_mg vector', () {
    for (final c in _vectors('ceil_mg.json')) {
      expect(ceilMg(_d(c['x'])!), c['mg'], reason: '${c['x']}');
    }
  });
}
