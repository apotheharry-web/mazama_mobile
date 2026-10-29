// SL-R19: after a sign-in on the state's page fails (not cancelled, not B2C's own refusal), SignInPage fetches the signed
// host list and the newest browser sign-in spec, retries once (the state's page opens again) when that spec is newer
// and a usable browser spec under the retry's hosts, and keeps the spec (login_browser_spec.yaml, apart from
// login_spec.yaml) and the list only after a session. The webview is an injected `browse` answering as the state's page
// would, the state system test/flow/fake_state.dart's FakeState through http.runWithClient; the fetches and stores are
// injected (lists signed with the shared vectors' TEST key), so nothing reaches Mazama's server and the only files
// written are in a temp folder.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/browser_login_spec.dart';
import 'package:mazama_mobile/browser_sign_in_page.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_hosts_store.dart';
import 'package:mazama_mobile/login_spec_client.dart';
import 'package:mazama_mobile/login_spec_store.dart';
import 'package:mazama_mobile/main.dart';
import 'package:mazama_mobile/select_center_page.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/state_client.dart' show resetStateReadsSpec;

import 'flow/fake_state.dart';
import 'host_list_signing.dart';

const _newHost = 'login.example.gov';

late Directory _dir;
final FlowSpec _login = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
final String _browserYaml = File(browserLoginSpecAsset).readAsStringSync();
final FlowSpec _bundledBrowser = FlowSpec.fromYaml(_browserYaml);

/// [_bundledBrowser]'s spec_version moved by [by] in its number after the dot.
String _version(int by) {
  final v = _bundledBrowser.specVersion!;
  final dot = v.lastIndexOf('.');
  return '${v.substring(0, dot)}.${int.parse(v.substring(dot + 1)) + by}';
}

/// The bundled browser spec at [version].
String _newerYaml(String version) {
  final from = 'spec_version: "${_bundledBrowser.specVersion}"';
  expect(from.allMatches(_browserYaml), hasLength(1));
  return _browserYaml.replaceFirst(from, 'spec_version: "$version"');
}

/// [_newerYaml] with the state's page and the token request at [_newHost].
String _movedYaml(String version) {
  const from = 'b2c: "https://{{tenant}}.b2clogin.com/{{tenant}}.onmicrosoft.com"';
  final text = _newerYaml(version);
  expect(from.allMatches(text), hasLength(1));
  return text.replaceFirst(from, 'b2c: "https://$_newHost/{{tenant}}.onmicrosoft.com"');
}

/// The server's answer, parsed without the page's own checks (the page holds it to them itself).
FetchedSpec _fetched(String yaml) => FetchedSpec(FlowSpec.fromYaml(yaml), yaml, 'server');

File get _savedBrowserSpec => File('${_dir.path}/login_browser_spec.yaml');
File get _savedLoginSpec => File('${_dir.path}/login_spec.yaml');
File get _hostsFile => File('${_dir.path}/login_hosts.json');

LoginHostsStore get _hostsStore => LoginHostsStore(dataDir: () => _dir, publicKey: testPublicKey);

/// A host list store whose saves fail (a full disk, say).
class _FailingHostsStore extends LoginHostsStore {
  _FailingHostsStore() : super(dataDir: () => _dir, publicKey: testPublicKey);

  @override
  Future<void> save(HostList list) async => throw const FileSystemException('the disk is full');
}

/// The state's page for [fake]: each opening is recorded in [opened] (its start URL) and answered by [answers] in turn
/// (given the start URL's `state`; null: the worker closed it). Hands out CODE1 against the start URL's challenge.
Future<String?> Function(String, String) _page(
    FakeState fake, List<String> opened, List<String? Function(String state)> answers) {
  return (url, until) async {
    expect(until, site);
    opened.add(url);
    final q = Uri.parse(url).queryParameters;
    fake.codes['CODE1'] = q['code_challenge']!;
    final answer = answers[opened.length - 1];
    return answer(q['state']!);
  };
}

String? _noCode(String st) => '$site#state=$st'; // no code: `structure` (the state's page changed)
String? _good(String st) => '$site#code=CODE1&state=$st';
String? _closed(String st) => null;

typedef _Outcome = ({SelectCenterPage? opened, bool named});

Future<_Outcome> _signInOnPage(
  WidgetTester tester,
  FakeState fake, {
  required List<String> opened,
  required List<String? Function(String state)> answers,
  required Future<FetchedSpec?> Function() fetchBrowserSpec,
  Future<HostList?> Function()? fetchHosts,
  LoginHostsStore? hostsStore,
  bool expectSignedIn = false,
}) async {
  SelectCenterPage? page;
  var named = false;
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      home: SignInPage(
        spec: _login,
        sessionStore: SessionStore(dataDir: () => _dir),
        reportSigninFailure: (e, v) async {},
        fetchSpec: () async => fail('the password sign-in spec was asked for'),
        specStore: LoginSpecStore(dataDir: () => _dir),
        fetchHosts: fetchHosts ?? () async => null,
        hostsStore: hostsStore ?? _hostsStore,
        browse: _page(fake, opened, answers),
        browserSpec: () async => _bundledBrowser,
        fetchBrowserSpec: fetchBrowserSpec,
        browserSpecStore: LoginSpecStore.browser(dataDir: () => _dir),
      ),
    ));
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, signInOnStatePageLabel));
    if (!expectSignedIn) {
      await tester.pumpAndSettle();
      return;
    }
    for (var i = 0; i < 100 && page == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      final found = find.byType(SelectCenterPage, skipOffstage: false);
      if (found.evaluate().isNotEmpty) page = tester.widget<SelectCenterPage>(found);
    }
    for (var i = 0; i < 10 && !named; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      named = find.text(newSigninHostsMessage(const [_newHost])).evaluate().isNotEmpty;
    }
    // Leave the page before its own state reads go anywhere.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, fake.client);
  return (opened: page, named: named);
}

void main() {
  // This file's widget tests load the state-reads spec (state_client.dart's stateReadsSpec) and other assets through
  // rootBundle; both caches keep the Future, which belongs to that test's fake async zone. Forget them after each
  // test, or a later test (in CI's one-isolate bundle, in another file) awaits them forever.
  tearDown(() {
    rootBundle.clear();
    resetStateReadsSpec();
  });

  late HostList listV1;
  late HostList wideV1;
  late HostList narrowV2;
  setUpAll(() async {
    listV1 = await signedHostList('2026-11-01.1', [_newHost]);
    wideV1 = await signedHostList('2026-11-01.1', [_newHost, 'other.example.gov']);
    narrowV2 = await signedHostList('2026-11-01.2', [_newHost]);
  });
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_sign_in_browser_retry_test_'));
  tearDown(() {
    useLoginHosts(null);
    _dir.deleteSync(recursive: true);
  });

  test('the test specs: the newer one is a usable browser spec, never a password one; the moved one needs the list', () {
    expect(usableLoginSpec(_newerYaml(_version(1)), served: ServedAs.browser), isNotNull);
    expect(usableLoginSpec(_newerYaml(_version(1)), served: ServedAs.login), isNull);
    expect(usableLoginSpec(_movedYaml(_version(1)), served: ServedAs.browser), isNull);
    expect(usableLoginSpec(_movedYaml(_version(1)), served: ServedAs.browser, allowedHosts: allowedHostsWith(listV1)),
        isNotNull);
  });

  testWidgets('a newer browser spec from the server gets the sign-in through on a second try and is kept on its own',
      (tester) async {
    final fake = FakeState();
    final opened = <String>[];
    var fetches = 0;
    final yaml = _newerYaml(_version(1));

    final out = await _signInOnPage(tester, fake,
        opened: opened,
        answers: [_noCode, _good],
        fetchBrowserSpec: () async {
          fetches += 1;
          return _fetched(yaml);
        },
        expectSignedIn: true);

    expect(fetches, 1);
    expect(opened, hasLength(2)); // the state's page opened again for the retry
    expect(out.opened, isNotNull);
    expect(out.opened!.session.accessToken, 'ACCESS-1');
    expect(identical(out.opened!.spec, _login), isTrue); // still renews with login.yaml
    expect(fake.logins, 1);
    expect(_savedBrowserSpec.readAsStringSync(), yaml); // kept apart from login.yaml's
    expect(_savedLoginSpec.existsSync(), isFalse);
    expect(out.named, isFalse);
    expect(tester.takeException(), isNull);
    // From now on the saved one is used: it is newer than the bundled one.
    expect(LoginSpecStore.browser(dataDir: () => _dir).savedSpec()?.specVersion, _version(1));
  });

  testWidgets('a fetched spec no newer than the one that failed is not tried', (tester) async {
    final fake = FakeState();
    final opened = <String>[];

    await _signInOnPage(tester, fake,
        opened: opened, answers: [_noCode, _good], fetchBrowserSpec: () async => _fetched(_newerYaml(_version(0))));

    expect(opened, hasLength(1));
    expect(find.text(browserSigninUnfinishedMessage), findsOneWidget);
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(_savedBrowserSpec.existsSync(), isFalse);
  });

  testWidgets('a newer fetched spec without an open_browser is never run as the browser sign-in', (tester) async {
    final fake = FakeState();
    final opened = <String>[];
    final login = File('assets/flows/login.yaml')
        .readAsStringSync()
        .replaceFirst('spec_version: "${_login.specVersion}"', 'spec_version: "2999-01-01.1"');

    await _signInOnPage(tester, fake,
        opened: opened, answers: [_noCode, _good], fetchBrowserSpec: () async => _fetched(login));

    expect(opened, hasLength(1));
    expect(fake.log, isEmpty); // nothing of the password sign-in was sent
    expect(find.text(browserSigninUnfinishedMessage), findsOneWidget);
    expect(_savedBrowserSpec.existsSync(), isFalse);
  });

  testWidgets('a retry that fails shows its own failure and keeps nothing', (tester) async {
    final fake = FakeState();
    final opened = <String>[];

    await _signInOnPage(tester, fake,
        opened: opened,
        answers: [_noCode, _closed],
        fetchBrowserSpec: () async => _fetched(_newerYaml(_version(1))));

    expect(opened, hasLength(2));
    expect(find.text(signInCancelledMessage), findsOneWidget); // the retry's own: the worker closed the page
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(_savedBrowserSpec.existsSync(), isFalse);
  });

  testWidgets('a closed page (a stuck one, say) with a newer browser spec to be had retries once and signs in',
      (tester) async {
    final fake = FakeState();
    final opened = <String>[];
    var fetches = 0;
    var hostFetches = 0;
    final yaml = _newerYaml(_version(1));

    final out = await _signInOnPage(tester, fake,
        opened: opened,
        answers: [_closed, _good],
        fetchHosts: () async {
          hostFetches += 1;
          return null;
        },
        fetchBrowserSpec: () async {
          fetches += 1;
          return _fetched(yaml);
        },
        expectSignedIn: true);

    expect((fetches, hostFetches, opened.length), (1, 1, 2));
    expect(out.opened, isNotNull);
    expect(fake.logins, 1);
    expect(_savedBrowserSpec.readAsStringSync(), yaml);
  });

  testWidgets('a closed page with no newer browser spec says "Sign-in cancelled." and does not reopen',
      (tester) async {
    final fake = FakeState();
    final opened = <String>[];
    var fetches = 0;

    await _signInOnPage(tester, fake, opened: opened, answers: [_closed, _good], fetchBrowserSpec: () async {
      fetches += 1;
      return _fetched(_newerYaml(_version(0))); // the same version: not newer
    });

    expect((fetches, opened.length), (1, 1));
    expect(find.text(signInCancelledMessage), findsOneWidget);
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(_savedBrowserSpec.existsSync(), isFalse);
  });

  testWidgets('a closed page whose fetch finds nothing says "Sign-in cancelled." as before', (tester) async {
    final fake = FakeState();
    final opened = <String>[];

    await _signInOnPage(tester, fake, opened: opened, answers: [_closed, _good], fetchBrowserSpec: () async => null);

    expect(opened, hasLength(1));
    expect(find.text(signInCancelledMessage), findsOneWidget);
    expect(find.text(browserSigninUnfinishedMessage), findsNothing);
  });

  testWidgets("B2C's own error (credentials: a changed policy or scope, say) with a newer browser spec retries once",
      (tester) async {
    final fake = FakeState();
    final opened = <String>[];
    var fetches = 0;

    final out = await _signInOnPage(tester, fake,
        opened: opened,
        answers: [(st) => '$site#error=invalid_scope&error_description=bad+scope&state=$st', _good],
        fetchBrowserSpec: () async {
          fetches += 1;
          return _fetched(_newerYaml(_version(1)));
        },
        expectSignedIn: true);

    expect((fetches, opened.length), (1, 2));
    expect(out.opened, isNotNull);
  });

  testWidgets("B2C's own error with no newer browser spec shows its description and does not reopen", (tester) async {
    final fake = FakeState();
    final opened = <String>[];

    await _signInOnPage(tester, fake,
        opened: opened,
        answers: [(st) => '$site#error=access_denied&error_description=refused&state=$st', _good],
        fetchBrowserSpec: () async => null);

    expect(opened, hasLength(1));
    expect(find.text("the state's sign-in page ended without signing in: refused"), findsOneWidget);
  });

  testWidgets('a signed list naming the new host lets a browser spec there sign in; both are kept and the host named',
      (tester) async {
    final fake = FakeState();
    final opened = <String>[];
    final yaml = _movedYaml(_version(1));

    final out = await _signInOnPage(tester, fake,
        opened: opened,
        answers: [_noCode, _good],
        fetchHosts: () async => listV1,
        fetchBrowserSpec: () async => _fetched(yaml),
        expectSignedIn: true);

    expect(opened, hasLength(2));
    expect(opened.last, startsWith('https://$_newHost/'));
    expect(out.opened, isNotNull);
    expect(fake.logins, 1); // the token request, at the new host
    expect(loginHostsInUse?.version, listV1.version);
    expect(_hostsFile.existsSync(), isTrue);
    expect(_savedBrowserSpec.readAsStringSync(), yaml);
    expect(out.named, isTrue); // "Sign-in now also allows: login.example.gov"
  });

  testWidgets('without the list, a browser spec at the new host is not tried', (tester) async {
    final fake = FakeState();
    final opened = <String>[];

    await _signInOnPage(tester, fake,
        opened: opened, answers: [_noCode, _good], fetchBrowserSpec: () async => _fetched(_movedYaml(_version(1))));

    expect(opened, hasLength(1));
    expect(loginHostsInUse, isNull);
    expect(_savedBrowserSpec.existsSync(), isFalse);
  });

  testWidgets('when the list cannot be saved, a spec that needs it is not kept either', (tester) async {
    final fake = FakeState();

    final out = await _signInOnPage(tester, fake,
        opened: <String>[],
        answers: [_noCode, _good],
        fetchHosts: () async => listV1,
        fetchBrowserSpec: () async => _fetched(_movedYaml(_version(1))),
        hostsStore: _FailingHostsStore(),
        expectSignedIn: true);

    expect(out.opened, isNotNull); // this sign-in still goes through
    expect(loginHostsInUse?.version, listV1.version); // in use until the app stops
    expect(_hostsFile.existsSync(), isFalse);
    expect(_savedBrowserSpec.existsSync(), isFalse); // the next start-up couldn't use it without the list
  });

  testWidgets('when the list cannot be saved, a spec that does not need it is still kept', (tester) async {
    final fake = FakeState();
    final yaml = _newerYaml(_version(1));

    final out = await _signInOnPage(tester, fake,
        opened: <String>[],
        answers: [_noCode, _good],
        fetchHosts: () async => listV1,
        fetchBrowserSpec: () async => _fetched(yaml),
        hostsStore: _FailingHostsStore(),
        expectSignedIn: true);

    expect(out.opened, isNotNull);
    expect(_hostsFile.existsSync(), isFalse);
    expect(_savedBrowserSpec.readAsStringSync(), yaml);
  });

  testWidgets('a newer list that only removes hosts is kept and in use at once, with no retry', (tester) async {
    useLoginHosts(wideV1);
    final fake = FakeState();
    final opened = <String>[];

    await _signInOnPage(tester, fake,
        opened: opened, answers: [_noCode, _good], fetchHosts: () async => narrowV2, fetchBrowserSpec: () async => null);

    expect(opened, hasLength(1));
    expect(find.text(browserSigninUnfinishedMessage), findsOneWidget);
    expect(loginHostsInUse?.version, narrowV2.version);
    expect((await tester.runAsync(() => _hostsStore.load()))?.version, narrowV2.version);
  });
}
