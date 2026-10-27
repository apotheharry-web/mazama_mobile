// SL-R5: SignInPage reports every failed sign-in except a wrong email or password, fire-and-forget, and says so
// in plain words when the state's sign-in page has changed. The state system is test/flow/fake_state.dart's
// FakeState, reached through http.runWithClient (SignInPage builds its own http.Client()); the reporter is
// injected, so nothing is posted to Mazama's server or written to disk, and so is the newer-spec fetch (none here).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/main.dart';
import 'package:mazama_mobile/session_store.dart';

import 'flow/fake_state.dart';

late Directory _dir;
final FlowSpec _spec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());

/// Signs in as the fake's own worker on a SignInPage whose requests all go to [clientFactory]'s clients.
Future<void> _signIn(WidgetTester tester, http.Client Function() clientFactory, SigninFailureReporter reporter) async {
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      home: SignInPage(
        spec: _spec,
        sessionStore: SessionStore(dataDir: () => _dir),
        reportSigninFailure: reporter,
        fetchSpec: () async => null, // no newer spec to retry with (SL-R10 is sign_in_retry_test.dart's)
        fetchHosts: () async => null, // nor a host list (SL-R18 is sign_in_hosts_test.dart's)
      ),
    ));
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), fakePassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
  }, clientFactory);
}

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_sign_in_failure_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

  test('the message is the one SL-R5 gives', () {
    expect(stateSigninChangedMessage, "The state's sign-in has changed. Mazama has been told.");
  });

  testWidgets("a changed sign-in page says so and is reported once, as structure, with the spec's version",
      (tester) async {
    final fake = FakeState()..pageHtml = '<html>new page</html>';
    final calls = <(FlowError, String?)>[];
    await _signIn(tester, fake.client, (e, v) async => calls.add((e, v)));

    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(calls, hasLength(1));
    final (error, version) = calls.single;
    expect((error.step, error.reason), ('require_page_fields', 'structure'));
    expect(version, _spec.vars['spec_version']);
    expect(version, isNotNull);
  });

  testWidgets('a wrong password shows the refusal and is not reported', (tester) async {
    final fake = FakeState()..rejectLogin = true;
    final calls = <FlowError>[];
    await _signIn(tester, fake.client, (e, v) async => calls.add(e));

    expect(find.text('the state system refused the login: bad password ***'), findsOneWidget);
    expect(find.text(stateSigninChangedMessage), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets('a transport failure (no reason) is reported and shows its own message', (tester) async {
    final calls = <FlowError>[];
    await _signIn(
      tester,
      () => http_testing.MockClient((req) async => throw http.ClientException('network is down', req.url)),
      (e, v) async => calls.add(e),
    );

    expect(calls, hasLength(1));
    expect(calls.single.reason, isNull);
    expect(find.text(calls.single.toString()), findsOneWidget);
    expect(find.text(stateSigninChangedMessage), findsNothing);
  });

  testWidgets('a reporter whose Future fails still leaves the message on screen', (tester) async {
    final fake = FakeState()..pageHtml = '<html>new page</html>';
    var called = 0;
    await _signIn(tester, fake.client, (e, v) async {
      called += 1;
      throw StateError('the report could not be sent');
    });

    expect(called, 1);
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reporter that throws before returning a Future still leaves the message on screen', (tester) async {
    final fake = FakeState()..pageHtml = '<html>new page</html>';
    var called = 0;
    await _signIn(tester, fake.client, (e, v) {
      called += 1;
      throw StateError('the reporter itself broke');
    });

    expect(called, 1);
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reporter that never finishes does not hold the message back', (tester) async {
    final fake = FakeState()..pageHtml = '<html>new page</html>';
    final never = Completer<void>();
    await _signIn(tester, fake.client, (e, v) => never.future);

    expect(never.isCompleted, isFalse);
    expect(find.text(stateSigninChangedMessage), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget); // no longer submitting
  });
}
