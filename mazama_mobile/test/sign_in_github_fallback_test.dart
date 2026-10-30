// specs/app-updates AU-R17, AU-D6: after a failed sign-in, when Mazama's server can't answer, SignInPage reads the
// owner's signed sign-in files from GitHub (github_signin_files.dart) and holds them to the same rules as the server's:
// the signature verified with the bundled key (the TEST key injected here), usable in its served mode under the
// attempt's hosts, strictly newer than the spec that failed, one retry, saved only after a session. When the server
// answers (an error, nothing, or an older spec), GitHub is not asked.
//
// The state system is test/flow/fake_state.dart's FakeState through http.runWithClient; GitHub is a MockClient handed
// to the injected GitHub fetchers, so nothing leaves the test.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mazama_mobile/browser_login_spec.dart';
import 'package:mazama_mobile/browser_sign_in_page.dart' show signInOnStatePageLabel;
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/github_files.dart';
import 'package:mazama_mobile/github_signin_files.dart';
import 'package:mazama_mobile/demo/demo_banner.dart' show setDemoMode;
import 'package:mazama_mobile/login_hosts_client.dart';
import 'package:mazama_mobile/login_hosts_store.dart';
import 'package:mazama_mobile/login_spec_client.dart';
import 'package:mazama_mobile/login_spec_store.dart';
import 'package:mazama_mobile/main.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_link_client.dart' show ServerLinkClient;
import 'package:mazama_mobile/select_center_page.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/state_client.dart' show resetStateReadsSpec;

import 'fake_timers.dart';
import 'flow/fake_state.dart';
import 'host_list_signing.dart';

late Directory _dir;
final String _bundledYaml = File('assets/flows/login.yaml').readAsStringSync();
final FlowSpec _bundled = FlowSpec.fromYaml(_bundledYaml);
final String _browserYaml = File(browserLoginSpecAsset).readAsStringSync();
final FlowSpec _bundledBrowser = FlowSpec.fromYaml(_browserYaml);

/// The authorize page with its token field renamed: the bundled spec can't find it, [_fixedYaml]'s spec can.
const _renamedFieldPage = 'var SETTINGS = {"csrfToken":"CSRF123","transId":"StateProperties=abc",'
    '"policy":"b2c_1_oha_ph_psilocybin_prod_susi"};';

String _bump(String v, int by) {
  final dot = v.lastIndexOf('.');
  return '${v.substring(0, dot)}.${int.parse(v.substring(dot + 1)) + by}';
}

/// The bundled login.yaml at [by] versions on, its csrf regex looking for "csrfToken" (works on [_renamedFieldPage]).
String _fixedYaml(int by) {
  const from = "regex: '\"csrf\"";
  final text =
      _bundledYaml.replaceFirst('spec_version: "${_bundled.specVersion}"', 'spec_version: "${_bump(_bundled.specVersion!, by)}"');
  expect(from.allMatches(text), hasLength(1));
  return text.replaceFirst(from, "regex: '\"csrfToken\"");
}

/// GitHub answering [files] (name -> text) with their TEST signatures (or [sigs]), recording what was asked.
class _GitHub {
  _GitHub(this.files, {this.sigs = const {}});
  final Map<String, String> files;
  final Map<String, String> sigs;
  final asked = <String>[];

  late final client = MockClient((req) async {
    asked.add(req.url.toString());
    final name = req.url.toString().substring(githubFilesBase.length);
    if (name.endsWith('.sig')) {
      final base = name.substring(0, name.length - 4);
      final text = files[base];
      if (text == null) return http.Response('', 404);
      return http.Response(sigs[base] ?? await testSignature(text), 200);
    }
    final text = files[name];
    return text == null ? http.Response('', 404) : http.Response(text, 200);
  });
}

class _CountingStore extends LoginSpecStore {
  int saves = 0;
  _CountingStore(Directory dir) : super(dataDir: () => dir);

  @override
  Future<void> save(String yaml) async {
    saves += 1;
    await super.save(yaml);
  }
}

int _logins(FakeState fake) => fake.log.where((e) => e.$2.endsWith('/oauth2/v2.0/authorize')).length;

Future<SelectCenterPage?> _signIn(
  WidgetTester tester,
  FakeState fake, {
  required _GitHub github,
  required bool offline,
  required LoginSpecStore store,
  Future<FetchedSpec?> Function()? fetchSpec,
  Future<HostList?> Function()? fetchHosts,
  bool Function()? serverOffline,
  bool expectSignedIn = false,
}) async {
  SelectCenterPage? opened;
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      home: SignInPage(
        spec: _bundled,
        sessionStore: SessionStore(dataDir: () => _dir),
        reportSigninFailure: (e, v) async {},
        fetchSpec: fetchSpec ?? () async => null,
        specStore: store,
        fetchHosts: fetchHosts ?? () async => null,
        hostsStore: LoginHostsStore(dataDir: () => _dir, publicKey: testPublicKey),
        serverOffline: serverOffline ?? () => offline,
        githubFetchSpec: (hosts) => githubLoginSpec(
            served: ServedAs.login, allowedHosts: hosts, client: github.client, publicKey: testPublicKey),
        githubFetchHosts: () => githubHostList(client: github.client, publicKey: testPublicKey),
      ),
    ));
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), fakePassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    if (!expectSignedIn) {
      await tester.pumpAndSettle();
      return;
    }
    for (var i = 0; i < 100 && opened == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      final found = find.byType(SelectCenterPage, skipOffstage: false);
      if (found.evaluate().isNotEmpty) opened = tester.widget<SelectCenterPage>(found);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, fake.client);
  return opened;
}

void main() {
  tearDown(() {
    rootBundle.clear();
    resetStateReadsSpec();
    useLoginHosts(null);
  });
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_sign_in_github_fallback_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

  testWidgets('server offline: GitHub is asked, a newer signed spec is retried once and saved after the session',
      (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir);
    final newYaml = _fixedYaml(1);
    final github = _GitHub({'login.yaml': newYaml});
    final page = await _signIn(tester, fake, github: github, offline: true, store: store, expectSignedIn: true);
    expect(page, isNotNull);
    expect(page!.spec.specVersion, _bump(_bundled.specVersion!, 1));
    expect(_logins(fake), 2);
    expect(store.saves, 1);
    expect(File('${_dir.path}/login_spec.yaml').readAsStringSync(), newYaml);
    expect(github.asked, containsAll(['${githubFilesBase}login.yaml', '${githubFilesBase}login.yaml.sig']));
  });

  testWidgets('a GitHub spec with a bad .sig never runs', (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir);
    final github = _GitHub({'login.yaml': _fixedYaml(1)}, sigs: {'login.yaml': await testSignature('another file')});
    await _signIn(tester, fake, github: github, offline: true, store: store);
    expect(_logins(fake), 1);
    expect(store.saves, 0);
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
  });

  testWidgets('a GitHub spec no newer than the one that failed is not retried', (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir);
    final github = _GitHub({'login.yaml': _fixedYaml(0)});
    await _signIn(tester, fake, github: github, offline: true, store: store);
    expect(_logins(fake), 1);
    expect(store.saves, 0);
  });

  testWidgets('the server answering (nothing, or an older spec): GitHub is never asked', (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final github = _GitHub({'login.yaml': _fixedYaml(1)});
    // the server answered with nothing (an error reply): the link counts it online
    await _signIn(tester, fake, github: github, offline: false, store: _CountingStore(_dir));
    expect(github.asked, isEmpty);
    // the server answered with an older spec, even while the link counts it offline
    final older = _bundledYaml.replaceFirst(
        'spec_version: "${_bundled.specVersion}"', 'spec_version: "${_bump(_bundled.specVersion!, -1)}"');
    await _signIn(tester, FakeState()..pageHtml = _renamedFieldPage,
        github: github,
        offline: true,
        store: _CountingStore(_dir),
        fetchSpec: () async => FetchedSpec(FlowSpec.fromYaml(older), older, 'server'));
    expect(github.asked.where((u) => u.contains('login.yaml')), isEmpty);
  });

  testWidgets("both down: today's message", (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final github = _GitHub(const {});
    await _signIn(tester, fake, github: github, offline: true, store: _CountingStore(_dir));
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(github.asked, isNotEmpty);
    expect(find.byType(SelectCenterPage), findsNothing);
  });

  testWidgets('a GitHub host list older than the one in use is ignored', (tester) async {
    final inUse = await signedHostList('2026-11-02.1', ['login.example.gov']);
    useLoginHosts(inUse);
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final github = _GitHub({'hosts.json': hostListText('2026-11-01.1', ['old.example.gov'])});
    await _signIn(tester, fake, github: github, offline: true, store: _CountingStore(_dir));
    expect(github.asked, contains('${githubFilesBase}hosts.json'));
    expect(loginHostsInUse?.version, '2026-11-02.1');
    expect(File('${_dir.path}/login_hosts.json').existsSync(), isFalse);
  });

  testWidgets('the browser sign-in reads login_browser.yaml from GitHub when the server is offline', (tester) async {
    final asked = <String>[];
    var browserGithub = 0;
    final fake = FakeState();
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: SignInPage(
          spec: _bundled,
          sessionStore: SessionStore(dataDir: () => _dir),
          reportSigninFailure: (e, v) async {},
          fetchSpec: () async => fail('the password sign-in spec was asked for'),
          specStore: LoginSpecStore(dataDir: () => _dir),
          fetchHosts: () async => null,
          browse: (url, until) async {
            asked.add(url);
            return null; // the worker closed the page: `cancelled`, which still fetches (SL-R19)
          },
          browserSpec: () async => _bundledBrowser,
          fetchBrowserSpec: () async => null,
          browserSpecStore: LoginSpecStore.browser(dataDir: () => _dir),
          serverOffline: () => true,
          githubFetchSpec: (hosts) async => fail('login.yaml was asked for on the browser path'),
          githubFetchBrowserSpec: (hosts) async {
            browserGithub++;
            return null;
          },
          githubFetchHosts: () async => null,
        ),
      ));
      await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, signInOnStatePageLabel));
      await tester.pumpAndSettle();
    }, fake.client);
    expect(asked, hasLength(1));
    expect(browserGithub, 1);
  });

  testWidgets('a server that never answers: GitHub is asked as soon as the fetch gives up, before the link notices '
      '(review I1)', (tester) async {
    final timers = FakeTimers();
    final health = ServerHealth(probe: () async => false, startTimer: timers.start);
    final hanging = ServerLinkClient(MockClient((_) => Completer<http.Response>().future),
        health: health, readTimeout: const Duration(seconds: 2));
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir);
    final github = _GitHub({'login.yaml': _fixedYaml(1)});
    final page = await _signIn(tester, fake,
        github: github,
        offline: false, // read through serverOffline below instead
        serverOffline: () => health.offline,
        store: store,
        fetchSpec: () => requestLoginSpec(client: hanging, timeout: const Duration(milliseconds: 50)),
        fetchHosts: () async => verifiedLoginHostsReply(
            await requestLoginHosts(client: hanging, timeout: const Duration(milliseconds: 50))),
        expectSignedIn: true);
    expect(page, isNotNull);
    expect(page!.spec.specVersion, _bump(_bundled.specVersion!, 1));
    expect(github.asked, contains('${githubFilesBase}login.yaml'));
    await tester.pump(const Duration(seconds: 3)); // the link's own timeouts run out
    health.dispose();
  });

  testWidgets("a 503 through the real server link (the server's own reply) never asks GitHub (review M3)",
      (tester) async {
    final timers = FakeTimers();
    final health = ServerHealth(probe: () async => false, startTimer: timers.start);
    final answering = ServerLinkClient(
        MockClient((_) async => http.Response('{"detail": "No sign-in spec this app can use."}', 503)),
        health: health);
    final github = _GitHub({'login.yaml': _fixedYaml(1)});
    await _signIn(tester, FakeState()..pageHtml = _renamedFieldPage,
        github: github,
        offline: false,
        serverOffline: () => health.offline,
        store: _CountingStore(_dir),
        fetchSpec: () => requestLoginSpec(client: answering),
        fetchHosts: () async => verifiedLoginHostsReply(await requestLoginHosts(client: answering)));
    expect(health.offline, isFalse);
    expect(github.asked, isEmpty);
    health.dispose();
  });

  testWidgets('a GitHub host list that adds a host is kept only after the sign-in it enabled (review M3)',
      (tester) async {
    const newHost = 'login.example.gov';
    const from = 'b2c: "https://{{tenant}}.b2clogin.com/{{tenant}}.onmicrosoft.com"';
    final moved = _fixedYaml(1).replaceFirst(from, 'b2c: "https://$newHost/{{tenant}}.onmicrosoft.com"');
    expect(moved, contains(newHost));
    final list = hostListText('2026-11-01.1', [newHost]);
    final hostsFile = File('${_dir.path}/login_hosts.json');

    // the spec that needs the host doesn't verify: no retry, so the list is not kept
    final failing = _GitHub({'login.yaml': moved, 'hosts.json': list}, sigs: {'login.yaml': await testSignature('x')});
    await _signIn(tester, FakeState()..pageHtml = _renamedFieldPage,
        github: failing, offline: true, store: _CountingStore(_dir));
    expect(hostsFile.existsSync(), isFalse);
    expect(loginHostsInUse, isNull);

    // with a good spec: the retry at the new host signs in, and only then is the list kept and put in use
    final good = _GitHub({'login.yaml': moved, 'hosts.json': list});
    final page = await _signIn(tester, FakeState()..pageHtml = _renamedFieldPage,
        github: good, offline: true, store: _CountingStore(_dir), expectSignedIn: true);
    expect(page, isNotNull);
    expect(hostsFile.existsSync(), isTrue);
    expect(loginHostsInUse?.hosts, [newHost]);
  });

  testWidgets('the demo sign-in (guest / guest) asks nothing of the server or GitHub (review M3)', (tester) async {
    final github = _GitHub({'login.yaml': _fixedYaml(1)});
    var serverAsked = 0;
    await tester.pumpWidget(MaterialApp(
      home: SignInPage(
        spec: _bundled,
        sessionStore: SessionStore(dataDir: () => _dir),
        reportSigninFailure: (e, v) async {
          serverAsked++;
        },
        fetchSpec: () async {
          serverAsked++;
          return null;
        },
        fetchHosts: () async {
          serverAsked++;
          return null;
        },
        serverOffline: () => true,
        githubFetchSpec: (hosts) => githubLoginSpec(served: ServedAs.login, client: github.client),
        githubFetchHosts: () => githubHostList(client: github.client),
      ),
    ));
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'guest');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'guest');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(serverAsked, 0);
    expect(github.asked, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    setDemoMode(false);
  });
}
