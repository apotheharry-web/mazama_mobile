import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/center_status_client.dart';
import 'package:mazama_mobile/coa_data_resolver.dart';
import 'package:mazama_mobile/coa_uploader.dart';
import 'package:mazama_mobile/enrichment_store.dart';
import 'package:mazama_mobile/inventory_cache_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/resilience_options.dart';
import 'package:mazama_mobile/state_packages_client.dart';

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

  testWidgets('shows a loading banner, then nothing extra (an empty cart has no dose total to show)', (tester) async {
    await tester.pumpWidget(cartPage(fetchPackages: (id) async {
      expect(id, 231);
      return inventory;
    }));
    expect(find.text('Downloading inventory...'), findsOneWidget);
    await tester.pumpAndSettle();
    // The old static "N packaged product(s)" banner is gone - replaced by the cart's own running dose total
    // (see the 'cart dose summary' group below), which has nothing to show while the cart is empty.
    expect(find.text('Downloading inventory...'), findsNothing);
    expect(find.textContaining('mg TPE'), findsNothing);
  });

  testWidgets('an inventory fetch error shows a retry button', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(cartPage(fetchPackages: (id) async {
      attempts += 1;
      throw Exception('server unreachable');
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('server unreachable'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  // R87: Mazama's server not answering is said once, by the app-wide banner (server_link.dart); the cart has no strip of
  // its own for it.
  testWidgets('tier 1 down, tier 2 (state) up: the state\'s stock, with no strip of the cart\'s own', (tester) async {
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => throw Exception('mazama server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async {
        expect(accessToken, 'TOKEN');
        return inventory;
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be reached'), findsNothing);
    expect(find.textContaining('read directly from the state system'), findsNothing);
    expect(find.byIcon(Icons.cloud_off), findsNothing);
    expect(find.text('Retry'), findsNothing);
    // The stock loaded (the state's): no error, and a worker on this tier can still work.
    expect(find.textContaining('server unreachable'), findsNothing);
    expect(find.text('Downloading inventory...'), findsNothing);
  });

  testWidgets("a live load remembers the server's own figures per package for a later outage", (tester) async {
    final enrichment = EnrichmentStore(dataDir: () => tempDir);
    await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, enrichmentStore: enrichment));
    await tester.pumpAndSettle();
    final known = await enrichment.load(DateTime.now());
    expect(known[enrichmentKey('PKPR-ab12c', 101)]!.strain, 'Golden Teacher');
    expect(known[enrichmentKey('PKPR-ff99aa', 102)]!.tpeMg, 90);
  });

  group("tier 2 with Mazama's last figures", () {
    // Consistent figures: the state's own tpeMg would be ceil(5 x 1.0) = 5 and ceil(10 x 9.0) = 90; the server sent a
    // COA-backed 8 for the first.
    // Relative to the real clock (the store drops entries older than 30 days), never a literal date.
    final seen = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    final served = [
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, strain: 'Golden Teacher', tpeMg: 8),
      Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10, analyteWeight: 9, strain: 'Enigma', tpeMg: 90),
    ];
    List<Package> fromState({double ff99aaPotency = 9}) => [
          Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, tpeMg: 5, quantity: 10),
          Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10, analyteWeight: ff99aaPotency,
              tpeMg: (10 * ff99aaPotency).ceil(), quantity: 3),
        ];

    testWidgets("every product filled: the cart line has Mazama's last TPE, with no strip of the cart's own", (tester) async {
      final enrichment = EnrichmentStore(dataDir: () => tempDir);
      await enrichment.remember(served, seen);
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => throw Exception('mazama server unreachable'),
        fetchPackagesFromState: (stateId, {required accessToken}) async => fromState(),
        enrichmentStore: enrichment,
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Strain and TPE'), findsNothing);
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      expect(find.textContaining('8mg TPE each'), findsOneWidget); // Mazama's 8, not the state's 5
    });

    testWidgets("a product whose state potency changed stays an estimate; the unchanged one keeps Mazama's TPE", (tester) async {
      final enrichment = EnrichmentStore(dataDir: () => tempDir);
      await enrichment.remember(served, seen);
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => throw Exception('mazama server unreachable'),
        fetchPackagesFromState: (stateId, {required accessToken}) async => fromState(ff99aaPotency: 9.5),
        enrichmentStore: enrichment,
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Strain and TPE'), findsNothing);
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      expect(find.textContaining('8mg TPE each'), findsOneWidget);
    });
  });

  // SM-D31: a product read from the state system with nothing kept for it shows and prices on the state's psilocybin,
  // and says so; the 50 mg cap and session lengths stay on raw psilocybin either way.
  group("state-only products (no TPE known)", () {
    // As state_packages_client.dart maps them: tpeMg = ceil(weightPerUnit x analyteWeight) - 23 from 22.5 here.
    List<Package> stateOnly() => [
          Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 4.5, tpeMg: 23, quantity: 10),
        ];

    Future<void> openStateOnly(WidgetTester tester) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => throw Exception('mazama server unreachable'),
        fetchPackagesFromState: (stateId, {required accessToken}) async => stateOnly(),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets("no strip of the cart's own, and the cart line says mg psilocybin", (tester) async {
      await openStateOnly(tester);
      expect(find.textContaining('No TPE is known'), findsNothing);
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      expect(find.textContaining('1 x \$10.00 · 23mg psilocybin each'), findsOneWidget);
      expect(find.textContaining('mg TPE each'), findsNothing);
      // the dose summary: no TPE to total, the raw psilocybin as always
      expect(find.text('TPE not known · 22.5 mg psilocybin in the cart'), findsOneWidget);
    });

    testWidgets('the price dialog prices per mg psilocybin, and says so', (tester) async {
      await openStateOnly(tester);
      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Price per mg'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'Price per mg (TPE)'), findsNothing);
      await tester.enterText(find.widgetWithText(TextFormField, 'Price per mg psilocybin'), '0.10');
      await tester.pump();
      // the state's 23 mg (rounded up), as before: lower than a TPE would be
      expect(find.textContaining('= \$2.30 each (23 mg psilocybin/unit)'), findsOneWidget);
    });

    testWidgets('the cart-wide per-mg field says where it prices by mg psilocybin', (tester) async {
      await openStateOnly(tester);
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.text('Cart \$/mg'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Price per mg (TPE; mg psilocybin where no TPE is known), whole cart'), findsOneWidget);
    });

    testWidgets('the 50 mg cap still counts raw psilocybin (22.5 mg a unit), not the rounded-up 23', (tester) async {
      await openStateOnly(tester);
      await addLine(tester, pkpr: 'ab12c', qty: '3', price: '10.00');
      expect(find.textContaining('This sale would total 67.5 mg psilocybin'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell')).onPressed, isNull);
    });

    testWidgets("a product filled from the phone's reading of the lab report shows mg TPE and says whose it is", (tester) async {
      final enrichment = EnrichmentStore(dataDir: () => tempDir);
      final seen = DateTime.now().toUtc().subtract(const Duration(hours: 2));
      await enrichment.rememberPhone([
        PackageEnrichment(productGuid: 'PKPR-ab12c', id: 101, weightPerUnit: 5, analyteWeight: 4.5, strain: 'Golden Teacher',
            tpeMg: 26, expires: null, seenAt: seen, source: EnrichmentSource.phone, tpeMgPerG: 5.12, psilocinMg: 2.8),
      ], seen);
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => throw Exception('mazama server unreachable'),
        fetchPackagesFromState: (stateId, {required accessToken}) async => stateOnly(),
        enrichmentStore: enrichment,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      expect(find.textContaining('26mg TPE each'), findsOneWidget);
      expect(find.text('26.0 mg TPE · 22.5 mg psilocybin in the cart'), findsOneWidget);
    });
  });

  testWidgets('tiers 1 and 2 both down, a same-center cache on file: shows the cache-fallback banner with its age', (tester) async {
    final store = InventoryCacheStore(dataDir: () => tempDir);
    final fetchedAt = DateTime.now().subtract(const Duration(hours: 5));
    await store.save(center.id, inventory, fetchedAt);
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => throw Exception('mazama server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable too'),
      inventoryCacheStore: store,
    ));
    await tester.pumpAndSettle();
    // R87: about the state system only; the app-wide banner says Mazama's server can't be reached.
    expect(
        find.text("The state system couldn't be reached - showing the last inventory downloaded from 5 hours ago. "
            'Counts may no longer be accurate.'),
        findsOneWidget);
    expect(find.textContaining("Mazama's server"), findsNothing);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
  });

  // R87: the strip with a Retry for stock read from the state alone is gone; the cart loads it again itself once the
  // app's tracker says Mazama's server answers, but only with nothing in the cart and no sale being sent.
  testWidgets('resilienceOptions.enableStateFallback: false skips tier 2, even with fetchPackagesFromState wired', (tester) async {
    var stateFallbackCalled = false;
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => throw Exception('mazama server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async {
        stateFallbackCalled = true;
        return inventory;
      },
      resilienceOptions: const ResilienceOptions(enableStateFallback: false),
    ));
    await tester.pumpAndSettle();
    expect(stateFallbackCalled, isFalse);
    // Tier 2 skipped and tier 3 empty (fresh tempDir) - the original tier-1 error is what surfaces, same as
    // if no fallback existed at all.
    expect(find.textContaining('server unreachable'), findsOneWidget);
  });

  testWidgets('resilienceOptions.cacheMaxAge shortens the window a cached inventory is still trusted in', (tester) async {
    final store = InventoryCacheStore(dataDir: () => tempDir);
    final fetchedAt = DateTime.now().subtract(const Duration(hours: 2));
    await store.save(center.id, inventory, fetchedAt);
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => throw Exception('mazama server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable too'),
      inventoryCacheStore: store,
      // A 2-hour-old cache would normally be well within the default 3-day window - this build's own 1-hour
      // window means it's already too old to trust, so the original tier-1 error should surface instead.
      resilienceOptions: const ResilienceOptions(cacheMaxAge: Duration(hours: 1)),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('server unreachable'), findsOneWidget);
    expect(find.textContaining("The state system couldn't be reached"), findsNothing);
  });

  testWidgets('centerIsConfigured false: switches to the adhoc flow entirely, never touching fetchPackages', (tester) async {
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => throw Exception('tier 1 should never be tried for an unconfigured center'),
      centerIsConfigured: (stateId) async => false,
      resolveAdhocInventory: ({required stateId, required accessToken, required workerEmail, required deviceId, onInventoryLoaded, onResolved}) async {
        onInventoryLoaded?.call(inventory);
        return AdhocInventoryResult(packages: inventory, guidsTotal: 0, guidsResolved: 0);
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("This center isn't configured in Mazama yet"), findsOneWidget);
    expect(find.textContaining('tier 1 should never be tried'), findsNothing);
  });

  testWidgets('centerIsConfigured false: progress wording reflects guidsResolved vs guidsTotal; Retry once the load has returned', (tester) async {
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      centerIsConfigured: (stateId) async => false,
      resolveAdhocInventory: ({required stateId, required accessToken, required workerEmail, required deviceId, onInventoryLoaded, onResolved}) async {
        onInventoryLoaded?.call(inventory);
        return AdhocInventoryResult(packages: inventory, guidsTotal: 3, guidsResolved: 1);
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('resolving lab reports: 1 of 3 lots so far'), findsOneWidget);
    // the other lots may only be queued for upload or have no lab report on file: Retry is there anyway
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('centerIsConfigured false: once every lot resolves, shows the fully-resolved wording and a Retry button', (tester) async {
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      centerIsConfigured: (stateId) async => false,
      resolveAdhocInventory: ({required stateId, required accessToken, required workerEmail, required deviceId, onInventoryLoaded, onResolved}) async {
        onInventoryLoaded?.call(inventory);
        return AdhocInventoryResult(packages: inventory, guidsTotal: 2, guidsResolved: 2);
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('every lot resolved'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('centerIsConfigured false: a lot resolved after the load returned is patched in and counted once',
      (tester) async {
    void Function(String guid, Package updated)? later;
    Package pkg(String pkpr, int id, String lot, {String strain = ''}) => Package(
        productGuid: pkpr, productType: 'Extract', id: id, weightPerUnit: 5.0, analyteWeight: 4.5, strain: strain, quantity: 10, lotGuid: lot);
    final inv = [pkg('PKPR-ab12c', 101, 'HB-1'), pkg('PKPR-cd34e', 102, 'HB-2'), pkg('PKPR-cd34e', 103, 'HB-2'), pkg('PKPR-ef56a', 104, 'HB-3')];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inv,
      centerIsConfigured: (stateId) async => false,
      resolveAdhocInventory: ({required stateId, required accessToken, required workerEmail, required deviceId, onInventoryLoaded, onResolved}) async {
        onInventoryLoaded?.call(inv);
        later = onResolved;
        onResolved?.call('HB-1', pkg('PKPR-ab12c', 101, 'HB-1', strain: 'Golden Teacher')); // the batch lookup's hit
        return AdhocInventoryResult(packages: inv, guidsTotal: 3, guidsResolved: 1);
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('resolving lab reports: 1 of 3 lots so far'), findsOneWidget);

    // the background uploader's answer for HB-2, one call per package of the lot
    later!('HB-2', pkg('PKPR-cd34e', 102, 'HB-2', strain: 'Blue Meanie'));
    later!('HB-2', pkg('PKPR-cd34e', 103, 'HB-2', strain: 'Blue Meanie'));
    await tester.pump();
    expect(find.textContaining('resolving lab reports: 2 of 3 lots so far'), findsOneWidget);
  });

  // specs/coa-upload CU-R1: a tracked center's load hands every lot the server has no lab report for to the uploader.
  testWidgets('a configured center the server answered: each lot the server has no report for is queued once', (tester) async {
    final queued = <CoaUploadLot>[];
    Package pkg(String pkpr, int id, String? lot, {bool coa = true}) => Package(productGuid: pkpr, productType: 'Extract', id: id,
        weightPerUnit: 5.0, analyteWeight: 4.5, strain: 'Golden Teacher', tpeMg: 5, quantity: 10, lotGuid: lot, coaAvailable: coa);
    final served = [
      pkg('PKPR-ab12c', 101, 'HB-aaaa0001', coa: false),
      pkg('PKPR-ab12c', 103, 'hb-AAAA0001', coa: false), // the same lot: one upload
      pkg('PKPR-ff99aa', 102, 'HB-bbbb0002'), // has its COA
      pkg('PKPR-cc77dd', 106, 'HB-cccc0003', coa: false),
      pkg('PKPR-cc77dd', 107, 'HB-cccc0003'), // the server has this lot's report through another package: left alone
      pkg('PKPR-ee11ff', 105, null, coa: false), // no lot id: nothing to key it by
    ];
    Map<String, Object?> raw(String pkpr, int id, {String? lot}) => {
          'id': id, 'productGuid': pkpr, 'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10,
          if (lot != null) 'harvestBatchGuid': lot,
        };
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => served,
      fetchRawPackagesFromState: (id, {required accessToken}) async => [
        for (final p in served) raw(p.productGuid, p.id),
        raw('PKPR-dd88ee', 108, lot: 'HB-dddd0004'), // only the state lists it: unknown to the server, not missing
      ],
      queueCoaUploads: (lots, {onResolved}) => queued.addAll(lots),
    ));
    await tester.pumpAndSettle();
    expect([for (final l in queued) (l.lotGuid, l.packageId, l.stateId, l.statePsilocybin)], [('HB-aaaa0001', 101, 231, 4.5)]);
  });

  testWidgets("a load Mazama's server didn't answer queues nothing: its lots are unknown, not missing", (tester) async {
    final queued = <CoaUploadLot>[];
    var stateRead = false;
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => throw PackagesError('server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async {
        stateRead = true;
        return [
          Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5,
              quantity: 10, lotGuid: 'HB-aaaa0001', coaAvailable: false),
        ];
      },
      queueCoaUploads: (lots, {onResolved}) => queued.addAll(lots),
    ));
    await tester.pumpAndSettle();
    expect(stateRead, isTrue); // the state's load
    expect(queued, isEmpty);
  });

  testWidgets('centerIsConfigured true: ordinary tiers run exactly as before, resolveAdhocInventory never called', (tester) async {
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      centerIsConfigured: (stateId) async => true,
      // Left at its default (throws) - a call here from the "configured" branch would be a real bug.
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't configured in Mazama yet"), findsNothing);
  });

  testWidgets('centerIsConfigured throwing falls through to the ordinary tiers, same as answering true', (tester) async {
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => inventory,
      centerIsConfigured: (stateId) async => throw Exception('center-status unreachable'),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't configured in Mazama yet"), findsNothing);
    expect(find.textContaining('center-status unreachable'), findsNothing);
  });

  testWidgets('typing an unknown PKPR shows a lookup error, not a crash', (tester) async {
    await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'zzzzz');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No PKPR zzzzz'), findsOneWidget);
  });

  for (final typed in ['ab', 'ab12c!', 'PKPR-0123456789abcdefg', 'ab 12c']) {
    testWidgets('a typed "$typed" is checked against the shared package id rule before it is looked up (SM-27)', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), typed);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining("isn't a package id (PKPR- and 4 to 16 letters or digits)"), findsOneWidget);
      expect(find.textContaining('No PKPR'), findsNothing); // never looked up
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets('a PKPR can be entered as the bare hex part or with the "pkpr-" prefix, any case', (tester) async {
    await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'AB12C');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.textContaining('PKPR-ab12c'), findsWidgets); // the add dialog is up, showing which package matched
  });

  testWidgets('adding a known PKPR opens the quantity/price dialog, then lists it with a running total', (tester) async {
    await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    // The add dialog is up, showing which package matched.
    expect(find.textContaining('PKPR-ab12c'), findsWidgets);

    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
    await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), '12.50');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
    await tester.pumpAndSettle();

    // The label-compare dialog pops up right after a successful add - close it before checking the cart list
    // underneath (see _showLabelDialog in cart_page.dart).
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();

    expect(find.text('Extract'), findsOneWidget);
    expect(find.textContaining('2 x \$12.50'), findsOneWidget);
    expect(find.text('\$25.00'), findsWidgets); // the line total and the cart total both read $25.00
    expect(find.text('Nothing in the cart yet.'), findsNothing);
  });

  group('PKPR search suggestions', () {
    testWidgets('suggests nothing until at least two significant characters are typed', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'a');
      await tester.pumpAndSettle();
      expect(find.text('PKPR-ab12c'), findsNothing);

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab');
      await tester.pumpAndSettle();
      expect(find.text('PKPR-ab12c'), findsOneWidget);
      expect(find.text('PKPR-ff99aa'), findsNothing); // doesn't match "ab"
    });

    testWidgets('suggests only PKPRs actually in this center\'s inventory, not an arbitrary match', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'zz');
      await tester.pumpAndSettle();
      expect(find.text('PKPR-ab12c'), findsNothing);
      expect(find.text('PKPR-ff99aa'), findsNothing);
    });

    testWidgets('a typed "pkpr-" prefix (any case) does not count toward the two-character minimum', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'PKPR-a');
      await tester.pumpAndSettle();
      expect(find.text('PKPR-ab12c'), findsNothing); // only one significant character after the prefix

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'pkpr-ab');
      await tester.pumpAndSettle();
      expect(find.text('PKPR-ab12c'), findsOneWidget); // now two significant characters, prefix stripped
    });

    testWidgets('tapping a suggestion fills the field with the full PKPR', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12');
      await tester.pumpAndSettle();
      await tester.tap(find.text('PKPR-ab12c'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.widgetWithText(TextField, 'PKPR'));
      expect(field.controller!.text, 'PKPR-ab12c');
    });
  });

  group('pricing modes', () {
    testWidgets('shows how many are in stock, and blocks adding more than that', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ff99aa');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('3 in stock (as of last sync)'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '5');
      await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), '9.00');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();

      // The server's own inventory figure wins - this is a hard cap, not a heads-up, so the dialog stays open
      // and no line was added.
      expect(find.textContaining('Only 3 in stock'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
    });

    testWidgets('a package showing 0 in stock cannot be added at all', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => [
            Package(productGuid: 'PKPR-aaaaa', productType: 'Extract', id: 1, weightPerUnit: 1.0, analyteWeight: 1.0, quantity: 0),
          ]));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'aaaaa');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('0 in stock (as of last sync)'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), '9.00');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Only 0 in stock'), findsOneWidget); // qty defaults to 1, already over the cap
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('an in-stock quantity is accepted normally', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ff99aa', qty: '3', price: '9.00'); // exactly the 3 in stock - the boundary

      expect(find.textContaining('3 x \$9.00'), findsOneWidget);
    });

    testWidgets('pricing per mg (TPE) works out the price each from the package\'s own tpeMg, never the raw analyte weight',
        (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      // PKPR-ab12c has tpeMg 5 (its analyteWeight, 4.5, is a different number on purpose - this proves the
      // calculation uses the real per-unit dose, not the raw mg/g potency field) - $0.02/mg -> 5 * 2c = 10c,
      // rounded = $0.10 each.
      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Price per mg'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Price per mg (TPE)'), '0.02');
      await tester.pump();

      expect(find.textContaining('= \$0.10 each (5 mg TPE/unit)'), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 x \$0.10'), findsOneWidget);
    });

    // SM-16: the cart's tax percent, agreement split and units-per-line cap are the server's live settings.
    const serverSettings = CartSettings(
        minutes: 1080, taxPercent: 10, agreementEdible: 1, agreementDried: 2, dedupeSeconds: 20, maxUnitsPerLine: 2);

    testWidgets("the cart offers the server's own tax percent", (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, fetchCartSettings: (id) async => serverSettings));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whole cart total'));
      await tester.pumpAndSettle();
      expect(find.text('+10% tax'), findsOneWidget);
      expect(find.text('+15% tax'), findsNothing);
    });

    testWidgets("a line can't hold more units than the server allows in one line", (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, fetchCartSettings: (id) async => serverSettings));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '3');
      await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), '1.00');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();
      expect(find.text('At most 2 units in one line.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets("when the server can't say, the built-in settings apply", (tester) async {
      await tester.pumpWidget(cartPage(
          fetchPackages: (id) async => inventory, fetchCartSettings: (id) async => throw CenterStatusError('offline')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whole cart total'));
      await tester.pumpAndSettle();
      expect(find.text('+${CartSettings.fallback.taxPercent}% tax'), findsOneWidget);
    });

    testWidgets('an out-of-range per-mg rate is rejected the same way an out-of-range flat price is', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Price per mg'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Price per mg (TPE)'), '1001');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Enter a rate from \$0 to \$1,000 per mg'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget); // still open - the dialog refused to close on bad input
    });

    testWidgets("a product with no mg TPE can't be priced per mg in the line dialog (SM-14, as the server)", (tester) async {
      final noMg = Package(
          productGuid: 'PKPR-cc33d', productType: 'Extract', id: 103, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 4);
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => [...inventory, noMg]));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'cc33d');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Price per mg'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Price per mg (TPE)'), '2');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();

      expect(find.text("No mg TPE is known for this product, so it can't be priced per mg"), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });

  group('the 50mg-psilocybin-per-sale cap', () {
    testWidgets('a line that alone goes over the cap shows the message and disables Sell', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      // PKPR-ff99aa: weightPerUnit 10.0 x analyteWeight 9.0 = 90mg raw psilocybin per unit, already over the
      // 50mg cap at a qty of just 1 - its tpeMg (90, same number here only by fixture coincidence - see this
      // file's own inventory comment) is not what this cap reads at all.
      await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '9.00');

      // Not just 'mg psilocybin' - the cart's own dose summary (see the 'cart dose summary' group below) now
      // always shows a "X mg psilocybin in the cart" line whenever the cart is non-empty, cap or no cap, so a
      // bare 'mg psilocybin' substring would match that line too. 'This sale would total' is unique to
      // analyteCapError's own message.
      expect(find.textContaining('This sale would total 90.0 mg psilocybin'), findsOneWidget);
      expect(find.textContaining('50 mg limit per sale'), findsOneWidget);
      final sellButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell'));
      expect(sellButton.onPressed, isNull);
    });

    testWidgets('several lines that each stay under the cap but add up over it still block Sell', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      // PKPR-ab12c: 5.0 x 4.5 = 22.5mg/unit. Three lots of 1 unit each (three separate adds, so they don't
      // merge into one line) still total 67.5mg between them - over the cap even though any one of them,
      // sold alone, would be comfortably under it.
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '11.00');
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '12.00');

      expect(find.textContaining('This sale would total 67.5 mg psilocybin'), findsOneWidget);
      final sellButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell'));
      expect(sellButton.onPressed, isNull);
    });

    testWidgets('a cart at or under the cap sells normally, with no cap message shown', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50'); // 2 x 22.5mg = 45mg, under the cap

      // The dose summary below still shows "45.0 mg psilocybin in the cart" here - that's expected and fine;
      // what must be absent is the cap error itself.
      expect(find.textContaining('more than the 50 mg limit per sale'), findsNothing);
      final sellButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell'));
      expect(sellButton.onPressed, isNotNull);
    });

    testWidgets('removing a line that pushed the cart over the cap re-enables Sell', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50'); // 45mg
      await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '9.00'); // +90mg = 135mg, over the cap

      expect(find.textContaining('more than the 50 mg limit per sale'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close).last); // remove the ff99aa line just added
      await tester.pumpAndSettle();

      expect(find.textContaining('more than the 50 mg limit per sale'), findsNothing);
      final sellButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell'));
      expect(sellButton.onPressed, isNotNull);
    });
  });

  group('cart dose summary', () {
    testWidgets('shows total mg TPE and mg psilocybin, and the primary-dose-only duration', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      // PKPR-ab12c: tpeMg 5/unit, weightPerUnit 5.0 x analyteWeight 4.5 = 22.5mg psilocybin/unit. qty 2 ->
      // 10.0mg TPE, 45.0mg psilocybin - both lines default to the initial (primary) dose, so the primary-only
      // and primary+secondary totals are the same here, and so is the duration: 45mg falls in the
      // 35mg-up-to-50mg bracket, a 6-hour minimum.
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      expect(find.text('10.0 mg TPE · 45.0 mg psilocybin in the cart'), findsOneWidget);
      expect(find.text('Duration: 6 hrs · 6 hrs w/ booster'), findsOneWidget);
    });

    testWidgets('a secondary-dose line only affects the "w/ booster" duration, not the primary-only one', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50'); // 45mg, primary dose (the dialog's own default)

      // Switch that same line to the secondary dose - same 45mg total, but now none of it is "primary", so the
      // primary-only duration should drop all the way to the lowest bracket (under 2.5mg -> 30 minutes) while
      // the "w/ booster" total (still 45mg either way) stays at 6 hours.
      await tester.tap(find.text('Extract')); // reopens the add/edit dialog for this line, pre-filled
      await tester.pumpAndSettle();
      // The edit dialog now shows the label picture at the top, so in the test's small window the dose selector
      // sits below the fold of the (scrollable) dialog - scroll it into view, or the tap lands on nothing.
      await tester.ensureVisible(find.text('Secondary dose'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Secondary dose'));
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Save')));
      await tester.pumpAndSettle();

      expect(find.text('10.0 mg TPE · 45.0 mg psilocybin in the cart'), findsOneWidget);
      expect(find.text('Duration: 30 min · 6 hrs w/ booster'), findsOneWidget);
    });

    testWidgets('shows nothing while the cart is empty', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      expect(find.textContaining('mg TPE'), findsNothing);
      expect(find.textContaining('mg psilocybin'), findsNothing);
      expect(find.textContaining('Duration:'), findsNothing);
      expect(find.text('Start Timer'), findsNothing);
    });
  });
}
