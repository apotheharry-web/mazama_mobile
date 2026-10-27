// SL-R16: the decisions behind the sign-in on the state's own page (lib/browser_sign_in_page.dart) - which navigations
// the webview may load, which it must refuse, and which one ends the sign-in - tested without a device through the
// pure decideBrowserNavigation, and how the page closes (SignInPageCloser) through a stand-in page that closes the way
// BrowserSignInPage does, with no webview. The webview itself (a platform view) is checked by hand on a device
// (specs/state-login "Testing").
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/browser_sign_in_page.dart';
import 'package:mazama_mobile/flow/flow_spec.dart' show defaultAllowedHosts;
import 'package:mazama_mobile/login_hosts_store.dart';

import 'host_list_signing.dart';

const _until = 'https://psilocybin.oregon.gov/';
const _authorize = 'https://oregonpsilocybinprodb2c.b2clogin.com/oregonpsilocybinprodb2c.onmicrosoft.com/'
    'b2c_1_oha_ph_psilocybin_prod_susi/oauth2/v2.0/authorize?client_id=x&state=abc';

BrowserNav _main(String url, {String until = _until}) => decideBrowserNavigation(url, until: until, isMainFrame: true);
BrowserNav _frame(String url, {String until = _until}) =>
    decideBrowserNavigation(url, until: until, isMainFrame: false);

void main() {
  group('the hosts a signed list adds (SL-R18)', () {
    tearDown(() => useLoginHosts(null));
    const moved = 'https://login.example.gov/oregonpsilocybinprodb2c.onmicrosoft.com/authorize?state=abc';

    test('a host no list names is refused', () {
      expect(_main(moved), BrowserNav.prevent);
    });

    test('a host the list in use names loads; the built-in ones still do', () async {
      useLoginHosts(await signedHostList('2026-11-01.1', ['login.example.gov']));
      expect(_main(moved), BrowserNav.navigate);
      expect(_main(_authorize), BrowserNav.navigate);
      expect(_main('https://evil.example.com/'), BrowserNav.prevent);
      expect(_main('http://login.example.gov/'), BrowserNav.prevent); // still https only
    });

    test('hosts given by the caller (the flow that opened the page) are the ones used', () async {
      useLoginHosts(await signedHostList('2026-11-01.1', ['login.example.gov']));
      expect(decideBrowserNavigation(moved, until: _until, isMainFrame: true, allowed: defaultAllowedHosts),
          BrowserNav.prevent);
      useLoginHosts(null);
      expect(
          decideBrowserNavigation(moved,
              until: _until, isMainFrame: true, allowed: [...defaultAllowedHosts, 'login.example.gov']),
          BrowserNav.navigate);
    });
  });

  group('the address the sign-in ends at (until)', () {
    test('ends the sign-in, handing back the whole URL with its fragment, without loading it', () {
      const back = '$_until#code=CODE1&state=abc';
      final nav = _main(back);
      expect(nav.kind, BrowserNavKind.finish);
      expect(nav.url, back);
      expect(nav, const BrowserNav.finish(back));
    });

    test('a query or a deeper path under until ends it too (a prefix match)', () {
      expect(_main('$_until?x=1#error=access_denied').kind, BrowserNavKind.finish);
      expect(_main('${_until}signin-oidc#code=C').url, '${_until}signin-oidc#code=C');
    });

    test('is checked before the allowlist: until wins even when it is not on an allowed host', () {
      const odd = 'https://callback.example/';
      expect(_main('$odd#code=C', until: odd), const BrowserNav.finish('$odd#code=C'));
      expect(_main('https://callback.example/other', until: _until), BrowserNav.prevent);
    });

    test('a host that only begins like the until host does not end it, and does not load', () {
      expect(_main('https://psilocybin.oregon.gov.evil.example/#code=C'), BrowserNav.prevent);
    });

    test('in a frame of the page it neither ends the sign-in nor loads (the code comes back in the main frame)', () {
      expect(_frame('$_until#code=C'), BrowserNav.prevent);
    });
  });

  group('main-frame navigations', () {
    test("the state's B2C pages and the state's own site load", () {
      expect(_main(_authorize), BrowserNav.navigate);
      expect(_main('https://oregonpsilocybinprodb2c.b2clogin.com/x/SelfAsserted?tx=1'), BrowserNav.navigate);
      expect(_main('https://psilocybin.oregon.gov:443/x', until: 'https://psilocybin.oregon.gov/done'),
          BrowserNav.navigate);
      expect(_main('https://psilocybin.oregon.gov/x', until: 'https://psilocybin.oregon.gov/done'),
          BrowserNav.navigate);
    });

    test('any other host stays put', () {
      expect(_main('https://evil.example/'), BrowserNav.prevent);
      expect(_main('https://b2clogin.com/'), BrowserNav.prevent); // the bare suffix is not a tenant's host
      expect(_main('https://login.microsoftonline.com/common/oauth2/authorize'), BrowserNav.prevent);
    });

    test("another B2C tenant's pages stay put: only the state's own tenant loads (SL-R17)", () {
      expect(_main('https://evil.b2clogin.com/evil.onmicrosoft.com/oauth2/v2.0/authorize?x=1'), BrowserNav.prevent);
      expect(_main('https://login.b2clogin.com/'), BrowserNav.prevent);
      expect(_main('https://oregonpsilocybinprodb2c.b2clogin.com.evil.example/x'), BrowserNav.prevent);
      expect(_main('https://xoregonpsilocybinprodb2c.b2clogin.com/x'), BrowserNav.prevent);
      expect(_main('https://a.oregonpsilocybinprodb2c.b2clogin.com/x'), BrowserNav.prevent);
      expect(_main('https://OregonPsilocybinProdB2C.b2clogin.com./x'), BrowserNav.navigate);
    });

    test('an allowed host over http or on another port stays put', () {
      expect(_main('http://oregonpsilocybinprodb2c.b2clogin.com/x'), BrowserNav.prevent);
      expect(_main('http://psilocybin.oregon.gov/'), BrowserNav.prevent);
      expect(_main('https://oregonpsilocybinprodb2c.b2clogin.com:8443/x'), BrowserNav.prevent);
    });

    test('script, data, app-launching and blank addresses stay put', () {
      expect(_main('javascript:alert(1)'), BrowserNav.prevent);
      expect(_main('data:text/html,<b>hi</b>'), BrowserNav.prevent);
      expect(_main('intent://scan/#Intent;scheme=zxing;end'), BrowserNav.prevent);
      expect(_main('about:blank'), BrowserNav.prevent);
      expect(_main('mailto:help@example.com'), BrowserNav.prevent);
      expect(_main(''), BrowserNav.prevent);
    });

    test('a URL with credentials in it stays put', () {
      expect(_main('https://user@oregonpsilocybinprodb2c.b2clogin.com/x'), BrowserNav.prevent);
    });
  });

  group('frames inside the page', () {
    test('load whatever they are (sub-resources never come through here; see the file comment)', () {
      expect(_frame('https://evil.example/frame'), BrowserNav.navigate);
      expect(_frame('about:blank'), BrowserNav.navigate);
      expect(_frame(_authorize), BrowserNav.navigate);
    });
  });

  test('the three answers are told apart', () {
    expect(BrowserNav.navigate, isNot(BrowserNav.prevent));
    expect(const BrowserNav.finish('a'), isNot(const BrowserNav.finish('b')));
    expect(const BrowserNav.finish('a').hashCode, const BrowserNav.finish('a').hashCode);
    expect(BrowserNav.navigate.url, isNull);
  });

  group('clearSignInBrowserData', () {
    test('runs every clearer, even when some fail or throw at once, and never throws', () async {
      final ran = <String>[];
      await clearSignInBrowserData([
        () async => ran.add('cookies'),
        () async {
          ran.add('cache');
          throw StateError('the webview has gone');
        },
        () {
          ran.add('storage');
          throw StateError('thrown before a Future');
        },
        () async => ran.add('last'),
      ]);
      expect(ran, ['cookies', 'cache', 'storage', 'last']);
    });
  });

  test("the page's title is the button's words", () {
    expect(signInOnStatePageLabel, "Sign in on the state's page");
  });

  group('SignInPageCloser: the page closes once', () {
    testWidgets('a finish answers its URL and leaves the page under it', (tester) async {
      final h = await _openStandIn(tester);
      h.closer.finish(h.context, 'https://psilocybin.oregon.gov/#code=C');
      await tester.pumpAndSettle();
      expect(h.result, 'https://psilocybin.oregon.gov/#code=C');
      expect(find.text(_under), findsOneWidget);
      expect(h.closer.done, isTrue);
    });

    testWidgets('a second finish (the redirect seen twice, say) does not pop the page under it', (tester) async {
      final h = await _openStandIn(tester);
      h.closer.finish(h.context, 'https://psilocybin.oregon.gov/#code=1');
      h.closer.finish(h.context, 'https://psilocybin.oregon.gov/#code=2');
      await tester.pumpAndSettle();
      h.closer.finish(h.context, 'https://psilocybin.oregon.gov/#code=3');
      await tester.pumpAndSettle();
      expect(h.result, 'https://psilocybin.oregon.gov/#code=1');
      expect(find.text(_under), findsOneWidget);
    });

    testWidgets('close, then the redirect: closed (null), the page under it stays', (tester) async {
      final h = await _openStandIn(tester);
      await tester.tap(find.byTooltip('Close'));
      h.closer.finish(h.context, 'https://psilocybin.oregon.gov/#code=C');
      await tester.pumpAndSettle();
      expect(h.result, isNull);
      expect(h.popped, isTrue);
      expect(find.text(_under), findsOneWidget);
    });

    testWidgets('the redirect, then close: the URL, and the page under it stays', (tester) async {
      final h = await _openStandIn(tester);
      h.closer.finish(h.context, 'https://psilocybin.oregon.gov/#code=C');
      await tester.tap(find.byTooltip('Close'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(h.result, 'https://psilocybin.oregon.gov/#code=C');
      expect(find.text(_under), findsOneWidget);
    });

    testWidgets('system back, then the redirect: closed (null), the page under it stays', (tester) async {
      final h = await _openStandIn(tester);
      // What the system back gesture does: a maybePop of the top route, through its PopScope.
      final handled = await Navigator.of(h.context).maybePop();
      expect(handled, isTrue);
      expect(h.closer.done, isTrue); // PopScope told the closer before the redirect came
      h.closer.finish(h.context, 'https://psilocybin.oregon.gov/#code=C');
      await tester.pumpAndSettle();
      expect(h.result, isNull);
      expect(find.text(_under), findsOneWidget);
    });

    testWidgets('a finish while another route is on top pops nothing', (tester) async {
      final h = await _openStandIn(tester);
      unawaited(Navigator.of(h.context).push(MaterialPageRoute<void>(builder: (_) => const Text('on top'))));
      await tester.pumpAndSettle();
      h.closer.finish(h.context, 'https://psilocybin.oregon.gov/#code=C');
      await tester.pumpAndSettle();
      expect(find.text('on top'), findsOneWidget);
      expect(h.popped, isFalse);
    });
  });
}

const _under = 'the sign-in page under it';

/// What a test holds of an opened stand-in page.
class _Opened {
  late SignInPageCloser closer;
  late BuildContext context;
  String? result;
  bool popped = false;
}

/// Opens [_StandIn] over a page showing [_under], as openBrowserSignIn opens the real one over SignInPage.
Future<_Opened> _openStandIn(WidgetTester tester) async {
  final h = _Opened();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Column(children: [
          const Text(_under),
          TextButton(
            onPressed: () async {
              h.result = await Navigator.of(context)
                  .push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _StandIn(h)));
              h.popped = true;
            },
            child: const Text('open'),
          ),
        ]),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(_StandIn), findsOneWidget);
  return h;
}

/// BrowserSignInPage's closing without its webview: a PopScope that tells the closer, a close button that goes
/// through it. Hands the test its closer and context.
class _StandIn extends StatefulWidget {
  final _Opened h;
  const _StandIn(this.h);

  @override
  State<_StandIn> createState() => _StandInState();
}

class _StandInState extends State<_StandIn> {
  final _closer = SignInPageCloser();

  @override
  Widget build(BuildContext context) {
    widget.h
      ..closer = _closer
      ..context = context;
    return SignInPageCloser.scope(
      closer: _closer,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Close', onPressed: () => _closer.close(context)),
        ),
        body: const Text('stand-in'),
      ),
    );
  }
}
