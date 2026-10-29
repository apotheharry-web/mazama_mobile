import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/coa_data_resolver.dart';
import 'package:mazama_mobile/inventory_cache_store.dart';
import 'package:mazama_mobile/state_packages_client.dart';
import 'package:mazama_mobile/server_health.dart';

import 'fake_timers.dart';
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

  group("Mazama's server back after a state-only load", () {
    ServerHealth offlineTracker() {
      final health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
      health.markUnreachable();
      return health;
    }

    testWidgets('an empty cart loads the inventory again', (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      var serverCalls = 0;
      var stateCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          if (health.offline) throw Exception('mazama server unreachable');
          return inventory;
        },
        fetchPackagesFromState: (stateId, {required accessToken}) async {
          stateCalls++;
          return inventory;
        },
        health: health,
      ));
      await tester.pumpAndSettle();
      expect([serverCalls, stateCalls], [1, 1]);

      health.markReachable();
      await tester.pumpAndSettle();
      expect([serverCalls, stateCalls], [2, 1]); // the server answered this time: no state fallback
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
    });

    testWidgets('a cart with lines waits, and loads again once its last line is removed', (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      var serverCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          if (health.offline) throw Exception('mazama server unreachable');
          return inventory;
        },
        fetchPackagesFromState: (stateId, {required accessToken}) async => inventory,
        health: health,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      health.markReachable();
      await tester.pumpAndSettle();
      expect(serverCalls, 1); // never under a cart being built
      expect(find.text('Extract'), findsOneWidget); // the line is still there

      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(serverCalls, 2);
    });

    testWidgets('online again while the cart still has lines, then offline again: no reload once it empties',
        (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      var serverCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          throw Exception('mazama server unreachable');
        },
        fetchPackagesFromState: (stateId, {required accessToken}) async => inventory,
        health: health,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      health.markReachable();
      health.markUnreachable();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(serverCalls, 1);
    });

    testWidgets('a live load does not reload', (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      var serverCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          return inventory;
        },
        health: health,
      ));
      await tester.pumpAndSettle();
      health.markReachable();
      await tester.pumpAndSettle();
      expect(serverCalls, 1);
    });

    testWidgets('the cached copy does not reload (the state system was down too)', (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      final store = InventoryCacheStore(dataDir: () => tempDir);
      await store.save(center.id, inventory, DateTime.now().subtract(const Duration(hours: 5)));
      var serverCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          throw Exception('mazama server unreachable');
        },
        fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable too'),
        inventoryCacheStore: store,
        health: health,
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining("The state system couldn't be reached"), findsOneWidget);
      health.markReachable();
      await tester.pumpAndSettle();
      expect(serverCalls, 1);
    });

    testWidgets('an unconfigured center (adhoc) does not reload', (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      var resolves = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => throw Exception('tier 1 should never be tried for an unconfigured center'),
        centerIsConfigured: (stateId) async => false,
        resolveAdhocInventory: ({required stateId, required accessToken, required workerEmail, required deviceId, onInventoryLoaded, onResolved}) async {
          resolves++;
          onInventoryLoaded?.call(inventory);
          return AdhocInventoryResult(packages: inventory, guidsTotal: 0, guidsResolved: 0);
        },
        health: health,
      ));
      await tester.pumpAndSettle();
      health.markReachable();
      await tester.pumpAndSettle();
      expect(resolves, 1);
    });

    testWidgets('the listener goes with the page', (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      var serverCalls = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async {
          serverCalls++;
          throw Exception('mazama server unreachable');
        },
        fetchPackagesFromState: (stateId, {required accessToken}) async => inventory,
        health: health,
      ));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const MaterialApp(home: Text('elsewhere')));
      health.markReachable(); // the page is gone: nothing loads
      await tester.pumpAndSettle();
      expect(serverCalls, 1);
    });
  });
}
