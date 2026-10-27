// SL-R18: the client for GET /p/flows/hosts (login_hosts_client.dart). The example reply it is held to is
// ../mazama_modules/api/examples/login_hosts.response.json (vendored at assets/shared/api/examples/), signed with the
// shared vectors' TEST key, which these tests inject; the app verifies with its bundled signing.pub.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/login_hosts_client.dart';

import 'host_list_signing.dart';

Map<String, Object?> _example() =>
    jsonDecode(File('assets/shared/api/examples/login_hosts.response.json').readAsStringSync()) as Map<String, Object?>;

http.Client _answer(Object? body, {int status = 200}) =>
    http_testing.MockClient((req) async => http.Response.bytes(utf8.encode(body is String ? body : jsonEncode(body)), status));

void main() {
  // fetchLoginHosts without an injected key reads the bundled signing.pub through rootBundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('asks C18 with the app key and reads the example reply, which verifies under the TEST key', () async {
    final example = _example();
    final seen = <http.Request>[];
    final client = http_testing.MockClient((req) async {
      seen.add(req);
      return http.Response.bytes(utf8.encode(jsonEncode(example)), 200);
    });
    final got = await fetchLoginHosts(client: client, publicKey: testPublicKey);
    expect(got, isNotNull);
    expect(got!.version, example['version']);
    expect(got.text, example['list']);
    expect(got.signature, example['signature']);
    expect(got.hosts, ['login.example.gov']);
    final req = seen.single;
    expect(req.method, 'GET');
    expect(req.url.toString(), '$apiBaseUrl${loginHostsPath()}');
    expect(req.url.queryParameters, isEmpty);
    for (final h in appApiKeyHeaders.entries) {
      expect(req.headers[h.key.toLowerCase()], h.value);
    }
  });

  test('requestLoginHosts hands the reply over as sent, unverified', () async {
    final example = _example();
    final got = await requestLoginHosts(client: _answer(example));
    expect((got.version, got.list, got.signature), (example['version'], example['list'], example['signature']));
  });

  test('no list on the server: all null from requestLoginHosts, null from fetchLoginHosts', () async {
    const none = {'version': null, 'list': null, 'signature': null};
    final got = await requestLoginHosts(client: _answer(none));
    expect((got.version, got.list, got.signature), (null, null, null));
    expect(await fetchLoginHosts(client: _answer(none), publicKey: testPublicKey), isNull);
  });

  test("the bundled key (the owner's) doesn't verify a list signed with the TEST key", () async {
    expect(File('assets/signing/signing.pub').readAsStringSync().trim(), isNot(testPublicKey));
    expect(await fetchLoginHosts(client: _answer(_example())), isNull);
  });

  test('a list signed by another key, or changed after signing, gives null', () async {
    expect(await fetchLoginHosts(client: _answer(_example()), publicKey: otherPublicKey), isNull);
    final changed = {..._example(), 'list': (_example()['list'] as String).replaceFirst('login', 'logon')};
    expect(await fetchLoginHosts(client: _answer(changed), publicKey: testPublicKey), isNull);
  });

  test("a reply whose version isn't the list's own gives null", () async {
    final other = {..._example(), 'version': '2030-01-01.1'};
    expect(await fetchLoginHosts(client: _answer(other), publicKey: testPublicKey), isNull);
  });

  test('a signed list that breaks the text rule gives null', () async {
    const text = '{"version": "2026-11-01.1", "hosts": ["*.example.gov"]}';
    final reply = {'version': '2026-11-01.1', 'list': text, 'signature': await testSignature(text)};
    expect(await fetchLoginHosts(client: _answer(reply), publicKey: testPublicKey), isNull);
  });

  test('a newly signed list with two hosts is read in its order', () async {
    final text = hostListText('2026-11-02.1', ['b.example.gov', 'a.example.gov']);
    final reply = {'version': '2026-11-02.1', 'list': text, 'signature': await testSignature(text)};
    final got = await fetchLoginHosts(client: _answer(reply), publicKey: testPublicKey);
    expect(got?.hosts, ['b.example.gov', 'a.example.gov']);
    expect(got?.extra, ['a.example.gov', 'b.example.gov']);
  });

  final failures = <String, http.Client>{
    'a 404': _answer({'detail': 'no'}, status: 404),
    'a 500': _answer({'detail': 'broken'}, status: 500),
    'a 201': _answer(_example(), status: 201),
    'a reply that is not JSON': _answer('<html>proxy error</html>'),
    'a JSON list': _answer([1, 2]),
    'a reply with some fields null': _answer({..._example(), 'signature': null}),
    'a reply with a number for the list': _answer({..._example(), 'list': 5}),
    'a reply without fields': _answer(<String, Object?>{'version': '2026-11-01.1'}),
    'a connection failure': http_testing.MockClient((req) async => throw const SocketException('no route')),
  };
  for (final e in failures.entries) {
    test('${e.key} gives null', () async {
      expect(await fetchLoginHosts(client: e.value, publicKey: testPublicKey), isNull);
    });
    test('${e.key} is a LoginHostsError from requestLoginHosts', () async {
      await expectLater(requestLoginHosts(client: e.value), throwsA(isA<LoginHostsError>()));
    });
  }

  test('no answer within the timeout gives null', () async {
    final never = Completer<http.Response>();
    final client = http_testing.MockClient((req) => never.future);
    final started = DateTime.now();
    expect(await fetchLoginHosts(client: client, timeout: const Duration(milliseconds: 50), publicKey: testPublicKey),
        isNull);
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 5)));
  });
}
