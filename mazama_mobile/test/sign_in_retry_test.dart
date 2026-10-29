// SL-R10 / SL-D7 / SL-D11: after a failed sign-in whose reason isn't `credentials`, SignInPage asks for a newer
// sign-in spec and, when the one it gets is newer than the spec that just failed, signs in once more with it. The
// state system is test/flow/fake_state.dart's FakeState through http.runWithClient (SignInPage builds its own
// http.Client()); the spec fetch, the spec store and the failure reporter are injected, so nothing reaches Mazama's
// server and the only files written are in a temp folder.
//
// The two specs really differ in behaviour: the fake's sign-in page here names its token field "csrfToken", which the
// bundled spec's regex ("csrf") doesn't find (a `structure` failure at require_page_fields), and the newer spec's
// regex does.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/browser_login_spec.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_spec_client.dart';
import 'package:mazama_mobile/login_spec_store.dart';
import 'package:mazama_mobile/main.dart';
import 'package:mazama_mobile/select_center_page.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/state_client.dart' show resetStateReadsSpec;

import 'flow/fake_state.dart';

late Directory _dir;
final String _bundledYaml = File('assets/flows/login.yaml').readAsStringSync();
final FlowSpec _bundled = FlowSpec.fromYaml(_bundledYaml);

/// The authorize page with its token field renamed: the bundled spec can't find it, [_fixedYaml]'s spec can.
const _renamedFieldPage = 'var SETTINGS = {"csrfToken":"CSRF123","transId":"StateProperties=abc",'
    '"policy":"b2c_1_oha_ph_psilocybin_prod_susi"};';

/// [_bundled]'s spec_version moved by [by] in its number after the dot (same date), e.g. .3 -> .4 for by = 1.
String _version(int by) {
  final v = _bundled.specVersion!;
  final dot = v.lastIndexOf('.');
  return '${v.substring(0, dot)}.${int.parse(v.substring(dot + 1)) + by}';
}

/// The bundled login.yaml text at [version], otherwise unchanged (so it fails on [_renamedFieldPage] the same way).
String _sameYaml(String version) {
  final from = 'spec_version: "${_bundled.specVersion}"';
  expect(from.allMatches(_bundledYaml), hasLength(1));
  return _bundledYaml.replaceFirst(from, 'spec_version: "$version"');
}

/// The bundled login.yaml text at [version], its csrf regex looking for "csrfToken" (works on [_renamedFieldPage]).
String _fixedYaml(String version) {
  const from = "regex: '\"csrf\"";
  final text = _sameYaml(version);
  expect(from.allMatches(text), hasLength(1));
  return text.replaceFirst(from, "regex: '\"csrfToken\"");
}

/// [_fixedYaml] whose login `token` step "extracts" access_token from a field the answer doesn't have and no longer
/// checks it: usable by the phone's rule, it runs to the end and leaves no token (final review C1).
String _noTokenYaml(String version) {
  var text = _fixedYaml(version);
  const extract = '        - {var: access_token, source: body, json: access_token}\n';
  const check = '      then_require:\n'
      '        - check: truthy\n'
      '          vars: [access_token]\n'
      '          reason: structure\n'
      '          error: "the token request returned no access token"\n';
  expect(extract.allMatches(text), hasLength(2)); // login's token step, then renew's
  expect(check.allMatches(text), hasLength(1));
  text = text.replaceFirst(extract, '        - {var: access_token, source: body, json: no_such_field}\n');
  return text.replaceFirst(check, '');
}

/// A FlowSpec at [version] that can't be run: its login opens with a generate step whose `into` holds a number, so
/// running it throws a TypeError, not a FlowError, before anything is sent. It is built in code, not from text: the
/// phone's rule refuses every spec text that would do this (a number in `into`, a list `method`), and runFlow turns
/// transport failures into FlowErrors, so the page's catch-all for a spec "the checks didn't foresee" is reached by
/// handing it this object through `spec` or `fetchSpec`, the way session_test.dart reaches ensureFreshSession's
/// (final review I1).
FlowSpec _unrunnable(String version) => FlowSpec({..._bundled.vars, 'spec_version': version}, {
      ..._bundled.flows,
      'login': [
        {'id': 'boom', 'type': 'generate', 'make': 'random_hex', 'into': <Object?>[3]},
      ],
    });

/// [_fixedYaml] in format 2 with a step before `authorize` that uses a name only a skipped step sets: usable by the
/// phone's rule (a name an earlier step can set counts whatever its `when`), but running it fails before anything is
/// sent with a FlowUnknownName (reason `structure`, stage null): the spec's own mistake (fix round 2).
String _unknownNameYaml(String version) {
  const authorize = '    - id: authorize\n';
  final text = _fixedYaml(version);
  expect(authorize.allMatches(text), hasLength(1));
  expect('format: 1\n'.allMatches(text), hasLength(1));
  return text.replaceFirst('format: 1\n', 'format: 2\n').replaceFirst(
      authorize,
      '    - id: maybe\n      type: generate\n      when: {var: never}\n      make: random_hex\n      into: [never_set]\n'
      '    - id: use_it\n      type: assert\n      require:\n        - check: json_equals\n          path: x\n'
      '          value: "{{never_set}}"\n          error: "never"\n'
      '$authorize');
}

/// The bundled browser sign-in spec (format 3, its login opens the state's page with `open_browser`) at [version]:
/// usable by the phone's rule, so a server could serve it as a newer sign-in spec (final review minor 5).
String _browserYaml(String version) {
  final text = File(browserLoginSpecAsset).readAsStringSync();
  final from = RegExp(r'spec_version: "[^"]*"');
  expect(from.allMatches(text), hasLength(1));
  expect(text, contains('type: open_browser'));
  return text.replaceFirst(from, 'spec_version: "$version"');
}

/// What the server would answer with: [yaml] parsed and held to the phone's rule, as fetchLoginSpec does.
FetchedSpec _fetched(String yaml) {
  final spec = usableLoginSpec(yaml);
  expect(spec, isNotNull, reason: 'the test spec must be usable');
  return FetchedSpec(spec!, yaml, 'server');
}

/// A LoginSpecStore in the test's folder that counts saves and can be told to fail them.
class _CountingStore extends LoginSpecStore {
  final bool fail;
  int saves = 0;
  _CountingStore(Directory dir, {this.fail = false}) : super(dataDir: () => dir);

  @override
  Future<void> save(String yaml) async {
    saves += 1;
    if (fail) throw const FileSystemException('the disk is full');
    await super.save(yaml);
  }
}

File get _savedFile => File('${_dir.path}/login_spec.yaml');

/// How many times the login flow ran against [fake] (each run starts at the authorize page).
int _logins(FakeState fake) => fake.log.where((e) => e.$2.endsWith('/oauth2/v2.0/authorize')).length;

/// Signs in as the fake's own worker on a SignInPage with the given fetch, store and reporter. With [expectSignedIn],
/// pumps until SelectCenterPage is up (it then starts its own reads, which these tests don't follow) and returns it;
/// otherwise settles the page and returns null.
Future<SelectCenterPage?> _signIn(
  WidgetTester tester,
  FakeState fake, {
  required Future<FetchedSpec?> Function() fetchSpec,
  required LoginSpecStore store,
  SigninFailureReporter? reporter,
  Future<String?> Function(String url, String until)? browse,
  bool expectSignedIn = false,
}) async {
  SelectCenterPage? opened;
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      home: SignInPage(
        spec: _bundled,
        sessionStore: SessionStore(dataDir: () => _dir),
        reportSigninFailure: reporter ?? (e, v) async {},
        fetchSpec: fetchSpec,
        specStore: store,
        fetchHosts: () async => null, // no host list (SL-R18 is sign_in_hosts_test.dart's)
        browse: browse,
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
    // Leave the page before its own state reads go anywhere.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, fake.client);
  return opened;
}

void main() {
  // This file's widget tests load the state-reads spec (state_client.dart's stateReadsSpec) and other assets through
  // rootBundle; both caches keep the Future, which belongs to that test's fake async zone. Forget them after each
  // test, or a later test (in CI's one-isolate bundle, in another file) awaits them forever.
  tearDown(() {
    rootBundle.clear();
    resetStateReadsSpec();
  });

  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_sign_in_retry_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

  test('the test specs: the newer one is newer, and only the fixed one looks for "csrfToken"', () {
    expect(compareSpecVersions(_version(1), _bundled.specVersion), greaterThan(0));
    expect(compareSpecVersions(_version(-1), _bundled.specVersion), lessThan(0));
    expect(_fixedYaml(_version(1)), contains('"csrfToken"'));
    expect(_sameYaml(_version(1)), isNot(contains('"csrfToken"')));
  });

  testWidgets('a structure failure, then a newer spec that works: signed in with it, and it is saved once',
      (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir);
    final newYaml = _fixedYaml(_version(1));
    var fetches = 0;
    final reports = <(FlowError, String?)>[];

    final page = await _signIn(tester, fake,
        fetchSpec: () async {
          fetches += 1;
          return _fetched(newYaml);
        },
        store: store,
        reporter: (e, v) async => reports.add((e, v)),
        expectSignedIn: true);

    expect(page, isNotNull);
    expect(page!.spec.specVersion, _version(1));
    expect(page.session.email, fakeEmail);
    expect(fetches, 1);
    expect(_logins(fake), 2);
    expect(fake.logins, 1); // one token exchange: the retry's
    expect(store.saves, 1);
    expect(_savedFile.readAsStringSync(), newYaml);
    expect(await SessionStore(dataDir: () => _dir).load(), isNotNull);
    // Only the first failure was reported, with the spec that failed.
    expect(reports, hasLength(1));
    expect((reports.single.$1.step, reports.single.$1.reason), ('require_page_fields', 'structure'));
    expect(reports.single.$2, _bundled.specVersion);
  });

  testWidgets("a fetched spec that opens the state's page is never tried on the password path", (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir);
    final reports = <(FlowError, String?)>[];
    final browsed = <String>[];

    await _signIn(tester, fake,
        fetchSpec: () async => _fetched(_browserYaml(_version(1))),
        store: store,
        reporter: (e, v) async => reports.add((e, v)),
        browse: (url, until) async {
          browsed.add(url);
          return null;
        });

    expect(tester.takeException(), isNull);
    expect(browsed, isEmpty); // a fetched spec never gets the page's browse
    expect(_logins(fake), 1); // the first try only: the page itself refuses a browser spec served as login.yaml
    expect(reports.map((r) => (r.$1.reason, r.$2)), [('structure', _bundled.specVersion)]);
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(find.text(browserSigninSuggestion), findsOneWidget);
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(store.saves, 0);
    expect(_savedFile.existsSync(), isFalse);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('a newer spec that works but cannot be saved still signs in with it', (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir, fail: true);

    final page = await _signIn(tester, fake,
        fetchSpec: () async => _fetched(_fixedYaml(_version(1))), store: store, expectSignedIn: true);

    expect(page, isNotNull);
    expect(page!.spec.specVersion, _version(1));
    expect(store.saves, 1);
    expect(_savedFile.existsSync(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a newer spec that also fails: its failure is shown and reported with its version, nothing is saved',
      (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir);
    var fetches = 0;
    final reports = <(FlowError, String?)>[];

    await _signIn(tester, fake,
        fetchSpec: () async {
          fetches += 1;
          return _fetched(_sameYaml(_version(1)));
        },
        store: store,
        reporter: (e, v) async => reports.add((e, v)));

    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(_logins(fake), 2); // the first try and exactly one retry
    expect(fetches, 1); // no fetch after the retry
    expect(store.saves, 0);
    expect(_savedFile.existsSync(), isFalse);
    expect(reports.map((r) => r.$2), [_bundled.specVersion, _version(1)]);
    expect(reports.map((r) => r.$1.reason), ['structure', 'structure']);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget); // no longer submitting
  });

  testWidgets("a retry that fails another way shows that failure's own message", (tester) async {
    // The newer spec gets past the page, then the state's SelfAsserted answers 503: reason `unavailable`.
    final fake = FakeState()
      ..pageHtml = _renamedFieldPage
      ..selfAssertedStatus = 503;
    final store = _CountingStore(_dir);
    final reports = <(FlowError, String?)>[];

    await _signIn(tester, fake,
        fetchSpec: () async => _fetched(_fixedYaml(_version(1))),
        store: store,
        reporter: (e, v) async => reports.add((e, v)));

    expect(reports, hasLength(2));
    final (retryError, retryVersion) = reports.last;
    expect(retryError.reason, isNot('structure'));
    expect(retryError.reason, isNot('credentials'));
    expect(retryVersion, _version(1));
    expect(find.text(retryError.toString()), findsOneWidget);
    expect(find.text(stateSigninChangedMessage), findsNothing);
    expect(store.saves, 0);
  });

  for (final (label, by) in [('the same', 0), ('an older', -1)]) {
    testWidgets('$label version is not tried', (tester) async {
      final fake = FakeState()..pageHtml = _renamedFieldPage;
      final store = _CountingStore(_dir);
      var fetches = 0;

      await _signIn(tester, fake,
          fetchSpec: () async {
            fetches += 1;
            return _fetched(_fixedYaml(_version(by)));
          },
          store: store);

      expect(fetches, 1);
      expect(_logins(fake), 1);
      expect(store.saves, 0);
      expect(find.text(stateSigninChangedMessage), findsOneWidget);
    });
  }

  testWidgets('a wrong password never asks for a spec', (tester) async {
    final fake = FakeState()..rejectLogin = true;
    final store = _CountingStore(_dir);
    var fetches = 0;

    await _signIn(tester, fake,
        fetchSpec: () async {
          fetches += 1;
          return _fetched(_fixedYaml(_version(1)));
        },
        store: store);

    expect(fetches, 0);
    expect(_logins(fake), 1);
    expect(find.text('the state system refused the login: bad password ***'), findsOneWidget);
  });

  final noSpec = <String, Future<FetchedSpec?> Function()>{
    'answers null': () async => null,
    'fails': () async => throw StateError('the fetch broke'),
    'throws before returning a Future': () => throw StateError('the fetch itself broke'),
  };
  for (final MapEntry(key: label, value: fetch) in noSpec.entries) {
    testWidgets('a fetch that $label leaves the original message', (tester) async {
      final fake = FakeState()..pageHtml = _renamedFieldPage;
      final store = _CountingStore(_dir);

      await _signIn(tester, fake, fetchSpec: fetch, store: store);

      expect(find.text(stateSigninChangedMessage), findsOneWidget);
      expect(_logins(fake), 1);
      expect(store.saves, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('C1: a newer spec that runs to the end without a token is not saved; the first message is shown',
      (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir);
    final reports = <(FlowError, String?)>[];

    await _signIn(tester, fake,
        fetchSpec: () async => _fetched(_noTokenYaml(_version(1))),
        store: store,
        reporter: (e, v) async => reports.add((e, v)));

    expect(tester.takeException(), isNull);
    expect(_logins(fake), 2); // the first try and the retry, which ran to the end
    expect(fake.logins, 1); // the retry's token exchange happened...
    expect(store.saves, 0); // ...but gave no token, so nothing was saved
    expect(_savedFile.existsSync(), isFalse);
    expect(await SessionStore(dataDir: () => _dir).load(), isNull);
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(reports.map((r) => (r.$1.reason, r.$2)), [('structure', _bundled.specVersion), ('structure', _version(1))]);
    expect(reports.last.$1.step, 'token');
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets("C1: a token-less retry after an outage shows the first failure's own message", (tester) async {
    // The first try meets a 503 on the sign-in page (`unavailable`); by the time the newer spec runs, the page is back
    // (with the renamed field the newer spec looks for), and that spec runs to the end without a token.
    final fake = FakeState()..pageStatus = 503;
    final reports = <(FlowError, String?)>[];

    await _signIn(tester, fake,
        fetchSpec: () async {
          fake
            ..pageStatus = 200
            ..pageHtml = _renamedFieldPage;
          return _fetched(_noTokenYaml(_version(1)));
        },
        store: _CountingStore(_dir),
        reporter: (e, v) async => reports.add((e, v)));

    expect(tester.takeException(), isNull);
    expect(_logins(fake), 2);
    expect(reports.map((r) => (r.$1.reason, r.$2)), [('unavailable', _bundled.specVersion), ('structure', _version(1))]);
    expect(find.text(reports.first.$1.toString()), findsOneWidget);
    expect(find.text(stateSigninChangedMessage), findsNothing);
    expect(_savedFile.existsSync(), isFalse);
  });

  testWidgets("a newer spec that uses a name nothing set is reported as structure and shows the first failure",
      (tester) async {
    // The first try meets a 503 (`unavailable`); the newer spec fails before sending anything, on its own mistake.
    final fake = FakeState()..pageStatus = 503;
    final reports = <(FlowError, String?)>[];

    await _signIn(tester, fake,
        fetchSpec: () async {
          fake.pageStatus = 200;
          return _fetched(_unknownNameYaml(_version(1)));
        },
        store: _CountingStore(_dir),
        reporter: (e, v) async => reports.add((e, v)));

    expect(tester.takeException(), isNull);
    expect(_logins(fake), 1); // the retry sent nothing
    expect(reports.map((r) => (r.$1.reason, r.$2)), [('unavailable', _bundled.specVersion), ('structure', _version(1))]);
    expect(reports.last.$1, isA<FlowUnknownName>());
    expect((reports.last.$1.step, reports.last.$1.stage), ('use_it', null));
    expect(find.text(reports.first.$1.toString()), findsOneWidget);
    expect(_savedFile.existsSync(), isFalse);
  });

  testWidgets('I1: a newer spec that throws something other than a FlowError is a failed retry', (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final store = _CountingStore(_dir);
    final reports = <(FlowError, String?)>[];

    await _signIn(tester, fake,
        // The yaml beside the unrunnable spec is a usable text; it would be saved only after a session, which never comes.
        fetchSpec: () async => FetchedSpec(_unrunnable(_version(1)), _fixedYaml(_version(1)), 'server'),
        store: store,
        reporter: (e, v) async => reports.add((e, v)));

    expect(tester.takeException(), isNull);
    expect(_logins(fake), 1); // the retry threw before sending anything
    expect(store.saves, 0);
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(reports.map((r) => (r.$1.reason, r.$2)), [('structure', _bundled.specVersion), ('structure', _version(1))]);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('I1: a first spec that throws something other than a FlowError is reported and a newer one is tried',
      (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage; // the newer spec's regex finds the field
    final store = _CountingStore(_dir);
    final reports = <(FlowError, String?)>[];
    SelectCenterPage? opened;

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: SignInPage(
          spec: _unrunnable(_bundled.specVersion!),
          sessionStore: SessionStore(dataDir: () => _dir),
          reportSigninFailure: (e, v) async => reports.add((e, v)),
          fetchSpec: () async => _fetched(_fixedYaml(_version(1))),
          specStore: store,
          fetchHosts: () async => null,
        ),
      ));
      await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
      await tester.enterText(find.widgetWithText(TextFormField, 'Password'), fakePassword);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      for (var i = 0; i < 100 && opened == null; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        final found = find.byType(SelectCenterPage, skipOffstage: false);
        if (found.evaluate().isNotEmpty) opened = tester.widget<SelectCenterPage>(found);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, fake.client);

    expect(tester.takeException(), isNull);
    expect(opened?.spec.specVersion, _version(1));
    expect(reports.single.$1.reason, 'structure');
    expect(store.saves, 1);
  });

  testWidgets('M3: a retry that fails on the password shows that message and is not reported', (tester) async {
    // The bundled spec fails on the page (structure); the newer spec gets past it, and B2C refuses the password.
    final fake = FakeState()
      ..pageHtml = _renamedFieldPage
      ..rejectLogin = true;
    final store = _CountingStore(_dir);
    final reports = <(FlowError, String?)>[];

    await _signIn(tester, fake,
        fetchSpec: () async => _fetched(_fixedYaml(_version(1))),
        store: store,
        reporter: (e, v) async => reports.add((e, v)));

    expect(_logins(fake), 2);
    expect(reports, hasLength(1)); // only the first failure
    expect(reports.single.$2, _bundled.specVersion);
    expect(find.text('the state system refused the login: bad password ***'), findsOneWidget);
    expect(store.saves, 0);
  });

  testWidgets('the page stays submitting while the spec is fetched', (tester) async {
    final fake = FakeState()..pageHtml = _renamedFieldPage;
    final pending = Completer<FetchedSpec?>();
    var fetches = 0;

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: SignInPage(
          spec: _bundled,
          sessionStore: SessionStore(dataDir: () => _dir),
          reportSigninFailure: (e, v) async {},
          fetchSpec: () {
            fetches += 1;
            return pending.future;
          },
          specStore: _CountingStore(_dir),
          fetchHosts: () async => null,
        ),
      ));
      await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
      await tester.enterText(find.widgetWithText(TextFormField, 'Password'), fakePassword);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      for (var i = 0; i < 50 && fetches == 0; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(fetches, 1);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsNothing); // the spinner instead
      expect(find.text(stateSigninChangedMessage), findsNothing);

      pending.complete(null);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
      expect(find.text(stateSigninChangedMessage), findsOneWidget);
    }, fake.client);
  });
}
