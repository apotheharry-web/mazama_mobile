// SM-25: why a sale line is refused when the state's inventory is read again just before sending
// (sellability.dart saleLineRefusal), held to the cases the server's sale worker computed
// (../mazama_modules/selling/gen.py -> salejobs.line_refusal), vendored here at
// assets/shared/selling/vectors/sale_check.json; and the age past which the phone reads again
// (rules.yaml sale_check.recheck_after_minutes, SM-D20: 5 minutes).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/resilience_options.dart';
import 'package:mazama_mobile/sellability.dart';
import 'package:yaml/yaml.dart';

final _cases = jsonDecode(File('assets/shared/selling/vectors/sale_check.json').readAsStringSync()) as Map<String, Object?>;
final _rules =
    (loadYaml(File('assets/shared/selling/rules/rules.yaml').readAsStringSync()) as YamlMap)['sale_check'] as YamlMap;

void main() {
  test('stock older than the shared limit is read again before a sale', () {
    expect(defaultStockRecheckAge, Duration(minutes: _rules['recheck_after_minutes'] as int));
    expect(const ResilienceOptions().stockRecheckAge, defaultStockRecheckAge);
  });

  final cases = (_cases['cases'] as List).cast<Map<String, Object?>>();
  test('there are enough cases', () => expect(cases.length, greaterThanOrEqualTo(8)));
  for (final c in cases) {
    test(c['name'] as String, () {
      final record = c['record'] == null ? null : Map<String, Object?>.from(c['record'] as Map);
      expect(saleLineRefusal(record, c['guid'] as String, c['qty'] as int), c['reason']);
    });
  }
}
