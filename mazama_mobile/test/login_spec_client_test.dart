// SL-R9: the client for GET /p/flows/login (login_spec_client.dart). The example reply it is held to is
// ../mazama_modules/api/examples/login_spec.response.json, vendored at assets/shared/api/examples/. SL-R19: the same
// client for GET /p/flows/login_browser, held to login_browser_spec.response.json.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_spec_client.dart';

Map<String, Object?> _example() =>
    jsonDecode(File('assets/shared/api/examples/login_spec.response.json').readAsStringSync()) as Map<String, Object?>;

Map<String, Object?> _browserExample() => jsonDecode(File('assets/shared/api/examples/login_browser_spec.response.json')
    .readAsStringSync()) as Map<String, Object?>;

http.Client _answer(Object? body, {int status = 200}) =>
    http_testing.MockClient((req) async => http.Response(body is String ? body : jsonEncode(body), status));

void main() {
  test("asks for this app's format with the app key and reads the example reply", () async {
    final example = _example();
    final seen = <http.Request>[];
    final client = http_testing.MockClient((req) async {
      seen.add(req);
      return http.Response(jsonEncode(example), 200);
    });
    final got = await fetchLoginSpec(client: client);
    expect(got, isNotNull);
    expect(got!.yaml, example['yaml']);
    expect(got.source, example['source']);
    expect(got.spec.specVersion, example['specVersion']);
    final req = seen.single;
    expect(req.method, 'GET');
    expect(req.url.path, loginSpecPath());
    expect(req.url.queryParameters, {'format': '$supportedFlowFormat'});
    expect(supportedFlowFormat, 3);
    for (final h in appApiKeyHeaders.entries) {
      expect(req.headers[h.key.toLowerCase()], h.value);
    }
  });

  test('a hosted copy is reported as hosted', () async {
    final got = await fetchLoginSpec(client: _answer({..._example(), 'source': 'hosted'}));
    expect(got?.source, 'hosted');
  });

  final failures = <String, http.Client>{
    'a 404': _answer({'detail': 'no'}, status: 404),
    'a 500': _answer({'detail': 'broken'}, status: 500),
    'a 201': _answer(_example(), status: 201),
    'a reply that is not JSON': _answer('<html>proxy error</html>'),
    'a JSON list': _answer([1, 2]),
    'a reply without yaml': _answer({'specVersion': '2026-10-24.3', 'source': 'server'}),
    'an unknown source': _answer({..._example(), 'source': 'elsewhere'}),
    'a spec of a later format': _answer({..._example(), 'yaml': 'format: 4\n${_example()['yaml']}'
        .replaceFirst('format: 1\n', '')}),
    'a spec with a host the app does not talk to': _answer(
        {..._example(), 'yaml': (_example()['yaml'] as String).replaceAll('oregonpsilocybinprodb2c.b2clogin.com', 'evil.example.com')}),
    'a spec with a YAML alias': _answer({..._example(), 'yaml': '${_example()['yaml']}x: &a [1]\ny: *a\n'}),
    "a specVersion that is not the spec's own": _answer({..._example(), 'specVersion': '2030-01-01.1'}),
    'a connection failure': http_testing.MockClient((req) async => throw const SocketException('no route')),
  };
  for (final e in failures.entries) {
    test('${e.key} gives null', () async {
      expect(await fetchLoginSpec(client: e.value), isNull);
    });
    test('${e.key} is a LoginSpecError from requestLoginSpec', () async {
      await expectLater(requestLoginSpec(client: e.value), throwsA(isA<LoginSpecError>()));
    });
  }

  test('no answer within the timeout gives null', () async {
    final never = Completer<http.Response>();
    final client = http_testing.MockClient((req) => never.future);
    final started = DateTime.now();
    expect(await fetchLoginSpec(client: client, timeout: const Duration(milliseconds: 50)), isNull);
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 5)));
  });

  test('a spec at a host a fetched list adds is read only with those hosts given (SL-R18)', () async {
    final moved = {..._example(), 'yaml': (_example()['yaml'] as String).replaceAll('oregonpsilocybinprodb2c.b2clogin.com', 'login.example.gov')};
    expect(await fetchLoginSpec(client: _answer(moved)), isNull);
    final got = await fetchLoginSpec(client: _answer(moved), allowedHosts: [...defaultAllowedHosts, 'login.example.gov']);
    expect(got?.spec.specVersion, _example()['specVersion']);
  });

  test('the default timeout is 10 seconds', () => expect(loginSpecTimeout, const Duration(seconds: 10)));

  group('the browser sign-in spec (C19, SL-R19)', () {
    test("asks /p/flows/login_browser for this app's format with the app key and reads the example reply", () async {
      final example = _browserExample();
      final seen = <http.Request>[];
      final client = http_testing.MockClient((req) async {
        seen.add(req);
        return http.Response(jsonEncode(example), 200);
      });
      final got = await fetchBrowserLoginSpec(client: client);
      expect(got?.yaml, example['yaml']);
      expect(got?.spec.specVersion, example['specVersion']);
      expect(seen.single.url.path, loginBrowserSpecPath());
      expect(seen.single.url.queryParameters, {'format': '$supportedFlowFormat'});
      for (final h in appApiKeyHeaders.entries) {
        expect(seen.single.headers[h.key.toLowerCase()], h.value);
      }
    });

    test('a spec without an open_browser is not a browser spec', () async {
      expect(await fetchBrowserLoginSpec(client: _answer(_example())), isNull);
      await expectLater(requestBrowserLoginSpec(client: _answer(_example())), throwsA(isA<LoginSpecError>()));
    });

    test('a spec with an open_browser is never taken as the password sign-in', () async {
      expect(await fetchLoginSpec(client: _answer(_browserExample())), isNull);
    });

    test('an error reply gives null', () async {
      expect(await fetchBrowserLoginSpec(client: _answer({'detail': 'no'}, status: 503)), isNull);
    });

    test('a browser spec at a host a fetched list adds is read only with those hosts given', () async {
      final moved = {
        ..._browserExample(),
        'yaml': (_browserExample()['yaml'] as String).replaceAll('{{tenant}}.b2clogin.com', 'login.example.gov'),
      };
      expect(moved['yaml'], contains('login.example.gov'));
      expect(await fetchBrowserLoginSpec(client: _answer(moved)), isNull);
      final got =
          await fetchBrowserLoginSpec(client: _answer(moved), allowedHosts: [...defaultAllowedHosts, 'login.example.gov']);
      expect(got?.spec.specVersion, _browserExample()['specVersion']);
    });
  });
}
