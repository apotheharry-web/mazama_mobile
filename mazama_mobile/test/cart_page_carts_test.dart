import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/cart_slots.dart';
import 'package:mazama_mobile/cart_store.dart';
import 'package:mazama_mobile/center_status_client.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/scan_match_client.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/session_timer_store.dart';
import 'package:mazama_mobile/text_scanner.dart';

import 'flow/fake_state.dart';
import 'cart_page_test_support.dart';
import 'temp_app_data_dir.dart';

void main() {
  useTempAppDataDir();
  // rootBundle.loadString caches its Future by asset key for the lifetime of the whole test *process*, not
  // per-test (see widget_test.dart's own note on this). CartPage's constructor loads assets/flows/sale.yaml
  // via rootBundle whenever a test doesn't pass saleSpec: explicitly, which is most tests in this file - without
  // clearing it, a later test can get an earlier test's already-created Future, straddling two different
  // testWidgets async zones. That doesn't throw - it just leaves that test's pumpAndSettle waiting on a Future
  // that never resolves in its own zone, hanging for the full default test timeout (10 minutes) instead of
  // failing fast. Only a few tests happened to lose this race on any given run, never a reliable repro.
  tearDown(() => rootBundle.clear());

  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  group('switching centers and signing out', () {
    testWidgets('switching centers with an empty cart goes straight to the picker, no confirmation needed', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Switch center'));
      // pumpAndSettle, not a bare pump - fetchLicenses here is cartPage()'s own fast, non-network stub (an
      // immediately-resolving empty list), not SelectCenterPage's real default, so there's no real network call
      // for this to ever hang on. A single pump() isn't actually enough: pushAndRemoveUntil's own route
      // transition needs a second frame before the new route is actually in the tree a Finder can see, even
      // though SelectCenterPage's own initState/build already ran by the end of the first frame.
      await tester.pumpAndSettle();

      expect(find.text('Choose a service center'), findsOneWidget);
      expect(find.widgetWithText(AlertDialog, 'Switch service center?'), findsNothing); // nothing to confirm
    });

    testWidgets("after switching centers the stock page still has the server's fields, with the state's quantities (SP-D10)",
        (tester) async {
      final served = [
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 1, analyteWeight: 25, strain: 'Golden Teacher',
            tpeMg: 25, quantity: 10, mazama: true, unitMgTpe: 25, description: 'Golden Teacher 25 mg'),
      ];
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => served,
        fetchRawPackagesFromState: (id, {required accessToken}) async => [
          {'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 1, 'analyteWeight': 25, 'quantity': 3},
        ],
        fetchLicenses: (token) async => [center],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Switch center'));
      await tester.pumpAndSettle();

      // One center: the picker opens its Mazama | Stock | Cart home, on Stock (no title bar there: the tab is its
      // title).
      expect(find.text('Units in stock'), findsOneWidget);
      expect(find.text('3 units'), findsOneWidget); // the state's live quantity
      expect(find.text('75 mg TPE'), findsOneWidget); // the server's exact mg TPE per unit, not blanked by the merge
      expect(find.textContaining('Partial'), findsNothing);
    });

    testWidgets('switching centers with items in the cart asks for confirmation first', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.byTooltip('Switch center'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AlertDialog, 'Switch service center?'), findsOneWidget);
      expect(find.text('Choose a service center'), findsNothing); // still here - not confirmed yet

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Extract'), findsOneWidget); // the cart line is untouched by backing out

      await tester.tap(find.byTooltip('Switch center'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard cart'));
      // Same reasoning as the other "switching centers" test above: a bare pump() isn't enough frames for
      // pushAndRemoveUntil's own route transition to actually land the new route in the tree.
      await tester.pumpAndSettle();

      expect(find.text('Choose a service center'), findsOneWidget);
    });

    testWidgets('signing out with an empty cart clears the stored session and returns to sign-in', (tester) async {
      final store = SessionStore(dataDir: () => tempDir);
      await store.save(freshSession().toJson());

      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, sessionStore: store));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('Mazama sign-in'), findsOneWidget);
      expect(await store.load(), isNull); // the whole point of signing out, not just leaving the screen
    });

    testWidgets('signing out with items in the cart asks for confirmation first', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AlertDialog, 'Sign out?'), findsOneWidget);
      expect(find.text('Mazama sign-in'), findsNothing); // not confirmed yet

      await tester.tap(find.widgetWithText(FilledButton, 'Discard cart'));
      await tester.pumpAndSettle();

      expect(find.text('Mazama sign-in'), findsOneWidget);
    });
  });

  group('offline cart persistence', () {
    testWidgets('a draft cart survives the page being recreated, as a killed/restarted app would', (tester) async {
      final cartStore = CartStore(dataDir: () => tempDir);

      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, cartStore: cartStore));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      expect(find.text('Extract'), findsOneWidget);

      // A fresh CartPage instance against the same store and the same center - standing in for the app process
      // being killed and relaunched, not just this widget rebuilding (which would keep the old State object
      // and its in-memory _lines regardless of persistence). Pumping the *same* widget type/position straight
      // to a second cartPage() would NOT actually do that: with no Key to tell the two apart, Flutter's own
      // reconciliation treats it as an update to the existing element and calls didUpdateWidget on the same
      // _CartPageState - initState (and therefore _restoreCart) never runs again, and the cart line "surviving"
      // would just be the original State's never-disposed in-memory _lines, proving nothing about persistence.
      // Pumping a throwaway widget in between forces the old CartPage to actually be disposed first, so the
      // next pumpWidget below is a genuinely new State object reading cartStore from scratch.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, cartStore: cartStore));
      await tester.pumpAndSettle();

      expect(find.text('Extract'), findsOneWidget); // restored, not a fresh empty cart
      expect(find.textContaining('Restored an unsold cart'), findsOneWidget);
    });

    testWidgets('a cart saved for a different center never reappears at this one', (tester) async {
      final cartStore = CartStore(dataDir: () => tempDir);
      await cartStore.save(999, [
        CartLine(group: PkprGroup([inventory.first]), qty: 1, priceCentsEach: 1000),
      ]);

      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, cartStore: cartStore));
      await tester.pumpAndSettle();

      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      expect(find.textContaining('Restored an unsold cart'), findsNothing);
    });

    testWidgets("restoring a draft once the server's settings arrive keeps it, and keeps the time it was saved",
        (tester) async {
      final cartStore = CartStore(dataDir: () => tempDir);
      final savedAt = DateTime.now().subtract(const Duration(hours: 2));
      await cartStore.save(center.id, [
        CartLine(group: PkprGroup([inventory.first]), qty: 1, priceCentsEach: 1000),
      ], now: () => savedAt);

      await tester.pumpWidget(cartPage(
          fetchPackages: (id) async => inventory, cartStore: cartStore, fetchCartSettings: (id) async => CartSettings.fallback));
      await tester.pumpAndSettle();

      expect(find.textContaining('Restored an unsold cart'), findsOneWidget);
      final stored = jsonDecode(LocalStore.forDir(tempDir).read('cart.json')!.body) as Map;
      expect(stored['savedAtMs'], savedAt.millisecondsSinceEpoch); // opening the page is not a change to the cart
      expect((stored['lines'] as List).length, 1);
    });

    testWidgets('onDraftCountChanged reports the number of lines as they change (SP-D8)', (tester) async {
      final counts = <int>[];
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, onDraftCountChanged: counts.add));
      await tester.pumpAndSettle();
      expect(counts, [0]);
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      expect(counts, [0, 1]);
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(counts, [0, 1, 0]);
    });

    testWidgets('removing the only line persists the now-empty cart, so it does not come back restored', (tester) async {
      final cartStore = CartStore(dataDir: () => tempDir);

      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, cartStore: cartStore));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, cartStore: cartStore));
      await tester.pumpAndSettle();

      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      expect(find.textContaining('Restored an unsold cart'), findsNothing); // nothing non-empty to restore
    });

    testWidgets('a confirmed sale clears the persisted draft, not just the on-screen cart', (tester) async {
      final fake = FakeState();
      final loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
      ];
      final cartStore = CartStore(dataDir: () => tempDir);

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        cartStore: cartStore,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(await cartStore.load(231), isNull);
    });

    testWidgets('discarding the cart to switch centers clears the persisted draft too', (tester) async {
      final cartStore = CartStore(dataDir: () => tempDir);

      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, cartStore: cartStore));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.byTooltip('Switch center'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard cart'));
      await tester.pump();

      expect(await cartStore.load(231), isNull);
    });
  });

  group('scanning', () {
    testWidgets('a single exact match goes straight to the same add dialog a typed PKPR would open', (tester) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        scanLabelText: () async => ['Lot: ab12c'],
        scanMatch: (stateId, lines, {typed = false}) async => ScanMatchResult(
          matches: [ScanMatch(guid: 'PKPR-ab12c', name: 'Extract', dist: 0, line: 'Lot: ab12c', stock: 10, sellable: true)],
          guesses: const [],
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(find.textContaining('PKPR-ab12c'), findsWidgets); // the add dialog is up, showing the matched package
      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '1');
      await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), '10.00');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Close')); // the label-compare dialog that pops up next
      await tester.pumpAndSettle();

      expect(find.textContaining('PKPR-ab12c'), findsWidgets); // now showing as a cart line instead
      expect(find.text('Nothing in the cart yet.'), findsNothing);
    });

    testWidgets('several matches are offered as a chooser, and picking one opens the add dialog for it', (tester) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        scanLabelText: () async => ['a blurry label'],
        scanMatch: (stateId, lines, {typed = false}) async => ScanMatchResult(
          matches: [
            ScanMatch(guid: 'PKPR-ab12c', name: 'Extract', dist: 2, line: 'a blurry label', stock: 10, sellable: true),
            ScanMatch(guid: 'PKPR-ff99aa', name: 'Whole Fungi', dist: 2, line: 'a blurry label', stock: 3, sellable: true),
          ],
          guesses: const [],
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(find.text('Which package?'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'Whole Fungi'));
      await tester.pumpAndSettle();

      expect(find.textContaining('PKPR-ff99aa'), findsWidgets); // the add dialog for the chosen package
    });

    testWidgets('no matches and no guesses leaves the cart alone and says so', (tester) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        scanLabelText: () async => ['nothing readable'],
        scanMatch: (stateId, lines, {typed = false}) async => ScanMatchResult(matches: const [], guesses: const []),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(find.text('No package found in that scan - enter the PKPR directly.'), findsOneWidget);
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
    });

    testWidgets('backing out of the camera screen does nothing and shows no error', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, scanLabelText: () async => throw ScanCancelled()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a camera/recognizer failure is shown as a readable snackbar', (tester) async {
      await tester.pumpWidget(
          cartPage(fetchPackages: (id) async => inventory, scanLabelText: () async => throw Exception('camera unavailable')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not read the camera'), findsOneWidget);
    });

    testWidgets('a matching-server failure is shown as a readable snackbar when the phone cannot match it either', (tester) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        scanLabelText: () async => ['Lot: ab12c'],
        scanMatch: (stateId, lines, {typed = false}) async => throw ScanMatchError('the server answered HTTP 500', status: 500),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not match the scan: the server answered HTTP 500'), findsOneWidget);
    });

    testWidgets('when the server cannot be reached the scan is matched on the phone against the cart\'s stock', (tester) async {
      List<Package>? matchedAgainst;
      List<String>? matchedLines;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        scanLabelText: () async => ['Lot: ab12c'],
        scanMatch: (stateId, lines, {typed = false}) async => throw ScanMatchError('cannot reach sales.example: ClientException'),
        localScanMatch: (inventory, lines, {typed = false}) {
          matchedAgainst = inventory;
          matchedLines = lines;
          return ScanMatchResult(
            matches: [ScanMatch(guid: 'PKPR-ab12c', name: 'Extract', dist: 0, line: 'Lot: ab12c', stock: 10, sellable: true)],
            guesses: const [],
          );
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(matchedLines, ['Lot: ab12c']);
      expect(matchedAgainst?.map((p) => p.productGuid), inventory.map((p) => p.productGuid));
      expect(find.textContaining('Could not match the scan'), findsNothing);
      expect(find.textContaining('PKPR-ab12c'), findsWidgets); // the same add dialog a server match opens
    });

    testWidgets('guesses matched on the phone are offered the same way as the server\'s', (tester) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        scanLabelText: () async => ['Net wt: 0.50 g'],
        scanMatch: (stateId, lines, {typed = false}) async => throw ScanMatchError('the server answered HTTP 502', status: 502),
        localScanMatch: (inventory, lines, {typed = false}) => ScanMatchResult(
          matches: const [],
          guesses: [ScanGuess(guid: 'PKPR-ff99aa', name: 'Whole Fungi', score: 3, why: const ['net weight 0.50 g'], stock: 3)],
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(find.text('No exact lot number was read - best guesses'), findsOneWidget);
      expect(find.textContaining('net weight 0.50 g'), findsOneWidget);
    });

    testWidgets('a request the server refused is not matched on the phone instead', (tester) async {
      var localCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        scanLabelText: () async => ['Lot: ab12c'],
        scanMatch: (stateId, lines, {typed = false}) async => throw ScanMatchError('No such service center.', status: 404),
        localScanMatch: (inventory, lines, {typed = false}) {
          localCalls++;
          return ScanMatchResult(matches: const [], guesses: const []);
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(localCalls, 0);
      expect(find.textContaining('Could not match the scan: No such service center.'), findsOneWidget);
    });
  });

  group('several carts (specs/multi-cart)', () {
    String cartName(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('cartName'))).data!;

    /// Every text in the carts sheet, for a failed expectation's reason.
    String sheetTexts(WidgetTester tester) => tester
        .widgetList<Text>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Text)))
        .map((t) => t.data)
        .join(' | ');

    Future<void> openCarts(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('cartsButton')));
      await tester.pumpAndSettle();
    }

    /// Makes a new cart through the carts sheet, keeping the suggested name unless [name] is given.
    Future<void> newCart(WidgetTester tester, {String? name}) async {
      await openCarts(tester);
      await tester.tap(find.text('New cart'));
      await tester.pumpAndSettle();
      if (name != null) await tester.enterText(find.widgetWithText(TextFormField, 'Cart name'), name);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
    }

    Future<void> showCart(WidgetTester tester, String name) async {
      await openCarts(tester);
      await tester.tap(find.widgetWithText(ListTile, name));
      await tester.pumpAndSettle();
    }

    testWidgets('the cart button lists the carts, a new cart starts empty, and each keeps its own lines', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      expect(cartName(tester), 'Cart 1');
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await openCarts(tester);
      expect(find.text('Carts'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '1 line'), findsOneWidget);
      await tester.tap(find.text('New cart'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save')); // the suggested "Cart 2"
      await tester.pumpAndSettle();

      expect(cartName(tester), 'Cart 2');
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '9.00');
      expect(find.textContaining('1 x \$9.00'), findsOneWidget);
      expect(find.textContaining('2 x \$12.50'), findsNothing);

      await showCart(tester, 'Cart 1');
      expect(cartName(tester), 'Cart 1');
      expect(find.textContaining('2 x \$12.50'), findsOneWidget);
      expect(find.textContaining('1 x \$9.00'), findsNothing);

      final slots = (await CartSlotsStore(dataDir: () => tempDir).load(231))!;
      expect(slots.carts.map((c) => c.name), ['Cart 1', 'Cart 2']);
      expect(slots.activeId, defaultCartId);
      final store = CartStore(dataDir: () => tempDir);
      expect((await store.load(231))!.single.qty, 2);
      expect((await store.load(231, cartId: slots.carts[1].id))!.single.qty, 1);
    });

    testWidgets('a cart can be renamed (names unique), and the list and the showing cart survive a restart', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await newCart(tester); // "Cart 2", showing

      await openCarts(tester);
      await tester.tap(find.byTooltip('Rename Cart 1'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Cart name'), 'cart 2');
      await tester.pumpAndSettle();
      expect(find.text('Another cart is already called "cart 2".'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'Cart name'), findsOneWidget); // refused: still open

      await tester.enterText(find.widgetWithText(TextFormField, 'Cart name'), '  Front desk ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(cartName(tester), 'Cart 2'); // renaming another cart doesn't switch to it

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      expect(cartName(tester), 'Cart 2');
      await openCarts(tester);
      expect(find.widgetWithText(ListTile, 'Front desk'), findsOneWidget);
    });

    testWidgets('each cart has its own timer, which keeps running while another cart shows', (tester) async {
      var clock = DateTime.now();
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => clock));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      clock = clock.add(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 05:00'), findsOneWidget);

      await newCart(tester);
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      expect(find.text('Start Timer'), findsOneWidget); // its own timer, not started
      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      expect(find.text('Elapsed: 00:00'), findsOneWidget);

      clock = clock.add(const Duration(minutes: 2));
      await openCarts(tester);
      // the list shows time left (MC-D14): 1 x PKPR-ab12c is 22.5 mg psilocybin, a 4 hour session
      expect(find.text('3:53:00 left'), findsOneWidget, reason: sheetTexts(tester)); // Cart 1's, still running
      expect(find.text('3:58:00 left'), findsOneWidget, reason: sheetTexts(tester)); // Cart 2's
      await tester.tap(find.widgetWithText(ListTile, 'Cart 1'));
      await tester.pumpAndSettle();
      expect(find.text('Elapsed: 07:00'), findsOneWidget);

      // Reset is the showing cart's only
      await tester.tap(find.text('Reset'));
      await tester.pump();
      final timers = SessionTimerStore(dataDir: () => tempDir);
      final cart2 = (await CartSlotsStore(dataDir: () => tempDir).load(231))!.carts[1].id;
      expect(await timers.load(231), isNull);
      expect(await timers.load(231, cartId: cart2), isNotNull);
    });

    testWidgets('the carts list counts the booster in the time left, and says when the time is up (MC-D14)',
        (tester) async {
      var clock = DateTime.now();
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => clock));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00'); // 22.5 mg, initial dose
      // a second unit as the secondary dose: 45 mg in all, a 6 hour session with the booster
      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), '10.00');
      await tester.tap(find.text('Secondary dose'));
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.text('Duration: 4 hrs · 6 hrs w/ booster'), findsOneWidget); // inside the cart: unchanged

      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      clock = clock.add(const Duration(hours: 1, minutes: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 1:30:00'), findsOneWidget); // inside the cart it still counts up

      await openCarts(tester);
      expect(find.text('4:30:00 left w/ booster'), findsOneWidget);
      clock = clock.add(const Duration(hours: 4, minutes: 35));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Time up · 05:00 over'), findsOneWidget);

      Navigator.of(tester.element(find.text('Carts'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pump();
    });

    testWidgets('a sold cart still shows its client\'s time left, until its timer is reset (MC-D14)', (tester) async {
      final loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [{'id': 9001, 'saleNumber': 'S-1'}];
      var clock = DateTime.now();
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        now: () => clock,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00'); // 22.5 mg: 4 hours
      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);

      clock = clock.add(const Duration(minutes: 10));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 10:00'), findsOneWidget); // the sold cart's timer stays in view, counting up

      await newCart(tester); // another client starts; Cart 1's session goes on
      await openCarts(tester);
      expect(find.text('3:50:00 left'), findsOneWidget, reason: sheetTexts(tester));
      await tester.tap(find.widgetWithText(ListTile, 'Cart 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset')); // that client is done: the sold dose is forgotten
      await tester.pump();
      expect(find.text('Start Timer'), findsNothing); // empty, not running: nothing shown, as before

      // a timer with nothing to time against (its line removed, nothing sold since the reset) shows how long it's run
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      await openCarts(tester);
      expect(find.text('elapsed 00:00'), findsOneWidget);

      Navigator.of(tester.element(find.text('Carts'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pump();
    });

    testWidgets('deleting a cart with lines asks first; the last cart cannot be deleted', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await openCarts(tester);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.delete_outline)).onPressed, isNull);
      await tester.tap(find.text('New cart'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await openCarts(tester);
      await tester.tap(find.byTooltip('Delete Cart 2'));
      await tester.pumpAndSettle();
      expect(find.text('Delete "Cart 2"?'), findsOneWidget);
      expect(find.textContaining('has not been sold'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete cart'));
      await tester.pumpAndSettle();

      expect(cartName(tester), 'Cart 1');
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      final slots = (await CartSlotsStore(dataDir: () => tempDir).load(231))!;
      expect(slots.carts.map((c) => c.name), ['Cart 1']);
    });

    testWidgets('switching centers asks about unsold lines in any cart, and discarding clears them all', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await newCart(tester); // empty, showing

      await tester.tap(find.byTooltip('Switch center'));
      await tester.pumpAndSettle();
      expect(find.textContaining('"Cart 1" has not been sold yet'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Discard cart'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a service center'), findsOneWidget);
      expect(await CartStore(dataDir: () => tempDir).load(231), isNull);
    });

    testWidgets('selling a cart clears that cart only (MC-D7)', (tester) async {
      final loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [{'id': 9001, 'saleNumber': 'S-1'}];
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await newCart(tester);
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '9.00');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();
      expect(fake.posted.single.$2.single['numberSold'], 1);
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);

      await showCart(tester, 'Cart 1');
      expect(find.textContaining('2 x \$12.50'), findsOneWidget);
    });
  });
}
