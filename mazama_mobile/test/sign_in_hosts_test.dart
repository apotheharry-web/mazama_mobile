// SL-R18: after a failed sign-in, SignInPage asks for the owner's signed host list beside the newer sign-in spec
// (SL-R10). A list newer than the one in use gives the retry its hosts (the built-in ones plus the list's): the fetched
// spec is held to them and runFlow runs with them. The list is kept, and put in use for every flow, only after the
// sign-in it enabled gave a session; the hosts it added are named. The state system is test/flow/fake_state.dart's
// FakeState through http.runWithClient; the fetches and stores are injected (lists signed with the shared vectors'
// TEST key, see host_list_signing.dart), so nothing reaches Mazama's server and the only files written are in a temp
// folder.
//
// The fake answers by path, whatever the host, so a spec whose B2C requests go to login.example.gov (the state's "new
// address") gets through it exactly as the bundled one would - if the phone lets it send them.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
final String _bundledYaml = File('assets/flows/login.yaml').readAsStringSync();
final FlowSpec _bundled = FlowSpec.fromYaml(_bundledYaml);

/// The authorize page with its token field renamed: the bundled spec fails on it (`structure`), the newer one doesn't.
const _renamedFieldPage = 'var SETTINGS = {"csrfToken":"CSRF123","transId":"StateProperties=abc",'
    '"policy":"b2c_1_oha_ph_psilocybin_prod_susi"};';

/// [_bundled]'s spec_version moved by [by] in its number after the dot.
String _version(int by) {
  final v = _bundled.specVersion!;
  final dot = v.lastIndexOf('.');
  return '${v.substring(0, dot)}.${int.parse(v.substring(dot + 1)) + by}';
}

/// The bundled login.yaml at [version], its csrf regex looking for "csrfToken" (works on [_renamedFieldPage]).
String _fixedYaml(String version) {
  final from = 'spec_version: "${_bundled.specVersion}"';
  const regex = "regex: '\"csrf\"";
  expect(from.allMatches(_bundledYaml), hasLength(1));
  expect(regex.allMatches(_bundledYaml), hasLength(1));
  return _bundledYaml.replaceFirst(from, 'spec_version: "$version"').replaceFirst(regex, "regex: '\"csrfToken\"");
}

/// [_fixedYaml] with every B2C request (authorize, SelfAsserted, confirmed, token, renew) sent to [_newHost].
String _movedYaml(String version) {
  const from = 'b2c: "https://{{tenant}}.b2clogin.com/{{tenant}}.onmicrosoft.com"';
  final text = _fixedYaml(version);
  expect(from.allMatches(text), hasLength(1));
  return text.replaceFirst(from, 'b2c: "https://$_newHost/{{tenant}}.onmicrosoft.com"');
}

/// What the server would answer with, held to the phone's rule under [hosts].
FetchedSpec _fetched(String yaml, {List<String> hosts = defaultAllowedHosts}) {
  final spec = usableLoginSpec(yaml, allowedHosts: hosts);
  expect(spec, isNotNull, reason: 'the test spec must be usable under $hosts');
  return FetchedSpec(spec!, yaml, 'server');
}

int _logins(FakeState fake) => fake.log.where((e) => e.$2.endsWith('/oauth2/v2.0/authorize')).length;

File get _hostsFile => File('${_dir.path}/login_hosts.json');
File get _specFile => File('${_dir.path}/login_spec.yaml');

LoginHostsStore get _hostsStore => LoginHostsStore(dataDir: () => _dir, publicKey: testPublicKey);

/// A host list store whose saves fail (a full disk, say).
class _FailingHostsStore extends LoginHostsStore {
  _FailingHostsStore() : super(dataDir: () => _dir, publicKey: testPublicKey);

  @override
  Future<void> save(HostList list) async => throw const FileSystemException('the disk is full');
}

late HostList _listV1; // adds _newHost
late HostList _listV2; // adds _newHost too, newer
late HostList _otherV2; // adds another host only, newer than _listV1
late HostList _wideV1; // adds _newHost and other.example.gov

/// What a sign-in on the page did: the SelectCenterPage it opened (null when it didn't), and whether the note naming
/// the new hosts was seen over it.
typedef _Outcome = ({SelectCenterPage? opened, bool named});

Future<_Outcome> _signIn(
  WidgetTester tester,
  FakeState fake, {
  FlowSpec? spec,
  required Future<HostList?> Function() fetchHosts,
  required Future<FetchedSpec?> Function() fetchSpec,
  LoginHostsStore? hostsStore,
  bool expectSignedIn = false,
}) async {
  SelectCenterPage? opened;
  var named = false;
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      home: SignInPage(
        spec: spec ?? _bundled,
        sessionStore: SessionStore(dataDir: () => _dir),
        reportSigninFailure: (e, v) async {},
        fetchSpec: fetchSpec,
        specStore: LoginSpecStore(dataDir: () => _dir),
        fetchHosts: fetchHosts,
        hostsStore: hostsStore ?? _hostsStore,
      ),
    ));
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), fakePassword);
    await tester.pump();
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
    for (var i = 0; i < 10 && !named; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      named = find.text(newSigninHostsMessage(const [_newHost])).evaluate().isNotEmpty;
    }
    // Leave the page before its own state reads go anywhere.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, fake.client);
  return (opened: opened, named: named);
}

void main() {
  // This file's widget tests load the state-reads spec (state_client.dart's stateReadsSpec) and other assets through
  // rootBundle; both caches keep the Future, which belongs to that test's fake async zone. Forget them after each
  // test, or a later test (in CI's one-isolate bundle, in another file) awaits them forever.
  tearDown(() {
    rootBundle.clear();
    resetStateReadsSpec();
  });

  setUpAll(() async {
    _listV1 = await signedHostList('2026-11-01.1', [_newHost]);
    _listV2 = await signedHostList('2026-11-01.2', [_newHost]);
    _otherV2 = await signedHostList('2026-11-01.2', ['other.example.gov']);
    _wideV1 = await signedHostList('2026-11-01.1', [_newHost, 'other.example.gov']);
  });
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_sign_in_hosts_test_'));
  tearDown(() {
    useLoginHosts(null);
    _dir.deleteSync(recursive: true);
  });

  test('the moved spec is usable only with the new host allowed', () {
    expect(usableLoginSpec(_movedYaml(_version(1))), isNull);
    expect(usableLoginSpec(_movedYaml(_version(1)), allowedHosts: allowedHostsWith(_listV1)), isNotNull);
    expect(newSigninHostsMessage(const [_newHost]), 'Sign-in now also allows: $_newHost');
    expect(newSigninHostsMessage(const ['a.example.gov', 'b.example.gov']),
        'Sign-in now also allows: a.example.gov, b.example.gov');
    expect(retrySigninHostsMessage(const [_newHost]), 'The retry also allowed: $_newHost');
  });

  testWidgets('a signed list naming the new host lets the newer spec sign in there; both are kept and used from now on',
      (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final yaml = _movedYaml(_version(1));
    var hostFetches = 0;

    final out = await _signIn(tester, fake,
        fetchHosts: () async {
          hostFetches += 1;
          return _listV1;
        },
        fetchSpec: () async => _fetched(yaml, hosts: allowedHostsWith(_listV1)),
        expectSignedIn: true);

    expect(out.opened, isNotNull);
    expect(out.opened!.spec.specVersion, _version(1));
    expect(hostFetches, 1);
    expect(_logins(fake), 2);
    expect(fake.logins, 1); // the retry's token exchange, at the new host
    // In use at once (reads, the sale, renew, the webview), and kept for the next start-up.
    expect(loginHostsInUse?.version, _listV1.version);
    expect(currentAllowedHosts(), [...defaultAllowedHosts, _newHost]);
    expect(_hostsFile.existsSync(), isTrue);
    final saved = await tester.runAsync(() => _hostsStore.load());
    expect(saved?.version, _listV1.version);
    expect(saved?.hosts, [_newHost]);
    expect(_specFile.readAsStringSync(), yaml); // saved under the new list's hosts
    expect(out.named, isTrue); // "Sign-in now also allows: login.example.gov"
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a list, a spec at the new host is not tried and nothing is kept', (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    var specFetches = 0;

    await _signIn(tester, fake, fetchHosts: () async => null, fetchSpec: () async {
      specFetches += 1;
      // A fetcher that didn't hold the reply to the hosts: the page holds it to them itself.
      return FetchedSpec(FlowSpec.fromYaml(_movedYaml(_version(1))), _movedYaml(_version(1)), 'server');
    });

    expect(specFetches, 1);
    expect(_logins(fake), 1); // no retry
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(find.textContaining('also allow'), findsNothing);
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(loginHostsInUse, isNull);
    expect(_hostsFile.existsSync(), isFalse);
    expect(_specFile.existsSync(), isFalse);
  });

  testWidgets('a retry with a new list that fails keeps nothing and names the new host under the failure',
      (tester) async {
    // The newer spec gets past the page at the new host; SelfAsserted then answers 503 (reason `unavailable`).
    final fake = FakeState()
      ..pageHtml = _renamedFieldPage
      ..selfAssertedStatus = 503;

    await _signIn(tester, fake,
        fetchHosts: () async => _listV1,
        fetchSpec: () async => _fetched(_movedYaml(_version(1)), hosts: allowedHostsWith(_listV1)));

    expect(_logins(fake), 2);
    expect(find.text(stateSigninChangedMessage), findsNothing); // the retry's own failure is shown
    expect(find.text(retrySigninHostsMessage(const [_newHost])), findsOneWidget);
    expect(find.text(newSigninHostsMessage(const [_newHost])), findsNothing);
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(loginHostsInUse, isNull);
    expect(currentAllowedHosts(), defaultAllowedHosts);
    expect(_hostsFile.existsSync(), isFalse);
    expect(_specFile.existsSync(), isFalse);
  });

  testWidgets('a list no newer than the one in use is not used', (tester) async {
    useLoginHosts(_otherV2);
    final fake = FakeState()..pageHtml = _renamedFieldPage;

    await _signIn(tester, fake,
        fetchHosts: () async => _listV1, // older than _otherV2: ignored
        fetchSpec: () async => FetchedSpec(FlowSpec.fromYaml(_movedYaml(_version(1))), _movedYaml(_version(1)), 'server'));

    expect(_logins(fake), 1); // the spec at the new host isn't allowed under _otherV2's hosts
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(loginHostsInUse, same(_otherV2));
    expect(_hostsFile.existsSync(), isFalse);
  });

  testWidgets('a newer list that adds nothing new is kept, and no new address is named', (tester) async {
    useLoginHosts(_listV1); // _newHost is already allowed
    final fake = FakeState()..pageHtml = _renamedFieldPage;

    final out = await _signIn(tester, fake,
        fetchHosts: () async => _listV2,
        fetchSpec: () async => _fetched(_movedYaml(_version(1)), hosts: allowedHostsWith(_listV1)),
        expectSignedIn: true);

    expect(out.opened?.spec.specVersion, _version(1));
    expect(out.named, isFalse);
    expect(loginHostsInUse?.version, _listV2.version);
    expect((await tester.runAsync(() => _hostsStore.load()))?.version, _listV2.version);
  });

  testWidgets('a retry with no new list keeps the list in use and saves no list', (tester) async {
    useLoginHosts(_listV1);
    final fake = FakeState()..pageHtml = _renamedFieldPage;

    final out = await _signIn(tester, fake,
        fetchHosts: () async => _listV1, // the same version: not a new list
        fetchSpec: () async => _fetched(_movedYaml(_version(1)), hosts: allowedHostsWith(_listV1)),
        expectSignedIn: true);

    expect(out.opened?.spec.specVersion, _version(1));
    expect(out.named, isFalse);
    expect(loginHostsInUse, same(_listV1));
    expect(_hostsFile.existsSync(), isFalse);
    expect(_specFile.existsSync(), isTrue);
  });

  testWidgets('the first try runs under the hosts in use: a spec at the new host signs in with no fetch',
      (tester) async {
    useLoginHosts(_listV1);
    final fake = FakeState();
    var fetches = 0;

    final out = await _signIn(tester, fake,
        spec: FlowSpec.fromYaml(_movedYaml(_bundled.specVersion!).replaceFirst("regex: '\"csrfToken\"", "regex: '\"csrf\"")),
        fetchHosts: () async {
          fetches += 1;
          return null;
        },
        fetchSpec: () async {
          fetches += 1;
          return null;
        },
        expectSignedIn: true);

    expect(out.opened, isNotNull);
    expect(fetches, 0);
    expect(_logins(fake), 1);
    expect(fake.logins, 1);
  });

  testWidgets('the same spec without the list in use is stopped before it sends anything', (tester) async {
    final fake = FakeState();

    await _signIn(tester, fake,
        spec: FlowSpec.fromYaml(_movedYaml(_bundled.specVersion!).replaceFirst("regex: '\"csrfToken\"", "regex: '\"csrf\"")),
        fetchHosts: () async => null,
        fetchSpec: () async => null);

    expect(fake.log, isEmpty); // the authorize request to the new host was never sent
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(find.textContaining('not an allowed https address'), findsOneWidget);
  });

  testWidgets('a list fetch that fails counts as none: a newer spec at the built-in hosts still signs in',
      (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;

    final out = await _signIn(tester, fake,
        fetchHosts: () async => throw StateError('the fetch broke'),
        fetchSpec: () async => _fetched(_fixedYaml(_version(1))),
        expectSignedIn: true);

    expect(out.opened?.spec.specVersion, _version(1));
    expect(loginHostsInUse, isNull);
    expect(_hostsFile.existsSync(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('when the list cannot be saved, a spec that needs it is not saved either (the sign-in still goes through)',
      (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;

    final out = await _signIn(tester, fake,
        fetchHosts: () async => _listV1,
        fetchSpec: () async => _fetched(_movedYaml(_version(1)), hosts: allowedHostsWith(_listV1)),
        hostsStore: _FailingHostsStore(),
        expectSignedIn: true);

    expect(out.opened?.spec.specVersion, _version(1));
    expect(loginHostsInUse?.version, _listV1.version); // in use until the app stops
    expect(_hostsFile.existsSync(), isFalse);
    expect(_specFile.existsSync(), isFalse); // the next start-up couldn't use it without the list
  });

  testWidgets('when the list cannot be saved, a spec that does not need it is still saved', (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final yaml = _fixedYaml(_version(1));

    final out = await _signIn(tester, fake,
        fetchHosts: () async => _listV1,
        fetchSpec: () async => _fetched(yaml),
        hostsStore: _FailingHostsStore(),
        expectSignedIn: true);

    expect(out.opened?.spec.specVersion, _version(1));
    expect(_hostsFile.existsSync(), isFalse);
    expect(_specFile.readAsStringSync(), yaml);
  });

  group('a newer list that only removes hosts', () {
    testWidgets('is kept and put in use at once, with no newer spec and no retry', (tester) async {
      useLoginHosts(_wideV1);
      final fake = FakeState()..pageHtml = _renamedFieldPage;
      var specFetches = 0;

      await _signIn(tester, fake, fetchHosts: () async => _otherV2, fetchSpec: () async {
        specFetches += 1;
        return null;
      });

      expect(specFetches, 1);
      expect(_logins(fake), 1); // no retry
      expect(find.text(stateSigninChangedMessage), findsOneWidget); // the failure shown as before
      expect(loginHostsInUse?.version, _otherV2.version);
      expect(currentAllowedHosts(), [...defaultAllowedHosts, 'other.example.gov']);
      expect((await tester.runAsync(() => _hostsStore.load()))?.version, _otherV2.version);
      expect(find.textContaining('also allow'), findsNothing);
    });

    testWidgets('a saved spec that needs a removed host is no longer used', (tester) async {
      useLoginHosts(_wideV1);
      final moved = _movedYaml(_version(1));
      final store = LoginSpecStore(dataDir: () => _dir);
      await tester.runAsync(() => store.save(moved));
      expect(store.savedSpec()?.specVersion, _version(1));
      final fake = FakeState()..pageHtml = _renamedFieldPage;

      await _signIn(tester, fake, fetchHosts: () async => _otherV2, fetchSpec: () async => null);

      expect(loginHostsInUse?.version, _otherV2.version);
      expect(store.savedSpec(), isNull); // _newHost is gone: the bundled spec is chosen again
      expect((await tester.runAsync(() => store.choose(_bundledYaml)))?.saved, isFalse);
    });

    testWidgets('a newer list that adds any host is still kept only with a newer spec that signs in', (tester) async {
      useLoginHosts(_listV1); // _newHost
      final fake = FakeState()..pageHtml = _renamedFieldPage;
      // newer, drops _newHost and adds other.example.gov: not a removal only
      await _signIn(tester, fake, fetchHosts: () async => _otherV2, fetchSpec: () async => null);

      expect(_logins(fake), 1);
      expect(loginHostsInUse, same(_listV1));
      expect(_hostsFile.existsSync(), isFalse);
    });
  });

  test('onlyRemovesHosts: newer, and its hosts a strict subset of those in use', () {
    expect(onlyRemovesHosts(_otherV2, _wideV1), isTrue);
    expect(onlyRemovesHosts(_otherV2, _listV1), isFalse); // adds other.example.gov
    expect(onlyRemovesHosts(_listV2, _listV1), isFalse); // the same hosts
    expect(onlyRemovesHosts(_listV1, _wideV1), isFalse); // not newer
    expect(onlyRemovesHosts(_otherV2, null), isFalse); // nothing in use to remove from
  });
}
