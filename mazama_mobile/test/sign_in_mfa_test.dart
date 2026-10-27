// SL-R13 on the sign-in page: when a sign-in spec's `await_input` step needs a value (an MFA code), SignInPage asks the
// worker - through its injected `ask`, or through askSignInValue's dialog when none is given - on the first attempt
// and on the SL-D11 retry alike. A cancelled question shows "Sign-in cancelled.", is not reported and starts no spec
// fetch. The state system is test/flow/fake_state.dart's FakeState with its `mfaCode` set, through http.runWithClient;
// the spec fetch, the store and the reporter are injected, as in sign_in_retry_test.dart.
//
// The bundled spec knows no MFA round: against an MFA state its `confirmed` step gets a 400 (a `structure` failure),
// so a newer spec with the round (the one SPEC.md shows, as in flow_runner_test.dart's phase-3 group) is fetched and
// retried.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_spec_client.dart';
import 'package:mazama_mobile/login_spec_store.dart';
import 'package:mazama_mobile/main.dart';
import 'package:mazama_mobile/select_center_page.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/session_store.dart';

import 'flow/fake_state.dart';

const _code = '123456';
const _prompt = 'Enter the most recent code the state sent you';

late Directory _dir;
final String _bundledYaml = File('assets/flows/login.yaml').readAsStringSync();
final FlowSpec _bundled = FlowSpec.fromYaml(_bundledYaml);

/// [_bundled]'s spec_version moved one on in its number after the dot (same date).
String _newerVersion() {
  final v = _bundled.specVersion!;
  final dot = v.lastIndexOf('.');
  return '${v.substring(0, dot)}.${int.parse(v.substring(dot + 1)) + 1}';
}

/// The bundled login.yaml at [version] in format 2 with an MFA round before `confirmed`: SelfAsserted's `mfa` is
/// captured, and when it is true the worker is asked for the code, which a second SelfAsserted sends.
String _mfaYaml(String version) {
  var text = _bundledYaml;
  const status = '        - {var: b2c_status, source: body, json: status}\n';
  final from = 'spec_version: "${_bundled.specVersion}"';
  for (final part in ['format: 1\n', '    - id: confirmed\n', status, from]) {
    expect(part.allMatches(text), hasLength(1), reason: part);
  }
  text = text.replaceFirst('format: 1\n', 'format: 2\n').replaceFirst(from, 'spec_version: "$version"');
  text = text.replaceFirst(status, '$status        - {var: mfa, source: body, json: mfa}\n');
  return text.replaceFirst('    - id: confirmed\n', '$_mfaSteps    - id: confirmed\n');
}

/// The MFA round SPEC.md shows (flow_runner_test.dart's _mfaSteps).
const _mfaSteps = r'''
    - id: ask_code
      type: await_input
      when: {var: mfa, matches: "^(true|True)$"}
      into: mfa_code
      prompt: "Enter the most recent code the state sent you"
      secret: true

    - id: send_code
      type: request
      when: {var: mfa, matches: "^(true|True)$"}
      method: POST
      url: "{{b2c}}/{{pol}}/SelfAsserted"
      params: {tx: "{{trans}}", p: "{{pol}}"}
      headers:
        X-CSRF-TOKEN: "{{csrf}}"
        X-Requested-With: XMLHttpRequest
        Origin: "{{b2c_host}}"
        Referer: "{{page_url}}"
      form:
        request_type: RESPONSE
        code: "{{mfa_code}}"
      require:
        - check: status_in
          values: [200]
          reason: unavailable
          error: "the code form did not answer: HTTP {status}"
        - check: json_equals
          path: status
          value: "200"
          reason: credentials
          error: "the code was refused: {{mfa_message}}"
      capture_on_fail:
        - {var: mfa_message, source: body, json: message, default: "wrong code"}

''';

/// What the server would answer with: [yaml] parsed and held to the phone's rule, as fetchLoginSpec does.
FetchedSpec _fetched(String yaml) {
  final spec = usableLoginSpec(yaml);
  expect(spec, isNotNull, reason: 'the test spec must be usable');
  return FetchedSpec(spec!, yaml, 'server');
}

/// A LoginSpecStore in the test's folder that counts saves.
class _CountingStore extends LoginSpecStore {
  int saves = 0;
  _CountingStore(Directory dir) : super(dataDir: () => dir);

  @override
  Future<void> save(String yaml) async {
    saves += 1;
    await super.save(yaml);
  }
}

/// SelfAsserted posts the fake was sent (the email/password one, then the code one when there is an MFA round).
int _selfAsserted(FakeState fake) => fake.log.where((e) => e.$2.endsWith('/SelfAsserted')).length;

/// How many times the login flow ran against [fake] (each run starts at the authorize page).
int _logins(FakeState fake) => fake.log.where((e) => e.$2.endsWith('/oauth2/v2.0/authorize')).length;

Finder get _dialogField => find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

/// Pumps (explicitly: the sign-in button's spinner never settles) until [found] finds something or time runs out.
Future<void> _pumpUntil(WidgetTester tester, Finder found) async {
  for (var i = 0; i < 100 && found.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Pumps a SignInPage on [spec] against [fake], fills in the fake's worker and presses Sign in, then runs [during]
/// (still inside the fake's client zone) before leaving the page. With [ask] null the page uses its own dialog.
Future<void> _signIn(
  WidgetTester tester,
  FakeState fake, {
  FlowSpec? spec,
  Future<String?> Function(String, bool)? ask,
  required Future<FetchedSpec?> Function() fetchSpec,
  required LoginSpecStore store,
  required SigninFailureReporter reporter,
  required Future<void> Function() during,
}) async {
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      home: SignInPage(
        spec: spec ?? _bundled,
        sessionStore: SessionStore(dataDir: () => _dir),
        reportSigninFailure: reporter,
        fetchSpec: fetchSpec,
        specStore: store,
        fetchHosts: () async => null, // no host list (SL-R18 is sign_in_hosts_test.dart's)
        ask: ask,
      ),
    ));
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), fakePassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await during();
    // Leave the page before SelectCenterPage's own state reads (if it opened) go anywhere.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, fake.client);
}

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_sign_in_mfa_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

  test('the message is the one SL-R13 gives', () {
    expect(signInCancelledMessage, 'Sign-in cancelled.');
  });

  testWidgets('a newer MFA spec retried through SL-D11 asks in the dialog, and the code signs in', (tester) async {
    final fake = FakeState(mfaCode: _code);
    final store = _CountingStore(_dir);
    final newYaml = _mfaYaml(_newerVersion());
    var fetches = 0;
    final reports = <(FlowError, String?)>[];
    SelectCenterPage? opened;

    await _signIn(tester, fake,
        fetchSpec: () async {
          fetches += 1;
          return _fetched(newYaml);
        },
        store: store,
        reporter: (e, v) async => reports.add((e, v)),
        during: () async {
          await _pumpUntil(tester, find.byType(AlertDialog));
          expect(find.text(_prompt), findsOneWidget);
          expect(tester.widget<TextField>(_dialogField).obscureText, isTrue);
          await tester.enterText(_dialogField, _code);
          await tester.pump(); // let Continue see the code
          await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
          final page = find.byType(SelectCenterPage, skipOffstage: false);
          await _pumpUntil(tester, page);
          if (page.evaluate().isNotEmpty) opened = tester.widget<SelectCenterPage>(page);
        });

    expect(opened, isNotNull);
    expect(opened!.spec.specVersion, _newerVersion());
    expect(opened!.session.email, fakeEmail);
    expect(fake.mfaPassed, isTrue);
    expect(fake.logins, 1); // one token exchange: the retry's
    expect(_logins(fake), 2);
    expect(fetches, 1);
    expect(store.saves, 1);
    // Only the first (bundled) failure was reported.
    expect(reports, hasLength(1));
    expect((reports.single.$1.step, reports.single.$1.reason), ('confirmed', 'structure'));
    expect(reports.single.$2, _bundled.specVersion);
  });

  // Final review Minor 7: a wrong code on the retry is the worker's to fix, like a wrong password.
  testWidgets("a wrong code on the retry shows the retry's own refusal, is not reported and saves nothing",
      (tester) async {
    final fake = FakeState(mfaCode: _code);
    final store = _CountingStore(_dir);
    final reports = <(FlowError, String?)>[];

    await _signIn(tester, fake,
        ask: (prompt, secret) async => '654321',
        fetchSpec: () async => _fetched(_mfaYaml(_newerVersion())),
        store: store,
        reporter: (e, v) async => reports.add((e, v)),
        during: () async {
          final refused = find.textContaining('the code was refused');
          await _pumpUntil(tester, refused);
          expect(refused, findsOneWidget);
          expect(find.textContaining('wrong code ***'), findsOneWidget); // the code itself is scrubbed
          expect(find.textContaining('654321'), findsNothing);
          expect(find.text(stateSigninChangedMessage), findsNothing);
        });

    expect(reports.map((r) => (r.$1.step, r.$1.reason)), [('confirmed', 'structure')]); // the bundled spec's only
    expect(store.saves, 0);
    expect(fake.mfaPassed, isFalse);
    expect(fake.logins, 0);
    expect(await SessionStore(dataDir: () => _dir).load(), isNull);
  });

  // Final review Minor 7: the whole chain after a retry saved the MFA spec - chosen at the next start-up, then used to
  // renew without asking anyone (ensureFreshSession takes no `ask`, and renew sends no sign-in form).
  test('a saved MFA spec is chosen at start-up and renews the session it signed in without asking', () async {
    final fake = FakeState(mfaCode: _code);
    final store = LoginSpecStore(dataDir: () => _dir);
    await store.save(_mfaYaml(_newerVersion()));

    final chosen = await store.current(_bundledYaml);
    expect((chosen.specVersion, chosen.format), (_newerVersion(), 2));

    final asked = <String>[];
    final signedInAt = DateTime.utc(2026, 1, 1, 12);
    final result = await runFlow(chosen, 'login', {'email': fakeEmail, 'password': fakePassword},
        client: fake.client(), ask: (prompt, secret) async {
      asked.add(prompt);
      return _code;
    });
    expect(asked, [_prompt]);
    final session = Session.fromFlowResult(result, email: fakeEmail, now: () => signedInAt);

    final formsBefore = _selfAsserted(fake);
    final loginsBefore = _logins(fake);
    final later = signedInAt.add(const Duration(hours: 2)); // past the token's hour
    final renewed = await ensureFreshSession(session, chosen, client: fake.client(), now: () => later);

    expect(fake.refreshes, 1);
    expect(renewed.accessToken, isNot(session.accessToken));
    expect(renewed.needsRenewal(now: () => later), isFalse);
    expect(_selfAsserted(fake), formsBefore); // no password or code form was sent
    expect(_logins(fake), loginsBefore);
    expect(asked, hasLength(1));
  });

  testWidgets('an injected ask is asked once, with the prompt and secret, on the retry', (tester) async {
    final fake = FakeState(mfaCode: _code);
    final asked = <(String, bool)>[];
    SelectCenterPage? opened;

    await _signIn(tester, fake,
        ask: (prompt, secret) async {
          asked.add((prompt, secret));
          return _code;
        },
        fetchSpec: () async => _fetched(_mfaYaml(_newerVersion())),
        store: _CountingStore(_dir),
        reporter: (e, v) async {},
        during: () async {
          final page = find.byType(SelectCenterPage, skipOffstage: false);
          await _pumpUntil(tester, page);
          if (page.evaluate().isNotEmpty) opened = tester.widget<SelectCenterPage>(page);
        });

    expect(opened, isNotNull);
    expect(asked, [(_prompt, true)]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Cancel on the retry: "Sign-in cancelled.", only the first failure reported, one fetch, nothing saved',
      (tester) async {
    final fake = FakeState(mfaCode: _code);
    final store = _CountingStore(_dir);
    var fetches = 0;
    final reports = <(FlowError, String?)>[];

    await _signIn(tester, fake,
        fetchSpec: () async {
          fetches += 1;
          return _fetched(_mfaYaml(_newerVersion()));
        },
        store: store,
        reporter: (e, v) async => reports.add((e, v)),
        during: () async {
          await _pumpUntil(tester, find.byType(AlertDialog));
          await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
          await _pumpUntil(tester, find.text(signInCancelledMessage));
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text(signInCancelledMessage), findsOneWidget);
          expect(find.text(stateSigninChangedMessage), findsNothing);
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget); // no longer submitting
        });

    expect(fetches, 1);
    expect(reports.map((r) => r.$1.reason), ['structure']); // the bundled spec's, not the cancel
    expect(store.saves, 0);
    expect(_logins(fake), 2);
    expect(_selfAsserted(fake), 2); // one per run; no code was sent
    expect(fake.logins, 0);
    expect(await SessionStore(dataDir: () => _dir).load(), isNull);
  });

  for (final (label, answer) in [('no answer', null), ('an empty answer', '')]) {
    testWidgets('$label on the first attempt: "Sign-in cancelled.", no report, no fetch', (tester) async {
      final fake = FakeState(mfaCode: _code);
      var fetches = 0;
      var asked = 0;
      final reports = <FlowError>[];

      await _signIn(tester, fake,
          spec: FlowSpec.fromYaml(_mfaYaml(_bundled.specVersion!)),
          ask: (p, s) async {
            asked += 1;
            return answer;
          },
          fetchSpec: () async {
            fetches += 1;
            return null;
          },
          store: _CountingStore(_dir),
          reporter: (e, v) async => reports.add(e),
          during: () async {
            await _pumpUntil(tester, find.text(signInCancelledMessage));
            expect(find.text(signInCancelledMessage), findsOneWidget);
          });

      expect(asked, 1);
      expect(fetches, 0);
      expect(reports, isEmpty);
      expect(_selfAsserted(fake), 1);
      expect(fake.logins, 0);
    });
  }

  testWidgets('the bundled spec signs in without ever asking', (tester) async {
    final fake = FakeState();
    var asked = 0;
    SelectCenterPage? opened;

    await _signIn(tester, fake,
        ask: (p, s) async {
          asked += 1;
          return _code;
        },
        fetchSpec: () async => null,
        store: _CountingStore(_dir),
        reporter: (e, v) async {},
        during: () async {
          final page = find.byType(SelectCenterPage, skipOffstage: false);
          await _pumpUntil(tester, page);
          if (page.evaluate().isNotEmpty) opened = tester.widget<SelectCenterPage>(page);
          expect(find.byType(AlertDialog), findsNothing);
        });

    expect(opened, isNotNull);
    expect(asked, 0);
  });

  testWidgets('the bundled spec against an MFA state shows no dialog: its own failure, reported', (tester) async {
    final fake = FakeState(mfaCode: _code);
    final reports = <FlowError>[];

    await _signIn(tester, fake,
        fetchSpec: () async => null,
        store: _CountingStore(_dir),
        reporter: (e, v) async => reports.add(e),
        during: () async {
          await _pumpUntil(tester, find.text(stateSigninChangedMessage));
          expect(find.text(stateSigninChangedMessage), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
        });

    expect(reports.map((e) => (e.step, e.reason)), [('confirmed', 'structure')]);
  });
}
