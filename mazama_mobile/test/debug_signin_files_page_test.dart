// The debug "Sign-in files" page (debug_signin_files_page.dart): the bundled copies are read from disk through an
// injected bundle, the server's replies are injected fakes, the hosted folder is a MockClient, the signatures are
// checked with the shared vectors' TEST key (host_list_signing.dart), and "Try" runs against test/flow/fake_state.dart's
// FakeState. The only folder anything could be written to is a temp one, checked afterwards.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/browser_login_spec.dart';
import 'package:mazama_mobile/debug_signin_files_page.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_hosts_client.dart';
import 'package:mazama_mobile/login_hosts_store.dart';
import 'package:mazama_mobile/login_spec_client.dart';
import 'package:mazama_mobile/login_spec_store.dart';

import 'flow/fake_state.dart';
import 'host_list_signing.dart';

final String _loginText = File(bundledLoginSpecAsset).readAsStringSync();
final String _browserText = File(browserLoginSpecAsset).readAsStringSync();

/// login.yaml at a later spec_version than the bundled one.
final String _newerLogin = _loginText.replaceFirst(RegExp(r'spec_version: "[^"]+"'), 'spec_version: "2099-01-01.1"');

/// [_newerLogin] with the password put in the authorize request's query: not a usable sign-in spec (claim 1).
final String _passwordInUrl =
    _newerLogin.replaceFirst('        nonce: "{{nonce}}"\n', '        nonce: "{{nonce}}"\n        pw: "{{password}}"\n');

final String _hostsText = hostListText('2026-10-25.1', ['psilocybin.oregon.gov']);

const _base = 'https://files.example.test/owner/repo/main/';

late String _loginSig;
late String _browserSig;
late String _hostsSig;

/// An asset bundle holding the two bundled specs, read from disk.
class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final text = switch (key) {
      bundledLoginSpecAsset => _loginText,
      browserLoginSpecAsset => _browserText,
      _ => throw StateError('no asset $key'),
    };
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

/// What the page asked for.
class _Spies {
  var serverSpecs = 0;
  var serverBrowserSpecs = 0;
  var serverHosts = 0;
  final hosted = <String>[];
}

/// The hosted folder: [files] (name -> text) under [_base]'s path; anything else 404.
http.Client _hostedFolder(Map<String, String> files, _Spies spies) => http_testing.MockClient((req) async {
      spies.hosted.add(req.url.toString());
      final name = req.url.toString().startsWith(_base) ? req.url.toString().substring(_base.length) : null;
      final text = name == null ? null : files[name];
      return text == null ? http.Response('not here', 404) : http.Response.bytes(utf8.encode(text), 200);
    });

FetchedSpec _fetched(String yaml, String source) => FetchedSpec(FlowSpec.fromYaml(yaml), yaml, source);

Widget _page(
  Directory dir,
  _Spies spies, {
  Map<String, String> hostedFiles = const {},
  String? loginSource,
  String? browserSource,
  LoginHostsReply serverHosts = const LoginHostsReply(null, null, null),
  String? publicKey,
  http.Client Function()? stateClient,
  Future<String?> Function(String url, String until)? browse,
  Key? key,
}) {
  return MaterialApp(
    home: DebugSigninFilesPage(
      key: key,
      addressStore: DebugSigninAddressStore(dataDir: () => dir),
      fetchServerSpec: (hosts) async {
        spies.serverSpecs += 1;
        if (loginSource == null) throw LoginSpecError('the server has none');
        return _fetched(_loginText, loginSource);
      },
      fetchServerBrowserSpec: (hosts) async {
        spies.serverBrowserSpecs += 1;
        if (browserSource == null) throw LoginSpecError('the server has none');
        return _fetched(_browserText, browserSource);
      },
      fetchServerHosts: () async {
        spies.serverHosts += 1;
        return serverHosts;
      },
      hostedClient: () => _hostedFolder(hostedFiles, spies),
      stateClient: stateClient ?? () => http_testing.MockClient((req) async => fail('nothing may reach the state')),
      bundle: _Bundle(),
      publicKey: publicKey ?? testPublicKey,
      ask: (prompt, secret) async => fail('no question was expected'),
      browse: browse ?? (url, until) async => fail('the state page was not expected'),
    ),
  );
}

Future<void> _fetch(WidgetTester tester, {String base = _base}) async {
  await tester.enterText(find.byKey(const ValueKey('hosted-base')), base);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('fetch')));
  await tester.pumpAndSettle();
}

Finder _inCard(String file, String id, Finder finder) =>
    find.descendant(of: find.byKey(ValueKey('copy-$file-$id')), matching: finder);

void main() {
  group('fetchHostedFile', () {
    final url = Uri.parse('https://files.example.org/x/login.yaml');

    test('a redirect is not followed', () async {
      var requests = 0;
      final client = http_testing.MockClient.streaming((req, body) async {
        requests += 1;
        return http.StreamedResponse(const Stream.empty(), 302, headers: {'location': 'http://elsewhere.example/x'});
      });
      final got = await fetchHostedFile(client, url);
      expect(got.text, isNull);
      expect(got.error, contains('redirected'));
      expect(requests, 1);
    });

    test('a download that trickles past the time limit gives up', () async {
      final client = http_testing.MockClient.streaming((req, body) async => http.StreamedResponse(
          Stream.periodic(const Duration(milliseconds: 40), (_) => [0x61]).take(100), 200));
      final got = await fetchHostedFile(client, url, timeout: const Duration(milliseconds: 200));
      expect(got.text, isNull);
      expect(got.error, contains('no answer'));
    });
  });

  late Directory dir;

  setUpAll(() async {
    _loginSig = await testSignature(_newerLogin);
    _browserSig = await testSignature(_browserText);
    _hostsSig = await testSignature(_hostsText);
  });

  setUp(() => dir = Directory.systemTemp.createTempSync('debug_signin_files_'));
  tearDown(() {
    useLoginHosts(null);
    dir.deleteSync(recursive: true);
  });

  group('hostedBaseUri', () {
    test('takes an https folder and ends it with a slash', () {
      expect(hostedBaseUri(' https://files.example.test/a/b ').toString(), 'https://files.example.test/a/b/');
      expect(hostedBaseUri('https://files.example.test/a/').toString(), 'https://files.example.test/a/');
    });

    test('refuses anything but https, and a query, fragment or user info', () {
      expect(hostedBaseUri(''), isNull);
      expect(hostedBaseUri('http://files.example.test/a/'), isNull);
      expect(hostedBaseUri('https://files.example.test/a/?x=1'), isNull);
      expect(hostedBaseUri('https://files.example.test/a/#x'), isNull);
      expect(hostedBaseUri('https://me@files.example.test/a/'), isNull);
    });
  });

  testWidgets('fetch shows the bundled, server and hosted copies with source, version and verified signatures',
      (tester) async {
    final spies = _Spies();
    await tester.pumpWidget(_page(dir, spies,
        hostedFiles: {
          'login.yaml': _newerLogin,
          'login.yaml.sig': _loginSig,
          'login_browser.yaml': _browserText,
          'login_browser.yaml.sig': _browserSig,
          'hosts.json': _hostsText,
          'hosts.json.sig': _hostsSig,
        },
        loginSource: 'hosted',
        browserSource: 'server',
        serverHosts: LoginHostsReply('2026-10-25.1', _hostsText, _hostsSig)));
    await _fetch(tester);

    expect(spies.serverSpecs, 1);
    expect(spies.serverBrowserSpecs, 1);
    expect(spies.serverHosts, 1);
    expect(spies.hosted, [
      '${_base}hosts.json',
      '${_base}hosts.json.sig',
      '${_base}login.yaml',
      '${_base}login.yaml.sig',
      '${_base}login_browser.yaml',
      '${_base}login_browser.yaml.sig',
    ]);

    // the server's copies: where the server got them, and the signature line that goes with that
    expect(_inCard('login', 'server', find.textContaining('source: hosted')), findsOneWidget);
    expect(_inCard('login', 'server', find.text('signature: the server verified it')), findsOneWidget);
    expect(_inCard('browser', 'server', find.textContaining('source: server')), findsOneWidget);
    expect(_inCard('browser', 'server', find.text("signature: the server's own copy (needs no signature)")),
        findsOneWidget);

    // the hosted copies (and the server's host list) verify under the TEST key
    const verified = "signature: verified with this build's key";
    expect(_inCard('login', 'hosted', find.text(verified)), findsOneWidget);
    expect(_inCard('browser', 'hosted', find.text(verified)), findsOneWidget);
    expect(_inCard('hosts', 'hosted', find.text(verified)), findsOneWidget);
    expect(_inCard('hosts', 'server', find.text(verified)), findsOneWidget);

    // versions, and how they compare
    expect(_inCard('login', 'hosted', find.text('spec_version 2099-01-01.1')), findsOneWidget);
    final bundledVersion = FlowSpec.fromYaml(_loginText).specVersion;
    expect(_inCard('login', 'hosted', find.text('newer than the bundled copy ($bundledVersion)')), findsOneWidget);
    expect(_inCard('login', 'server', find.text('same as the bundled copy ($bundledVersion)')), findsOneWidget);
    expect(_inCard('login', 'bundled', find.text('older than the hosted copy (2099-01-01.1)')), findsOneWidget);
    expect(_inCard('login', 'hosted', find.text('usable as served (login)')), findsOneWidget);
    expect(_inCard('browser', 'bundled', find.text('usable as served (browser)')), findsOneWidget);
    expect(_inCard('hosts', 'hosted', find.text('parses and follows the host list rule')), findsOneWidget);
    expect(_inCard('hosts', 'hosted', find.text('version 2026-10-25.1')), findsOneWidget);
    expect(_inCard('hosts', 'hosted', find.text('hosts: psilocybin.oregon.gov')), findsOneWidget);
    expect(find.textContaining('FAIL:'), findsNothing);

    // a verified list can be ticked for a try
    final tick = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('use-hosts-hosted')));
    expect(tick.onChanged, isNotNull);
  });

  testWidgets('a tampered copy, a missing .sig and an unusable spec each show their failing check', (tester) async {
    final spies = _Spies();
    await tester.pumpWidget(_page(dir, spies, hostedFiles: {
      'login.yaml': _passwordInUrl, // signed as _newerLogin: the signature no longer matches
      'login.yaml.sig': _loginSig,
      'login_browser.yaml': _browserText, // no .sig
      'hosts.json': _hostsText,
      'hosts.json.sig': _loginSig, // another file's signature
    }));
    await _fetch(tester);

    expect(_inCard('login', 'hosted', find.text("FAIL: signature: does not verify with this build's key")),
        findsOneWidget);
    expect(_inCard('login', 'hosted', find.text('FAIL: not a usable sign-in spec as served (login)')), findsOneWidget);
    expect(_inCard('login', 'hosted', find.text('parses')), findsOneWidget);
    expect(_inCard('browser', 'hosted', find.text('FAIL: signature: no .sig file (HTTP 404)')), findsOneWidget);
    expect(_inCard('hosts', 'hosted', find.text("FAIL: signature: does not verify with this build's key")),
        findsOneWidget);
    // a list that didn't verify can't be ticked
    final tick = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('use-hosts-hosted')));
    expect(tick.onChanged, isNull);
    // the server had nothing: said, not a crash
    expect(_inCard('login', 'server', find.text('the server did not give one: the server has none')), findsOneWidget);
    expect(_inCard('hosts', 'server', find.text('the server has no host list')), findsOneWidget);
  });

  testWidgets('with no key in this build, the signature lines say so', (tester) async {
    final spies = _Spies();
    await tester.pumpWidget(_page(dir, spies,
        publicKey: 'none\n',
        hostedFiles: {'login.yaml': _newerLogin, 'login.yaml.sig': _loginSig}));
    await _fetch(tester);
    expect(_inCard('login', 'hosted', find.text('FAIL: signature: no key in this build')), findsOneWidget);
    expect(find.text("signature: verified with this build's key"), findsNothing);
  });

  testWidgets('Try signs in with a copy through the state and saves nothing, reports nothing', (tester) async {
    final spies = _Spies();
    final fake = FakeState();
    await tester.pumpWidget(_page(dir, spies, loginSource: 'server', stateClient: fake.client));
    await _fetch(tester); // nothing is hosted there: every hosted GET is a 404
    final hostedBefore = spies.hosted.length;

    final tryButton = find.byKey(const ValueKey('try-login-server'));
    await tester.ensureVisible(tryButton);
    await tester.pumpAndSettle();
    await tester.tap(tryButton);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('try-email')), fakeEmail);
    await tester.enterText(find.byKey(const ValueKey('try-password')), fakePassword);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('try-go')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('try-result-login-server')), findsOneWidget);
    expect(find.text('Signed in, token expires in 60 minutes. Nothing was saved.'), findsOneWidget);
    expect(fake.logins, 1);
    expect(find.textContaining('ACCESS-'), findsNothing); // never the token
    // nothing saved (no session, spec or host list, nothing put in use): only the typed address is on disk
    expect(dir.listSync().map((f) => f.uri.pathSegments.last).toList(), ['debug_signin_files.json']);
    expect(loginHostsInUse, isNull);
    // and nothing else was asked for: no report, no refetch
    expect(spies.hosted.length, hostedBefore);
    expect(spies.serverSpecs, 1);
  });

  testWidgets('Try with the state page signs in with the browser copy, nothing saved', (tester) async {
    final spies = _Spies();
    final fake = FakeState();
    final opened = <String>[];
    await tester.pumpWidget(_page(dir, spies, stateClient: fake.client, browse: (url, until) async {
      opened.add(url);
      expect(until, site);
      final q = Uri.parse(url).queryParameters;
      fake.codes['CODE1'] = q['code_challenge']!;
      return '$site#code=CODE1&state=${q['state']}';
    }));
    await _fetch(tester);

    final tryButton = find.byKey(const ValueKey('try-browser-bundled'));
    await tester.ensureVisible(tryButton);
    await tester.pumpAndSettle();
    await tester.tap(tryButton);
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(find.text('Signed in, token expires in 60 minutes. Nothing was saved.'), findsOneWidget);
    expect(dir.listSync().map((f) => f.uri.pathSegments.last).toList(), ['debug_signin_files.json']);
  });

  testWidgets('a failed try shows the step and reason, scrubbed', (tester) async {
    final spies = _Spies();
    final fake = FakeState()..rejectLogin = true;
    await tester.pumpWidget(_page(dir, spies, loginSource: 'server', stateClient: fake.client));
    await _fetch(tester);
    final tryButton = find.byKey(const ValueKey('try-login-bundled'));
    await tester.ensureVisible(tryButton);
    await tester.pumpAndSettle();
    await tester.tap(tryButton);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('try-email')), fakeEmail);
    await tester.enterText(find.byKey(const ValueKey('try-password')), fakePassword);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('try-go')));
    await tester.pumpAndSettle();

    final result = tester.widget<Text>(find.byKey(const ValueKey('try-result-login-bundled'))).data!;
    expect(result, startsWith('Failed at step '));
    expect(result, contains('reason credentials'));
    expect(result, isNot(contains(fakePassword)));
  });

  testWidgets('the hosted address is remembered; an http one is refused and not kept', (tester) async {
    final spies = _Spies();
    await tester.pumpWidget(_page(dir, spies, key: const ValueKey('first')));
    await _fetch(tester, base: 'https://files.example.test/owner/repo/main');
    await tester.pumpWidget(_page(dir, spies, key: const ValueKey('second')));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('hosted-base'))).controller!.text,
        'https://files.example.test/owner/repo/main/');

    await _fetch(tester, base: 'http://files.example.test/other/');
    expect(find.text('The hosted address must be an https address'), findsOneWidget);
    await tester.pumpWidget(_page(dir, spies, key: const ValueKey('third')));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('hosted-base'))).controller!.text,
        'https://files.example.test/owner/repo/main/');
  });
}
