// SM-13: the phone's price maths (pricing.dart, cart_pricing.dart shareTotal), held to the cases the server's own Python
// computed (../mazama_modules/selling/gen.py -> pricing.py), vendored here at assets/shared/selling/vectors/pricing.json,
// and the ceilings in ../mazama_modules/selling/rules.yaml (vendored at assets/shared/selling/rules/rules.yaml).
// SM-D9: a typed price is a plain decimal; SM-D10: a per-mg rate is whole cents.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_pricing.dart';
import 'package:mazama_mobile/pricing.dart';
import 'package:yaml/yaml.dart';

final _cases = jsonDecode(File('assets/shared/selling/vectors/pricing.json').readAsStringSync()) as Map<String, Object?>;
final _rules = (loadYaml(File('assets/shared/selling/rules/rules.yaml').readAsStringSync()) as YamlMap)['pricing'] as YamlMap;

List<Map<String, Object?>> _list(String name) => (_cases[name] as List).cast<Map<String, Object?>>();

void main() {
  test('the ceilings are the shared rules', () {
    expect(maxUnitCents, _rules['max_unit_cents']);
    expect(maxPerMgCents, _rules['max_per_mg_cents']);
    expect(maxTotalCents, (_rules['max_unit_cents'] as int) * (_rules['max_total_units'] as int));
  });

  for (final c in _list('to_cents')) {
    test('toCents("${c['text']}") is ${c['cents']}', () => expect(toCents(c['text'] as String), c['cents']));
  }
  for (final c in _list('total_to_cents')) {
    test('totalToCents("${c['text']}") is ${c['cents']}', () => expect(totalToCents(c['text'] as String), c['cents']));
  }
  for (final c in _list('per_mg_rate_to_cents')) {
    test('perMgRateToCents("${c['text']}") is ${c['cents']}', () => expect(perMgRateToCents(c['text'] as String), c['cents']));
  }
  for (final c in _list('per_mg_price')) {
    test('a ${c['rate_cents']}c/mg rate on ${c['mg']} mg is ${c['cents']}c', () {
      expect(perMgPriceCentsEach(c['rate_cents'] as int, double.parse(c['mg'] as String)), c['cents']);
    });
  }
  for (final c in _list('with_tax')) {
    test('${c['cents']}c plus ${c['percent']}% is ${c['result']}c', () {
      expect(withTax(c['cents'] as int, c['percent'] as int), c['result']);
    });
  }
  for (final c in _list('share_total')) {
    test('sharing ${c['total_cents']}c over ${c['weights']}', () {
      expect(shareTotal(c['total_cents'] as int, (c['weights'] as List).cast<int>()), c['parts']);
    });
  }
  for (final c in _list('money')) {
    test('money(${c['cents']}) is ${c['text']}', () => expect(money(c['cents'] as int), c['text']));
  }
}
