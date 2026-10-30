// specs/phone-sync PS-R6, Review Focus 1, 2 and 4: selling never goes through the sync engine. The sale completes
// while everything the engine could wait on hangs; an uncertain sale's flow runs once however often the engine runs;
// stock of any age is shown with its age, but never sold from once older than three days (Q3); stock older than five
// minutes is read from the state itself before a sale (SM-25); a confirmed sale asks for a refresh and never waits.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/cart_slots.dart' show defaultCartId;
import 'package:mazama_mobile/cart_store.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/inventory_cache_store.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/sellability.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/state_packages_client.dart';
import 'package:mazama_mobile/sync/center_stock.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/sync_engine.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';

import 'fake_timers.dart';
import 'flow/fake_state.dart';
import 'cart_page_test_support.dart';

void main() {
  tearDown(() => rootBundle.clear()); // as cart_page_sell_test.dart: no Future straddling two tests
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_guarantees_test_'));
  tearDown(() {
    LocalStore.debugCloseAll();
    tempDir.deleteSync(recursive: true);
  });

  late final FlowSpec loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());

  /// A future that never completes.
  Future<T> never<T>() => Completer<T>().future;

  /// An engine on the test folder whose every sender and refresher hangs forever, woken and ticked as often as asked.
  SyncEngine hangingEngine() {
    final health = ServerHealth(probe: () async => true, startTimer: FakeTimers().start);
    final e = SyncEngine(
      store: LocalStore.forDir(tempDir),
      health: health,
      startTimer: FakeTimers().start,
      senders: {for (final k in QueueKind.values) k: (item) => never<SendResult>()},
    );
    for (final d in Dataset.values) {
      e.register(d, (key) => never<({String body, String source})>());
    }
    addTearDown(() {
      e.dispose();
      health.dispose();
    });
    return e;
  }

  Future<void> sell(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
    await tester.pumpAndSettle();
  }

  testWidgets('the sale completes while every engine fake hangs forever', (tester) async {
    final fake = FakeState();
    final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    fake.data['CreateSalesRecords/false'] = [
      {'id': 9001, 'saleNumber': 'S-1'},
    ];
    final engine = hangingEngine();
    engine.queue.add(QueueKind.saleLog, 'c-old', {'n': 1});
    engine.wake();
    engine.foregroundTick();
    final watched = engine.watch(Dataset.centerStock, '${center.id}').listen((_) {});
    addTearDown(watched.cancel);
    final asked = <int>[];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      session: freshSession(accessToken: login['access_token'] as String),
      saleSpec: Future.value(realSaleSpec),
      httpClientFactory: fake.client,
      // everything the page hands work to after a sale hangs: the sale log, the snapshot upload, the refresh
      postSaleLog: (stateId, {required workerEmail, required deviceId, required request, required response}) => never<void>(),
      uploadInventorySnapshot: (stateId, records, {required workerEmail, required deviceId}) =>
          never<Map<String, Object?>>(),
      requestStockRefresh: (stateId) {
        asked.add(stateId);
        unawaited(engine.refresh(Dataset.centerStock, '$stateId')); // hangs: never awaited by the page
      },
    ));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
    await sell(tester);

    expect(fake.posted, hasLength(1));
    expect(find.textContaining('Sale recorded'), findsOneWidget);
    expect(find.text('Nothing in the cart yet.'), findsOneWidget);
    expect(asked, [center.id]);
  });

  testWidgets("an uncertain sale's flow runs once however often the engine runs", (tester) async {
    final fake = FakeState();
    final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    fake.data['CreateSalesRecords/false'] = {'ok': true}; // a 200 that isn't a confirmed sale (looksLikeConfirmedSale)
    final engine = hangingEngine();
    final asked = <int>[];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      session: freshSession(accessToken: login['access_token'] as String),
      saleSpec: Future.value(realSaleSpec),
      httpClientFactory: fake.client,
      requestStockRefresh: asked.add,
    ));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    await sell(tester);
    expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();

    for (var i = 0; i < 10; i++) {
      engine.wake();
      engine.foregroundTick();
      engine.onForeground();
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(fake.posted, hasLength(1)); // sent once, never again
    expect(asked, isEmpty); // not confirmed: nothing to refresh for
    expect(find.text('Nothing in the cart yet.'), findsNothing); // the cart waits for a person
  });

  group('stock older than three days is shown and selling refuses it (Q3)', () {
    Future<void> openWithKept(WidgetTester tester, Duration age, DateTime clock) async {
      await InventoryCacheStore(dataDir: () => tempDir).save(center.id, inventory, clock.subtract(age));
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => throw Exception('mazama server unreachable'),
        fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable too'),
        now: () => clock,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    }

    testWidgets('3 days and a minute old: shown with its age, Sell refused, nothing sent', (tester) async {
      final clock = DateTime.now();
      await openWithKept(tester, const Duration(days: 3, minutes: 1), clock);
      expect(find.textContaining('showing the last inventory downloaded from'), findsOneWidget);
      expect(find.textContaining('too old to sell from'), findsOneWidget);
      expect(find.text('Extract'), findsOneWidget); // the line is in the cart
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      expect(find.text(staleStockRefusal(const Duration(days: 3))), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing); // never as far as the confirmation
    });

    testWidgets('exactly 3 days old: still sellable', (tester) async {
      final clock = DateTime.now();
      await openWithKept(tester, const Duration(days: 3), clock);
      expect(find.textContaining('too old to sell from'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      expect(find.text(staleStockRefusal(const Duration(days: 3))), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget); // the confirmation: the sale may go ahead
      await tester.tap(find.widgetWithText(TextButton, 'Cancel')); // closed, so no dialog outlives the test
      await tester.pumpAndSettle();
    });

    testWidgets('kept stock that turns 3 days old stays refused after a sale and during a Retry (I-A)', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
      ];
      final record = <String, Object?>{
        'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
        'quantity': 10, 'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false, 'pendingTransfer': false,
      };
      var clock = DateTime.now();
      // kept a minute inside the limit
      await InventoryCacheStore(dataDir: () => tempDir)
          .save(center.id, inventory, clock.subtract(const Duration(days: 2, hours: 23, minutes: 59)));
      var phase = 'load';
      var reads = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          if (phase == 'retry') return Completer<List<Package>>().future; // the Retry's load never ends here
          throw Exception('mazama server unreachable');
        },
        fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable too'),
        fetchRawPackagesFromState: (id, {required accessToken}) async {
          if (phase == 'load') throw StatePackagesError('state unreachable at load');
          if (phase == 'retry') return Completer<List<Object?>>().future;
          reads++;
          return [record];
        },
        now: () => clock,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('showing the last inventory downloaded from'), findsOneWidget);
      expect(find.textContaining('too old to sell from'), findsNothing);
      phase = 'sale';
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await sell(tester);
      expect([reads, fake.posted.length], [1, 1]); // a kept copy is never the state's word: read, then sent
      expect(find.textContaining('Sale recorded'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10)); // the snackbar times out, off the Sell button
      await tester.pumpAndSettle();

      clock = clock.add(const Duration(minutes: 2)); // the kept stock is now 3 days and a minute old
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      expect(find.textContaining('too old to sell from'), findsOneWidget); // the sale didn't make it any newer
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      expect(find.text(staleStockRefusal(const Duration(days: 3))), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing); // never as far as the confirmation
      expect([reads, fake.posted.length], [1, 1]);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      phase = 'retry'; // loading again: the line was built from the kept stock, which is still too old
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Downloading inventory...'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(staleStockRefusal(const Duration(days: 3))), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect([reads, fake.posted.length], [1, 1]);
    });

    testWidgets('stock the cart read itself, once too old, is refused with Retry offered, and Retry lets it sell (M-1)',
        (tester) async {
      var clock = DateTime.now();
      var serverCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          return inventory;
        },
        now: () => clock,
      ));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Retry'), findsNothing); // just read: no strip
      clock = clock.add(const Duration(days: 3, minutes: 1)); // the page was left open
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      expect(find.text(staleStockRefusal(const Duration(days: 3))), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('The stock on this phone is too old to sell from. Retry to load it again.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10)); // the refusal times out
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(serverCalls, 2); // loaded again
      expect(find.widgetWithText(TextButton, 'Retry'), findsNothing); // read just now
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      expect(find.text(staleStockRefusal(const Duration(days: 3))), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget); // the confirmation: the sale may go ahead
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
    });

    test('the rule: older than the limit only; a time in the future is just read', () {
      final now = DateTime.utc(2026, 10, 30, 12);
      const limit = Duration(days: 3);
      expect(stockTooOld(now.subtract(limit), now, limit), isFalse);
      expect(stockTooOld(now.subtract(limit + const Duration(seconds: 1)), now, limit), isTrue);
      expect(stockTooOld(now.add(const Duration(days: 9)), now, limit), isFalse);
      expect(staleStockRefusal(limit), contains('more than 3 days ago'));
      // a kept time has whole milliseconds only: the clock's microseconds don't make exactly 3 days too old
      final clock = DateTime.utc(2026, 10, 30, 12, 0, 0, 0, 750);
      final kept = DateTime.fromMillisecondsSinceEpoch(clock.subtract(limit).millisecondsSinceEpoch, isUtc: true);
      expect(stockTooOld(kept, clock, limit), isFalse);
      expect(stockTooOld(kept.subtract(const Duration(milliseconds: 1)), clock, limit), isTrue);
    });
  });

  testWidgets('stock older than five minutes is read from the state before a sale; the refresh is asked for only after',
      (tester) async {
    final fake = FakeState();
    final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    fake.data['CreateSalesRecords/false'] = [
      {'id': 9001, 'saleNumber': 'S-1'},
    ];
    final record = <String, Object?>{
      'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
      'quantity': 10, 'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false, 'pendingTransfer': false,
    };
    var clock = DateTime.now();
    var loaded = false;
    final order = <String>[];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      fetchRawPackagesFromState: (id, {required accessToken}) async {
        if (!loaded) return [record]; // the load reads the state: confirmed then, 6 minutes before the sale
        order.add('state read');
        return [record];
      },
      now: () => clock,
      session: freshSession(accessToken: login['access_token'] as String),
      saleSpec: Future.value(realSaleSpec),
      httpClientFactory: fake.client,
      requestStockRefresh: (stateId) => order.add('refresh asked'),
    ));
    await tester.pumpAndSettle();
    loaded = true;
    clock = clock.add(const Duration(minutes: 6));
    await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
    await sell(tester);
    expect(fake.posted, hasLength(1));
    expect(order, ['state read', 'refresh asked']); // the state itself, directly; the engine only after the sale
  });

  testWidgets('a confirmed sale asks for a refresh and never waits for it; a refresh that throws changes nothing',
      (tester) async {
    final fake = FakeState();
    final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    fake.data['CreateSalesRecords/false'] = [
      {'id': 9001, 'saleNumber': 'S-1'},
    ];
    final asked = <int>[];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      session: freshSession(accessToken: login['access_token'] as String),
      saleSpec: Future.value(realSaleSpec),
      httpClientFactory: fake.client,
      requestStockRefresh: (stateId) {
        asked.add(stateId);
        throw StateError('the engine is gone');
      },
    ));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
    await sell(tester);
    expect(asked, [center.id]);
    expect(find.textContaining('Sale recorded'), findsOneWidget);
    expect(find.text('Nothing in the cart yet.'), findsOneWidget);
    expect(find.text('The sale may or may not have been recorded'), findsNothing);
  });

  // Review of phase 3 (I1-I3): the state is read before a sale unless it confirmed this stock in the last 5 minutes.
  group('SM-25: when the state must be read before a sale', () {
    Map<String, Object?> rec(int id, String guid, String type, double wpu, double aw, num qty) => {
          'id': id, 'productGuid': guid, 'productType': type, 'weightPerUnit': wpu, 'analyteWeight': aw, 'quantity': qty,
          'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false, 'pendingTransfer': false,
        };

    /// Opens the cart with the state's stock as [atLoad] gives it (null: the state doesn't answer the load), the clock
    /// in [clock]. -> the fake state and a counter of the state reads after the load.
    Future<(FakeState, List<int>)> open(WidgetTester tester,
        {required List<Object?>? Function() atLoad,
        required List<Object?> Function() later,
        required DateTime Function() clock,
        Object? saleReply,
        List<Package>? served,
        CartStore? cartStore}) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = saleReply ??
          [
            {'id': 9001, 'saleNumber': 'S-1'},
          ];
      var loaded = false;
      final reads = <int>[0];
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => served ?? inventory,
        fetchRawPackagesFromState: (id, {required accessToken}) async {
          if (!loaded) {
            final r = atLoad();
            if (r == null) throw StatePackagesError('the state did not answer the load');
            return r;
          }
          reads[0]++;
          return later();
        },
        now: clock,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        cartStore: cartStore,
      ));
      await tester.pumpAndSettle();
      loaded = true;
      return (fake, reads);
    }

    final ab12c = rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, 10);

    testWidgets('stock the state confirmed a minute ago: no read', (tester) async {
      var now = DateTime.now();
      final (fake, reads) = await open(tester, atLoad: () => [ab12c], later: () => [ab12c], clock: () => now);
      now = now.add(const Duration(minutes: 1));
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await sell(tester);
      expect([reads[0], fake.posted.length], [0, 1]);
    });

    testWidgets("Mazama's server's rows alone (the state didn't answer the load): read before the first sale", (tester) async {
      final now = DateTime.now();
      final (fake, reads) = await open(tester, atLoad: () => null, later: () => [ab12c], clock: () => now);
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await sell(tester);
      expect([reads[0], fake.posted.length], [1, 1]);
    });

    testWidgets('a read time in the future (the clock moved back): read', (tester) async {
      var now = DateTime.now();
      final (fake, reads) = await open(tester, atLoad: () => [ab12c], later: () => [ab12c], clock: () => now);
      now = now.subtract(const Duration(hours: 1));
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await sell(tester);
      expect([reads[0], fake.posted.length], [1, 1]);
    });

    testWidgets('a second sale of a lot just sold reads the state again, and is refused when the lot is gone', (tester) async {
      final now = DateTime.now();
      var left = 10;
      final (fake, reads) = await open(tester,
          atLoad: () => [ab12c], later: () => [rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, left)], clock: () => now);
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await sell(tester);
      expect([reads[0], fake.posted.length], [0, 1]); // confirmed at load
      // "Sale recorded" sits over the Sell button until it times out (the clock the page reads stays put)
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      left = 0; // the sale above took the last of it, as far as the state now says
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await sell(tester);
      expect(reads[0], 1); // read again: the stock moved
      expect(fake.posted, hasLength(1)); // never sent
      expect(find.textContaining('PKPR-ab12c'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    testWidgets('a read before one lot confirms that lot only: another lot of the same old stock is read again', (tester) async {
      var now = DateTime.now();
      // two lots of two products, each light enough for one sale (PKPR-ff99aa's 90 mg is over the 50 mg limit)
      final cd34e = rec(103, 'PKPR-cd34e', 'Extract', 5.0, 4.5, 10);
      final (fake, reads) = await open(tester,
          atLoad: () => [ab12c, cd34e],
          later: () => [ab12c, cd34e],
          clock: () => now,
          served: [
            inventory.first,
            Package(productGuid: 'PKPR-cd34e', productType: 'Extract', id: 103, weightPerUnit: 5.0, analyteWeight: 4.5,
                strain: 'Golden Teacher', tpeMg: 5, quantity: 10),
          ],
          saleReply: {'ok': true}); // uncertain: the cart keeps its lines and nothing resets
      now = now.add(const Duration(minutes: 6));
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await sell(tester);
      expect(reads[0], 1); // 6 minutes old: read, and PKPR-ab12c's lot confirmed
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'cd34e', qty: '1', price: '10.00');
      await sell(tester);
      expect(reads[0], 2); // the other lot wasn't confirmed by that read
      expect(fake.posted, hasLength(2));
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    // Review of Task 8b (I-C, I-D, I-E): what a load, a cart switch, a restored draft and a sale that wasn't confirmed
    // leave behind. Each sale that must read the state shows the read happened, and an oversell that nothing was sent.

    /// Every sale is confirmed (S-1), [onSale] run first (the state taking the units).
    void saleAnswers(FakeState fake, void Function() onSale) {
      fake.override['CreateSalesRecords/false'] = (req) async {
        onSale();
        return http.Response(
            jsonEncode([
              {'id': 9001, 'saleNumber': 'S-1'},
            ]),
            200);
      };
    }

    Future<void> pumpFor(WidgetTester tester, Duration d) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(d ~/ 10);
      }
    }

    Future<void> openCarts(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('cartsButton')));
      await tester.pumpAndSettle();
    }

    Future<void> showCart(WidgetTester tester, String name) async {
      await openCarts(tester);
      await tester.tap(find.widgetWithText(ListTile, name));
      await tester.pumpAndSettle();
    }

    testWidgets('a load a sale was sent across never confirms the counts it read before that sale (I-C)', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      var left = 3;
      saleAnswers(fake, () => left -= 2);
      final clock = DateTime.now();
      // a kept copy an hour old, so the stock banner offers Retry
      await InventoryCacheStore(dataDir: () => tempDir).save(center.id, inventory, clock.subtract(const Duration(hours: 1)));
      var atLoad = true;
      var reads = 0;
      final server = Completer<List<Package>>();
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          if (atLoad) throw Exception('mazama server unreachable');
          return server.future; // the Retry's answer, held until the test lets it come
        },
        fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable'),
        fetchRawPackagesFromState: (id, {required accessToken}) async {
          if (atLoad) throw StatePackagesError('state unreachable at load');
          reads++;
          return [rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, left)];
        },
        now: () => clock,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('showing the last inventory downloaded from'), findsOneWidget);
      atLoad = false;
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(reads, 1); // the Retry's load has read the state (3) and waits for the server
      expect(find.text('Downloading inventory...'), findsOneWidget);
      // sold while that load runs: the kept copy is nobody's word, so SM-25 reads the state, then the sale is sent
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await pumpFor(tester, const Duration(seconds: 1));
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await pumpFor(tester, const Duration(seconds: 1));
      expect(reads, 2);
      expect(fake.posted, hasLength(1));
      expect(left, 1);
      server.complete(inventory); // the load ends now, with the 3 it read before the sale
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10)); // "Sale recorded" times out, off the Sell button
      await tester.pumpAndSettle();
      // 3 on screen; 2 units (45 mg: within the 50 mg cap, which would keep Sell disabled for more)
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await sell(tester);
      expect(reads, 3); // that load never confirmed its counts: the state is read again first
      expect(fake.posted, hasLength(1)); // and the sale refused: 1 left
      expect(find.textContaining(saleLineRefusal(rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, 1), 'PKPR-ab12c', 2)!),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    testWidgets('Retry is off while a sale is being sent, so no load reads the stock alongside it (N-1)', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      var left = 3;
      final reply = Completer<void>();
      fake.override['CreateSalesRecords/false'] = (req) async {
        await reply.future; // the sale is being sent until the test lets the state answer
        left -= 2;
        return http.Response(
            jsonEncode([
              {'id': 9001, 'saleNumber': 'S-1'},
            ]),
            200);
      };
      final clock = DateTime.now();
      // a kept copy an hour old, so the stock banner offers Retry
      await InventoryCacheStore(dataDir: () => tempDir).save(center.id, inventory, clock.subtract(const Duration(hours: 1)));
      var atLoad = true;
      var reads = 0;
      var serverCalls = 0;
      final server = Completer<List<Package>>();
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          if (atLoad) throw Exception('mazama server unreachable');
          return server.future;
        },
        fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable'),
        fetchRawPackagesFromState: (id, {required accessToken}) async {
          if (atLoad) throw StatePackagesError('state unreachable at load');
          reads++;
          return [rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, left)];
        },
        now: () => clock,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      atLoad = false;
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await pumpFor(tester, const Duration(seconds: 1));
      expect(reads, 1); // SM-25 read the state (3) before sending
      expect(fake.posted, hasLength(1)); // sent, and not yet answered
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Retry')).onPressed, isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(serverCalls, 1); // no load started beside the sale
      expect(reads, 1);
      reply.complete();
      await pumpFor(tester, const Duration(seconds: 1));
      server.complete(inventory); // nothing waits on it: no load ran
      await tester.pumpAndSettle();
      expect(left, 1);
      await tester.pump(const Duration(seconds: 10)); // "Sale recorded" times out, off the Sell button
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50'); // the kept copy still says 10
      await sell(tester);
      expect(reads, 2); // read before anything was sent
      expect(fake.posted, hasLength(1)); // and refused: 1 left
      expect(find.textContaining(saleLineRefusal(rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, 1), 'PKPR-ab12c', 2)!),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    testWidgets("another cart's lines are read from the state before they are sold, whatever a reload confirmed (I-D)",
        (tester) async {
      final health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
      health.markUnreachable();
      addTearDown(health.dispose);
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      var left = 3;
      saleAnswers(fake, () => left -= 2);
      final clock = DateTime.now();
      var loaded = false;
      var reads = 0;
      var serverCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          if (health.offline) throw Exception('mazama server unreachable');
          return inventory;
        },
        fetchRawPackagesFromState: (id, {required accessToken}) async {
          if (loaded) reads++;
          return [rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, left)];
        },
        now: () => clock,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        health: health,
      ));
      await tester.pumpAndSettle(); // the state's stock alone, confirmed by it just now: 3 of PKPR-ab12c
      loaded = true;
      // Cart 2 and Cart 1 each hold 2 of the lot
      await openCarts(tester);
      await tester.tap(find.text('New cart'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '10.00');
      await showCart(tester, 'Cart 1');
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '10.00');
      health.markReachable(); // the server is back: the stock is loaded again once this cart is empty
      await tester.pumpAndSettle();
      await sell(tester); // the load is a moment old: sent without a read
      expect(fake.posted, hasLength(1));
      expect(left, 1);
      // the sale emptied Cart 1, so the stock was loaded again: the state said 1, and that load confirmed it
      expect(serverCalls, 2);
      expect(reads, 1); // that load's read, and no other
      await tester.pump(const Duration(seconds: 10)); // "Sale recorded" times out
      await tester.pumpAndSettle();
      await showCart(tester, 'Cart 2');
      expect(find.textContaining('2 x \$10.00'), findsOneWidget); // its line, built when the lot had 3
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Confirm sale'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();
      expect(reads, 2); // read before anything was sent
      expect(fake.posted, hasLength(1)); // and refused: 1 left
      expect(find.textContaining(saleLineRefusal(rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, 1), 'PKPR-ab12c', 2)!),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    testWidgets('a draft restored at page open, after a load the state confirmed, is read from the state before it is sold (I-D)',
        (tester) async {
      // saved when the lot had 10; the state has 1 now, and confirms that at load
      final gate = Completer<void>();
      final store = _HeldCartStore(gate, dataDir: () => tempDir);
      await store.save(center.id, [
        CartLine(group: PkprGroup([inventory.first]), qty: 2, priceCentsEach: 1000),
      ]);
      final one = rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, 1);
      final now = DateTime.now();
      final (fake, reads) = await open(tester, atLoad: () => [one], later: () => [one], clock: () => now, cartStore: store);
      // the load has ended under an empty cart, so the state's read of it counts; the draft comes back only now
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Restored an unsold cart'), findsOneWidget);
      ScaffoldMessenger.of(tester.element(find.byType(CartPage))).clearSnackBars(); // read; it lies over Sell
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Confirm sale'), findsOneWidget); // its own snapshot says 10
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();
      expect(reads[0], 1); // read before anything was sent
      expect(fake.posted, isEmpty); // and refused: 1 left
      expect(find.textContaining(saleLineRefusal(one, 'PKPR-ab12c', 2)!), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    testWidgets('after an uncertain sale the next try reads the state, and is refused if the first was recorded (I-E)',
        (tester) async {
      var now = DateTime.now();
      var left = 10;
      final (fake, reads) = await open(tester,
          atLoad: () => [ab12c],
          later: () => [rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, left)],
          clock: () => now,
          saleReply: {'ok': true}); // a 200 that isn't a confirmed sale
      now = now.add(const Duration(minutes: 1));
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await sell(tester);
      expect([reads[0], fake.posted.length], [0, 1]); // confirmed at load: sent without a read
      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      left = 0; // it was recorded, and took the last of the lot
      await sell(tester); // the same cart, still a minute after the load
      expect(reads[0], 1); // read before anything was sent
      expect(fake.posted, hasLength(1)); // and refused
      expect(find.textContaining(saleLineRefusal(rec(101, 'PKPR-ab12c', 'Extract', 5.0, 4.5, 0), 'PKPR-ab12c', 2)!),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    testWidgets('after a sale that failed once sent, the next try reads the state first (I-E)', (tester) async {
      var now = DateTime.now();
      final (fake, reads) = await open(tester, atLoad: () => [ab12c], later: () => [ab12c], clock: () => now);
      fake.override['CreateSalesRecords/false'] = (req) async => http.Response('', 503);
      now = now.add(const Duration(minutes: 1));
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await sell(tester);
      expect([reads[0], fake.posted.length], [0, 1]);
      expect(find.text('Nothing in the cart yet.'), findsNothing); // the cart waits as it is
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      fake.override.remove('CreateSalesRecords/false');
      await sell(tester);
      expect([reads[0], fake.posted.length], [1, 2]); // read first, then sent
    });
  });
}

/// A cart store whose load waits for [gate], so a draft comes back only once the test lets it (after the page's load).
class _HeldCartStore extends CartStore {
  _HeldCartStore(this.gate, {super.dataDir});

  final Completer<void> gate;

  @override
  Future<List<CartLine>?> load(int centerId,
      {Duration? maxAge, DateTime Function() now = DateTime.now, String cartId = defaultCartId}) async {
    await gate.future;
    return super.load(centerId, maxAge: maxAge, now: now, cartId: cartId);
  }
}
