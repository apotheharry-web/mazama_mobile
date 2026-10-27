// `flutter create .` generates a stock widget test that pumps a `MyApp` class - we don't have one, our entry
// point is `MazamaApp` (see lib/main.dart). This is a smoke test against the real SignInPage: it loads
// assets/flows/login.yaml (so run tool/sync_flows.sh before `flutter test`, same as everywhere else in this
// repo) and checks the form actually renders, without making any network call - the real login flow logic is
// covered independently in test/flow/, against a fake transport, not a widget tree.
//
// MazamaApp now checks for a saved session before deciding to show SignInPage at all (see main.dart's
// _resolveHome and session_store.dart) - every pump here uses a SessionStore pointed at a fresh temp directory,
// never the real default app-data directory, so these tests always see "nothing saved yet" regardless of what
// a real run on this machine may have written, and never leave a file behind for a later test run to trip on.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_hosts_store.dart';
import 'package:mazama_mobile/login_spec_store.dart';
import 'package:mazama_mobile/reply_store.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_link.dart';
import 'package:mazama_mobile/server_outbox.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/session_store.dart';

import 'fake_timers.dart';
import 'host_list_signing.dart';

import 'package:mazama_mobile/main.dart';

late Directory _tempDir;

/// A server link of the test's own, in its folder, whose probe never answers (README R56).
ServerLink _link() {
  final timers = FakeTimers();
  final health = ServerHealth(probe: () async => false, startTimer: timers.start);
  return ServerLink(
    health: health,
    outbox: ServerOutbox(health: health, store: OutboxStore(dataDir: () => _tempDir), send: (e) async {}, startTimer: timers.start),
    catchUp: CatchUpWork(
        health: health,
        store: CatchUpStore(dataDir: () => _tempDir),
        submitCoa: (l, a) async => true,
        uploadSnapshot: (s) async {},
        auth: () async => null),
    replies: ReplyStore(dataDir: () => _tempDir),
  );
}

MazamaApp _app({ServerLink? link}) => MazamaApp(sessionStore: SessionStore(dataDir: () => _tempDir), serverLink: link ?? _link());

void main() {
  // rootBundle.loadString caches its Future by asset key for the lifetime of the whole test *process*, not
  // per-test - without clearing it, the second test to load assets/flows/login.yaml can get the first test's
  // already-created Future, straddling two different testWidgets async zones, which is what was making
  // pumpAndSettle hang on this exact asset load (only on the second test to touch it, never the first).
  tearDown(() => rootBundle.clear());

  setUp(() => _tempDir = Directory.systemTemp.createTempSync('mazama_widget_test_'));
  tearDown(() => _tempDir.deleteSync(recursive: true));

  testWidgets('SignInPage renders the email/password form once the flow spec loads', (WidgetTester tester) async {
    await tester.pumpWidget(_app());

    // MazamaApp resolves its home asynchronously (loading the flow spec, checking for a saved session), so the
    // first frame is just a spinner - pumpAndSettle lets that resolve before asserting on the form it unlocks.
    await tester.pumpAndSettle();

    expect(find.text('Mazama sign-in'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('Sign in button is disabled with empty fields until validated', (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    // No network call happens here - an empty form fails Flutter's own form validation before _submit ever
    // builds a request, so this never leaves the device.
    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
  });

  // README R56: one banner above every page while Mazama's server can't be reached, from the app's own link.
  testWidgets('the server link banner: none online; over the sign-in page while offline, with since when', (tester) async {
    final link = _link();
    addTearDown(link.dispose);
    await tester.pumpWidget(_app(link: link));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('server-link-banner')), findsNothing);

    link.health.markUnreachable();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('server-link-banner')), findsOneWidget);
    expect(find.textContaining('Selling still works.'), findsOneWidget);
    expect(find.text('Mazama sign-in'), findsOneWidget); // the page is still there under it
    expect(identical(serverLink, link), isTrue); // the app's link is the one every /p/ client reports to
  });

  // Final review I1: a saved spec whose renew fails with something other than a FlowError, with a stored session that is
  // due for renewal, must not leave the app on its start-up spinner: the saved spec is set aside (kept as .bad) and
  // the bundled one decides. Here the bundled renew is refused by the state (HTTP 400): a real sign-in.
  //
  // How the non-FlowError is produced: runFlow turns every transport failure into a FlowError, and the usable rule now
  // refuses the spec shapes that used to make it throw (a list `method`, a number in `into`), so the failure comes from
  // the injected state instead. The saved spec is usable but its renew no longer checks that a token came back; the
  // state answers that token request with a 200 holding no token, so Session.fromFlowResult throws a FlowSpecError in
  // ensureFreshSession's catch-all. (session_test.dart reaches the same catch-all with a spec built in code.)
  testWidgets('a saved spec with a broken renew and a stored session gives a page, not a spinner', (tester) async {
    final bundledYaml = File('assets/flows/login.yaml').readAsStringSync();
    final version = FlowSpec.fromYaml(bundledYaml).specVersion!;
    final dot = version.lastIndexOf('.');
    final newer = '${version.substring(0, dot)}.${int.parse(version.substring(dot + 1)) + 1}';
    const renewCheck = '      then_require:\n'
        '        - check: truthy\n'
        '          vars: [access_token]\n'
        '          reason: structure\n'
        '          error: "the token refresh returned no access token"\n';
    expect(renewCheck.allMatches(bundledYaml), hasLength(1));
    final saved =
        bundledYaml.replaceFirst('spec_version: "$version"', 'spec_version: "$newer"').replaceFirst(renewCheck, '');
    expect(usableLoginSpec(saved)?.specVersion, newer); // the phone's checks don't catch this one
    File('${_tempDir.path}/login_spec.yaml').writeAsStringSync(saved);
    await SessionStore(dataDir: () => _tempDir)
        .save(const Session(accessToken: 'OLD', refreshToken: 'R', email: 'worker@example.com', expiresAtMs: 0).toJson());

    final requests = <String>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
    }, () => http_testing.MockClient((req) async {
          requests.add('${req.method} ${req.url.path}');
          // The first token request is the saved spec's renew: answered, but with no token. The next is the bundled
          // renew's, which the state refuses.
          return requests.length == 1
              ? http.Response('{"token_type": "Bearer"}', 200)
              : http.Response('{"error": "invalid_grant"}', 400);
        }));

    expect(tester.takeException(), isNull);
    expect(find.text('Mazama sign-in'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(File('${_tempDir.path}/login_spec.yaml').existsSync(), isFalse);
    expect(File('${_tempDir.path}/login_spec.yaml.bad').readAsStringSync(), saved);
    // One token request from each spec: the saved renew's (no token), then the bundled renew's (refused).
    expect(requests, hasLength(2));
    expect(requests, everyElement(allOf(startsWith('POST '), endsWith('/oauth2/v2.0/token'))));
    expect(await SessionStore(dataDir: () => _tempDir).load(), isNull);
  });

  // Fix round 2: a saved renew that uses a name nothing set fails with a FlowError that involved no request (stage
  // null, reason structure). That is the spec's own mistake: the saved spec is set aside, as for any other broken renew,
  // instead of being kept as a momentary outage ("try again shortly").
  testWidgets('a saved spec whose renew uses a name nothing set is set aside', (tester) async {
    final bundledYaml = File('assets/flows/login.yaml').readAsStringSync();
    final version = FlowSpec.fromYaml(bundledYaml).specVersion!;
    final dot = version.lastIndexOf('.');
    final newer = '${version.substring(0, dot)}.${int.parse(version.substring(dot + 1)) + 1}';
    const renewStart = '  renew:\n    - id: token\n';
    const grant = '        grant_type: refresh_token\n';
    expect(renewStart.allMatches(bundledYaml), hasLength(1));
    expect(grant.allMatches(bundledYaml), hasLength(1));
    expect('format: 1\n'.allMatches(bundledYaml), hasLength(1));
    // Usable (format 2; a name an earlier step can set counts whatever its `when`), but `renew_nonce` is never set at
    // run time.
    final saved = bundledYaml
        .replaceFirst('format: 1\n', 'format: 2\n')
        .replaceFirst('spec_version: "$version"', 'spec_version: "$newer"')
        .replaceFirst(renewStart,
            '  renew:\n    - id: maybe\n      type: generate\n      when: {var: never}\n      make: random_hex\n'
            '      into: [renew_nonce]\n    - id: token\n')
        .replaceFirst(grant, '$grant        nonce: "{{renew_nonce}}"\n');
    expect(usableLoginSpec(saved)?.specVersion, newer);
    File('${_tempDir.path}/login_spec.yaml').writeAsStringSync(saved);
    await SessionStore(dataDir: () => _tempDir)
        .save(const Session(accessToken: 'OLD', refreshToken: 'R', email: 'worker@example.com', expiresAtMs: 0).toJson());

    final requests = <String>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
    }, () => http_testing.MockClient((req) async {
          requests.add('${req.method} ${req.url.path}');
          return http.Response('{"error": "invalid_grant"}', 400);
        }));

    expect(tester.takeException(), isNull);
    expect(find.text('Mazama sign-in'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(File('${_tempDir.path}/login_spec.yaml').existsSync(), isFalse);
    expect(File('${_tempDir.path}/login_spec.yaml.bad').readAsStringSync(), saved);
    // The saved renew sent nothing; the bundled renew sent one token request, which the state refused.
    expect(requests, hasLength(1));
    expect(requests.single, allOf(startsWith('POST '), endsWith('/oauth2/v2.0/token')));
    expect(await SessionStore(dataDir: () => _tempDir).load(), isNull);
  });

  // SL-R18: at start-up the saved host list is verified again with the bundled key before anything uses it; a list
  // signed with another key (here the vectors' TEST key, never the shipped one) is never put in use, and one in use before is
  // taken out.
  testWidgets('a saved host list that the bundled key does not verify is not used at start-up', (tester) async {
    addTearDown(() => useLoginHosts(null));
    final list = (await tester.runAsync(() => signedHostList('2026-11-01.1', ['login.example.gov'])))!;
    await LoginHostsStore(dataDir: () => _tempDir, publicKey: testPublicKey).save(list);
    useLoginHosts(list);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Mazama sign-in'), findsOneWidget);
    expect(loginHostsInUse, isNull);
    expect(currentAllowedHosts(), defaultAllowedHosts);
  });
}
