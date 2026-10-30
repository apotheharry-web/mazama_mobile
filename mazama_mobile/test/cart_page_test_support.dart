import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/cart_pricing.dart';
import 'package:mazama_mobile/cart_slots.dart';
import 'package:mazama_mobile/cart_store.dart';
import 'package:mazama_mobile/cart_timer_widget.dart';
import 'package:mazama_mobile/center_status_client.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/coa_data_resolver.dart';
import 'package:mazama_mobile/coa_uploader.dart';
import 'package:mazama_mobile/device_id.dart';
import 'package:mazama_mobile/enrichment_store.dart';
import 'package:mazama_mobile/features.g.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/inventory_cache_store.dart';
import 'package:mazama_mobile/label_client.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/phone_label.dart';
import 'package:mazama_mobile/resilience_options.dart';
import 'package:mazama_mobile/state_packages_client.dart';
import 'package:mazama_mobile/scan_match_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/session_timer_store.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';
import 'package:mazama_mobile/text_scanner.dart';


final center = License(id: 231, licenseId: 'SC-b1c7379a', licenseName: 'Bendable Service Center', licenseType: 'ServiceCenter');

// Real-shaped PKPRs (see mazama_sales/src/mazama_sales/labels.py's PKPR_RE: "PKPR-" + 5-8 hex digits) -
// deliberately sharing no common hex prefix with each other so a two-character search can distinguish them.
final inventory = [
  Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5, strain: 'Golden Teacher', tpeMg: 5, quantity: 10),
  Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0, strain: 'Enigma', tpeMg: 90, quantity: 3),
];

// Far from expiry - none of these tests exercise the renewal path (see session_test.dart for that), so every
// session here is fresh enough that CartPage's own startup renewal check and its periodic timer both return
// immediately with no network call, the same way a widget test for any other page doesn't want to accidentally
// depend on flow_runner.dart/fake_state.dart machinery it isn't testing.
Session freshSession({String accessToken = 'TOKEN', String email = 'worker@example.com'}) => Session(
    accessToken: accessToken, refreshToken: 'REFRESH', email: email, expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

final dummySpec = FlowSpec(const {}, const {});

/// A label spec as mazama_core gives it (its LabelSpec), for the phone-drawn label.
const Map<String, Object?> drawnSpec = {
  'pkpr': 'PKPR-ab12c', 'strain': 'Golden Teacher', 'dose_mg_tpe': 25, 'net_wt_g': 2.89, 'best_by': '2027-08-31',
  'per_unit_mg': {'psilocybin': 22.98, 'psilocin': 1.43},
};

/// A real, decodable 1x1 transparent PNG - fetchLabel fixtures need actual image bytes, not just any
/// Uint8List: Image.memory tries to decode whatever it's given, and a placeholder like [1] or [1,2,3,4]
/// throws "Invalid image data" from the image resource service. That exception is asynchronous (it surfaces
/// well after the widget itself is built) and flutter_test still fails the test over it even when every
/// explicit expect() already passed, so a fixture that doesn't actually decode is never actually a no-op.
final fakeLabelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');

// The real spec, read straight off disk the same way flow_runner_test.dart does - only the Sell tests below
// actually exercise it (against fake_state.dart, never the real state system).
late final FlowSpec realSaleSpec = FlowSpec.fromYaml(File('assets/flows/sale.yaml').readAsStringSync());

late Directory tempDir;

/// Keeps what CartPage sends the home-screen widget (MC-D15), instead of sending it.
class RecordingTimerWidget extends CartTimerWidget {
  final snapshots = <Map<String, Object?>>[];
  var clears = 0;

  @override
  Future<void> publish(Map<String, Object?> snapshot) async => snapshots.add(snapshot);

  @override
  Future<void> clear() async => clears++;

  List<Map<String, Object?>> get lastCarts => [for (final c in snapshots.last['carts'] as List) Map<String, Object?>.from(c as Map)];
}

Widget cartPage({
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
  QueueCoaUploads? queueCoaUploads,
  bool Function(String lotGuid)? coaUploadPending,
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
  ServerHealth? health,
  Map<String, Feature>? featureTable,
  void Function(int stateId)? requestStockRefresh,
  Stream<DatasetRow?>? Function(int stateId)? watchStock,
}) {
  // The default state read (specs/phone-sync phase 3): it fails at the page's load, as it always did here (so a load
  // is Mazama's server's rows alone, or the tier-2 fixture's), and afterwards answers with the packages the test's own
  // fetchPackages last gave, as sellable state records: the read a sale makes first (SM-25) now that a load the state
  // didn't answer, and every confirmed sale, leave the stock unconfirmed.
  List<Package>? served;
  var stateReads = 0;
  Future<List<Package>> fetchServed(int id) async => served = await fetchPackages(id);
  Future<List<Object?>> defaultStateRead(int id, {required String accessToken}) async {
    final known = served;
    if (stateReads++ == 0 || known == null) throw StatePackagesError('no raw-state fixture wired for this test');
    return [
      for (final p in known)
        {
          ...p.toSaleItem(),
          'quantity': p.exactQuantity,
          'serviceCenterId': id,
          'zeroOut': false,
          'locked': false,
          'flagged': false,
          'pendingTransfer': false,
        },
    ];
  }

  return MaterialApp(
      home: CartPage(
        featureTable: featureTable ?? features,
        // PS-R6: the refresh a confirmed sale asks for; never the app's own engine in a test.
        requestStockRefresh: requestStockRefresh ?? (stateId) {},
        // Task 8b: the engine's copy of the stock; none unless a test gives one (never the app's link)
        watchStock: watchStock ?? (stateId) => null,
        session: session ?? freshSession(),
        now: now ?? DateTime.now,
        center: center,
        spec: spec ?? dummySpec,
        sessionStore: sessionStore ?? SessionStore(dataDir: () => tempDir),
        // Same tempDir as sessionStore's own default above - a distinct file name (cart.json vs session.json)
        // means the two never collide, and most tests here don't care about cart persistence at all, so a real
        // (if temporary) store that happens to find nothing to restore is a safer default than a fake that
        // silently swallows calls a test might actually want to assert on.
        cartStore: cartStore ?? CartStore(dataDir: () => tempDir),
        // Same reasoning again - a real (temporary) store, so a test that cares whether the session timer's
        // start time survived a simulated app restart (a fresh pumpWidget reusing the same store) can assert
        // on it directly, same as cartStore's own restore tests do.
        sessionTimerStore: sessionTimerStore ?? SessionTimerStore(dataDir: () => tempDir),
        // The list of carts (specs/multi-cart): a real (temporary) store, as cartStore.
        cartSlotsStore: cartSlotsStore ?? CartSlotsStore(dataDir: () => tempDir),
        // The home-screen widget (MC-D15): recorded, never sent over a real platform channel.
        cartTimerWidget: cartTimerWidget ?? RecordingTimerWidget(),
        // Same reasoning again - a real (temporary) store rather than a fixed fake string, so a test that
        // cares what deviceId was sent can read it back the same way the real app would generate it.
        deviceIdStore: deviceIdStore ?? DeviceIdStore(dataDir: () => tempDir),
        // Same reasoning again - a real (temporary) store, so a test exercising the 3-day cache fallback can
        // seed or inspect it directly, same as cartStore's own restore tests do.
        inventoryCacheStore: inventoryCacheStore ?? InventoryCacheStore(dataDir: () => tempDir),
        // Same reasoning: what Mazama's server last sent per package, in the test's own folder.
        enrichmentStore: enrichmentStore ?? EnrichmentStore(dataDir: () => tempDir),
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
        fetchRawPackagesFromState: fetchRawPackagesFromState ?? defaultStateRead,
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
        // never the app's own background uploader (server_link.dart) in a test
        queueCoaUploads: queueCoaUploads ?? (lots, {onResolved}) {},
        coaUploadPending: coaUploadPending ?? (lotGuid) => false,
        fetchPackages: fetchServed,
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
        // and exercises the exact same "no label available" branch addLine below has to get past either way.
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
        // never the real one (the core's matcher over the test's stock): no local match unless a test gives one
        localScanMatch: localScanMatch ?? (inventory, lines, {typed = false}) => null,
        // The real app now defaults to CartPricingMode.total (most sales are priced as a whole-cart total),
        // but almost every test in this file is specifically exercising "each" mode's own per-line price entry
        // (typing a Quantity/Price each into the add dialog) - defaulting tests to "each" here keeps every one
        // of those tests decoupled from whatever the real app's own default happens to be, the same reasoning
        // fetchLabel/postSaleLog/scanLabelText above already use for their own test-friendly defaults.
        initialPricingMode: pricingMode ?? CartPricingMode.each,
        onDraftCountChanged: onDraftCountChanged,
        health: health,
      ),
    );
}

/// Drives the same UI path a worker uses to add a line - enter the PKPR, tap Add, fill in the dialog, confirm
/// it - stopping right as the label-compare dialog (cart_page.dart's _showLabelDialog) pops up, so a caller
/// that wants to inspect that dialog can do so before anything dismisses it.
Future<void> addLineLeavingLabelDialogOpen(WidgetTester tester,
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
Future<void> addLine(WidgetTester tester, {required String pkpr, required String qty, required String price}) async {
  await addLineLeavingLabelDialogOpen(tester, pkpr: pkpr, qty: qty, price: price);
  await tester.tap(find.widgetWithText(TextButton, 'Close'));
  await tester.pumpAndSettle();
}
