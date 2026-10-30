import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/cart_store.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/state_packages_client.dart';
import 'package:mazama_mobile/sale_log_client.dart';
import 'package:mazama_mobile/sellability.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_outbox.dart';

import 'fake_timers.dart';
import 'features_off.dart';
import 'flow/fake_state.dart';
import 'cart_page_test_support.dart';

void main() {
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

  group('Sell', () {
    // A real access_token FakeState's own ProductTracking bearer check will accept - minted by actually
    // running the real `login` flow against it, the same way session_test.dart does, rather than a made-up
    // string the fake's generic branch would just 401 on.
    late final FlowSpec loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());

    testWidgets('a confirmed sale clears the cart and posts one record per line, with this center\'s id', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
      ];

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      // Not widgetWithText(AlertDialog, 'Confirm sale'): the dialog's title and its confirm button both read
      // exactly "Confirm sale", and find.ancestor (which widgetWithText is built on) returns the one AlertDialog
      // ancestor once per matching descendant, not deduplicated - so that finder reports "Found 2" for the
      // single real dialog. find.byType is what actually asserts there's exactly one dialog on screen; leaving
      // the wrong assertion in here previously made this test fail before it ever tapped 'Confirm sale',
      // leaving that dialog's own showDialog() Future permanently unresolved - which, same as the rootBundle
      // Future-caching race elsewhere in this file, straddled into every later test in this file and made all
      // of them hang in pumpAndSettle too.
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      final (path, body) = fake.posted.single;
      expect(path, 'CreateSalesRecords/false');
      final records = body as List;
      expect(records, hasLength(1)); // one cart line -> one record (numberSold carries the quantity)
      expect(records.single['productGuid'], 'PKPR-ab12c');
      expect(records.single['numberSold'], 2);
      expect(records.single['productCost'], 25.0); // 2 x $12.50
      expect(records.single['serviceCenterId'], 231); // this cart's own center, not anything from the package payload
      expect(records.single['initialDose'], 2); // the add-dialog's own default dose

      expect(find.text('Nothing in the cart yet.'), findsOneWidget); // the cart was cleared on confirmed success
      expect(find.textContaining('Sale recorded'), findsOneWidget);
    });

    // R87: the server came back while this cart had lines: the state-only stock is loaded again once the sale has
    // gone through and emptied the cart, never while it is being sent.
    testWidgets("Mazama's server back mid-cart: the inventory is loaded again after the sale, not before", (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
      ];
      final health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
      addTearDown(health.dispose);
      health.markUnreachable();
      var serverCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          if (health.offline) throw Exception('mazama server unreachable');
          return inventory;
        },
        fetchPackagesFromState: (stateId, {required accessToken}) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        health: health,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      health.markReachable();
      await tester.pumpAndSettle();
      expect(serverCalls, 1);

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();
      expect(fake.posted, hasLength(1));
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      expect(serverCalls, 2);
    });

    group('stock older than 5 minutes is read again before sending (SM-25, SM-D20)', () {
      final ab12cRecord = <String, Object?>{
        'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
        'quantity': 10, 'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false, 'pendingTransfer': false,
      };

      // Opens the cart at [start], lets the clock run [age], adds 2 x PKPR-ab12c and presses Sell then Confirm.
      // -> how many times the state's stock was read after the page loaded, and the fake state (what was posted).
      Future<(int, FakeState)> sellAfter(WidgetTester tester, Duration age,
          {required Future<List<Object?>> Function() reread}) async {
        final fake = FakeState();
        final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
        fake.data['CreateSalesRecords/false'] = [{'id': 9001, 'saleNumber': 'S-1'}];
        var clock = DateTime.now();
        var loaded = false;
        var reads = 0;
        await tester.pumpWidget(cartPage(
          fetchPackages: (id) async => inventory,
          fetchRawPackagesFromState: (id, {required accessToken}) async {
            // the load reads the state too (a load it didn't answer is never taken as confirmed, SM-25)
            if (!loaded) return [ab12cRecord];
            reads++;
            return reread();
          },
          now: () => clock,
          session: freshSession(accessToken: login['access_token'] as String),
          saleSpec: Future.value(realSaleSpec),
          httpClientFactory: fake.client,
        ));
        await tester.pumpAndSettle();
        loaded = true;
        clock = clock.add(age);
        await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
        await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
        await tester.pumpAndSettle();
        return (reads, fake);
      }

      testWidgets('4 minutes old: sent at once, without reading the stock again', (tester) async {
        final (reads, fake) = await sellAfter(tester, const Duration(minutes: 4), reread: () async => [ab12cRecord]);
        expect(reads, 0);
        expect(fake.posted, hasLength(1));
        expect(find.textContaining('Sale recorded'), findsOneWidget);
      });

      testWidgets('6 minutes old and still sellable: read again, then sent', (tester) async {
        final (reads, fake) = await sellAfter(tester, const Duration(minutes: 6), reread: () async => [ab12cRecord]);
        expect(reads, 1);
        expect(fake.posted, hasLength(1));
      });

      testWidgets("6 minutes old and locked since: refused with the sale worker's reason, nothing sent", (tester) async {
        final (reads, fake) = await sellAfter(tester, const Duration(minutes: 6),
            reread: () async => [{...ab12cRecord, 'locked': true, 'reasonLocked': 'Recall 2026-10'}]);
        expect(reads, 1);
        expect(fake.posted, isEmpty);
        expect(find.textContaining(saleLineRefusal({...ab12cRecord, 'locked': true, 'reasonLocked': 'Recall 2026-10'}, 'PKPR-ab12c', 2)!),
            findsOneWidget);
        expect(find.textContaining('Sale recorded'), findsNothing);
      });

      testWidgets('6 minutes old and gone from the state: refused, nothing sent', (tester) async {
        final (_, fake) = await sellAfter(tester, const Duration(minutes: 6), reread: () async => []);
        expect(fake.posted, isEmpty);
        expect(find.textContaining("PKPR-ab12c is no longer in the state system's inventory for this service center."),
            findsOneWidget);
      });

      testWidgets("6 minutes old and the state can't be read: refused as not sent", (tester) async {
        final (_, fake) = await sellAfter(tester, const Duration(minutes: 6),
            reread: () async => throw StatePackagesError('connection reset'));
        expect(fake.posted, isEmpty);
        expect(find.textContaining("Couldn't check the stock with the state system"), findsOneWidget);
      });
    });

    testWidgets('adding the same package again never takes a line past what is in stock (SM-17)', (tester) async {
      final four = [
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 0.5, quantity: 4),
      ];
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => four));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '3', price: '10.00');
      await addLine(tester, pkpr: 'ab12c', qty: '3', price: '10.00');

      expect(find.text('Only 4 of PKPR-ab12c in stock.'), findsOneWidget);
      expect(find.textContaining('3 x \$10.00'), findsOneWidget); // the line still holds 3, not 6
      expect(find.textContaining('6 x '), findsNothing);
    });

    testWidgets('a line beyond every lot is refused before anything is sent, never put on the last lot (SM-17)',
        (tester) async {
      // A saved cart from when there was more stock: 5 units, but the lots behind it now hold 2.
      final cartStore = CartStore(dataDir: () => tempDir);
      final two = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 0.5, quantity: 2);
      await cartStore.save(center.id, [CartLine(group: PkprGroup([two]), qty: 5, priceCentsEach: 1000)]);
      final fake = FakeState();

      await tester.pumpWidget(cartPage(fetchPackages: (id) async => [two], cartStore: cartStore, httpClientFactory: fake.client));
      await tester.pumpAndSettle();
      // The "Restored an unsold cart" notice lies over the Sell button; it has been read.
      ScaffoldMessenger.of(tester.element(find.byType(CartPage))).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();

      expect(find.text('Only 2 of PKPR-ab12c in stock: reduce the line. Nothing was sent.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing); // never got as far as confirming
      expect(fake.posted, isEmpty);
    });

    testWidgets('a line spanning more than one lot splits into one record per lot, the earliest expiry first (SM-D29)',
        (tester) async {
      // Two separate lots/transfers of PKPR-ab12c (same productGuid, different id/quantity/expiry - exactly what the
      // server's own public_packages sends for a center with more than one). The worker never sees either lot on its
      // own - only "14 in stock" - but the lot that expires first is drawn from first, here the larger one.
      final twoLots = [
        // analyteWeight deliberately low (unlike inventory's own ab12c) - this test's whole point is selling
        // 12 units in one line, which is nothing to do with the 50mg-psilocybin-per-sale cap (see
        // cart_pricing_test.dart's own analyteCapError tests for that).
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 0.5, quantity: 4,
            expires: DateTime(2027, 9, 1)),
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 105, weightPerUnit: 5.0, analyteWeight: 0.5, quantity: 10,
            expires: DateTime(2027, 3, 1)),
      ];
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      // One created record per record actually sent (two, since this line splits across both lots) - the real
      // state system's own CreateSalesRecords does this (see selling.dart's looksLikeConfirmedSale and
      // sale.yaml's own comment: "all given the same sale number since they went up in one request"), and
      // CartPage._sell now checks that shape before treating a 200 as a confirmed sale at all.
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
        {'id': 9002, 'saleNumber': 'S-1'},
      ];

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => twoLots,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '12', price: '12.50'); // more than the earlier lot's own 10

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      final (path, body) = fake.posted.single;
      expect(path, 'CreateSalesRecords/false');
      final records = (body as List).cast<Map<String, Object?>>();
      expect(records, hasLength(2)); // one line, but split across both lots
      expect(records[0]['productId'], 105); // expires first, so drained first
      expect(records[0]['numberSold'], 10); // all of what it had
      expect(records[0]['productCost'], 125.0); // 10 x $12.50
      expect(records[1]['productId'], 101); // the rest from the later lot
      expect(records[1]['numberSold'], 2); // 12 requested - 10 already taken
      expect(records[1]['productCost'], 25.0); // 2 x $12.50
      for (final r in records) {
        expect(r['productGuid'], 'PKPR-ab12c'); // same PKPR either way - the split is invisible to the state system
        expect(r['serviceCenterId'], 231);
      }

      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      expect(find.textContaining('Sale recorded'), findsOneWidget);
    });

    testWidgets('a confirmed sale posts the attribution log with the worker\'s email, the request and the response',
        (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
      ];

      int calls = 0;
      int? loggedStateId;
      String? loggedEmail;
      String? loggedDeviceId;
      List<Map<String, Object?>>? loggedRequest;
      Object? loggedResponse;

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String, email: 'picker@example.com'),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        postSaleLog: (stateId, {required workerEmail, required deviceId, required request, required response}) async {
          calls++;
          loggedStateId = stateId;
          loggedEmail = workerEmail;
          loggedDeviceId = deviceId;
          loggedRequest = request;
          loggedResponse = response;
        },
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(loggedStateId, 231); // this cart's own center id
      expect(loggedEmail, 'picker@example.com');
      expect(loggedDeviceId, isNotEmpty); // this install's own id (device_id.dart), not a hardware identifier
      expect(loggedRequest, hasLength(1));
      expect(loggedRequest!.single['productGuid'], 'PKPR-ab12c');
      expect(loggedResponse, [
        {'id': 9001, 'saleNumber': 'S-1'},
      ]);
    });

    // README R56: Mazama's server being down (the server link counting it offline) never slows or blocks a sale -
    // the sale goes straight to the state system, and the attribution log is handed to the outbox at once.
    testWidgets('a sale goes through with Mazama\'s server offline; the log is queued, not waited on', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
      ];
      final health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
      health.markUnreachable();
      final outbox = ServerOutbox(
          health: health,
          store: OutboxStore(dataDir: () => tempDir),
          send: (e) async => fail('nothing is sent while the server is offline'));
      addTearDown(() {
        outbox.dispose();
        health.dispose();
      });

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory, // stock from earlier: what matters here is the sale and its log
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        postSaleLog: (stateId, {required workerEmail, required deviceId, required request, required response}) =>
            outbox.addSaleLog(stateId, workerEmail: workerEmail, deviceId: deviceId, request: request, response: response),
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Sale recorded'), findsOneWidget);
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      expect(outbox.pendingCount, 1); // waiting for the server, kept on the phone
      expect(outbox.pending.single.response, [
        {'id': 9001, 'saleNumber': 'S-1'},
      ]);
      expect(health.offline, isTrue);
    });

    testWidgets('a sale-log failure never affects the sale-success UI or the cart clearing', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
      ];

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        // Deliberately always throws - this is the one thing _logSaleAttribution exists to swallow. If this
        // ever escapes, the test fails loudly on an unhandled exception rather than quietly passing.
        postSaleLog: (stateId, {required workerEmail, required deviceId, required request, required response}) async {
          throw SaleLogError('sale-log server unreachable');
        },
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      // Exactly the same success path as the unmodified-sale-log test above - a logging failure is invisible
      // to the worker, by design.
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      expect(find.textContaining('Sale recorded'), findsOneWidget);
    });

    testWidgets('a 4xx (nothing recorded) keeps the cart and says it is safe to try again', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      // No fake.data entry for CreateSalesRecords/false -> the generic ProductTracking branch answers 404.

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(find.text('The sale was not sent'), findsOneWidget);
      expect(find.textContaining('safe to try again'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing); // the line is still there - nothing was sent
    });
  });

  group('view stock', () {
    testWidgets('opens StockPage on top of the cart, with the same fetchPackages fixture, and comes back on pop', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');     // something in the cart to prove it survives

      await tester.tap(find.byTooltip('View stock'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Bendable Service Center stock'), findsOneWidget);
      expect(find.text('Extract'), findsOneWidget);             // the exact same fixture CartPage itself used
      expect(find.text('Whole Fungi'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Bendable Service Center'), findsOneWidget);
      expect(find.text('Extract'), findsOneWidget);              // the cart line added before navigating away is still there
    });

    // specs/features FR-3: the stock list is center_stock's page.
    testWidgets('the stock list button is hidden when center_stock is off', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, featureTable: featuresWithOff(['center_stock'])));
      await tester.pumpAndSettle();
      expect(find.byTooltip('View stock'), findsNothing);
      expect(find.byTooltip('Switch center'), findsOneWidget); // the rest of the bar is unchanged
    });
  });
}
