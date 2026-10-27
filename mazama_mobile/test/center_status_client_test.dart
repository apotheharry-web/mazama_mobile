// SM-16: the phone takes a cart's settings (tax %, agreement split, units per line, cart life) from the server's
// /p/center-status reply, and falls back to its vendored copy of ../mazama_modules/selling/rules.yaml
// (assets/shared/selling/rules/rules.yaml) when the server can't be asked or is too old to send them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/center_status_client.dart';
import 'package:yaml/yaml.dart';

final _rules = (loadYaml(File('assets/shared/selling/rules/rules.yaml').readAsStringSync()) as YamlMap)['cart'] as YamlMap;
final _example = File('assets/shared/api/examples/center_status.response.json').readAsStringSync();

http.Client _answering(String body, [int status = 200]) => http_testing.MockClient((req) async => http.Response(body, status));

void main() {
  test('the fallback is the shared rules', () {
    const f = CartSettings.fallback;
    expect([f.minutes, f.taxPercent, f.agreementEdible, f.agreementDried, f.dedupeSeconds, f.maxUnitsPerLine], [
      _rules['minutes'], _rules['tax_percent'], _rules['agreement_edible'], _rules['agreement_dried'],
      _rules['dedupe_seconds'], _rules['max_units_per_line'],
    ]);
  });

  test("reads the server's live cart settings from the example reply", () async {
    final s = await fetchCenterStatus(225, client: _answering(_example));
    expect(s.configured, isTrue);
    expect(s.cart.taxPercent, 15);
    expect(s.cart.maxUnitsPerLine, 999);
    expect(s.mazamaLicenses, ['mf-1e72fc8f']); // SP-R8
  });

  test("Mazama's licenses come lower-case and sorted; an older server sends none", () async {
    final s = await fetchCenterStatus(225,
        client: _answering(jsonEncode({'configured': true, 'mazamaLicenses': ['MF-b', 'mf-a', 'mf-a', 7, ' ']})));
    expect(s.mazamaLicenses, ['mf-a', 'mf-b']);
    expect((await fetchCenterStatus(225, client: _answering(jsonEncode({'configured': true})))).mazamaLicenses, isEmpty);
  });

  test('values the server sends win over the fallback', () async {
    final body = jsonEncode({
      'configured': false,
      'cart': {'minutes': 60, 'tax_percent': 10, 'agreement_edible': 1, 'agreement_dried': 2, 'dedupe_seconds': 5, 'max_units_per_line': 3},
    });
    final s = await fetchCenterStatus(225, client: _answering(body));
    expect(s.configured, isFalse);
    expect([s.cart.minutes, s.cart.taxPercent, s.cart.agreementEdible, s.cart.agreementDried, s.cart.dedupeSeconds, s.cart.maxUnitsPerLine],
        [60, 10, 1, 2, 5, 3]);
  });

  test('a server too old to send the cart settings gets the fallback, and one odd value falls back alone', () async {
    expect((await fetchCenterStatus(225, client: _answering(jsonEncode({'configured': true})))).cart.taxPercent,
        CartSettings.fallback.taxPercent);
    final s = await fetchCenterStatus(225, client: _answering(jsonEncode({'configured': true, 'cart': {'tax_percent': 'lots', 'minutes': 30}})));
    expect([s.cart.taxPercent, s.cart.minutes], [CartSettings.fallback.taxPercent, 30]);
  });

  test('a failed request is a CenterStatusError (the caller then uses the fallback)', () async {
    await expectLater(fetchCenterStatus(225, client: _answering('{"detail": "x"}', 500)), throwsA(isA<CenterStatusError>()));
  });
}
