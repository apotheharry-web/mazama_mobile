// SM-15 (SM-D11): the phone's per-sale raw psilocybin cap and session-length table are the shared rules
// (../mazama_modules/selling/rules.yaml "dose", vendored at assets/shared/selling/rules/), and give the same answers as
// the server's selling.py for every case in selling/vectors/dose_limits.json (vendored at assets/shared/selling/vectors/).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_pricing.dart';
import 'package:yaml/yaml.dart';

final _rules = (loadYaml(File('assets/shared/selling/rules/rules.yaml').readAsStringSync()) as YamlMap)['dose'] as YamlMap;
final _cases = (jsonDecode(File('assets/shared/selling/vectors/dose_limits.json').readAsStringSync()) as List).cast<Map<String, Object?>>();

double _num(Object? v) => v == null ? 0 : (v as num).toDouble();

void main() {
  test('the cap and the session table are the shared rules', () {
    expect(maxAnalyteMgPerSale, (_rules['max_psilocybin_mg_per_sale'] as num).toDouble());
    final rows = (_rules['session_minutes'] as YamlList).cast<YamlMap>();
    expect(sessionTable.length, rows.length);
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final limit = (r['below_mg'] ?? r['up_to_mg']) as num;
      expect(sessionTable[i].limitMg, limit.toDouble(), reason: 'row $i');
      expect(sessionTable[i].inclusive, r.containsKey('up_to_mg'), reason: 'row $i');
      expect(sessionTable[i].duration, Duration(minutes: r['minutes'] as int), reason: 'row $i');
    }
  });

  test('there are cases', () => expect(_cases.length, greaterThanOrEqualTo(15)));
  for (final c in _cases) {
    test(c['name'] as String, () {
      final lines = [
        for (final ln in (c['lines'] as List).cast<Map<String, Object?>>())
          CartPricingLine(
            group: 'A',
            mgTpe: 0,
            qty: ln['qty'] as int,
            analyteMgPerUnit: _num((ln['record'] as Map)['weightPerUnit']) * _num((ln['record'] as Map)['analyteWeight']),
          ),
      ];
      final total = totalAnalyteMg(lines);
      expect(total, closeTo(double.parse(c['psilocybin_mg'] as String), 1e-9));
      expect(analyteCapError(lines) == null, c['allowed']);
      expect(minSessionDuration(total)?.inMinutes, c['session_minutes']);
    });
  }
}
