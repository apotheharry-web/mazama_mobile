import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/cart_pricing.dart';
import 'package:mazama_mobile/cart_slots.dart';
import 'package:mazama_mobile/cart_store.dart';
import 'package:mazama_mobile/cart_timer_widget.dart';
import 'package:mazama_mobile/center_status_client.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/coa_data_resolver.dart';
import 'package:mazama_mobile/device_id.dart';
import 'package:mazama_mobile/enrichment_store.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/inventory_cache_store.dart';
import 'package:mazama_mobile/label_client.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/phone_label.dart';
import 'package:mazama_mobile/resilience_options.dart';
import 'package:mazama_mobile/state_packages_client.dart';
import 'package:mazama_mobile/sale_failure_client.dart';
import 'package:mazama_mobile/sale_log_client.dart';
import 'package:mazama_mobile/scan_match_client.dart';
import 'package:mazama_mobile/sellability.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_outbox.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/session_timer_store.dart';
import 'package:mazama_mobile/text_scanner.dart';

import 'fake_timers.dart';
import 'flow/fake_state.dart';

final _center = License(id: 231, licenseId: 'SC-b1c7379a', licenseName: 'Bendable Service Center', licenseType: 'ServiceCenter');

// Real-shaped PKPRs (see mazama_sales/src/mazama_sales/labels.py's PKPR_RE: "PKPR-" + 5-8 hex digits) -
// deliberately sharing no common hex prefix with each other so a two-character search can distinguish them.
final _inventory = [
  Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5, strain: 'Golden Teacher', tpeMg: 5, quantity: 10),
  Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0, strain: 'Enigma', tpeMg: 90, quantity: 3),
];

// Far from expiry - none of these tests exercise the renewal path (see session_test.dart for that), so every
// session here is fresh enough that CartPage's own startup renewal check and its periodic timer both return
// immediately with no network call, the same way a widget test for any other page doesn't want to accidentally
// depend on flow_runner.dart/fake_state.dart machinery it isn't testing.
Session _freshSession({String accessToken = 'TOKEN', String email = 'worker@example.com'}) => Session(
    accessToken: accessToken, refreshToken: 'REFRESH', email: email, expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

final _dummySpec = FlowSpec(const {}, const {});

/// A label spec as coa_core gives it (its LabelSpec), for the phone-drawn label.
const Map<String, Object?> _drawnSpec = {
  'pkpr': 'PKPR-ab12c', 'strain': 'Golden Teacher', 'dose_mg_tpe': 25, 'net_wt_g': 2.89, 'best_by': '2027-08-31',
  'per_unit_mg': {'psilocybin': 22.98, 'psilocin': 1.43},
};

/// A real, decodable 1x1 transparent PNG - fetchLabel fixtures need actual image bytes, not just any
/// Uint8List: Image.memory tries to decode whatever it's given, and a placeholder like [1] or [1,2,3,4]
/// throws "Invalid image data" from the image resource service. That exception is asynchronous (it surfaces
/// well after the widget itself is built) and flutter_test still fails the test over it even when every
/// explicit expect() already passed, so a fixture that doesn't actually decode is never actually a no-op.
final _fakeLabelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');

// The real spec, read straight off disk the same way flow_runner_test.dart does - only the Sell tests below
// actually exercise it (against fake_state.dart, never the real state system).
late final FlowSpec _realSaleSpec = FlowSpec.fromYaml(File('assets/flows/sale.yaml').readAsStringSync());

late Directory _tempDir;

/// Keeps what CartPage sends the home-screen widget (MC-D15), instead of sending it.
class _RecordingTimerWidget extends CartTimerWidget {
  final snapshots = <Map<String, Object?>>[];
  var clears = 0;

  @override
  Future<void> publish(Map<String, Object?> snapshot) async => snapshots.add(snapshot);

  @override
  Future<void> clear() async => clears++;

  List<Map<String, Object?>> get lastCarts => [for (final c in snapshots.last['carts'] as List) Map<String, Object?>.from(c as Map)];
}

Widget _cartPage({
  required Future<List<Package>> Function(int) fetchPackages,
  Future<List<Package>> Function(int, {required String accessToken})? fetchPackagesFromState,
  Future<List<Object?>> Function(int, {required String accessToken})? fetchRawPackagesFromState,
  Future<Map<String, Object?>> Function(int, List<Object?>, {required String workerEmail, required String deviceId})? uploadInventorySnapshot,
  Future<CoaData?> Function({
    required String lotGuid,
    required int representativePackageId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    double? statePsilocybin,
  })? submitCoaForLot,
  void Function(int, {required String lotGuid, required int packageId, double? statePsilocybin})? keepCoaLotForLater,
  Future<bool> Function(int)? centerIsConfigured,
  Future<CartSettings> Function(int)? fetchCartSettings,
  Future<AdhocInventoryResult> Function({
    required int stateId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    void Function(List<Package> packages)? onInventoryLoaded,
    void Function(String guid, Package updated)? onResolved,
  })? resolveAdhocInventory,
  InventoryCacheStore? inventoryCacheStore,
  EnrichmentStore? enrichmentStore,
  ResilienceOptions? resilienceOptions,
  Future<Uint8List> Function(int, String)? fetchLabel,
  Future<Map<String, Object?>> Function(int, String, {required String accessToken, String strain})? drawLabel,
  Future<List<License>> Function(String)? fetchLicenses,
  Session? session,
  DateTime Function()? now,
  Future<FlowSpec>? saleSpec,
  http.Client Function()? httpClientFactory,
  SessionStore? sessionStore,
  CartStore? cartStore,
  SessionTimerStore? sessionTimerStore,
  CartSlotsStore? cartSlotsStore,
  CartTimerWidget? cartTimerWidget,
  DeviceIdStore? deviceIdStore,
  Future<void> Function(int, {required String workerEmail, required String deviceId, required List<Map<String, Object?>> request, required Object? response})? postSaleLog,
  Future<void> Function(int, {required String workerEmail, required String deviceId, required String reason, required List<Map<String, Object?>> request})? postSaleFailure,
  Future<List<String>> Function()? scanLabelText,
  Future<ScanMatchResult> Function(int, List<String>, {bool typed})? scanMatch,
  ScanMatchResult? Function(List<Package>, List<String>, {bool typed})? localScanMatch,
  CartPricingMode? pricingMode,
  ValueChanged<int>? onDraftCountChanged,
  FlowSpec? spec,
}) =>
    MaterialApp(
      home: CartPage(
        session: session ?? _freshSession(),
        now: now ?? DateTime.now,
        center: _center,
        spec: spec ?? _dummySpec,
        sessionStore: sessionStore ?? SessionStore(dataDir: () => _tempDir),
        // Same _tempDir as sessionStore's own default above - a distinct file name (cart.json vs session.json)
        // means the two never collide, and most tests here don't care about cart persistence at all, so a real
        // (if temporary) store that happens to find nothing to restore is a safer default than a fake that
        // silently swallows calls a test might actually want to assert on.
        cartStore: cartStore ?? CartStore(dataDir: () => _tempDir),
        // Same reasoning again - a real (temporary) store, so a test that cares whether the session timer's
        // start time survived a simulated app restart (a fresh pumpWidget reusing the same store) can assert
        // on it directly, same as cartStore's own restore tests do.
        sessionTimerStore: sessionTimerStore ?? SessionTimerStore(dataDir: () => _tempDir),
        // The list of carts (specs/multi-cart): a real (temporary) store, as cartStore.
        cartSlotsStore: cartSlotsStore ?? CartSlotsStore(dataDir: () => _tempDir),
        // The home-screen widget (MC-D15): recorded, never sent over a real platform channel.
        cartTimerWidget: cartTimerWidget ?? _RecordingTimerWidget(),
        // Same reasoning again - a real (temporary) store rather than a fixed fake string, so a test that
        // cares what deviceId was sent can read it back the same way the real app would generate it.
        deviceIdStore: deviceIdStore ?? DeviceIdStore(dataDir: () => _tempDir),
        // Same reasoning again - a real (temporary) store, so a test exercising the 3-day cache fallback can
        // seed or inspect it directly, same as cartStore's own restore tests do.
        inventoryCacheStore: inventoryCacheStore ?? InventoryCacheStore(dataDir: () => _tempDir),
        // Same reasoning: what Mazama's server last sent per package, in the test's own folder.
        enrichmentStore: enrichmentStore ?? EnrichmentStore(dataDir: () => _tempDir),
        // Unlike the stores above, the REAL default here is a live network call to the state system - never
        // safe to fall through to in a test. A test that doesn't care about this fallback (most of them) still
        // needs it to fail cleanly with no network access at all, so a failed fetchPackages in those tests
        // still surfaces its OWN error (resilient_inventory.dart's own rule: the original failure always wins
        // once every fallback tier has also failed) rather than hanging or throwing something unrelated.
        fetchPackagesFromState: fetchPackagesFromState ??
            (stateId, {required accessToken}) async => throw StatePackagesError('no state-fallback fixture wired for this test'),
        // The REAL default here is also a live network call (to the state system, raw/unmapped - see
        // merged_inventory.dart) - and unlike fetchPackagesFromState above, it is no longer a tier-2 fallback
        // only reached on a tier-1 failure: _fetchMergedForCart calls it on EVERY configured-center load,
        // concurrently with fetchPackages, so every test in this file that opens a CartPage needs a fixture
        // here or it hangs waiting on a real (and in a test sandbox, unreachable) network call. Throwing is the
        // cheapest fixture - merged_inventory.dart's own fetchMergedInventory already treats "the state side
        // failed" as a non-fatal, mazama-only result exactly as long as fetchPackages itself succeeded, so this
        // default keeps every existing test's tier-1-only expectations unchanged.
        fetchRawPackagesFromState: fetchRawPackagesFromState ??
            (stateId, {required accessToken}) async => throw StatePackagesError('no raw-state fixture wired for this test'),
        // A test that doesn't care about item 3a's push-after-every-state-read (every test above this field was
        // added, since fetchRawPackagesFromState above throws by default) never reaches this at all - succeeding
        // with an empty map, rather than throwing, is the safer default in case a test ever wires a succeeding
        // fetchRawPackagesFromState without separately wiring this one, the same "never surfaced to the worker"
        // rule cart_page.dart's own _fetchMergedForCart already applies to a real push failure.
        uploadInventorySnapshot: uploadInventorySnapshot ??
            (stateId, records, {required workerEmail, required deviceId}) async => <String, Object?>{},
        // A test that doesn't exercise item 3b's cart-add COA submission (every test above this field was added)
        // never reaches this at all - every existing fixture Package already defaults coaAvailable/
        // labelAvailable to true (packages_client.dart's own Package constructor), so _ensureCoaForCartLine
        // finds nothing to submit for and never calls this. Throwing is the cheapest fixture and would surface
        // clearly as a bug if that ever stopped being the case - same reasoning as resolveAdhocInventory below.
        submitCoaForLot: submitCoaForLot ??
            ({required lotGuid, required representativePackageId, required accessToken, required workerEmail, required deviceId, statePsilocybin}) async =>
                throw CoaDataError('no configured-coa-submit fixture wired for this test'),
        // never the app's own catch-up file (server_link.dart) in a test
        keepCoaLotForLater: keepCoaLotForLater ?? (stateId, {required lotGuid, required packageId, statePsilocybin}) {},
        fetchPackages: fetchPackages,
        // The real default here is also a live network call (to Mazama's own server, not the state system -
        // see coa_data_client.dart's own centerIsConfigured) - never safe to fall through to in a test either.
        // Defaulting to "true" (rather than letting it fail and rely on _loadInventoryAsync's own catch-and-
        // assume-configured fallback) means every existing test above, which was written before this field
        // existed, keeps exercising the exact same ordinary fetchPackages/fetchPackagesFromState tiers it
        // always did, with no real network attempt in between even on the failure path.
        centerIsConfigured: centerIsConfigured ?? (stateId) async => true,
        // SM-16: the built-in fallback unless a test sets the server's live values - never a network call.
        fetchCartSettings: fetchCartSettings ?? (stateId) async => CartSettings.fallback,
        // A test that doesn't exercise the adhoc-COA path (every test above this field was added) never reaches
        // this at all, since centerIsConfigured defaults to true above - throwing is the cheapest fixture and
        // would surface clearly as a bug if that ever stopped being the case.
        resolveAdhocInventory: resolveAdhocInventory ??
            ({required stateId, required accessToken, required workerEmail, required deviceId, onInventoryLoaded, onResolved}) async =>
                throw AdhocCoaError('no adhoc-COA fixture wired for this test'),
        resilienceOptions: resilienceOptions ?? const ResilienceOptions(),
        // A test that doesn't care about the post-add label-compare dialog (most of them) still needs this to
        // resolve to *something* without a real network call - a 404-shaped failure is the cheapest fixture
        // and exercises the exact same "no label available" branch _addLine below has to get past either way.
        fetchLabel: fetchLabel ?? (stateId, guid) async => throw LabelError('no label fixture for $guid'),
        // ...and the phone's own drawing, tried next, likewise never reads the real state system in a test.
        drawLabel: drawLabel ?? (stateId, pkpr, {required accessToken, strain = ''}) async => throw PhoneLabelError('no drawing fixture'),
        // Same reasoning - a test that doesn't exercise "switch center" still needs this to resolve to
        // something rather than make a real GetApplicableLicenses call if it's ever reached.
        fetchLicenses: fetchLicenses ?? (accessToken) async => const [],
        saleSpec: saleSpec,
        httpClientFactory: httpClientFactory,
        // Same reasoning again - a test that doesn't care about sale-attribution logging (most of them) still
        // needs this to resolve to *something* without a real network call, and silently succeeding (rather
        // than throwing) is the right default: a thrown default here would be indistinguishable in test output
        // from a real bug, for tests that never meant to exercise this path at all.
        postSaleLog: postSaleLog ?? (stateId, {required workerEmail, required deviceId, required request, required response}) async {},
        postSaleFailure: postSaleFailure ?? (stateId, {required workerEmail, required deviceId, required reason, required request}) async {},
        // A test that doesn't exercise scanning (most of them) still needs these to resolve to something
        // rather than ever reach a real platform channel or a real network call if _onScanPressed is somehow
        // reached - throwing ScanCancelled is the cheapest fixture and reads the same as "nothing happened" the
        // scan button's own tooltip/snackbar already treats a cancelled scan as.
        scanLabelText: scanLabelText ?? () async => throw ScanCancelled(),
        scanMatch: scanMatch ?? (stateId, lines, {typed = false}) async => ScanMatchResult(matches: const [], guesses: const []),
        // never the real one, which would load whatever coa_core library the test machine has: "not built" (null)
        localScanMatch: localScanMatch ?? (inventory, lines, {typed = false}) => null,
        // The real app now defaults to CartPricingMode.total (most sales are priced as a whole-cart total),
        // but almost every test in this file is specifically exercising "each" mode's own per-line price entry
        // (typing a Quantity/Price each into the add dialog) - defaulting tests to "each" here keeps every one
        // of those tests decoupled from whatever the real app's own default happens to be, the same reasoning
        // fetchLabel/postSaleLog/scanLabelText above already use for their own test-friendly defaults.
        initialPricingMode: pricingMode ?? CartPricingMode.each,
        onDraftCountChanged: onDraftCountChanged,
      ),
    );

/// Drives the same UI path a worker uses to add a line - enter the PKPR, tap Add, fill in the dialog, confirm
/// it - stopping right as the label-compare dialog (cart_page.dart's _showLabelDialog) pops up, so a caller
/// that wants to inspect that dialog can do so before anything dismisses it.
Future<void> _addLineLeavingLabelDialogOpen(WidgetTester tester,
    {required String pkpr, required String qty, required String price}) async {
  await tester.enterText(find.widgetWithText(TextField, 'PKPR'), pkpr);
  await tester.tap(find.widgetWithText(FilledButton, 'Add'));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), qty);
  await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), price);
  // Scoped to the dialog specifically - the main screen's own 'Add' FilledButton is still in the tree
  // underneath it (showDialog doesn't remove the page below), so an unscoped find.text('Add') here would
  // match both and tap() would refuse to pick one.
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
  await tester.pumpAndSettle();
}

/// Same as above, but also closes the label-compare dialog that pops up right after a successful add - what
/// every test that isn't specifically about that dialog should use, so it doesn't sit open and intercept
/// whatever the test does next (tapping Sell, reading the cart list, and so on).
Future<void> _addLine(WidgetTester tester, {required String pkpr, required String qty, required String price}) async {
  await _addLineLeavingLabelDialogOpen(tester, pkpr: pkpr, qty: qty, price: price);
  await tester.tap(find.widgetWithText(TextButton, 'Close'));
  await tester.pumpAndSettle();
}

void main() {
  // rootBundle.loadString caches its Future by asset key for the lifetime of the whole test *process*, not
  // per-test (see widget_test.dart's own note on this). CartPage's constructor loads assets/flows/sale.yaml
  // via rootBundle whenever a test doesn't pass saleSpec: explicitly, which is most tests in this file - without
  // clearing it, a later test can get an earlier test's already-created Future, straddling two different
  // testWidgets async zones. That doesn't throw - it just leaves that test's pumpAndSettle waiting on a Future
  // that never resolves in its own zone, hanging for the full default test timeout (10 minutes) instead of
  // failing fast. Only a few tests happened to lose this race on any given run, never a reliable repro.
  tearDown(() => rootBundle.clear());

  setUp(() => _tempDir = Directory.systemTemp.createTempSync('mazama_cart_test_'));
  tearDown(() => _tempDir.deleteSync(recursive: true));

  testWidgets('shows a loading banner, then nothing extra (an empty cart has no dose total to show)', (tester) async {
    await tester.pumpWidget(_cartPage(fetchPackages: (id) async {
      expect(id, 231);
      return _inventory;
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
    await tester.pumpWidget(_cartPage(fetchPackages: (id) async {
      attempts += 1;
      throw Exception('server unreachable');
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('server unreachable'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  testWidgets('tier 1 down, tier 2 (state) up: shows the state-fallback banner, no retry-count assumptions', (tester) async {
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => throw Exception('mazama server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async {
        expect(accessToken, 'TOKEN');
        return _inventory;
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("Mazama's own server could not be reached"), findsOneWidget);
    // The cart dose summary (built from _inventory) still renders underneath the banner - a worker on this
    // tier can still work, just without a live count.
    expect(find.textContaining('server unreachable'), findsNothing);
  });

  testWidgets("a live load remembers the server's own figures per package for a later outage", (tester) async {
    final enrichment = EnrichmentStore(dataDir: () => _tempDir);
    await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, enrichmentStore: enrichment));
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

    testWidgets("every product filled: the banner says strain and TPE are Mazama's from its last update", (tester) async {
      final enrichment = EnrichmentStore(dataDir: () => _tempDir);
      await enrichment.remember(served, seen);
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => throw Exception('mazama server unreachable'),
        fetchPackagesFromState: (stateId, {required accessToken}) async => fromState(),
        enrichmentStore: enrichment,
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining("Strain and TPE are from Mazama's last update on ${formatEnrichmentDate(seen)}"), findsOneWidget);
      expect(find.textContaining('Strain names are not shown'), findsNothing);
    });

    testWidgets("a product whose state potency changed stays an estimate, and the banner says how many", (tester) async {
      final enrichment = EnrichmentStore(dataDir: () => _tempDir);
      await enrichment.remember(served, seen);
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => throw Exception('mazama server unreachable'),
        fetchPackagesFromState: (stateId, {required accessToken}) async => fromState(ff99aaPotency: 9.5),
        enrichmentStore: enrichment,
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining("Strain and TPE for 1 of 2 products are from Mazama's last update on ${formatEnrichmentDate(seen)}"),
          findsOneWidget);
      expect(find.textContaining("For the other product only the state's psilocybin is known: shown as mg psilocybin (marked in the stock list)"),
          findsOneWidget);
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
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => throw Exception('mazama server unreachable'),
        fetchPackagesFromState: (stateId, {required accessToken}) async => stateOnly(),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets("the banner says only the state's psilocybin is known, and the cart line says mg psilocybin", (tester) async {
      await openStateOnly(tester);
      expect(find.textContaining("No TPE is known for these products: amounts are the state's psilocybin only, shown as mg psilocybin"),
          findsOneWidget);
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
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
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.text('Cart \$/mg'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Price per mg (TPE; mg psilocybin where no TPE is known), whole cart'), findsOneWidget);
    });

    testWidgets('the 50 mg cap still counts raw psilocybin (22.5 mg a unit), not the rounded-up 23', (tester) async {
      await openStateOnly(tester);
      await _addLine(tester, pkpr: 'ab12c', qty: '3', price: '10.00');
      expect(find.textContaining('This sale would total 67.5 mg psilocybin'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell')).onPressed, isNull);
    });

    testWidgets("a product filled from the phone's reading of the lab report shows mg TPE and says whose it is", (tester) async {
      final enrichment = EnrichmentStore(dataDir: () => _tempDir);
      final seen = DateTime.now().toUtc().subtract(const Duration(hours: 2));
      await enrichment.rememberPhone([
        PackageEnrichment(productGuid: 'PKPR-ab12c', id: 101, weightPerUnit: 5, analyteWeight: 4.5, strain: 'Golden Teacher',
            tpeMg: 26, expires: null, seenAt: seen, source: EnrichmentSource.phone, tpeMgPerG: 5.12, psilocinMg: 2.8),
      ], seen);
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => throw Exception('mazama server unreachable'),
        fetchPackagesFromState: (stateId, {required accessToken}) async => stateOnly(),
        enrichmentStore: enrichment,
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining("Strain and TPE are from this phone's reading of the lab reports, from ${formatEnrichmentDate(seen)} on"),
          findsOneWidget);
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      expect(find.textContaining('26mg TPE each'), findsOneWidget);
      expect(find.text('26.0 mg TPE · 22.5 mg psilocybin in the cart'), findsOneWidget);
    });
  });

  testWidgets('tiers 1 and 2 both down, a same-center cache on file: shows the cache-fallback banner with its age', (tester) async {
    final store = InventoryCacheStore(dataDir: () => _tempDir);
    final fetchedAt = DateTime.now().subtract(const Duration(hours: 5));
    await store.save(_center.id, _inventory, fetchedAt);
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => throw Exception('mazama server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable too'),
      inventoryCacheStore: store,
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("Neither Mazama's server nor the state system could be reached"), findsOneWidget);
    expect(find.textContaining('5 hours ago'), findsOneWidget);
  });

  testWidgets('resilienceOptions.enableStateFallback: false skips tier 2, even with fetchPackagesFromState wired', (tester) async {
    var stateFallbackCalled = false;
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => throw Exception('mazama server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async {
        stateFallbackCalled = true;
        return _inventory;
      },
      resilienceOptions: const ResilienceOptions(enableStateFallback: false),
    ));
    await tester.pumpAndSettle();
    expect(stateFallbackCalled, isFalse);
    // Tier 2 skipped and tier 3 empty (fresh _tempDir) - the original tier-1 error is what surfaces, same as
    // if no fallback existed at all.
    expect(find.textContaining('server unreachable'), findsOneWidget);
    expect(find.textContaining("Mazama's own server could not be reached"), findsNothing);
  });

  testWidgets('resilienceOptions.cacheMaxAge shortens the window a cached inventory is still trusted in', (tester) async {
    final store = InventoryCacheStore(dataDir: () => _tempDir);
    final fetchedAt = DateTime.now().subtract(const Duration(hours: 2));
    await store.save(_center.id, _inventory, fetchedAt);
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => throw Exception('mazama server unreachable'),
      fetchPackagesFromState: (stateId, {required accessToken}) async => throw StatePackagesError('state unreachable too'),
      inventoryCacheStore: store,
      // A 2-hour-old cache would normally be well within the default 3-day window - this build's own 1-hour
      // window means it's already too old to trust, so the original tier-1 error should surface instead.
      resilienceOptions: const ResilienceOptions(cacheMaxAge: Duration(hours: 1)),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('server unreachable'), findsOneWidget);
    expect(find.textContaining("Neither Mazama's server nor the state system could be reached"), findsNothing);
  });

  testWidgets('centerIsConfigured false: switches to the adhoc flow entirely, never touching fetchPackages', (tester) async {
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => throw Exception('tier 1 should never be tried for an unconfigured center'),
      centerIsConfigured: (stateId) async => false,
      resolveAdhocInventory: ({required stateId, required accessToken, required workerEmail, required deviceId, onInventoryLoaded, onResolved}) async {
        onInventoryLoaded?.call(_inventory);
        return AdhocInventoryResult(packages: _inventory, guidsTotal: 0, guidsResolved: 0);
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("This center isn't configured in Mazama yet"), findsOneWidget);
    expect(find.textContaining('tier 1 should never be tried'), findsNothing);
  });

  testWidgets('centerIsConfigured false: progress wording reflects guidsResolved vs guidsTotal, no Retry button until fully resolved', (tester) async {
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => _inventory,
      centerIsConfigured: (stateId) async => false,
      resolveAdhocInventory: ({required stateId, required accessToken, required workerEmail, required deviceId, onInventoryLoaded, onResolved}) async {
        onInventoryLoaded?.call(_inventory);
        return AdhocInventoryResult(packages: _inventory, guidsTotal: 3, guidsResolved: 1);
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('resolving lab reports: 1 of 3 lots so far'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('centerIsConfigured false: once every lot resolves, shows the fully-resolved wording and a Retry button', (tester) async {
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => _inventory,
      centerIsConfigured: (stateId) async => false,
      resolveAdhocInventory: ({required stateId, required accessToken, required workerEmail, required deviceId, onInventoryLoaded, onResolved}) async {
        onInventoryLoaded?.call(_inventory);
        return AdhocInventoryResult(packages: _inventory, guidsTotal: 2, guidsResolved: 2);
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('every lot resolved'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('centerIsConfigured true: ordinary tiers run exactly as before, resolveAdhocInventory never called', (tester) async {
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => _inventory,
      centerIsConfigured: (stateId) async => true,
      // Left at its default (throws) - a call here from the "configured" branch would be a real bug.
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't configured in Mazama yet"), findsNothing);
  });

  testWidgets('centerIsConfigured throwing falls through to the ordinary tiers, same as answering true', (tester) async {
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => _inventory,
      centerIsConfigured: (stateId) async => throw Exception('center-status unreachable'),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't configured in Mazama yet"), findsNothing);
    expect(find.textContaining('center-status unreachable'), findsNothing);
  });

  testWidgets('typing an unknown PKPR shows a lookup error, not a crash', (tester) async {
    await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'zzzzz');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No PKPR zzzzz'), findsOneWidget);
  });

  for (final typed in ['ab', 'ab12c!', 'PKPR-0123456789abcdefg', 'ab 12c']) {
    testWidgets('a typed "$typed" is checked against the shared package id rule before it is looked up (SM-27)', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
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
    await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'AB12C');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.textContaining('PKPR-ab12c'), findsWidgets); // the add dialog is up, showing which package matched
  });

  testWidgets('adding a known PKPR opens the quantity/price dialog, then lists it with a running total', (tester) async {
    await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'zz');
      await tester.pumpAndSettle();
      expect(find.text('PKPR-ab12c'), findsNothing);
      expect(find.text('PKPR-ff99aa'), findsNothing);
    });

    testWidgets('a typed "pkpr-" prefix (any case) does not count toward the two-character minimum', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'PKPR-a');
      await tester.pumpAndSettle();
      expect(find.text('PKPR-ab12c'), findsNothing); // only one significant character after the prefix

      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'pkpr-ab');
      await tester.pumpAndSettle();
      expect(find.text('PKPR-ab12c'), findsOneWidget); // now two significant characters, prefix stripped
    });

    testWidgets('tapping a suggestion fills the field with the full PKPR', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => [
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ff99aa', qty: '3', price: '9.00'); // exactly the 3 in stock - the boundary

      expect(find.textContaining('3 x \$9.00'), findsOneWidget);
    });

    testWidgets('pricing per mg (TPE) works out the price each from the package\'s own tpeMg, never the raw analyte weight',
        (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, fetchCartSettings: (id) async => serverSettings));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whole cart total'));
      await tester.pumpAndSettle();
      expect(find.text('+10% tax'), findsOneWidget);
      expect(find.text('+15% tax'), findsNothing);
    });

    testWidgets("a line can't hold more units than the server allows in one line", (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, fetchCartSettings: (id) async => serverSettings));
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
      await tester.pumpWidget(_cartPage(
          fetchPackages: (id) async => _inventory, fetchCartSettings: (id) async => throw CenterStatusError('offline')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whole cart total'));
      await tester.pumpAndSettle();
      expect(find.text('+${CartSettings.fallback.taxPercent}% tax'), findsOneWidget);
    });

    testWidgets('an out-of-range per-mg rate is rejected the same way an out-of-range flat price is', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => [..._inventory, noMg]));
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      // PKPR-ff99aa: weightPerUnit 10.0 x analyteWeight 9.0 = 90mg raw psilocybin per unit, already over the
      // 50mg cap at a qty of just 1 - its tpeMg (90, same number here only by fixture coincidence - see this
      // file's own _inventory comment) is not what this cap reads at all.
      await _addLine(tester, pkpr: 'ff99aa', qty: '1', price: '9.00');

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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      // PKPR-ab12c: 5.0 x 4.5 = 22.5mg/unit. Three lots of 1 unit each (three separate adds, so they don't
      // merge into one line) still total 67.5mg between them - over the cap even though any one of them,
      // sold alone, would be comfortably under it.
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '11.00');
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '12.00');

      expect(find.textContaining('This sale would total 67.5 mg psilocybin'), findsOneWidget);
      final sellButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell'));
      expect(sellButton.onPressed, isNull);
    });

    testWidgets('a cart at or under the cap sells normally, with no cap message shown', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50'); // 2 x 22.5mg = 45mg, under the cap

      // The dose summary below still shows "45.0 mg psilocybin in the cart" here - that's expected and fine;
      // what must be absent is the cap error itself.
      expect(find.textContaining('more than the 50 mg limit per sale'), findsNothing);
      final sellButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell'));
      expect(sellButton.onPressed, isNotNull);
    });

    testWidgets('removing a line that pushed the cart over the cap re-enables Sell', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50'); // 45mg
      await _addLine(tester, pkpr: 'ff99aa', qty: '1', price: '9.00'); // +90mg = 135mg, over the cap

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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      // PKPR-ab12c: tpeMg 5/unit, weightPerUnit 5.0 x analyteWeight 4.5 = 22.5mg psilocybin/unit. qty 2 ->
      // 10.0mg TPE, 45.0mg psilocybin - both lines default to the initial (primary) dose, so the primary-only
      // and primary+secondary totals are the same here, and so is the duration: 45mg falls in the
      // 35mg-up-to-50mg bracket, a 6-hour minimum.
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      expect(find.text('10.0 mg TPE · 45.0 mg psilocybin in the cart'), findsOneWidget);
      expect(find.text('Duration: 6 hrs · 6 hrs w/ booster'), findsOneWidget);
    });

    testWidgets('a secondary-dose line only affects the "w/ booster" duration, not the primary-only one', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50'); // 45mg, primary dose (the dialog's own default)

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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();

      expect(find.textContaining('mg TPE'), findsNothing);
      expect(find.textContaining('mg psilocybin'), findsNothing);
      expect(find.textContaining('Duration:'), findsNothing);
      expect(find.text('Start Timer'), findsNothing);
    });
  });

  group('cart session timer', () {
    testWidgets('the home-screen widget is sent the running timer, counting down to the dose\'s session end, then nothing after Reset',
        (tester) async {
      final fakeNow = DateTime.now();
      final timers = _RecordingTimerWidget();
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, now: () => fakeNow, cartTimerWidget: timers));
      await tester.pumpAndSettle();
      expect(timers.lastCarts, isEmpty);
      expect(timers.snapshots.last['center'], 'Bendable Service Center');

      // 2 x 5.0 g x 4.5 mg/g = 45 mg psilocybin: a 6 hour session (sessionTable).
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      await tester.pump();
      expect(timers.lastCarts, [
        {
          'id': defaultCartId,
          'name': 'Cart 1',
          'startMs': fakeNow.millisecondsSinceEpoch,
          'endMs': fakeNow.add(const Duration(hours: 6)).millisecondsSinceEpoch,
          'booster': false,
        }
      ]);

      await tester.tap(find.text('Reset'));
      await tester.pump();
      await tester.pump();
      expect(timers.lastCarts, isEmpty);
    });

    testWidgets('starts at "Start Timer", switches to a counting-up elapsed display once tapped', (tester) async {
      var fakeNow = DateTime.now();
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, now: () => fakeNow));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      expect(find.text('Start Timer'), findsOneWidget);
      expect(find.textContaining('Elapsed:'), findsNothing);

      await tester.tap(find.text('Start Timer'));
      await tester.pump();

      expect(find.text('Start Timer'), findsNothing);
      expect(find.text('Elapsed: 00:00'), findsOneWidget);

      // The on-page ticker redraws once a second against widget.now() (never the real wall clock) - advancing
      // the fake clock and then pumping one tick is enough to see the new elapsed figure, regardless of how
      // many real ticker callbacks fired in between.
      fakeNow = fakeNow.add(const Duration(minutes: 1, seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 01:30'), findsOneWidget);

      fakeNow = fakeNow.add(const Duration(hours: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 1:01:30'), findsOneWidget);

      // Reset before the test ends, so the periodic ticker is cancelled rather than left pending.
      await tester.tap(find.text('Reset'));
      await tester.pump();
    });

    testWidgets('Reset clears the timer back to the Start Timer button', (tester) async {
      var fakeNow = DateTime.now();
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, now: () => fakeNow));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      fakeNow = fakeNow.add(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 05:00'), findsOneWidget);

      await tester.tap(find.text('Reset'));
      await tester.pump();

      expect(find.text('Start Timer'), findsOneWidget);
      expect(find.textContaining('Elapsed:'), findsNothing);
    });

    testWidgets('a running timer survives a simulated app restart (same sessionTimerStore)', (tester) async {
      var fakeNow = DateTime.now();
      final store = SessionTimerStore(dataDir: () => _tempDir);
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, now: () => fakeNow, sessionTimerStore: store));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      fakeNow = fakeNow.add(const Duration(minutes: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 03:00'), findsOneWidget);

      // Simulate the app being force-closed and reopened: a brand new CartPage/State reading from the same
      // sessionTimerStore (and the same _tempDir the cart itself restores from) - the same scenario the
      // existing "restores a draft cart across restart" tests already simulate this same way, with another
      // 2 minutes having passed on the fake clock while the app was "closed".
      fakeNow = fakeNow.add(const Duration(minutes: 2));
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, now: () => fakeNow, sessionTimerStore: store));
      await tester.pumpAndSettle();

      // Picks the original start time back up - the elapsed figure reflects the full 5 minutes since the
      // timer was first started, not a reset back to zero.
      expect(find.text('Elapsed: 05:00'), findsOneWidget);
      expect(find.text('Start Timer'), findsNothing);

      // Reset before the test ends, so the periodic ticker is cancelled rather than left pending.
      await tester.tap(find.text('Reset'));
      await tester.pump();
    });

    testWidgets('the timer resets itself automatically once sessionTimerMaxAge has passed', (tester) async {
      var fakeNow = DateTime.now();
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, now: () => fakeNow));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.text('Start Timer'));
      await tester.pump();

      // A worker who starts a session and simply never comes back to reset it (the client's visit runs long,
      // or the "Reset" tap is just forgotten) shouldn't see the stopwatch keep counting into the next day -
      // once sessionTimerMaxAge has passed, the next tick resets it back to "Start Timer" on its own, with
      // nothing left for the test to clean up (the periodic ticker cancels itself as part of that reset).
      fakeNow = fakeNow.add(sessionTimerMaxAge);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Start Timer'), findsOneWidget);
      expect(find.textContaining('Elapsed:'), findsNothing);
    });

    testWidgets('a persisted timer older than sessionTimerMaxAge is not restored on reopen, and is cleared', (tester) async {
      final fakeNow = DateTime.now();
      final store = SessionTimerStore(dataDir: () => _tempDir);
      // A worker started a session, then the app was force-closed for well over sessionTimerMaxAge (an
      // overnight shutdown, say) - by the time it's reopened, resuming the stopwatch from that stale start
      // time would show a nonsensical elapsed figure, so this is treated the same as a timer that already
      // aged out while the app stayed open: not resumed, and cleared from disk.
      await store.save(231, fakeNow.subtract(sessionTimerMaxAge + const Duration(minutes: 1)));

      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, now: () => fakeNow, sessionTimerStore: store));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      expect(find.text('Start Timer'), findsOneWidget);
      expect(find.textContaining('Elapsed:'), findsNothing);
      expect(await store.load(231), isNull);
    });
  });

  group('editing a cart line', () {
    testWidgets('tapping a line reopens the dialog pre-filled, and Save updates it in place', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.text('Extract'));
      await tester.pumpAndSettle();

      // Pre-filled from the existing line, not reset to the dialog's own "new line" defaults.
      expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Quantity')).controller!.text, '2');
      expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Price each')).controller!.text, '12.50');
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
      // Scoped to the dialog - the main screen's own 'Add' FilledButton (next to the PKPR field) is still in
      // the tree underneath it, so an unscoped check here would find that one instead.
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')),
          findsNothing);

      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '5');
      await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), '20.00');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('5 x \$20.00'), findsOneWidget);
      expect(find.text('\$100.00'), findsWidgets); // the one line now totals $100, same as the cart
      expect(find.textContaining('2 x \$12.50'), findsNothing); // the old figures are gone, not duplicated
    });

    testWidgets('the edit icon opens the same dialog as tapping the line', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    });

    testWidgets('cancelling an edit leaves the line untouched', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.text('Extract'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '99');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 x \$10.00'), findsOneWidget);
      expect(find.textContaining('99'), findsNothing);
    });

    testWidgets('editing does not merge the line into another one with the same price and dose', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await _addLine(tester, pkpr: 'ff99aa', qty: '1', price: '10.00');

      // Edit the second line (ff99aa) to the same price - if this merged the way adding a matching PKPR does,
      // the cart would collapse to one line; it must stay two, since the worker only meant to change this one.
      await tester.tap(find.text('Whole Fungi'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Save')));
      await tester.pumpAndSettle();

      expect(find.text('Extract'), findsOneWidget);
      expect(find.text('Whole Fungi'), findsOneWidget);
    });
  });

  group('label comparison', () {
    testWidgets('shows the fetched label image after a successful add, for this center\'s own state id', (tester) async {
      final bytes = _fakeLabelPng;
      int? seenStateId;
      String? seenGuid;
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        fetchLabel: (stateId, guid) async {
          seenStateId = stateId;
          seenGuid = guid;
          return bytes;
        },
      ));
      await tester.pumpAndSettle();
      await _addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.widgetWithText(AlertDialog, 'Compare label · PKPR-ab12c'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(seenStateId, 231); // this cart's own center id, not anything from the package payload
      expect(seenGuid, 'PKPR-ab12c');

      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('shows a plain message, not a crash, when the server has no label for this package', (tester) async {
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        fetchLabel: (stateId, guid) async => throw LabelError('no label on file for $guid'),
      ));
      await tester.pumpAndSettle();
      await _addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.textContaining('No label on file'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('draws the label on the phone when the server has none', (tester) async {
      final drawn = <String>[];
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        fetchLabel: (stateId, guid) async => throw LabelError('no label on file for $guid'),
        drawLabel: (stateId, pkpr, {required accessToken, strain = ''}) async {
          drawn.add('$stateId $pkpr $accessToken $strain');
          return _drawnSpec;
        },
      ));
      await tester.pumpAndSettle();
      await _addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      // the cart's own center, the package, the worker's state session and the strain the server already knows
      expect(drawn, ['231 PKPR-ab12c TOKEN Golden Teacher']);
      expect(find.text('Drawn on this phone: no label on file at the server'), findsOneWidget);
      expect(find.text('Lot: ab12c'), findsOneWidget);
      expect(find.text('Psilocybin: 22.98 mg'), findsOneWidget);
      expect(find.textContaining('No label on file'), findsNothing);
      expect(find.byType(Image), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Extract')); // the edit dialog shows the same drawing, without reading the report again
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Lot: ab12c')), findsOneWidget);
      expect(drawn, hasLength(1));
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('never draws on the phone when the server has a label', (tester) async {
      var drew = false;
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        fetchLabel: (stateId, guid) async => _fakeLabelPng,
        drawLabel: (stateId, pkpr, {required accessToken, strain = ''}) async {
          drew = true;
          return _drawnSpec;
        },
      ));
      await tester.pumpAndSettle();
      await _addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.byType(Image), findsOneWidget);
      expect(drew, isFalse);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('says why when neither the server nor the phone has a label, and tries the phone again next time', (tester) async {
      var tries = 0;
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        drawLabel: (stateId, pkpr, {required accessToken, strain = ''}) async {
          tries++;
          throw PhoneLabelError('lot HB-aaaa0001 has no accepted lab report on file at the state yet');
        },
      ));
      await tester.pumpAndSettle();
      await _addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.textContaining('No label on file'), findsOneWidget);
      expect(find.textContaining("The phone couldn't draw one: lot HB-aaaa0001 has no accepted lab report on file"), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Extract'));
      await tester.pumpAndSettle();
      expect(tries, 2); // a failed drawing isn't kept
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('editing a line in the cart shows that package\'s label in the edit dialog', (tester) async {
      final seenGuids = <String>[];
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        fetchLabel: (stateId, guid) async {
          seenGuids.add(guid);
          return _fakeLabelPng;
        },
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      seenGuids.clear(); // only count what the edit dialog fetches

      await tester.tap(find.text('Extract')); // reopens the line in the edit dialog
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Image)), findsOneWidget);
      // Typing in the dialog rebuilds it; the label must not be fetched again for each keystroke.
      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
      await tester.pumpAndSettle();
      expect(seenGuids, ['PKPR-ab12c']);

      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('the edit dialog shows a plain message when the package has no label', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory)); // default fetchLabel throws
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.text('Extract'));
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('No label on file')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget); // the rest of the dialog still works

      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('the add dialog does not show the label (the compare popup after the add does)', (tester) async {
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        fetchLabel: (stateId, guid) async => _fakeLabelPng,
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Image)), findsNothing);

      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('closing it does not affect the line that was already added to the cart', (tester) async {
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        fetchLabel: (stateId, guid) async => _fakeLabelPng,
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.text('Nothing in the cart yet.'), findsNothing);
      expect(find.text('Extract'), findsOneWidget);
    });
  });

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

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

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
        await tester.pumpWidget(_cartPage(
          fetchPackages: (id) async => _inventory,
          fetchRawPackagesFromState: (id, {required accessToken}) async {
            if (!loaded) throw StatePackagesError('not read at load in this test');
            reads++;
            return reread();
          },
          now: () => clock,
          session: _freshSession(accessToken: login['access_token'] as String),
          saleSpec: Future.value(_realSaleSpec),
          httpClientFactory: fake.client,
        ));
        await tester.pumpAndSettle();
        loaded = true;
        clock = clock.add(age);
        await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => four));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '3', price: '10.00');
      await _addLine(tester, pkpr: 'ab12c', qty: '3', price: '10.00');

      expect(find.text('Only 4 of PKPR-ab12c in stock.'), findsOneWidget);
      expect(find.textContaining('3 x \$10.00'), findsOneWidget); // the line still holds 3, not 6
      expect(find.textContaining('6 x '), findsNothing);
    });

    testWidgets('a line beyond every lot is refused before anything is sent, never put on the last lot (SM-17)',
        (tester) async {
      // A saved cart from when there was more stock: 5 units, but the lots behind it now hold 2.
      final cartStore = CartStore(dataDir: () => _tempDir);
      final two = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 0.5, quantity: 2);
      await cartStore.save(_center.id, [CartLine(group: PkprGroup([two]), qty: 5, priceCentsEach: 1000)]);
      final fake = FakeState();

      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => [two], cartStore: cartStore, httpClientFactory: fake.client));
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
        // analyteWeight deliberately low (unlike _inventory's own ab12c) - this test's whole point is selling
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

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => twoLots,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '12', price: '12.50'); // more than the earlier lot's own 10

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

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String, email: 'picker@example.com'),
        saleSpec: Future.value(_realSaleSpec),
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
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

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
          store: OutboxStore(dataDir: () => _tempDir),
          send: (e) async => fail('nothing is sent while the server is offline'));
      addTearDown(() {
        outbox.dispose();
        health.dispose();
      });

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory, // stock from earlier: what matters here is the sale and its log
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
        postSaleLog: (stateId, {required workerEmail, required deviceId, required request, required response}) =>
            outbox.addSaleLog(stateId, workerEmail: workerEmail, deviceId: deviceId, request: request, response: response),
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

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

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
        // Deliberately always throws - this is the one thing _logSaleAttribution exists to swallow. If this
        // ever escapes, the test fails loudly on an unhandled exception rather than quietly passing.
        postSaleLog: (stateId, {required workerEmail, required deviceId, required request, required response}) async {
          throw SaleLogError('sale-log server unreachable');
        },
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

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

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

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

    testWidgets('an unconfirmed reply keeps the cart and refuses to call it safe to retry', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      // A 200 whose body decodes to JSON null - the generic branch returns exactly `data[path]` on a hit, and
      // this key exists (with a null value), so it's a 200, not the 404 the previous test relies on. sale.yaml's
      // own then_require then rejects `created` (null) as unconfirmed - the real "got a 200, still don't know
      // for sure" case classifySaleFailure treats as uncertain, the same as a 5xx.
      fake.data['CreateSalesRecords/false'] = null;

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(find.textContaining('NOT safe to just try again'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing); // the line is still there either way
    });

    // SM-12: the reported bug. The phone had sent the sale and the connection dropped before the answer came
    // back; the dialog said "not sent, safe to try again".
    Future<void> sellWith(WidgetTester tester, FakeState fake, Map<String, Object?> login) async {
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
    }

    testWidgets('a connection reset after the sale was sent is uncertain, never "safe to try again"', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.override['CreateSalesRecords/false'] =
          (req) async => throw const SocketException('Connection reset by peer', osError: OSError('Connection reset by peer', 104));

      await sellWith(tester, fake, login);
      await tester.pumpAndSettle();

      expect(fake.posted, hasLength(1)); // it really was sent
      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(find.textContaining('safe to try again'), findsNothing);
      expect(find.textContaining('NOT safe to just try again'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing);
    });

    testWidgets('a state system that never answers stops after 60 s as uncertain, not a spinner forever', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.override['CreateSalesRecords/false'] = (req) => Completer<http.Response>().future;

      String? queuedReason;
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          queuedReason = reason;
        },
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      // Not pumpAndSettle: the Sell button's spinner never settles while the request is outstanding. The test
      // clock is advanced by hand instead, so the real 60 s from sale.yaml is what is being tested.
      await tester.pump();
      await tester.pump(const Duration(seconds: 59));
      expect(fake.posted, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsWidgets); // still waiting just before the limit
      expect(find.text('The sale may or may not have been recorded'), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(find.textContaining('within 60 s'), findsOneWidget);
      expect(queuedReason, startsWith('[uncertain]'));
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing);
    });

    testWidgets('a failed host lookup (nothing left the phone) is still "not sent, safe to try again"', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.override['CreateSalesRecords/false'] =
          (req) async => throw const SocketException("Failed host lookup: 'psilocybin.oregon.gov'");

      await sellWith(tester, fake, login);
      await tester.pumpAndSettle();

      expect(find.text('The sale was not sent'), findsOneWidget);
      expect(find.textContaining('safe to try again'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    testWidgets('a 200 with two different sale numbers for one sale is uncertain (SM-D2)', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
        {'id': 9002, 'saleNumber': 'S-2'},
      ];
      final twoLots = [
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 1.0, quantity: 1),
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 105, weightPerUnit: 5.0, analyteWeight: 1.0, quantity: 10),
      ];
      String? queuedReason;
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => twoLots,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          queuedReason = reason;
        },
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '10.00'); // splits across both lots: two records
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect((fake.posted.single.$2 as List), hasLength(2));
      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(queuedReason, startsWith('[uncertain]'));
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing);
    });

    testWidgets('a 200 whose body does not look like confirmed sale records is treated as uncertain and queued', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      // A non-empty, JSON-decodable, status-200 body that still isn't what a confirmed sale looks like - not a
      // list of created records, each with its own saleNumber. A plain truthy check (flow_runner.dart's own
      // then_require) waves this through; selling.dart's looksLikeConfirmedSale is the second check that
      // catches it.
      fake.data['CreateSalesRecords/false'] = {'ok': true};

      String? queuedReason;
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          queuedReason = reason;
        },
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(queuedReason, contains('uncertain'));

      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing); // never cleared - this was never confirmed
    });

    testWidgets('the state system being unreachable while renewing mid-sale does not sign the worker out, and queues it',
        (tester) async {
      final loginFake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: loginFake.client());

      var fakeNow = DateTime.now();
      final session = Session(
        accessToken: login['access_token'] as String,
        refreshToken: login['refresh_token'] as String,
        email: 'worker@example.com',
        expiresAtMs: fakeNow.millisecondsSinceEpoch + 3600 * 1000,
      );

      // Answers the renewal's own token request with a 503 (the state system erroring, not refusing the
      // grant) and nothing else - this test never expects an actual sale attempt to be made at all, since
      // renewing the session is what fails, before the sale flow is ever reached.
      http.Client unreachableDuringRenewal() => http_testing.MockClient((req) async {
            if (req.url.path.endsWith('/oauth2/v2.0/token')) return http.Response('', 503);
            throw StateError('unexpected request in this test: ${req.url}');
          });

      String? queuedReason;
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: session,
        now: () => fakeNow,
        // The real sign-in spec, so the renewal really sends its token request and meets the 503. With the empty
        // _dummySpec there is no `renew` flow at all ("no such flow", a stage-null FlowError): once a spec mistake
        // rather than an outage (fix round 2), that signs the worker out, which is right for a spec that can't renew.
        spec: loginSpec,
        httpClientFactory: unreachableDuringRenewal,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          queuedReason = reason;
        },
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      fakeNow = fakeNow.add(const Duration(hours: 2)); // now within the refresh margin

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      // Never signed out - this was never a dead session, just an unreachable state system.
      expect(find.widgetWithText(AppBar, 'Mazama sign-in'), findsNothing);
      expect(find.text('The sale was not sent'), findsOneWidget);
      expect(queuedReason, contains('notSent'));

      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing); // the line is still there - nothing was sent
    });

    // Round 3 A: a renew spec fetched from Mazama's server could capture a token under another name and put it in its
    // error text; the failed-sale report carries a fixed text instead, and the worker still sees the message.
    for (final (status, expected) in [
      (400, "the state's sign-in session expired"),
      (503, "[notSent] the state's sign-in could not be renewed"),
    ]) {
      testWidgets('a renew error carrying a captured token (HTTP $status) never reaches the failed-sale report',
          (tester) async {
        const leaked = 'LEAKED-OTHER-TOKEN-1234';
        final leakySpec = FlowSpec.fromYaml('''
format: 1
vars:
  spec_version: "2026-10-24.3"
flows:
  login:
    - id: token
      type: request
      method: POST
      url: "https://oregonpsilocybinprodb2c.b2clogin.com/token"
      form: {email: "{{email}}", password: "{{password}}"}
      extract:
        - {var: access_token, source: body, json: access_token}
  renew:
    - id: token
      type: request
      method: POST
      url: "https://oregonpsilocybinprodb2c.b2clogin.com/token"
      form: {refresh_token: "{{refresh_token}}"}
      require:
        - check: status_in
          values: [200]
          error: "refused {{leak}} (HTTP {status})"
      capture_on_fail:
        - {var: leak, source: body, json: other_token}
      extract:
        - {var: access_token, source: body, json: access_token}
''');
        var fakeNow = DateTime.now();
        final session = Session(
          accessToken: 'TOKEN',
          refreshToken: 'REFRESH',
          email: 'worker@example.com',
          expiresAtMs: fakeNow.millisecondsSinceEpoch + 3600 * 1000,
        );
        http.Client leakyRenewal() => http_testing.MockClient((req) async {
              if (req.url.path == '/token') return http.Response(jsonEncode({'other_token': leaked}), status);
              throw StateError('unexpected request in this test: ${req.url}');
            });
        final reasons = <String>[];
        await tester.pumpWidget(_cartPage(
          fetchPackages: (id) async => _inventory,
          session: session,
          now: () => fakeNow,
          spec: leakySpec,
          httpClientFactory: leakyRenewal,
          postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
            reasons.add(reason);
          },
        ));
        await tester.pumpAndSettle();
        await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
        fakeNow = fakeNow.add(const Duration(hours: 2)); // now within the refresh margin

        await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
        await tester.pumpAndSettle();

        expect(reasons, [expected]);
        expect(reasons.single, isNot(contains(leaked)));
        if (status == 400) {
          // A refused renewal still sends the worker to sign-in with the message (on screen only).
          expect(find.widgetWithText(AppBar, 'Mazama sign-in'), findsOneWidget);
          expect(find.textContaining(leaked), findsOneWidget);
        } else {
          expect(find.text('The sale was not sent'), findsOneWidget);
          await tester.tap(find.widgetWithText(FilledButton, 'OK'));
          await tester.pumpAndSettle();
        }
      });
    }

    testWidgets('the Sell button is disabled while the cart is empty', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();

      final sellButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell'));
      expect(sellButton.onPressed, isNull);
    });

    testWidgets('a SessionExpired during the sale itself queues the failed sale and still goes to sign-in', (tester) async {
      // No refresh token at all, so ensureFreshSession throws SessionExpired the instant it decides renewal is
      // needed - no network call, no FakeState involved (this is deliberately the login/auth-shaped failure,
      // not an ordinary refused sale, so it never reaches the state system at all). Starts at a `now` the
      // session reads as fresh (so initState's own immediate _maybeRenewSession check, and the identical check
      // CartPage's constructor-default periodic timer would make, both see "not expired yet" and do nothing) -
      // moved to "expired" only after the page has loaded, right before Sell is tapped, so the one check inside
      // _sell itself is the only one that ever sees it as expired. This is exactly the gap CartPage.now exists
      // to let a test control, since nothing on this page can fast-forward the real wall clock.
      var fakeNow = DateTime.now();
      final session = Session(accessToken: 'TOKEN', refreshToken: null, email: 'worker@example.com', expiresAtMs: fakeNow.millisecondsSinceEpoch + 3600 * 1000);

      int calls = 0;
      int? queuedStateId;
      String? queuedEmail;
      String? queuedDeviceId;
      String? queuedReason;
      List<Map<String, Object?>>? queuedRequest;

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: session,
        now: () => fakeNow,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          calls++;
          queuedStateId = stateId;
          queuedEmail = workerEmail;
          queuedDeviceId = deviceId;
          queuedReason = reason;
          queuedRequest = request;
        },
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      // Now within REFRESH_MARGIN of (in fact, well past) expiry - only _sell's own renewal check has run since.
      fakeNow = fakeNow.add(const Duration(hours: 2));

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(queuedStateId, 231); // this cart's own center id
      expect(queuedEmail, 'worker@example.com');
      expect(queuedDeviceId, isNotEmpty); // this install's own id (device_id.dart), not a hardware identifier
      expect(queuedReason, contains('expired'));
      expect(queuedRequest, hasLength(1));
      expect(queuedRequest!.single['productGuid'], 'PKPR-ab12c');

      // The worker still ends up back at sign-in, exactly as if _queueFailedSale didn't exist at all.
      expect(find.widgetWithText(AppBar, 'Mazama sign-in'), findsOneWidget);
    });

    testWidgets('a postSaleFailure failure never blocks or changes the trip back to sign-in', (tester) async {
      var fakeNow = DateTime.now();
      final session = Session(accessToken: 'TOKEN', refreshToken: null, email: 'worker@example.com', expiresAtMs: fakeNow.millisecondsSinceEpoch + 3600 * 1000);

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: session,
        now: () => fakeNow,
        // Deliberately always throws - this is the one thing _queueFailedSale exists to swallow. If this ever
        // escapes, the test fails loudly on an unhandled exception rather than quietly passing.
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          throw SaleFailureError('sale-failure server unreachable');
        },
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      fakeNow = fakeNow.add(const Duration(hours: 2));

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Mazama sign-in'), findsOneWidget);
    });
  });

  group('view stock', () {
    testWidgets('opens StockPage on top of the cart, with the same fetchPackages fixture, and comes back on pop', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');     // something in the cart to prove it survives

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
  });

  group('switching centers and signing out', () {
    testWidgets('switching centers with an empty cart goes straight to the picker, no confirmation needed', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Switch center'));
      // pumpAndSettle, not a bare pump - fetchLicenses here is _cartPage()'s own fast, non-network stub (an
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
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => served,
        fetchRawPackagesFromState: (id, {required accessToken}) async => [
          {'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 1, 'analyteWeight': 25, 'quantity': 3},
        ],
        fetchLicenses: (token) async => [_center],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Switch center'));
      await tester.pumpAndSettle();

      // One center: the picker opens its Mazama | Stock | Cart home, on Stock (no title bar there: the tab is its
      // title).
      expect(find.text('Units in stock'), findsOneWidget);
      expect(find.text('3 units'), findsOneWidget); // the state's live quantity
      expect(find.text('75 mg TPE'), findsOneWidget); // the server's exact mg TPE per unit, not blanked by the merge
      expect(find.text("Partial: the Mazama server isn't reachable"), findsNothing);
    });

    testWidgets('switching centers with items in the cart asks for confirmation first', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

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
      final store = SessionStore(dataDir: () => _tempDir);
      await store.save(_freshSession().toJson());

      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, sessionStore: store));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('Mazama sign-in'), findsOneWidget);
      expect(await store.load(), isNull); // the whole point of signing out, not just leaving the screen
    });

    testWidgets('signing out with items in the cart asks for confirmation first', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

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
      final cartStore = CartStore(dataDir: () => _tempDir);

      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, cartStore: cartStore));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      expect(find.text('Extract'), findsOneWidget);

      // A fresh CartPage instance against the same store and the same center - standing in for the app process
      // being killed and relaunched, not just this widget rebuilding (which would keep the old State object
      // and its in-memory _lines regardless of persistence). Pumping the *same* widget type/position straight
      // to a second _cartPage() would NOT actually do that: with no Key to tell the two apart, Flutter's own
      // reconciliation treats it as an update to the existing element and calls didUpdateWidget on the same
      // _CartPageState - initState (and therefore _restoreCart) never runs again, and the cart line "surviving"
      // would just be the original State's never-disposed in-memory _lines, proving nothing about persistence.
      // Pumping a throwaway widget in between forces the old CartPage to actually be disposed first, so the
      // next pumpWidget below is a genuinely new State object reading cartStore from scratch.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, cartStore: cartStore));
      await tester.pumpAndSettle();

      expect(find.text('Extract'), findsOneWidget); // restored, not a fresh empty cart
      expect(find.textContaining('Restored an unsold cart'), findsOneWidget);
    });

    testWidgets('a cart saved for a different center never reappears at this one', (tester) async {
      final cartStore = CartStore(dataDir: () => _tempDir);
      await cartStore.save(999, [
        CartLine(group: PkprGroup([_inventory.first]), qty: 1, priceCentsEach: 1000),
      ]);

      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, cartStore: cartStore));
      await tester.pumpAndSettle();

      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      expect(find.textContaining('Restored an unsold cart'), findsNothing);
    });

    testWidgets("restoring a draft once the server's settings arrive keeps it, and keeps the time it was saved",
        (tester) async {
      final cartStore = CartStore(dataDir: () => _tempDir);
      final savedAt = DateTime.now().subtract(const Duration(hours: 2));
      await cartStore.save(_center.id, [
        CartLine(group: PkprGroup([_inventory.first]), qty: 1, priceCentsEach: 1000),
      ], now: () => savedAt);

      await tester.pumpWidget(_cartPage(
          fetchPackages: (id) async => _inventory, cartStore: cartStore, fetchCartSettings: (id) async => CartSettings.fallback));
      await tester.pumpAndSettle();

      expect(find.textContaining('Restored an unsold cart'), findsOneWidget);
      final stored = jsonDecode(File('${_tempDir.path}/cart.json').readAsStringSync()) as Map;
      expect(stored['savedAtMs'], savedAt.millisecondsSinceEpoch); // opening the page is not a change to the cart
      expect((stored['lines'] as List).length, 1);
    });

    testWidgets('onDraftCountChanged reports the number of lines as they change (SP-D8)', (tester) async {
      final counts = <int>[];
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, onDraftCountChanged: counts.add));
      await tester.pumpAndSettle();
      expect(counts, [0]);
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      expect(counts, [0, 1]);
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(counts, [0, 1, 0]);
    });

    testWidgets('removing the only line persists the now-empty cart, so it does not come back restored', (tester) async {
      final cartStore = CartStore(dataDir: () => _tempDir);

      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, cartStore: cartStore));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, cartStore: cartStore));
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
      final cartStore = CartStore(dataDir: () => _tempDir);

      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
        cartStore: cartStore,
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(await cartStore.load(231), isNull);
    });

    testWidgets('discarding the cart to switch centers clears the persisted draft too', (tester) async {
      final cartStore = CartStore(dataDir: () => _tempDir);

      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, cartStore: cartStore));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.byTooltip('Switch center'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard cart'));
      await tester.pump();

      expect(await cartStore.load(231), isNull);
    });
  });

  group('scanning', () {
    testWidgets('a single exact match goes straight to the same add dialog a typed PKPR would open', (tester) async {
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
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
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
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
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, scanLabelText: () async => throw ScanCancelled()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a camera/recognizer failure is shown as a readable snackbar', (tester) async {
      await tester.pumpWidget(
          _cartPage(fetchPackages: (id) async => _inventory, scanLabelText: () async => throw Exception('camera unavailable')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Scan'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not read the camera'), findsOneWidget);
    });

    testWidgets('a matching-server failure is shown as a readable snackbar when coa_core is not built in', (tester) async {
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
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
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
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
      expect(matchedAgainst?.map((p) => p.productGuid), _inventory.map((p) => p.productGuid));
      expect(find.textContaining('Could not match the scan'), findsNothing);
      expect(find.textContaining('PKPR-ab12c'), findsWidgets); // the same add dialog a server match opens
    });

    testWidgets('guesses matched on the phone are offered the same way as the server\'s', (tester) async {
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
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
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      expect(cartName(tester), 'Cart 1');
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await openCarts(tester);
      expect(find.text('Carts'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '1 line'), findsOneWidget);
      await tester.tap(find.text('New cart'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save')); // the suggested "Cart 2"
      await tester.pumpAndSettle();

      expect(cartName(tester), 'Cart 2');
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '9.00');
      expect(find.textContaining('1 x \$9.00'), findsOneWidget);
      expect(find.textContaining('2 x \$12.50'), findsNothing);

      await showCart(tester, 'Cart 1');
      expect(cartName(tester), 'Cart 1');
      expect(find.textContaining('2 x \$12.50'), findsOneWidget);
      expect(find.textContaining('1 x \$9.00'), findsNothing);

      final slots = (await CartSlotsStore(dataDir: () => _tempDir).load(231))!;
      expect(slots.carts.map((c) => c.name), ['Cart 1', 'Cart 2']);
      expect(slots.activeId, defaultCartId);
      final store = CartStore(dataDir: () => _tempDir);
      expect((await store.load(231))!.single.qty, 2);
      expect((await store.load(231, cartId: slots.carts[1].id))!.single.qty, 1);
    });

    testWidgets('a cart can be renamed (names unique), and the list and the showing cart survive a restart', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      expect(cartName(tester), 'Cart 2');
      await openCarts(tester);
      expect(find.widgetWithText(ListTile, 'Front desk'), findsOneWidget);
    });

    testWidgets('each cart has its own timer, which keeps running while another cart shows', (tester) async {
      var clock = DateTime.now();
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, now: () => clock));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      clock = clock.add(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 05:00'), findsOneWidget);

      await newCart(tester);
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
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
      final timers = SessionTimerStore(dataDir: () => _tempDir);
      final cart2 = (await CartSlotsStore(dataDir: () => _tempDir).load(231))!.carts[1].id;
      expect(await timers.load(231), isNull);
      expect(await timers.load(231, cartId: cart2), isNotNull);
    });

    testWidgets('the carts list counts the booster in the time left, and says when the time is up (MC-D14)',
        (tester) async {
      var clock = DateTime.now();
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory, now: () => clock));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00'); // 22.5 mg, initial dose
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
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
        now: () => clock,
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00'); // 22.5 mg: 4 hours
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
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
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
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await openCarts(tester);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.delete_outline)).onPressed, isNull);
      await tester.tap(find.text('New cart'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await openCarts(tester);
      await tester.tap(find.byTooltip('Delete Cart 2'));
      await tester.pumpAndSettle();
      expect(find.text('Delete "Cart 2"?'), findsOneWidget);
      expect(find.textContaining('has not been sold'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete cart'));
      await tester.pumpAndSettle();

      expect(cartName(tester), 'Cart 1');
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
      final slots = (await CartSlotsStore(dataDir: () => _tempDir).load(231))!;
      expect(slots.carts.map((c) => c.name), ['Cart 1']);
    });

    testWidgets('switching centers asks about unsold lines in any cart, and discarding clears them all', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await newCart(tester); // empty, showing

      await tester.tap(find.byTooltip('Switch center'));
      await tester.pumpAndSettle();
      expect(find.textContaining('"Cart 1" has not been sold yet'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Discard cart'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a service center'), findsOneWidget);
      expect(await CartStore(dataDir: () => _tempDir).load(231), isNull);
    });

    testWidgets('selling a cart clears that cart only (MC-D7)', (tester) async {
      final loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [{'id': 9001, 'saleNumber': 'S-1'}];
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await newCart(tester);
      await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '9.00');

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

  group('bulk sell (specs/multi-cart MC-D8 to MC-D13)', () {
    late final FlowSpec loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
    final ab12cRecord = <String, Object?>{
      'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
      'quantity': 10, 'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false, 'pendingTransfer': false,
    };

    /// Opens the cart (the state's stock readable only once the page has loaded, as [reread] answers), adds 2 x
    /// PKPR-ab12c at $12.50 and long-presses the cart button. -> the fake state system, every sale answered S-1.
    Future<FakeState> openBulk(WidgetTester tester,
        {Future<List<Object?>> Function()? reread,
        Future<void> Function(int, {required String workerEmail, required String deviceId, required String reason, required List<Map<String, Object?>> request})?
            postSaleFailure}) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [{'id': 9001, 'saleNumber': 'S-1'}];
      var loaded = false;
      await tester.pumpWidget(_cartPage(
        fetchPackages: (id) async => _inventory,
        fetchRawPackagesFromState: (id, {required accessToken}) async {
          if (!loaded) throw StatePackagesError('not read at load in this test');
          if (reread == null) return [ab12cRecord];
          return reread();
        },
        session: _freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(_realSaleSpec),
        httpClientFactory: fake.client,
        postSaleFailure: postSaleFailure,
      ));
      await tester.pumpAndSettle();
      loaded = true;
      await _addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await tester.longPress(find.byKey(const Key('cartsButton')));
      await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('long-pressing the cart button sells the cart N times, each its own sale, then clears it', (tester) async {
      final fake = await openBulk(tester);
      expect(find.text('Bulk sell Cart 1'), findsOneWidget);
      expect(find.text('Each sale: 1 line(s), 2 unit(s), \$25.00.'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, 'Number of sales'), '3');
      await tester.pumpAndSettle();
      expect(find.text('All 3 sales: 6 unit(s), \$75.00.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm 3 sales'));
      await tester.pumpAndSettle();

      expect(fake.posted, hasLength(3)); // three requests, so three sale numbers
      for (final (path, body) in fake.posted) {
        expect(path, 'CreateSalesRecords/false');
        expect(body, hasLength(1));
        expect(body.single['productGuid'], 'PKPR-ab12c');
        expect(body.single['numberSold'], 2);
        expect(body.single['productCost'], 25.0);
        expect(body.single['serviceCenterId'], 231);
      }
      expect(find.text('3 sales recorded with the state system.'), findsOneWidget);
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
    });

    testWidgets('too little stock for N sales, or too many sales, is refused in the dialog', (tester) async {
      final fake = await openBulk(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Number of sales'), '6');
      await tester.pumpAndSettle();
      expect(find.text('Only 10 of PKPR-ab12c in stock: 6 sales need 12.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);

      await tester.enterText(find.widgetWithText(TextFormField, 'Number of sales'), '51');
      await tester.pumpAndSettle();
      expect(find.text('At most $maxBulkSales sales at once.'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(fake.posted, isEmpty);
    });

    testWidgets('a sale refused part way stops the run, says how many were recorded, and keeps the cart', (tester) async {
      final reasons = <String>[];
      final fake = await openBulk(tester,
          postSaleFailure: (id, {required workerEmail, required deviceId, required reason, required request}) async =>
              reasons.add(reason));
      var calls = 0;
      fake.override['CreateSalesRecords/false'] = (req) async {
        calls++;
        return calls < 3
            ? http.Response(jsonEncode([{'id': 9000 + calls, 'saleNumber': 'S-$calls'}]), 200)
            : http.Response('', 400);
      };
      await tester.enterText(find.widgetWithText(TextFormField, 'Number of sales'), '4');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm 4 sales'));
      await tester.pumpAndSettle();

      expect(fake.posted, hasLength(3)); // the fourth was never attempted
      expect(find.text('2 of 4 sales recorded'), findsOneWidget);
      expect(find.textContaining('Sale 3 was not sent'), findsOneWidget);
      expect(find.textContaining('The other 1 sale was never attempted.'), findsOneWidget);
      expect(reasons, hasLength(1));
      expect(reasons.single, startsWith('[bulk 3 of 4] [notSent]'));

      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing); // the cart is kept
    });

    testWidgets('the stock is always read again first: a lot locked since refuses them all, nothing sent', (tester) async {
      final locked = {...ab12cRecord, 'locked': true, 'reasonLocked': 'Recall 2026-10'};
      final fake = await openBulk(tester, reread: () async => [locked]);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm 2 sales'));
      await tester.pumpAndSettle();

      expect(fake.posted, isEmpty);
      expect(find.text('The sales were not sent'), findsOneWidget);
      expect(find.textContaining(saleLineRefusal(locked, 'PKPR-ab12c', 4)!), findsOneWidget);
    });

    testWidgets('long-pressing with an empty cart says so and opens nothing', (tester) async {
      await tester.pumpWidget(_cartPage(fetchPackages: (id) async => _inventory));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const Key('cartsButton')));
      await tester.pumpAndSettle();
      expect(find.text('Bulk sell: add items to the cart first.'), findsOneWidget);
      expect(find.text('Number of sales'), findsNothing);
    });
  });

  group('sessionTimeLeftText (MC-D14)', () {
    test('the session table length less the time elapsed, the booster named only when there is one', () {
      expect(sessionTimeLeftText(22.5, const Duration(minutes: 7), booster: false), '3:53:00 left');
      expect(sessionTimeLeftText(45, const Duration(minutes: 30), booster: true), '5:30:00 left w/ booster');
      expect(sessionTimeLeftText(2, const Duration(minutes: 29, seconds: 30), booster: false), '00:30 left');
      // part of a second left counts as a whole one
      expect(sessionTimeLeftText(22.5, const Duration(minutes: 7, microseconds: 1), booster: false), '3:53:00 left');
      expect(sessionTimeLeftText(22.5, const Duration(hours: 3, minutes: 59, seconds: 59, milliseconds: 500), booster: false),
          '00:01 left');
    });

    test('says how far over once the time is up, and nothing over the limit per sale', () {
      expect(sessionTimeLeftText(22.5, const Duration(hours: 4), booster: false), 'Time up · 00:00 over');
      expect(sessionTimeLeftText(22.5, const Duration(hours: 4, minutes: 12), booster: false), 'Time up · 12:00 over');
      expect(sessionTimeLeftText(60, Duration.zero, booster: false), isNull);
    });
  });

  // README R56: a lab report that couldn't reach Mazama's server is kept for a submission once it answers.
  testWidgets("a cart add whose lab report can't reach the server keeps the lot for later; another failure doesn't",
      (tester) async {
    final kept = <(int, String, int, double?)>[];
    final pkgs = [
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5,
          strain: 'Golden Teacher', tpeMg: 5, quantity: 10, lotGuid: 'HB-aaaa0001', coaAvailable: false),
      Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0,
          strain: 'Enigma', tpeMg: 90, quantity: 3, lotGuid: 'HB-bbbb0002', labelAvailable: false),
    ];
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => pkgs,
      submitCoaForLot: ({required lotGuid, required representativePackageId, required accessToken, required workerEmail,
          required deviceId, statePsilocybin}) async {
        if (lotGuid == 'HB-aaaa0001') throw CoaDataError('cannot reach sales.mazamamushrooms.com', unreachable: true);
        throw CoaDataError('Not a PDF.'); // the server's own refusal: not kept
      },
      keepCoaLotForLater: (stateId, {required lotGuid, required packageId, statePsilocybin}) =>
          kept.add((stateId, lotGuid, packageId, statePsilocybin)),
    ));
    await tester.pumpAndSettle();
    await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10');
    await _addLine(tester, pkpr: 'ff99aa', qty: '1', price: '10');
    expect(kept, [(231, 'HB-aaaa0001', 101, 4.5)]);
  });

  // README R64: the phone fetches a lab report from the state system only when the server has no COA for the lot. A lot
  // whose COA the server has but whose label it hasn't drawn yet costs no state calls: the server draws the label itself.
  testWidgets('a cart add submits a lab report only for a lot the server has no COA for', (tester) async {
    final submitted = <String>[];
    final pkgs = [
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5,
          strain: 'Golden Teacher', tpeMg: 5, quantity: 10, lotGuid: 'HB-aaaa0001', coaAvailable: false, labelAvailable: false),
      Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0,
          strain: 'Enigma', tpeMg: 90, quantity: 3, lotGuid: 'HB-bbbb0002', labelAvailable: false),
    ];
    await tester.pumpWidget(_cartPage(
      fetchPackages: (id) async => pkgs,
      submitCoaForLot: ({required lotGuid, required representativePackageId, required accessToken, required workerEmail,
          required deviceId, statePsilocybin}) async {
        submitted.add(lotGuid);
        return null;
      },
    ));
    await tester.pumpAndSettle();
    await _addLine(tester, pkpr: 'ab12c', qty: '1', price: '10');
    await _addLine(tester, pkpr: 'ff99aa', qty: '1', price: '10');
    expect(submitted, ['HB-aaaa0001']);
  });
}
