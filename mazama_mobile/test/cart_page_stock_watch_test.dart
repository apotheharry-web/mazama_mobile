// specs/phone-sync Task 8b: the cart follows the sync engine's copy of its center's stock (CartPage.watchStock). A newer
// copy is taken only while the cart has no lines and no sale is being sent; it waits otherwise, and is taken once the
// cart empties. Taken, it keeps Lane K's stamps: a copy the state answered is confirmed by the state at its own time; a
// copy of Mazama's server's rows alone makes the next sale read the state first (SM-25).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/sellability.dart';
import 'package:mazama_mobile/state_packages_client.dart';
import 'package:mazama_mobile/stock_page.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';
import 'package:mazama_mobile/sync/updated_line.dart';

import 'flow/fake_state.dart';
import 'cart_page_test_support.dart';

DatasetRow _copy(List<Package> packages, String source, DateTime at) => DatasetRow(
      name: 'center_stock',
      key: '${center.id}',
      body: jsonEncode({'packages': [for (final p in packages) p.toJson()], 'source': source}),
      source: source,
      fetchedAt: at.toUtc(),
    );

void main() {
  tearDown(() => rootBundle.clear());
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_watch_test_'));
  tearDown(() {
    LocalStore.debugCloseAll();
    tempDir.deleteSync(recursive: true);
  });

  late final FlowSpec loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
  final abOnly = [inventory.first];

  Future<void> openCarts(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('cartsButton')));
    await tester.pumpAndSettle();
  }

  Future<void> newCart(WidgetTester tester) async {
    await openCarts(tester);
    await tester.tap(find.text('New cart'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
  }

  Future<void> showCart(WidgetTester tester, String name) async {
    await openCarts(tester);
    await tester.tap(find.widgetWithText(ListTile, name));
    await tester.pumpAndSettle();
  }

  Future<void> tryAdd(WidgetTester tester, String pkpr) async {
    await tester.enterText(find.widgetWithText(TextField, 'PKPR'), pkpr);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
  }

  String notInStock(String pkpr) => "No PKPR $pkpr in ${center.licenseName}'s inventory.";

  /// Opens [pkpr]'s add dialog, expects it to say [n] in stock (the stock on screen), and cancels it.
  Future<void> expectInStock(WidgetTester tester, String pkpr, int n) async {
    await tester.enterText(find.widgetWithText(TextField, 'PKPR'), pkpr);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('$n in stock (as of last sync)'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
    await tester.pumpAndSettle();
  }

  /// PKPR-ab12c (id 101) as a copy holds it, with [quantity] units.
  Package ab12cWith(int quantity) => Package(
      productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5,
      strain: 'Golden Teacher', tpeMg: 5, quantity: quantity);

  testWidgets('a newer copy is taken at once while the cart is empty', (tester) async {
    final clock = DateTime.now();
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      now: () => clock,
      watchStock: (id) => copies.stream,
    ));
    await tester.pumpAndSettle();
    copies.add(_copy(abOnly, sourceMerged, clock.add(const Duration(minutes: 1))));
    await tester.pumpAndSettle();
    await tryAdd(tester, 'ff99aa'); // gone in the newer copy
    expect(find.text(notInStock('ff99aa')), findsOneWidget);
  });

  testWidgets('an older copy, or the cart\'s own, is not taken', (tester) async {
    final clock = DateTime.now();
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => clock, watchStock: (id) => copies.stream));
    await tester.pumpAndSettle();
    copies.add(_copy(abOnly, sourceMerged, clock.subtract(const Duration(minutes: 1))));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '9.00'); // still the loaded stock
    expect(find.text('Whole Fungi'), findsOneWidget);
  });

  testWidgets('a refresh under a cart being built waits until it is empty', (tester) async {
    final clock = DateTime.now();
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => clock, watchStock: (id) => copies.stream));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    copies.add(_copy(abOnly, sourceMerged, clock.add(const Duration(minutes: 1))));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '1.00'); // the stock under the cart is unchanged
    expect(find.text('Whole Fungi'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byTooltip('Remove').first);
      await tester.pumpAndSettle();
    }
    expect(find.text('Nothing in the cart yet.'), findsOneWidget);
    await tryAdd(tester, 'ff99aa'); // emptied: the newer copy was taken
    expect(find.text(notInStock('ff99aa')), findsOneWidget);
  });

  testWidgets("a copy of Mazama's server's rows alone makes the next sale read the state first", (tester) async {
    final fake = FakeState();
    final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    fake.data['CreateSalesRecords/false'] = [
      {'id': 9001, 'saleNumber': 'S-1'},
    ];
    final record = <String, Object?>{
      'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
      'quantity': 10, 'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false, 'pendingTransfer': false,
    };
    final clock = DateTime.now();
    var loaded = false;
    var reads = 0;
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      fetchRawPackagesFromState: (id, {required accessToken}) async {
        if (loaded) reads++;
        return [record]; // the load is confirmed by the state
      },
      now: () => clock,
      session: freshSession(accessToken: login['access_token'] as String),
      saleSpec: Future.value(realSaleSpec),
      httpClientFactory: fake.client,
      watchStock: (id) => copies.stream,
    ));
    await tester.pumpAndSettle();
    loaded = true;
    copies.add(_copy(inventory, sourceServer, clock.add(const Duration(seconds: 30))));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
    await tester.pumpAndSettle();
    expect(reads, 1); // the server's copy isn't the state's word: read before the sale
    expect(fake.posted, hasLength(1));
  });

  /// Opens a cart whose sale is held until the test lets it answer; the state read counted after the load.
  Future<({FakeState fake, List<int> reads, Completer<void> reply})> sellable(
    WidgetTester tester, {
    required DateTime Function() clock,
    required Stream<DatasetRow?> copies,
    Map<String, Object?>? record,
  }) async {
    final fake = FakeState();
    final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    final reply = Completer<void>();
    final rec = record ??
        <String, Object?>{
          'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
          'quantity': 10, 'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false, 'pendingTransfer': false,
        };
    fake.override['CreateSalesRecords/false'] = (req) async {
      await reply.future;
      return http.Response(
          jsonEncode([
            {'id': 9001, 'saleNumber': 'S-1'},
          ]),
          200);
    };
    var loaded = false;
    final reads = <int>[0];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      fetchRawPackagesFromState: (id, {required accessToken}) async {
        if (loaded) reads[0]++;
        return [rec];
      },
      now: clock,
      session: freshSession(accessToken: login['access_token'] as String),
      saleSpec: Future.value(realSaleSpec),
      httpClientFactory: fake.client,
      watchStock: (id) => copies,
    ));
    await tester.pumpAndSettle();
    loaded = true;
    return (fake: fake, reads: reads, reply: reply);
  }

  Future<void> sell(WidgetTester tester, Completer<void> reply) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
    await tester.pump();
    reply.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Sale recorded'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10)); // the "Sale recorded" snackbar times out, off the Sell button
    await tester.pumpAndSettle();
  }

  testWidgets('a copy read before a sale is never taken after it (C1)', (tester) async {
    var now = DateTime.now();
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    final s = await sellable(tester, clock: () => now, copies: copies.stream); // the load: 10 of PKPR-ab12c
    await expectInStock(tester, 'ab12c', 10);
    final beforeTheSale = now.add(const Duration(seconds: 1)); // newer than the load, older than the sale
    now = now.add(const Duration(seconds: 2));
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    copies.add(_copy([ab12cWith(1)], sourceMerged, beforeTheSale)); // arrives while the cart has lines
    await tester.pump();
    await sell(tester, s.reply);
    expect(s.fake.posted, hasLength(1));
    expect(find.text('Nothing in the cart yet.'), findsOneWidget); // emptied: a copy would be taken now
    await expectInStock(tester, 'ab12c', 10); // dropped, not taken: the stock on screen is still the load's
    // nothing more comes; the cart is filled and emptied again, and the dropped copy still never goes on screen
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing in the cart yet.'), findsOneWidget);
    await expectInStock(tester, 'ab12c', 10);
  });

  testWidgets('a copy taken after a sale never counts as the state\'s word: the next sale reads the state (C1)',
      (tester) async {
    var now = DateTime.now();
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    final s = await sellable(tester, clock: () => now, copies: copies.stream);
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    await sell(tester, s.reply);
    expect(s.reads[0], 0); // the load's own state read confirmed this sale
    now = now.add(const Duration(seconds: 2));
    // read after the sale (stamped at the page's own now, so not in the future: it would count if it were the state's)
    copies.add(_copy([ab12cWith(5)], sourceMerged, now));
    await tester.pumpAndSettle();
    await expectInStock(tester, 'ab12c', 5); // taken: the copy's count is on screen, not the load's 10
    final again = Completer<void>();
    s.fake.override['CreateSalesRecords/false'] = (req) async {
      await again.future;
      return http.Response(
          jsonEncode([
            {'id': 9002, 'saleNumber': 'S-2'},
          ]),
          200);
    };
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    await sell(tester, again);
    expect(s.reads[0], 1); // a taken copy is never the state's word (SM-25 read it itself)
    expect(s.fake.posted, hasLength(2));
  });

  testWidgets("a copy taken while one cart is empty never vouches for another cart's lines (C2)", (tester) async {
    var now = DateTime.now();
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    // the lot has 3 when the page loads (so cart 2's line of 2 can be built), and 1 by the time cart 2 is sold
    final lot = <String, Object?>{
      'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
      'quantity': 3, 'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false, 'pendingTransfer': false,
    };
    final s = await sellable(tester, clock: () => now, copies: copies.stream, record: lot);
    // cart 2 holds a line of the same lot, built from the load's stock
    await newCart(tester);
    await addLine(tester, pkpr: 'ab12c', qty: '2', price: '10.00');
    lot['quantity'] = 1; // sold elsewhere meanwhile: what the state now says
    await showCart(tester, 'Cart 1'); // cart 1, empty: a newer copy is taken here
    now = now.add(const Duration(seconds: 2));
    copies.add(_copy(abOnly, sourceMerged, now));
    await tester.pumpAndSettle();
    // cart 2 again: its lines were built before that copy, so its sale reads the state and is refused (1 in stock)
    await showCart(tester, 'Cart 2');
    expect(find.textContaining('2 x \$10.00'), findsOneWidget); // cart 2's line is back
    await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Confirm sale'), findsOneWidget); // its own snapshot let it this far
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
    await tester.pumpAndSettle();
    expect(s.reads[0], 1); // the state was read before anything was sent
    expect(s.fake.posted, isEmpty); // and the sale was refused: only 1 unit left
    expect(find.textContaining(saleLineRefusal(lot, 'PKPR-ab12c', 2)!), findsOneWidget); // in the sale worker's words
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
  });

  testWidgets("a taken merged copy queues no lab report; a copy of the server's rows alone does (CU-R1)", (tester) async {
    final clock = DateTime.now();
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    final queued = <String>[];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      now: () => clock,
      watchStock: (id) => copies.stream,
      queueCoaUploads: (lots, {onResolved}) => queued.addAll([for (final l in lots) l.lotGuid]),
    ));
    await tester.pumpAndSettle();
    // no lab report known for the lot: in a merged copy that may be a row only the state listed (never asked)
    final noReport = Package(
        productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5,
        strain: 'Golden Teacher', tpeMg: 5, quantity: 4, lotGuid: 'LOT-ab12c', coaAvailable: false);
    copies.add(_copy([noReport], sourceMerged, clock.add(const Duration(seconds: 1))));
    await tester.pumpAndSettle();
    await tryAdd(tester, 'ff99aa'); // taken: the copy holds PKPR-ab12c alone
    expect(find.text(notInStock('ff99aa')), findsOneWidget);
    expect(queued, isEmpty);
    copies.add(_copy([noReport], sourceServer, clock.add(const Duration(seconds: 2))));
    await tester.pumpAndSettle();
    expect(queued, ['LOT-ab12c']); // every row of this one is the server's own
  });

  testWidgets('a failed load is rescued by a newer copy', (tester) async {
    final clock = DateTime.now();
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => throw Exception('mazama server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable'),
      now: () => clock,
      watchStock: (id) => copies.stream,
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Inventory did not load'), findsOneWidget);
    copies.add(_copy(inventory, sourceMerged, clock.add(const Duration(seconds: 1))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Inventory did not load'), findsNothing);
    await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '9.00');
    expect(find.text('Whole Fungi'), findsOneWidget);
  });

  // Task 8b Step 8 (PS-R7, PS-D5): the stock's age is in the app bar's second line, beside the cart's name, so the
  // selling screen is no taller than before (a row above the dose summary pushed the lines under Total/Sell).
  testWidgets("the cart shows its stock's age", (tester) async {
    var clock = DateTime.now();
    final copies = StreamController<DatasetRow?>();
    addTearDown(copies.close);
    final load = Completer<List<Package>>();
    await tester.pumpWidget(cartPage(fetchPackages: (id) => load.future, now: () => clock, watchStock: (id) => copies.stream));
    await tester.pump();
    final inAppBar = find.descendant(of: find.byType(AppBar), matching: find.byKey(updatedLineKey));
    expect(inAppBar, findsNothing); // nothing on screen yet
    final barHeight = tester.getSize(find.byType(AppBar)).height;
    load.complete(inventory);
    await tester.pumpAndSettle();
    expect(inAppBar, findsOneWidget);
    expect(tester.widget<Text>(inAppBar).data, 'Updated just now'); // the load just read it
    expect(tester.widget<Text>(find.byKey(const Key('cartName'))).data, 'Cart 1');
    expect(tester.getSize(find.byType(AppBar)).height, barHeight); // no taller than without it
    final start = clock;
    clock = start.add(const Duration(minutes: 21));
    copies.add(_copy(abOnly, sourceMerged, start.add(const Duration(minutes: 1)))); // taken: the copy's own time
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(inAppBar).data, 'Updated 20 min ago');
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    expect(tester.widget<Text>(inAppBar).data, 'Updated 20 min ago'); // still there with a line, in the same place
    expect(tester.getSize(find.byType(AppBar)).height, barHeight);
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing in the cart yet.'), findsOneWidget);
  });

  testWidgets('no age is shown before the stock has loaded, or when it did not load', (tester) async {
    // the load waits on [answer], then fails: an async fetch, so its error is the load's own whenever it is asked
    final answer = Completer<void>();
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async {
        await answer.future;
        throw Exception('mazama server unreachable');
      },
      fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable'),
    ));
    await tester.pump();
    expect(find.byKey(updatedLineKey), findsNothing);
    answer.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Inventory did not load'), findsOneWidget);
    expect(find.byKey(updatedLineKey), findsNothing);
  });

  testWidgets("the stock list's age is its stock's, from the center's kept stock", (tester) async {
    final start = DateTime.now();
    var clock = start;
    var calls = 0;
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async {
        if (calls++ > 0) throw Exception('mazama server unreachable');
        return inventory;
      },
      // the state never answers either (the support's default state read answers after the first): the list's load
      // falls back to the copy the page's load kept
      fetchRawPackagesFromState: (id, {required accessToken}) async => throw StatePackagesError('state unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable'),
      now: () => clock,
    ));
    await tester.pumpAndSettle();
    clock = start.add(const Duration(minutes: 30));
    await tester.tap(find.byTooltip('View stock'));
    await tester.pumpAndSettle();
    final list = find.byType(StockPage);
    expect(find.descendant(of: list, matching: find.text('PKPR-ff99aa')), findsOneWidget); // the copy kept at the load
    expect(find.descendant(of: list, matching: find.text('Updated 30 min ago')), findsOneWidget);
  });
}
