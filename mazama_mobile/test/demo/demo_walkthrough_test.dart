// Demo mode end to end (specs/demo-mode, Testing): sign in as guest / guest, the Stock page, a sale in the Cart,
// Switch center, sign out - all inside http.runWithClient with a client that records any request, so a page reached
// from the demo that still used a real network function would show up here (DM-D1). The demo's own sale client is
// the only other client in play.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/center_stock_page.dart';
import 'package:mazama_mobile/demo/demo_banner.dart';
import 'package:mazama_mobile/main.dart';
import 'package:mazama_mobile/mazama_inventory_page.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/stock_pie.dart';

/// Any request at all is recorded and refused: nothing in the demo may reach the network.
class _NoNetwork extends http.BaseClient {
  final requests = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add('${request.method} ${request.url}');
    throw StateError('the demo made a network request: ${request.method} ${request.url}');
  }
}

late Directory _dir;

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// The demo's stock as the Stock page shows it on opening: every sellable, unexpired package, any maker.
Future<void> _expectDemoStock(WidgetTester tester) async {
  expect(find.byType(CenterStockPage), findsOneWidget);
  expect(find.text('111 units'), findsOneWidget);
  expect(find.byType(StockPie), findsWidgets);
  expect(find.textContaining('below par'), findsNothing); // SP-D19: par is set when ordering
  expect(find.text('Other stock (2)'), findsOneWidget);
  // SP-D18: the demo's own three sheets, as the lot table (its chocolate lot under "Chocolate", as the pies name it)
  expect(find.text('3 lots · 3 strains', skipOffstage: false), findsOneWidget);
  // Other stock starts collapsed (SP-D16): open it, unless an earlier check on this same page already did.
  final toggle = find.byKey(const ValueKey('other-toggle'));
  if (find.descendant(of: toggle, matching: find.byIcon(Icons.expand_more)).evaluate().isNotEmpty) {
    // A message from the sale ("Demo sale: nothing was sent…") may still sit over the bottom of the page.
    for (final m in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      m.removeCurrentSnackBar();
    }
    await tester.pumpAndSettle();
    await _tap(tester, toggle);
  }
  expect(find.text('expired'), findsOneWidget);
  expect(find.text('locked (Demo hold)'), findsOneWidget);
}

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_demo_walkthrough_test_'));
  tearDown(() {
    rootBundle.clear();
    demoModeOn.value = false;
    _dir.deleteSync(recursive: true);
  });

  testWidgets('the whole demo works and nothing leaves the phone', (tester) async {
    final net = _NoNetwork();
    final store = SessionStore(dataDir: () => _dir);
    await http.runWithClient(() async {
      // Sign in as guest / guest.
      await tester.pumpWidget(MazamaApp(sessionStore: store));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'guest');
      await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'guest');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      // The center opens on Stock (it is the only one), under the banner.
      expect(find.text(demoBannerText), findsOneWidget);
      await _expectDemoStock(tester);

      // MI-R3: the Mazama inventory page, left of Stock, shows the demo's own mix (no request either).
      await tester.tap(find.text('Mazama'));
      await tester.pumpAndSettle();
      expect(find.text('Demo Mushroom Co.'), findsNothing); // no maker's name on the page (owner, 2026-10-22)
      expect(find.text('46,876 mg TPE in all'), findsOneWidget);
      // MI-D21: Order opens the demo's par levels first, compared with the demo's stock.
      await tester.tap(find.byKey(const ValueKey('order-button')));
      await tester.pumpAndSettle();
      // Starlit Meadow 25 mg short 8, Quiet Harbor 10 mg short 3, Chocolate Booster short 1 (3 of 4: specs/edibles)
      expect(find.text('12 units below par'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('par-continue')));
      // MI-R6: the order form from the demo's par levels; the demo answers with a number and sends nothing.
      expect(find.widgetWithText(AppBar, 'Order from Mazama'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('type-all')), matching: find.text('Freeze dried')));
      await tester.pumpAndSettle();
      await _tap(tester, find.widgetWithText(FilledButton, 'Review order'));
      await tester.enterText(find.byKey(const ValueKey('order-notes')), 'A demo note.');
      await _tap(tester, find.widgetWithText(FilledButton, 'Submit order'));
      expect(find.text('Order 1001 sent to Mazama'), findsOneWidget);
      expect(find.text('Notes: A demo note.'), findsOneWidget);
      await _tap(tester, find.widgetWithText(FilledButton, 'Done'));
      expect(find.byType(MazamaInventoryPage), findsOneWidget); // Done closes the form and the par step
      await tester.tap(find.text('Stock'));
      await tester.pumpAndSettle();

      // Swipe to the Cart (from the total above the pies: a swipe on the pies swaps the pies first), add a package
      // by its typed id, sell. Opening Other stock scrolled the page down: bring the total back on screen first.
      await tester.ensureVisible(find.text('111 units'));
      await tester.pumpAndSettle();
      await tester.fling(find.text('111 units'), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('Demo Service Center'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'DEMO0001');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();
      // The label compare: the demo's sample label.
      expect(find.byType(Image), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Total price for the whole cart'), '40.00');
      await tester.pumpAndSettle();
      // Sell sits in the cart's fixed bottom bar, always on screen: tapped as it is. (_tap's ensureVisible would also
      // align the button's left edge in the tabs' PageView, and with Sales right of Cart that snaps to the Sales page.)
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await _tap(tester, find.widgetWithText(FilledButton, 'Confirm sale'));
      expect(find.textContaining('Demo sale: nothing was sent'), findsWidgets);
      expect(find.text('Cart (1)'), findsNothing); // the cart is cleared, as after a real sale

      // CW-R10: the Sales tab, right of Cart: the demo reads no sales and uploads nothing (no request either).
      await tester.tap(find.text('Sales'));
      await tester.pumpAndSettle();
      expect(find.text('No sales in the last 30 days.'), findsOneWidget);

      // DM-D4: the demo stock is as it was.
      await tester.tap(find.text('Stock'));
      await tester.pumpAndSettle();
      await _expectDemoStock(tester);

      // Switch center stays in the demo, and its fresh Stock page reloads the demo stock: still as it was (DM-D4;
      // the Stock page has no pull to refresh, only the PKPR list does).
      await tester.tap(find.text('Cart'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Switch center'));
      await tester.pumpAndSettle();
      expect(find.byType(CenterStockPage), findsOneWidget);
      expect(find.text(demoBannerText), findsOneWidget);
      await _expectDemoStock(tester);

      // Sign out: the sign-in page, no banner, nothing saved.
      await tester.tap(find.text('Cart'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Mazama sign-in'), findsOneWidget);
      expect(find.text(demoBannerText), findsNothing);
    }, () => net);

    expect(net.requests, isEmpty);
    expect(await store.load(), isNull);
  });
}
