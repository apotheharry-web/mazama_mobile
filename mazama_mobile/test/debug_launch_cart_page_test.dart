import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/debug_launch_cart_page.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/state_client.dart' show resetStateReadsSpec;
import 'temp_app_data_dir.dart';

Session _session() => Session(
    accessToken: 'TOKEN', refreshToken: 'REFRESH', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

final _dummySpec = FlowSpec(const {}, const {});

SessionStore _sessionStore() => SessionStore(dataDir: () => Directory.systemTemp.createTempSync());

// CartPage._fetchMergedForCart now calls fetchRawPackagesFromState on every load (see the cart_page_*_test.dart files'
// own fixture for why) - DebugLaunchCartPage doesn't override CartPage's own defaults at all (it opens the
// real page, deliberately), so every CartPage this page opens needs the real network calls to fail fast
// rather than hang, same as every other test that opens a real CartPage without its own fixtures.
Widget _page({
  int? initialStateId,
  Future<bool> Function(int)? centerIsConfigured,
}) =>
    MaterialApp(
      home: DebugLaunchCartPage(
        session: _session(),
        spec: _dummySpec,
        sessionStore: _sessionStore(),
        initialStateId: initialStateId,
        centerIsConfigured: centerIsConfigured ?? (stateId) async => throw Exception('no fixture'),
      ),
    );

/// The real CartPage starts loading as soon as it opens (its network calls fail fast here, see _page); unmount it and
/// let the fake clock run so nothing it started is left pending when the test ends ("A Timer is still pending even
/// after the widget tree was disposed").
Future<void> _closeCart(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

void main() {
  useTempAppDataDir();
  // The real CartPage loads assets/flows/sale.yaml through rootBundle and the state-reads spec (state_client.dart's
  // stateReadsSpec); both caches keep the Future, which belongs to this test's fake async zone. Left there, a later
  // test (this file's or, in CI's one-isolate bundle, another file's) awaits it forever: demo_walkthrough_test's
  // pumpAndSettle never settled, coa_data_resolver_test's setUpAll never ended.
  tearDown(() {
    rootBundle.clear();
    resetStateReadsSpec();
  });

  testWidgets('the state-id field is pre-filled from initialStateId', (tester) async {
    await tester.pumpWidget(_page(initialStateId: 231));
    expect((tester.widget(find.byType(TextField).first) as TextField).controller!.text, '231');
  });

  testWidgets('check center status shows the configured and unconfigured cases', (tester) async {
    await tester.pumpWidget(_page(initialStateId: 231, centerIsConfigured: (stateId) async => stateId == 231));

    await tester.tap(find.text('Check center status first'));
    await tester.pumpAndSettle();
    expect(find.textContaining('mazama_sales tracks this center'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Service center state id'), '999');
    await tester.tap(find.text('Check center status first'));
    await tester.pumpAndSettle();
    expect(find.textContaining('does NOT track this center'), findsOneWidget);
  });

  testWidgets('open cart pushes a real CartPage with a placeholder license carrying the typed state id and name',
      (tester) async {
    await tester.pumpWidget(_page());

    await tester.enterText(find.widgetWithText(TextField, 'Service center state id'), '231');
    await tester.enterText(
        find.widgetWithText(TextField, 'Display name (optional - shown in the cart\'s own AppBar)'), 'Test Center');
    await tester.tap(find.text('Open cart'));
    // two frames: the pushed route is built offstage in the first (MaterialApp's HeroController measures it), and
    // finders skip offstage widgets. Not pumpAndSettle: the real CartPage's own loading never settles here.
    await tester.pump();
    await tester.pump();

    final cart = tester.widget<CartPage>(find.byType(CartPage));
    expect(cart.center.id, 231);
    expect(cart.center.licenseName, 'Test Center');
    expect(cart.center.licenseType, 'ServiceCenter');
    // the cart's own AppBar title (mid-transition the launch page, with 'Test Center' still in its text field, is
    // on screen too, so look only inside the cart)
    expect(find.descendant(of: find.byType(CartPage), matching: find.text('Test Center')), findsOneWidget);
    await _closeCart(tester);
  });

  testWidgets('open cart with no display name falls back to "Debug center <id>"', (tester) async {
    await tester.pumpWidget(_page());

    await tester.enterText(find.widgetWithText(TextField, 'Service center state id'), '231');
    await tester.tap(find.text('Open cart'));
    await tester.pump(); // two frames, see the test above
    await tester.pump();

    final cart = tester.widget<CartPage>(find.byType(CartPage));
    expect(cart.center.licenseName, 'Debug center 231');
    await _closeCart(tester);
  });

  testWidgets('a non-numeric state id refuses to open a cart rather than crashing', (tester) async {
    await tester.pumpWidget(_page());
    await tester.enterText(find.widgetWithText(TextField, 'Service center state id'), 'not-a-number');
    await tester.tap(find.text('Open cart'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Enter a numeric state id'), findsOneWidget);
    expect(find.byType(CartPage), findsNothing);
  });
}
