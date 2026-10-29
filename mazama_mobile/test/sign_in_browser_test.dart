// SL-R16: "Sign in on the state's page" on SignInPage. The browser sign-in spec is the bundled asset file read from
// disk (run tool/sync_flows.sh first if it is missing); the webview is replaced by an injected `browse` that answers as
// the state's page would; the state system is test/flow/fake_state.dart's FakeState through http.runWithClient
// (SignInPage builds its own http.Client()); the failure reporter and the newer-spec fetches are injected spies, so
// nothing reaches Mazama's server and the only files written are in a temp folder. The SL-R19 retry with a fetched
// browser spec is sign_in_browser_retry_test.dart's; here the fetch finds none.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/browser_login_spec.dart';
import 'package:mazama_mobile/browser_sign_in_page.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_spec_store.dart';
import 'package:mazama_mobile/main.dart';
import 'package:mazama_mobile/open_source_link.dart';
import 'package:mazama_mobile/select_center_page.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/state_client.dart' show resetStateReadsSpec;

import 'flow/fake_state.dart';

late Directory _dir;
final FlowSpec _login = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
final FlowSpec _browserSpec = FlowSpec.fromYaml(File(browserLoginSpecAsset).readAsStringSync());

typedef _Browse = Future<String?> Function(String url, String until);

/// What the state's page would do for [fake]: hands out CODE1 against the start URL's challenge (as the fake's own
/// `confirmed` does) and ends at the address [answer] gives for the start URL's `state`; null: the worker closed it.
_Browse _page(FakeState fake, String? Function(String state) answer, {List<String>? opened}) {
  return (url, until) async {
    opened?.add(url);
    expect(until, site);
    final q = Uri.parse(url).queryParameters;
    fake.codes['CODE1'] = q['code_challenge']!;
    return answer(q['state']!);
  };
}

/// The spies a test reads afterwards.
class _Spies {
  final reports = <FlowError>[];
  var fetches = 0;
  var browserFetches = 0;
}

Finder get _browserButton => find.widgetWithText(TextButton, signInOnStatePageLabel);

/// A password sign-in spec whose login only asks a question (SL-R13's `await_input`): with an `ask` that throws, its
/// FlowError comes through as it is (flow_runner.dart's _callBack); with one that answers null, reason `cancelled`.
final FlowSpec _askingSpec = FlowSpec({..._login.vars}, {
  ..._login.flows,
  'login': [
    {'id': 'ask_code', 'type': 'await_input', 'into': 'mfa_code', 'prompt': 'Enter the code'},
  ],
}, format: 2);

Widget _app(_Spies spies,
    {_Browse? browse,
    Future<FlowSpec> Function()? browserSpec,
    Future<String?> Function(String, bool)? ask,
    FlowSpec? spec,
    Future<bool> Function(Uri)? openLink}) {
  return MaterialApp(
    home: SignInPage(
      spec: spec ?? _login,
      sessionStore: SessionStore(dataDir: () => _dir),
      reportSigninFailure: (e, v) async => spies.reports.add(e),
      fetchSpec: () async {
        spies.fetches += 1;
        return null; // no newer spec (SL-R10 is sign_in_retry_test.dart's)
      },
      fetchHosts: () async => null, // nor a host list (SL-R18 is sign_in_hosts_test.dart's)
      fetchBrowserSpec: () async {
        spies.browserFetches += 1;
        return null; // nor a newer browser spec (SL-R19 is sign_in_browser_retry_test.dart's)
      },
      browserSpecStore: LoginSpecStore.browser(dataDir: () => _dir),
      ask: ask,
      browse: browse,
      browserSpec: browserSpec ?? () async => _browserSpec,
      openLink: openLink ?? (u) async => fail('no link was to be opened'),
    ),
  );
}

/// Types the fake's worker's email (and no password) and presses "Sign in on the state's page". With [expectSignedIn],
/// pumps until SelectCenterPage is up, leaves it before its own reads go anywhere and returns it; otherwise settles.
Future<SelectCenterPage?> _signInOnPage(WidgetTester tester, FakeState fake, _Spies spies, _Browse browse,
    {bool expectSignedIn = false, String email = fakeEmail, Future<FlowSpec> Function()? browserSpec}) async {
  SelectCenterPage? opened;
  await http.runWithClient(() async {
    await tester.pumpWidget(_app(spies, browse: browse, browserSpec: browserSpec));
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
    await tester.pump();
    await tester.tap(_browserButton);
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

/// A password sign-in as the fake's worker (SL-R16's suggestion line follows some of its failures).
Future<void> _passwordSignIn(WidgetTester tester, FakeState fake, _Spies spies,
    {Future<String?> Function(String, bool)? ask, FlowSpec? spec, _Browse? browse}) async {
  await http.runWithClient(() async {
    await tester.pumpWidget(_app(spies,
        browse: browse ?? (u, t) async => fail('the state page was not asked for'), ask: ask, spec: spec));
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), fakePassword);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
  }, fake.client);
}

void main() {
  // This file's widget tests load the state-reads spec (state_client.dart's stateReadsSpec) and other assets through
  // rootBundle; both caches keep the Future, which belongs to that test's fake async zone. Forget them after each
  // test, or a later test (in CI's one-isolate bundle, in another file) awaits them forever.
  tearDown(() {
    rootBundle.clear();
    resetStateReadsSpec();
  });

  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_sign_in_browser_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

  test('the messages are the ones SL-R16 gives', () {
    expect(browserSigninUnfinishedMessage, "The state's page didn't finish signing in. Try again, or tell Mazama.");
    expect(browserSigninSuggestion, "You can sign in on the state's page instead.");
  });

  testWidgets('PA-R6: the open-source link sits under the button and opens the public repository, carrying nothing typed',
      (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(_app(_Spies(), browse: (u, t) async => null, openLink: (u) async {
      opened.add(u);
      return true;
    }));
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), fakePassword);
    final link = find.byKey(const ValueKey('open-source-link'));
    expect(link, findsOneWidget);
    expect(find.text(openSourceLabel), findsOneWidget);
    expect(find.text(openSourceAddress), findsOneWidget);
    expect(tester.getTopLeft(link).dy, greaterThan(tester.getTopLeft(_browserButton).dy));
    await tester.tap(link);
    await tester.pump();
    expect(opened, [Uri.parse('https://github.com/apotheharry-web/mazama_mobile')]);
  });

  testWidgets('the button sits at the bottom of the screen, apart from the form', (tester) async {
    await tester.pumpWidget(_app(_Spies(), browse: (u, t) async => null));
    expect(_browserButton, findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    // Below "Sign in", in the page's bottom bar rather than in the form.
    expect(tester.getTopLeft(_browserButton).dy, greaterThan(tester.getTopLeft(find.byType(FilledButton)).dy));
    expect(find.descendant(of: find.byType(Form), matching: _browserButton), findsNothing);
    final screenHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    // the bottom bar: only the two small links (open source, privacy policy, PA-R6/R8) sit under it
    expect(tester.getBottomLeft(_browserButton).dy, greaterThan(screenHeight - 160));
    final privacy = find.byKey(const ValueKey('privacy-policy-link'));
    expect(tester.getBottomLeft(privacy).dy, greaterThan(screenHeight - 40));
  });

  testWidgets('the password sign-in still asks for the email in its own words', (tester) async {
    await tester.pumpWidget(_app(_Spies(), browse: (u, t) async => null));
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text(emailRequiredMessage), findsOneWidget);
    expect(find.text(browserEmailRequiredMessage), findsNothing);
  });

  test('the email messages are the ones the owner chose', () {
    expect(emailRequiredMessage, 'Enter your email');
    expect(browserEmailRequiredMessage, 'Enter an email address to receive notifications');
  });

  testWidgets("signing in on the state's page signs in and goes on as a password sign-in does", (tester) async {
    final fake = FakeState();
    final spies = _Spies();
    final opened = <String>[];
    final page = await _signInOnPage(
        tester, fake, spies, _page(fake, (st) => '$site#code=CODE1&state=$st', opened: opened),
        expectSignedIn: true);

    expect(opened, hasLength(1));
    expect(opened.single, startsWith('$b2cHost/$tenant.onmicrosoft.com/$policy/oauth2/v2.0/authorize?'));
    expect(page, isNotNull);
    expect(page!.session.accessToken, 'ACCESS-1');
    expect(page.session.refreshToken, 'REFRESH-1');
    expect(page.session.email, fakeEmail);
    expect(identical(page.spec, _login), isTrue); // renews with login.yaml, whose renew the browser spec copies
    expect(fake.logins, 1);
    // The only sign-in request is the token request: the sign-in form itself was the state's page, never replayed.
    // (The page the app goes on to then reads the worker's licenses, as after a password sign-in.)
    final signInRequests = fake.log.where((r) => !r.$2.startsWith('/api/')).toList();
    expect(signInRequests, [('POST', '/$tenant.onmicrosoft.com/$policy/oauth2/v2.0/token')]);
    expect(spies.reports, isEmpty);
    expect(spies.fetches, 0);
    expect(spies.browserFetches, 0);
    final saved = await tester.runAsync(() => SessionStore(dataDir: () => _dir).load());
    expect(saved?['access_token'], 'ACCESS-1');
    expect(saved?['email'], fakeEmail);
  });

  testWidgets('without an email it asks for one and does not open the page', (tester) async {
    final fake = FakeState();
    final spies = _Spies();
    final opened = <String>[];
    await _signInOnPage(tester, fake, spies, _page(fake, (st) => null, opened: opened), email: '');

    expect(find.text(browserEmailRequiredMessage), findsOneWidget);
    expect(find.text(emailRequiredMessage), findsNothing);
    expect(find.text('Enter your password'), findsNothing);
    expect(opened, isEmpty);
    expect(fake.log, isEmpty);
  });

  testWidgets('closing the page says "Sign-in cancelled." and tells no one; with no newer browser spec, no retry',
      (tester) async {
    final fake = FakeState();
    final spies = _Spies();
    await _signInOnPage(tester, fake, spies, _page(fake, (st) => null));

    expect(find.text(signInCancelledMessage), findsOneWidget);
    expect(find.text(browserSigninSuggestion), findsNothing);
    expect(spies.reports, isEmpty);
    expect(spies.fetches, 0);
    expect(spies.browserFetches, 1); // a stuck page may be a moved host: looked for, none here (SL-R19)
    expect(fake.log, isEmpty);
    expect(find.byType(SignInPage), findsOneWidget);
  });

  testWidgets(
      'a page that answered another sign-in shows the browser message: not reported; a newer browser spec is looked for',
      (tester) async {
    final fake = FakeState();
    final spies = _Spies();
    await _signInOnPage(tester, fake, spies, _page(fake, (st) => '$site#code=CODE1&state=${st}x'));

    expect(find.text(browserSigninUnfinishedMessage), findsOneWidget);
    expect(find.text(stateSigninChangedMessage), findsNothing);
    expect(find.text(browserSigninSuggestion), findsNothing);
    expect(spies.reports, isEmpty);
    expect(spies.fetches, 0); // never the password sign-in's spec
    expect(spies.browserFetches, 1); // SL-R19: none to be had here, so no retry
    expect(fake.log, isEmpty); // no token asked for
  });

  testWidgets("B2C's own error shows its description, not a password message", (tester) async {
    final fake = FakeState();
    final spies = _Spies();
    await _signInOnPage(tester, fake, spies,
        _page(fake, (st) => '$site#error=access_denied&error_description=AADB2C90118%3A+forgot&state=$st'));

    expect(find.text("the state's sign-in page ended without signing in: AADB2C90118: forgot"), findsOneWidget);
    expect(find.text(browserSigninUnfinishedMessage), findsNothing);
    expect(spies.reports, isEmpty);
    expect(spies.fetches, 0);
    expect(spies.browserFetches, 1); // B2C's error may be a changed policy or scope: looked for, none here
    expect(fake.log, isEmpty);
  });

  testWidgets('a browser spec that will not load shows the browser message', (tester) async {
    final fake = FakeState();
    final spies = _Spies();
    final opened = <String>[];
    await _signInOnPage(tester, fake, spies, _page(fake, (st) => null, opened: opened),
        browserSpec: () async => throw FlowSpecError('not usable'));

    expect(find.text(browserSigninUnfinishedMessage), findsOneWidget);
    expect(opened, isEmpty);
    expect(spies.reports, isEmpty);
  });

  testWidgets('while the page is open both buttons and the fields are disabled', (tester) async {
    final fake = FakeState();
    final spies = _Spies();
    final answer = Completer<String?>();
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(spies, browse: (u, t) => answer.future));
      await tester.enterText(find.widgetWithText(TextFormField, 'Email'), fakeEmail);
      await tester.pump();
      await tester.tap(_browserButton);
      await tester.pump();
      await tester.pump();

      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      expect(tester.widget<TextButton>(_browserButton).onPressed, isNull);
      expect(tester.widget<TextFormField>(find.byType(TextFormField).first).enabled, isFalse);

      answer.complete(null);
      await tester.pumpAndSettle();
      expect(find.text(signInCancelledMessage), findsOneWidget);
      expect(tester.widget<TextButton>(_browserButton).onPressed, isNotNull);
    }, fake.client);
  });

  group('after a password sign-in fails', () {
    testWidgets("a changed sign-in (structure) suggests the state's page", (tester) async {
      final fake = FakeState()..pageHtml = '<html>new page</html>';
      final spies = _Spies();
      await _passwordSignIn(tester, fake, spies);

      expect(find.text(stateSigninChangedMessage), findsOneWidget);
      expect(find.text(browserSigninSuggestion), findsOneWidget);
      expect(spies.reports, hasLength(1)); // still reported as before (SL-R5)
      expect(spies.fetches, 1);
    });

    testWidgets("a question nobody here can answer (needs_person) suggests the state's page", (tester) async {
      final fake = FakeState();
      final spies = _Spies();
      await _passwordSignIn(tester, fake, spies,
          spec: _askingSpec,
          ask: (prompt, secret) async => throw FlowError('a person has to answer this', reason: 'needs_person'));

      expect(find.text('a person has to answer this'), findsOneWidget);
      expect(find.text(browserSigninSuggestion), findsOneWidget);
    });

    testWidgets('a wrong email or password does not', (tester) async {
      final fake = FakeState()..rejectLogin = true;
      final spies = _Spies();
      await _passwordSignIn(tester, fake, spies);

      expect(find.text('the state system refused the login: bad password ***'), findsOneWidget);
      expect(find.text(browserSigninSuggestion), findsNothing);
    });

    testWidgets('a cancelled question does not', (tester) async {
      final fake = FakeState();
      final spies = _Spies();
      await _passwordSignIn(tester, fake, spies, spec: _askingSpec, ask: (prompt, secret) async => null);

      expect(find.text(signInCancelledMessage), findsOneWidget);
      expect(find.text(browserSigninSuggestion), findsNothing);
    });

    testWidgets('the suggestion goes when the next attempt starts', (tester) async {
      final fake = FakeState()..pageHtml = '<html>new page</html>';
      final spies = _Spies();
      await _passwordSignIn(tester, fake, spies, browse: (u, t) async => null);
      expect(find.text(browserSigninSuggestion), findsOneWidget);

      await http.runWithClient(() async {
        await tester.tap(_browserButton); // closed at once: "Sign-in cancelled.", and no suggestion
        await tester.pumpAndSettle();
      }, fake.client);
      expect(find.text(signInCancelledMessage), findsOneWidget);
      expect(find.text(stateSigninChangedMessage), findsNothing);
      expect(find.text(browserSigninSuggestion), findsNothing);
    });
  });
}
