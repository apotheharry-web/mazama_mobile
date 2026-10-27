// Demo mode sign-in, session and banner (specs/demo-mode DM-D2, DM-D6, DM-R3, DM-R4, DM-R5).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/center_stock_page.dart';
import 'package:mazama_mobile/demo/demo_banner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/main.dart';
import 'package:mazama_mobile/select_center_page.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/session_store.dart';

late Directory _dir;

SessionStore _store() => SessionStore(dataDir: () => _dir);

Future<void> _signIn(WidgetTester tester, String email, String password) async {
  await tester.pumpWidget(MazamaApp(sessionStore: _store()));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
  await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_demo_sign_in_test_'));
  tearDown(() {
    rootBundle.clear();
    demoModeOn.value = false;
    _dir.deleteSync(recursive: true);
  });

  test('DM-D2: guest / guest, the user name trimmed and in any case, the password exactly', () {
    expect(isDemoSignIn('guest', 'guest'), isTrue);
    expect(isDemoSignIn('GUEST ', 'guest'), isTrue);
    expect(isDemoSignIn(' Guest', 'guest'), isTrue);
    expect(isDemoSignIn('guest', 'Guest'), isFalse);
    expect(isDemoSignIn('guest', 'guest '), isFalse);
    expect(isDemoSignIn('guest@example.com', 'guest'), isFalse);
  });

  for (final email in ['guest', 'GUEST ']) {
    testWidgets('"$email" / guest opens the demo center, with the banner, and saves nothing', (tester) async {
      await _signIn(tester, email, 'guest');

      // The picker opened the demo center's home (it had one center); the cart beside it runs on the demo too.
      final cart = tester.widget<CartPage>(find.byType(CartPage, skipOffstage: false));
      expect(cart.demo, isNotNull);
      expect(cart.session.isDemo, isTrue);
      // One center: it opens on its Stock page.
      expect(find.byType(CenterStockPage), findsOneWidget);
      expect(find.text('Demo Service Center stock'), findsNothing); // no title bar under the tabs (owner, 2026-10-22)
      expect(find.text(demoBannerText), findsOneWidget);
      expect(await _store().load(), isNull); // DM-D6: not remembered

      // The banner stays over the Cart too.
      await tester.tap(find.text('Cart'));
      await tester.pumpAndSettle();
      expect(find.text('Demo Service Center'), findsOneWidget); // the cart's title
      expect(find.text(demoBannerText), findsOneWidget);
    });
  }

  testWidgets('guest / Guest is a real sign-in: the login flow runs, no demo', (tester) async {
    final asked = <Uri>[];
    await http.runWithClient(() async {
      await _signIn(tester, 'guest', 'Guest');
    }, () => http_testing.MockClient((req) async {
          asked.add(req.url);
          return http.Response('no', 500);
        }));
    expect(asked, isNotEmpty); // the real login flow asked the state's sign-in
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(find.text('Mazama sign-in'), findsOneWidget);
    expect(find.text(demoBannerText), findsNothing);
  });

  test('DM-R4: a demo session is never renewed, whatever the clock says', () async {
    final spec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
    final asked = <Uri>[];
    final client = http_testing.MockClient((req) async {
      asked.add(req.url);
      return http.Response('no', 500);
    });
    const demo = Session.demo();
    final out = await ensureFreshSession(demo, spec, client: client, now: () => DateTime(10000));
    expect(identical(out, demo) || out.accessToken == demo.accessToken, isTrue);
    expect(asked, isEmpty);
    expect(demo.refreshToken, isNull);
  });
}
