// SM-14: pricing a whole cart (cart_pricing.dart priceWholeCart, groupOf), held to the cases the server's own Python
// computed (../mazama_modules/selling/gen.py -> pricing.py price_cart), vendored here at
// assets/shared/selling/vectors/cart.json, and the "pricing_modes" rules in assets/shared/selling/rules/rules.yaml.
// SM-D26: per-mg tax goes on the rate; SM-D27: every unit of a line costs the same; SM-D28: a new cart starts in
// "total".
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_pricing.dart';
import 'package:yaml/yaml.dart';

final _cases = jsonDecode(File('assets/shared/selling/vectors/cart.json').readAsStringSync()) as Map<String, Object?>;
final _rules =
    (loadYaml(File('assets/shared/selling/rules/rules.yaml').readAsStringSync()) as YamlMap)['pricing_modes'] as YamlMap;

CartPricingMode _mode(String m) => switch (m) {
      'total' => CartPricingMode.total,
      'per_mg' => CartPricingMode.perMg,
      _ => CartPricingMode.each,
    };

void main() {
  test('a new cart starts in the shared default mode, and the group words are the shared ones', () {
    expect(_rules['default'], 'total');
    expect(defaultCartPricingMode, _mode(_rules['default'] as String));
    expect(groupAWords, (_rules['group_a_words'] as YamlList).cast<String>().toList());
  });

  for (final c in (_cases['groups'] as List).cast<Map<String, Object?>>()) {
    test('"${c['product_type']}" is in group ${c['group']}', () {
      expect(groupOf(c['product_type'] as String), c['group']);
    });
  }

  final cases = (_cases['cases'] as List).cast<Map<String, Object?>>();
  test('there are enough cases', () => expect(cases.length, greaterThanOrEqualTo(15)));
  for (final c in cases) {
    test(c['name'] as String, () {
      final lines = [
        for (final l in (c['lines'] as List).cast<Map<String, Object?>>())
          CartPricingLine(group: l['group'] as String, mgTpe: (l['mg'] as num).toDouble(), qty: l['qty'] as int),
      ];
      final agreement = (c['agreement'] as List).cast<int>();
      final r = priceWholeCart(
        mode: _mode(c['mode'] as String),
        lines: lines,
        totalText: c['total'] as String,
        perMgText: c['per_mg'] as String,
        tax: c['tax'] == true ? CartTaxMode.addPercent : CartTaxMode.included,
        taxPercent: c['tax_percent'] as int,
        agreementEdible: agreement[0],
        agreementDried: agreement[1],
      );
      expect(r.errorCode, c['error']);
      if (c['error'] == null) {
        final each = (c['each'] as List).cast<int>();
        expect(r.priceCentsEach, each);
        var total = 0;
        for (var i = 0; i < lines.length; i++) {
          total += each[i] * lines[i].qty;
        }
        expect(r.grandTotalCents, total);
      } else {
        expect(r.priceCentsEach, isNull);
      }
      if (c['error'] == 'no_mg') {
        final lineErrors = (c['line_errors'] as List);
        expect(r.unpricedLines, [for (var i = 0; i < lineErrors.length; i++) if (lineErrors[i] != null) i]);
      }
    });
  }
}
