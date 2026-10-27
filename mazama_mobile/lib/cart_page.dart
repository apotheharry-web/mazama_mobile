// The working screen: inventory for the chosen center downloads in the background as soon as this page opens
// (fetchPackages, against Mazama's own public /p/packages/{state_id} - no login to that server at all), while
// the worker can already type a PKPR (a packaged product's own state-system id, the number on its label) to
// add it to the cart. Scanning a label is meant to land on the exact same path as typing its PKPR by hand -
// see _onScanPressed for why that button doesn't do anything real yet.
//
// A worker can sit in this screen a long time building up a cart before whatever eventually sells it runs -
// long enough for the state-system access token to expire. _renewTimer checks every 30s and silently renews
// via ensureFreshSession well before that happens (same REFRESH_MARGIN the real server itself uses), so a
// token that's been fine the whole time the worker was shopping doesn't suddenly fail right when they need it.
// If it genuinely can't be renewed (no refresh token, or the state system explicitly refuses the one there is
// with a 4xx - see session.dart's SessionExpired), this sends the worker back to sign-in rather than leaving
// them on a screen that will fail whenever they next try to use it. If the state system is merely unreachable
// or erroring right now (session.dart's SessionRenewalUnavailable) this deliberately does NOT sign the worker
// out or touch anything on disk - that's not a dead session, just a bad moment to ask, and the next 30s tick
// (or the explicit check _sell makes right before a sale) simply tries again.
//
// The "Sell" button (_onSellPressed/_sell) is what actually records the cart with the state system: it builds
// one sale record per line (selling.dart's buildSale - the same field-for-field shape the real web app sends)
// and submits them all in one request via shared/flows/sale.yaml's `sale` flow, so the state system gives every
// line in this cart the same sale number. A failure there is treated with real care, not a generic error
// banner - see sale_outcome.dart and _showSaleFailureDialog for why a failed sale can't just be silently
// retried the way a failed inventory fetch can.
//
// A center can keep several carts at once (specs/multi-cart): the cart button at the top right opens the list of
// them (switch, new, rename, delete), and each has its own lines, timer and pricing controls. Long-pressing that
// button sells the showing cart as the same sale several times over (bulk sell, _onBulkSellPressed/_bulkSell).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'bulk_sale.dart';
import 'cart_pricing.dart';
import 'cart_slots.dart';
import 'cart_store.dart';
import 'cart_timer_widget.dart';
import 'coa_data_client.dart' as coa_data_client; // see CartPage.centerIsConfigured: avoids a same-name default-value ambiguity
import 'coa_data_resolver.dart' as coa_data_resolver; // see CartPage.resolveAdhocInventory: avoids a same-name default-value ambiguity
import 'center_status_client.dart' show CartSettings;
import 'center_status_client.dart' as center_status_client; // see CartPage.fetchCartSettings: same reason as below
import 'demo/demo_backend.dart'; // see CartPage.submitCoaForLot: avoids a same-name default-value ambiguity
import 'device_id.dart';
import 'enrichment_store.dart';
import 'flow/flow_runner.dart';
import 'flow/flow_spec.dart';
import 'inventory_cache_store.dart';
import 'label_client.dart' as label_client; // see CartPage.fetchLabel: avoids a same-name default-value ambiguity
import 'label_preview.dart';
import 'licenses_client.dart';
import 'login_hosts_store.dart' show currentAllowedHosts;
import 'main.dart' show goToSignIn;
import 'merged_inventory.dart' as merged_inventory;
import 'package_ids.dart';
import 'packages_client.dart';
import 'packages_client.dart' as packages_client; // see CartPage.fetchPackages: avoids a same-name default-value ambiguity
import 'phone_label.dart' as phone_label; // see CartPage.drawLabel: avoids a same-name default-value ambiguity
import 'stock_page.dart';
import 'pricing.dart';
import 'responsive.dart';
import 'sale_outcome.dart';
import 'scan_match_client.dart';
import 'scan_match_client.dart' as scan_match_client; // see CartPage.scanMatch: avoids a same-name default-value ambiguity
import 'local_scan_match.dart' as local_scan_match; // see CartPage.localScanMatch, the same reason
import 'select_center_page.dart';
import 'server_error.dart' show isServerUnreachable;
import 'server_link.dart' as server_link; // the defaults for the writes to Mazama's server (README R56)
import 'sellability.dart';
import 'selling.dart';
import 'session.dart';
import 'session_store.dart';
import 'session_timer_store.dart';
import 'resilience_options.dart';
import 'resilient_inventory.dart';
import 'state_packages_client.dart' as state_packages_client; // see CartPage.fetchPackagesFromState: avoids a same-name default-value ambiguity
import 'text_scanner.dart';
import 'text_scanner.dart' as text_scanner; // see CartPage.scanLabelText: avoids a same-name default-value ambiguity

/// Strips an optional, case-insensitive "pkpr-" prefix and surrounding whitespace, so a worker can type either
/// the bare hex part of a PKPR or the whole thing (as the label itself prints it) and land on the same value.
/// Used both for matching a typed/selected PKPR against inventory and for deciding when a search has enough
/// characters to suggest anything.
String stripPkprPrefix(String text) {
  final trimmed = text.trim();
  return trimmed.toLowerCase().startsWith('pkpr-') ? trimmed.substring(5) : trimmed;
}

/// How often CartPage checks whether its session needs renewing. Deliberately much shorter than the refresh
/// margin itself (login.yaml's refresh_margin_seconds, 120 s), so the check has several chances to catch the
/// window rather than relying on a single timer tick lining up with it exactly.
const sessionCheckInterval = Duration(seconds: 30);

/// How long the cart's own session stopwatch (_sessionTimerRow) is allowed to keep running - counted from
/// widget.now() at the moment "Start Timer" was tapped, not real wall-clock time elapsed while the app
/// happened to be open. Once this much time has passed, the timer resets itself back to the "Start Timer"
/// button on its own, the same as if the worker had tapped "Reset" by hand - chosen so a timer left running
/// (forgotten about, or resumed from a persisted start time days later - see SessionTimerStore) never keeps
/// counting indefinitely. Comfortably above the longest administration session the duration table above would
/// ever call for (6 hrs).
const sessionTimerMaxAge = Duration(hours: 8);

/// Raw mg psilocybin in [lines], every dose counted - the figure the session table reads (minSessionDuration).
double cartPsilocybinMg(List<CartLine> lines) =>
    lines.fold<double>(0, (sum, l) => sum + l.group.weightPerUnit * l.group.analyteWeight * l.qty);

/// How long a client's session lasts (the session table's length for [psilocybinMg], the booster included, the same
/// "w/ booster" figure the cart's dose summary shows) and how much of it is left [elapsed] in, as the carts list shows
/// a running timer (specs/multi-cart MC-D14): "1:52:10 left w/ booster" ("w/ booster" only when [booster]), then
/// "Time up · 04:12 over" once it has run out. Null when the table gives no length (over the limit per sale).
String? sessionTimeLeftText(double psilocybinMg, Duration elapsed, {required bool booster}) {
  final length = minSessionDuration(psilocybinMg);
  if (length == null) return null;
  final left = length - elapsed;
  // A countdown never shows less time than is left: part of a second left counts as a whole one (a start time read
  // back from disk keeps only milliseconds, so this is the usual case, not an edge one).
  if (left > Duration.zero) {
    final shown = Duration(seconds: (left.inMicroseconds + Duration.microsecondsPerSecond - 1) ~/ Duration.microsecondsPerSecond);
    return '${formatElapsed(shown)} left${booster ? ' w/ booster' : ''}';
  }
  return 'Time up · ${formatElapsed(-left)} over';
}

/// A plain top-level function (not a constructor tear-off) specifically so it's an unambiguous constant default
/// value for CartPage.httpClientFactory, needing no assumption about how package:http's own Client() factory
/// constructor behaves when torn off.
http.Client _newHttpClient() => http.Client();

class CartLine {
  /// The PKPR this line is selling, and the underlying lots/transfers its quantity will be split across at
  /// sale time (see buildSaleRecords below) - a snapshot taken when this line was added or last edited, same
  /// "as of last sync" staleness every other number on this page already tolerates. A worker never sees a
  /// lot's own id or quantity - only group.productGuid/productType and this line's own qty/price.
  final PkprGroup group;
  final int qty;
  final int priceCentsEach;

  /// doseInitial or doseSecondary (selling.dart) - which of a sale record's initialDose/secondaryDose fields
  /// this line's units count toward. Defaults to doseInitial, the same default the real cart_line table uses
  /// for a line the moment it's added (see mazama_sales/src/mazama_sales/carts.py's own `add`).
  final String dose;

  CartLine({required this.group, required this.qty, required this.priceCentsEach, this.dose = doseInitial});

  String get productGuid => group.productGuid;
  String get productType => group.productType;

  int get totalCents => qty * priceCentsEach;

  CartLine withQty(int newQty) => CartLine(group: group, qty: newQty, priceCentsEach: priceCentsEach, dose: dose);

  /// Used only by _recomputeCartPricing, when the cart-wide "total"/"perMg" modes (cart_pricing.dart) work out
  /// what this line's own price should be - never by the per-line dialog itself, which builds a whole new
  /// CartLine directly since it already has every other field in hand too.
  CartLine withPrice(int newPriceCentsEach) => CartLine(group: group, qty: qty, priceCentsEach: newPriceCentsEach, dose: dose);

  /// Round-trips this line through CartStore (cart_store.dart) - see that file's own comment for why a line
  /// that hasn't been sold yet is worth persisting at all, unlike a sale that's already in flight. Persists
  /// every underlying lot, not just a merged total, so a restored draft still has what buildSaleRecords needs
  /// to split a sale the same way it would have right after the line was first added.
  Map<String, Object?> toJson() =>
      {'lots': [for (final l in group.lots) l.toJson()], 'qty': qty, 'priceCentsEach': priceCentsEach, 'dose': dose};

  /// Null (not a thrown error) for anything that isn't a line this class itself wrote - a missing/wrong-typed
  /// field, no lots at all, or some future/older format - so CartStore.load can treat one bad line as "nothing
  /// readable" the same way SessionStore.load treats a corrupt file, rather than letting one bad line crash the
  /// whole restore.
  static CartLine? fromJson(Map<String, Object?> j) {
    final lotsJson = j['lots'];
    final qty = j['qty'];
    final priceCentsEach = j['priceCentsEach'];
    final dose = j['dose'];
    if (lotsJson is! List || lotsJson.isEmpty || qty is! num || priceCentsEach is! num || dose is! String) return null;
    final lots = <Package>[];
    for (final lj in lotsJson) {
      if (lj is! Map) return null;
      lots.add(Package.fromJson(Map<String, Object?>.from(lj)));
    }
    return CartLine(group: PkprGroup(lots), qty: qty.toInt(), priceCentsEach: priceCentsEach.toInt(), dose: dose);
  }
}

class CartPage extends StatefulWidget {
  final Session session;
  final License center;
  final FlowSpec spec;
  final SessionStore sessionStore;

  /// Overridable for tests, so a widget test never makes a real network call. Defaults to the real
  /// fetchPackages (against Mazama's own public /p/packages/{state_id}), referenced through the aliased
  /// import above purely to avoid any ambiguity with this field's own same name.
  final Future<List<Package>> Function(int stateId) fetchPackages;

  /// The second of the three resilience tiers around [fetchPackages] (see resilient_inventory.dart's own file
  /// comment for all three): a direct call to the real state system's own GetPackagedProducts, tried only when
  /// [fetchPackages] itself fails. Overridable for tests, so a widget test exercising a failed inventory load
  /// never makes a real network call for this fallback either - defaults to the real fetchPackagesFromState
  /// (state_packages_client.dart), referenced through the aliased import above for the same reason as
  /// fetchLabel.
  final Future<List<Package>> Function(int stateId, {required String accessToken}) fetchPackagesFromState;

  /// The RAW half of [fetchPackagesFromState] (state_packages_client.dart's fetchRawPackagesFromState) - used
  /// only for a CONFIGURED center's merged inventory load (merged_inventory.dart's fetchMergedInventory,
  /// item 2), since that merge needs mazama_sales' own enrichment (strain/tpeMg/coaAvailable/labelAvailable)
  /// layered onto the state's own fresher quantity, AND the unmapped records themselves to hand to
  /// [uploadInventorySnapshot] (item 3a) - [fetchPackagesFromState] above alone can't supply the second half.
  /// Overridable for tests for the same reason as fetchPackagesFromState. Defaults to the real
  /// fetchRawPackagesFromState, referenced through the aliased import above.
  final Future<List<Object?>> Function(int stateId, {required String accessToken}) fetchRawPackagesFromState;

  /// Item 3a: posts a configured center's own fresh state read (merged_inventory.dart's own
  /// MergedInventoryResult.rawStateRecords) back to mazama_sales' POST /p/inventory/{stateId}, so its mirror
  /// stays current from this device instead of waiting on the server's own (now possibly manual-only) sync.
  /// Called fire-and-forget after every successful merged load for a configured center - see
  /// _fetchMergedForCart. Overridable for tests for the same reason as fetchPackagesFromState. Defaults to the
  /// real upload through the app's server link (server_link.dart): while Mazama's server can't be reached the newest
  /// snapshot per center is kept and sent once it answers (catch_up_store.dart).
  final Future<Map<String, Object?>> Function(int stateId, List<Object?> records, {required String workerEmail, required String deviceId}) uploadInventorySnapshot;

  /// Checked once, right at the start of every _loadInventory, before [fetchPackages]/[fetchPackagesFromState]
  /// are ever tried - see coa_data_client.dart's own file comment. True (or this check itself failing, treated
  /// the same as true: see _loadInventoryAsync) runs the ordinary [_resilient] tiers exactly as before this
  /// field existed. False switches this load entirely onto [resolveAdhocInventory] instead - a center Mazama's
  /// own server has never been configured for has nothing for [fetchPackages] (tier 1) to ever return anyway.
  /// Overridable for tests, so a widget test never makes a real network call for this either. Defaults to the
  /// real centerIsConfigured, referenced through the aliased import above for the same reason as fetchLabel.
  final Future<bool> Function(int stateId) centerIsConfigured;

  /// The cart's live settings from this center's server (SM-16: tax percent, agreement split, units per line, cart
  /// life), or [CartSettings.fallback] when it can't say. Overridable for tests, so a widget test never makes a
  /// real network call for this either.
  final Future<CartSettings> Function(int stateId) fetchCartSettings;

  /// Runs the whole adhoc-COA flow (coa_data_resolver.dart's own file comment has the full shape) for a center
  /// [centerIsConfigured] said no for. Overridable for tests, so a widget test exercising that path never makes
  /// a real network call either. Defaults to the real resolveAdhocInventory, referenced through the aliased
  /// import above for the same reason as fetchLabel.
  final Future<coa_data_resolver.AdhocInventoryResult> Function({
    required int stateId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    void Function(List<Package> packages)? onInventoryLoaded,
    void Function(String guid, Package updated)? onResolved,
  }) resolveAdhocInventory;

  /// Item 3b: run (fire-and-forget, from _ensureCoaForCartLine) right after a product is added to the cart at a
  /// CONFIGURED center, for each lot backing that PKPR that still has coaAvailable false (README R64) - the
  /// "already built function" (configured_coa_submit.dart's submitCoaForLot, reusing coa_data_resolver.dart's
  /// own GetPackagedProductInfo -> newest-PDF -> downloadStateDocument -> uploadCoaParse chain) submitting that
  /// lot's lab report so mazama_sales can join it into the shared COA pipeline and, per item 4, auto-queue a
  /// label. Never awaited by the add itself - see this field's own call site. Overridable for tests, so a
  /// widget test exercising a configured center's cart-add never makes a real network call for this either.
  /// Defaults to the real submitCoaForLot, referenced through an aliased import for the same reason as
  /// fetchLabel.
  final Future<coa_data_client.CoaData?> Function({
    required String lotGuid,
    required int representativePackageId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    double? statePsilocybin,
  }) submitCoaForLot;

  /// Called when [submitCoaForLot] failed because Mazama's server couldn't be reached (README R56): the lot is kept and
  /// submitted again once the server answers, with the session current then (server_link.dart's catch-up work).
  /// Overridable for tests; the real one keeps it in the app's catch-up file.
  final void Function(int stateId, {required String lotGuid, required int packageId, double? statePsilocybin}) keepCoaLotForLater;

  /// The third resilience tier: the last inventory this center successfully loaded (by either of the tiers
  /// above), good for up to 3 days (see resilient_inventory.dart's own maxAge). Overridable for tests, so a
  /// widget test never reads or writes the real app-data directory for this either - same real-by-default,
  /// redirected-in-tests pattern as cartStore/sessionTimerStore/deviceIdStore.
  final InventoryCacheStore inventoryCacheStore;

  /// What Mazama's server last sent per package (strain, TPE, expiry), filled back in when stock has to come from the
  /// state system alone (enrichment_store.dart, resilient_inventory.dart). Overridable for tests, as
  /// [inventoryCacheStore].
  final EnrichmentStore enrichmentStore;

  /// The build-time knobs behind both fallback tiers above (resilience_options.dart's own file comment) -
  /// constructed once in main.dart, before MazamaApp exists, and threaded down through every SelectCenterPage
  /// and CartPage from there (including the SelectCenterPage _onSwitchCenterPressed re-opens). Defaults to
  /// `const ResilienceOptions()` - today's behavior (state fallback on, 3-day cache) - for every call site,
  /// including every existing test, that doesn't pass one explicitly.
  final ResilienceOptions resilienceOptions;

  /// Overridable for tests, so a widget test never makes a real network call for the post-add label-compare
  /// picture either. Defaults to the real fetchLabel (against Mazama's own public /p/label/{state_id}/{guid}),
  /// referenced through the aliased import above for the same reason as fetchPackages above.
  final Future<Uint8List> Function(int stateId, String guid) fetchLabel;

  /// When [fetchLabel] has no label (or can't be reached): the package's label drawn on the phone from its lab
  /// report (phone_label.dart's drawPhoneLabelSpec - the shared coa_core rules, run on the device), so the worker
  /// still has a label to compare against. Returns coa_core's LabelSpec, drawn by LabelPreview; throws with the
  /// reason when even the phone can't make one (no lab report on file, no coa_core in this build, ...).
  /// Overridable for tests, so a widget test never makes a real state-system call for it. Null (the default) is the real
  /// one, keeping what the phone read from the lab report in [enrichmentStore] (SM-D31, _drawLabel).
  final Future<Map<String, Object?>> Function(int stateId, String pkpr, {required String accessToken, String strain})? drawLabel;

  /// Forwarded straight through to the SelectCenterPage _onSwitchCenterPressed opens - same reasoning as
  /// SelectCenterPage's own field by this name: overridable so a widget test exercising "switch center" never
  /// makes a real GetApplicableLicenses call either. CartPage never calls this itself.
  final Future<List<License>> Function(String accessToken) fetchLicenses;

  /// Called (fire-and-forget, via _logSaleAttribution) right after a sale is confirmed with the state system,
  /// so Mazama's own server can log which worker made it - see sale_log_client.dart's own file comment for why.
  /// Overridable for tests, so a widget test never makes a real network call for this either, and can assert
  /// what this was called with without a sale-log failure ever being able to affect the sale itself. Defaults
  /// to the app's outbox (server_link.dart's queueSaleLog, README R56): the log is kept on the phone with a clientId
  /// and sent now, or once Mazama's server answers again - never lost while it is down, never in the way of a sale.
  final Future<void> Function(int stateId,
      {required String workerEmail, required String deviceId, required List<Map<String, Object?>> request, required Object? response}) postSaleLog;

  /// Called (fire-and-forget, via _queueFailedSale) when a sale attempt is stopped by a SessionExpired - the
  /// state system's own sign-in refused to renew or re-authenticate, the shape a breaking change on the
  /// state's side would take. See sale_failure_client.dart's own file comment for why this exists at all.
  /// Overridable for tests, defaulting to the app's outbox the same way postSaleLog does (server_link.dart's
  /// queueSaleFailure): a failed-sale report is never dropped while Mazama's server is down.
  final Future<void> Function(int stateId,
      {required String workerEmail, required String deviceId, required String reason,
      required List<Map<String, Object?>> request}) postSaleFailure;

  /// Overridable for tests, so a widget test never reaches a real platform channel (there's no native host to
  /// answer one in a test run at all) - see text_scanner.dart's own file comment for why this is a platform
  /// channel rather than a pub.dev plugin. Defaults to the real scanLabelText, referenced through the aliased
  /// import above for the same reason as fetchLabel.
  final Future<List<String>> Function() scanLabelText;

  /// Overridable for tests, so a widget test never makes a real network call for this either. Defaults to the
  /// real scanMatch (against Mazama's own public /p/scan-match/{state_id} - see scan_match_client.dart's own
  /// file comment), referenced through the aliased import above for the same reason as fetchLabel.
  final Future<ScanMatchResult> Function(int stateId, List<String> lines, {bool typed}) scanMatch;

  /// The same matcher (coa_core's, through the FFI) run on this phone against the cart's own copy of the stock,
  /// for when [scanMatch] can't get an answer from the server (ScanMatchError.serverUnavailable); null from it
  /// when coa_core isn't built into this app. Overridable for tests, defaulting to local_scan_match.dart's own.
  final local_scan_match.LocalScanMatcher localScanMatch;

  /// This device's own install id (see device_id.dart) - read fresh on every postSaleLog/postSaleFailure call
  /// rather than cached on this widget, the same reasoning as cartStore/sessionStore being read fresh each
  /// time rather than loaded once into page state. Overridable for tests, defaulting to a real DeviceIdStore.
  final DeviceIdStore deviceIdStore;

  /// shared/flows/sale.yaml, loaded once per page - a second, separate spec from `spec` (login.yaml's
  /// login/renew), the same split flow_runner_test.dart's own spec/saleSpec already keep. Overridable for
  /// tests (a widget test supplies the real spec text directly, never through rootBundle), so defaults to
  /// loading the real asset only when not given one.
  final Future<FlowSpec> saleSpec;

  /// Overridable for tests, so a widget test can point every network call this page makes (session renewal,
  /// the sale itself) at a fake state system instead of the real one. Defaults to a real http.Client per call,
  /// same as every other page in this app that talks to the network.
  final http.Client Function() httpClientFactory;

  /// Where an in-progress cart is saved as it's built, and restored from on initState - see cart_store.dart's
  /// own file comment for why (a killed/crashed app shouldn't silently lose a draft cart) and exactly what it
  /// does and doesn't cover. Overridable for tests, so a widget test never touches the real app-data directory
  /// for this either. Defaults to a real CartStore, same as sessionStore's own real-by-default pattern.
  final CartStore cartStore;

  /// Threaded into every needsRenewal/ensureFreshSession call this page makes (the periodic/initState check in
  /// _maybeRenewSession, and the one inside _sell itself), the same optional-now pattern session.dart's own
  /// needsRenewal/ensureFreshSession/fromFlowResult already use. Overridable for tests: a real clock can't be
  /// made to look "fresh" at page-load and "expired" a moment later without actually waiting out real wall-clock
  /// time, which is impractical in a test - a fake clock lets a test move the two checks independently instead.
  /// Defaults to the real DateTime.now, same as every other optional-now parameter in this app.
  final DateTime Function() now;

  /// What _pricingMode starts out as when this page opens - see that field's own comment for what each mode
  /// means. Overridable for tests that specifically exercise "each" mode's own per-line price entry (most of
  /// them), so they don't have to tap back to it themselves just because the real app's own default changed;
  /// defaults to the real app's actual default, CartPricingMode.total.
  final CartPricingMode initialPricingMode;

  /// Called with the draft cart's number of lines whenever it changes (and once when first known), so the page
  /// hosting this one (center_home_page.dart's Cart tab, SP-D8) can show it. Optional; null calls nothing.
  final ValueChanged<int>? onDraftCountChanged;

  /// Demo mode (specs/demo-mode): the backend this cart's functions come from. Switch center stays in the demo, and
  /// a sale's success says nothing was sent. Null for a real sign-in.
  final DemoBackend? demo;

  /// Where the cart's own session stopwatch (_sessionTimerRow) persists its start time across app restarts -
  /// see session_timer_store.dart's own file comment for why. Overridable for tests, so a test never touches
  /// the real app-data directory for this either. Defaults to a real SessionTimerStore, same as cartStore's
  /// real-by-default pattern.
  final SessionTimerStore sessionTimerStore;

  /// Where this center's list of carts (names, which one is showing) is kept - see cart_slots.dart. Overridable for
  /// tests, real by default, as cartStore.
  final CartSlotsStore cartSlotsStore;

  /// The home-screen widget showing every cart's running timer (cart_timer_widget.dart, MC-D15): sent a fresh snapshot
  /// whenever a timer, a cart's lines or the list of carts changes. Overridable for tests; the real one does nothing
  /// where there's no native widget (a widget test).
  final CartTimerWidget cartTimerWidget;

  CartPage({
    super.key,
    required this.session,
    required this.center,
    required this.spec,
    required this.sessionStore,
    this.cartStore = const CartStore(),
    this.sessionTimerStore = const SessionTimerStore(),
    this.cartSlotsStore = const CartSlotsStore(),
    this.cartTimerWidget = const CartTimerWidget(),
    this.fetchPackages = packages_client.fetchPackages,
    this.fetchPackagesFromState = state_packages_client.fetchPackagesFromState,
    this.fetchRawPackagesFromState = state_packages_client.fetchRawPackagesFromState,
    this.uploadInventorySnapshot = server_link.linkUploadInventorySnapshot,
    this.centerIsConfigured = coa_data_client.centerIsConfigured,
    this.fetchCartSettings = center_status_client.fetchCartSettings,
    this.resolveAdhocInventory = coa_data_resolver.resolveAdhocInventory,
    this.submitCoaForLot = server_link.linkSubmitCoaForLot,
    this.keepCoaLotForLater = server_link.rememberCoaLot,
    this.inventoryCacheStore = const InventoryCacheStore(),
    this.enrichmentStore = const EnrichmentStore(),
    this.resilienceOptions = const ResilienceOptions(),
    this.fetchLabel = label_client.fetchLabel,
    this.drawLabel,
    this.fetchLicenses = fetchApplicableLicenses,
    this.postSaleLog = server_link.queueSaleLog,
    this.postSaleFailure = server_link.queueSaleFailure,
    this.scanLabelText = text_scanner.scanLabelText,
    this.scanMatch = scan_match_client.scanMatch,
    this.localScanMatch = local_scan_match.localScanMatch,
    this.deviceIdStore = const DeviceIdStore(),
    this.now = DateTime.now,
    this.initialPricingMode = defaultCartPricingMode,
    this.onDraftCountChanged,
    this.demo,
    Future<FlowSpec>? saleSpec,
    http.Client Function()? httpClientFactory,
  })  : saleSpec = saleSpec ?? rootBundle.loadString('assets/flows/sale.yaml').then(FlowSpec.fromYaml),
        httpClientFactory = httpClientFactory ?? _newHttpClient;

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  final _pkprController = TextEditingController();
  final _pkprFocus = FocusNode();

  List<Package>? _inventory;
  String? _inventoryError;
  String? _lookupError;
  final List<CartLine> _lines = [];

  /// The center's carts and which one is showing (specs/multi-cart). _lines, _sessionTimerStart and the pricing
  /// controls below are always the showing cart's; the others' are on disk (lines, timer) or in _pricingByCart.
  CartSlots _slots = CartSlots.initial();
  String get _cartId => _slots.activeId;

  /// The pricing controls of every cart not showing, by cart id, while this page is open (MC-D4). Not saved, the same
  /// as the showing cart's own controls never were.
  final _pricingByCart = <String, _CartPricing>{};

  /// Cart-wide pricing (cart_pricing.dart): "each" (every line keeps whatever price its own add/edit dialog
  /// set) or one of two shared modes that override every line's price at once - a single total for the whole
  /// cart, or a single $/mg rate. Starts out as widget.initialPricingMode (CartPricingMode.total by default -
  /// most sales are priced as a whole-cart total, not line by line). Neither the mode nor these two
  /// controllers is persisted across an app restart (cart_store.dart only ever saves each line's own
  /// priceCentsEach, same as "each" mode already relies on) - a restored draft cart always comes back in
  /// whatever the current default mode is, with whatever prices were last computed, editable from there same
  /// as any other line.
  late CartPricingMode _pricingMode;
  final _cartTotalController = TextEditingController();
  final _cartPerMgController = TextEditingController();
  CartTaxMode _cartTax = CartTaxMode.included;

  /// Set by _recomputeCartPricing whenever the cart-wide total/perMg field is empty or invalid, or a line would
  /// come out over the $10,000 cap - shown next to the pricing controls and also blocks Sell, the same way an
  /// empty cart already does, since there is no trustworthy price to sell at.
  String? _pricingError;

  /// Set by _recomputeCartPricing whenever the cart would sell more than maxAnalyteMgPerSale mg of raw
  /// psilocybin in total (cart_pricing.dart's analyteCapError) - a wholly separate rule from _pricingError
  /// above (that one is about money; this one is about the state's own raw analyteWeight field and has
  /// nothing to do with price) and checked in every pricing mode, "each" included. Also blocks Sell, same as
  /// _pricingError, and shown near the Total/Sell row rather than next to the pricing controls, since it
  /// applies whether or not the cart-wide pricing controls are even showing.
  String? _capError;

  /// Starts as widget.session but is kept up to date by _maybeRenewSession as it silently renews - the Sell
  /// action (and anything else this page does that needs a token) reads this field, never widget.session.
  late Session _session;

  /// Labels drawn on the phone this visit, by PKPR (_labelFor): a lab report doesn't change while the worker is
  /// at the counter, so adding the same package twice, or editing its line, doesn't download and read it again.
  /// A failed drawing isn't kept, so the next look tries again.
  final _drawnLabels = <String, Future<Map<String, Object?>>>{};
  Timer? _renewTimer;

  /// Wraps widget.fetchPackages with the state-system and 3-day-cache fallbacks (resilient_inventory.dart) -
  /// built once initState has set _session, and read through `() => _session` rather than captured once, so
  /// tier 2 (the state fallback) always uses whatever access token _maybeRenewSession most recently put there.
  /// _resilient.fetchPackages (not widget.fetchPackages directly) is what _loadInventory calls, and what gets
  /// handed down to StockPage/SelectCenterPage below - so both inherit the exact same resilience CartPage's
  /// own inventory load gets, with no changes needed to either of those widgets themselves.
  ///
  /// `base` is [_fetchMergedForCart], not widget.fetchPackages directly (item 2: a configured center now
  /// merges BOTH mazama_sales and the state system on every load, not just on a tier-1 failure - see that
  /// method's own doc comment). Tiers 2/3 (the state-only fallback, then the 3-day cache) are unchanged: they
  /// still exist for when the merge itself fails outright (no session, both sources down at once), the same
  /// safety net this page had before item 2 existed.
  late final ResilientInventory _resilient = ResilientInventory(
    merged: _fetchMergedForCart,
    enrichment: widget.enrichmentStore,
    fetchFromState: widget.fetchPackagesFromState,
    cache: widget.inventoryCacheStore,
    session: () => _session,
    maxAge: widget.resilienceOptions.cacheMaxAge,
    enableStateFallback: widget.resilienceOptions.enableStateFallback,
  );

  /// Tier 1 of [_resilient] for a configured center (item 2): fetches BOTH mazama_sales (widget.fetchPackages)
  /// and the state system (widget.fetchRawPackagesFromState) and merges them every time (merged_inventory.dart's
  /// own file comment has the exact rule - the state's own quantity wins, mazama's own strain/tpeMg/coaAvailable/
  /// labelAvailable wins). Whenever the state side actually answered, that same fresh read is also pushed
  /// straight back to mazama_sales (item 3a, widget.uploadInventorySnapshot) fire-and-forget: a push failing is
  /// never surfaced to the worker, since the merge already used the fresh numbers for this screen regardless -
  /// a failed push only means the SERVER's own copy stays one read further behind, not that anything on screen
  /// right now is wrong.
  ///
  /// Returns the whole merge result: _resilient remembers the server's own rows from it, and reports a merge only the
  /// state answered as InventorySource.state (with Mazama's last figures filled in where safe), not as live.
  Future<merged_inventory.MergedInventoryResult> _fetchMergedForCart(int stateId) async {
    final result = await merged_inventory.fetchMergedInventory(
      stateId,
      accessToken: _session.accessToken,
      fetchMazama: widget.fetchPackages,
      fetchRawState: widget.fetchRawPackagesFromState,
    );
    final raw = result.rawStateRecords;
    if (raw != null) {
      unawaited(() async {
        final deviceId = await widget.deviceIdStore.idOrCreate();
        await widget.uploadInventorySnapshot(stateId, raw, workerEmail: _session.email, deviceId: deviceId);
      }().catchError((_) {}));
    }
    return result;
  }

  /// Which tier _inventory actually came from, set by _loadInventory right alongside it - null until the first
  /// load finishes. Read by _body to show a banner whenever it's anything other than live: a worker should
  /// never mistake a cached or state-estimated count for Mazama's own real-time figure.
  InventorySource? _inventorySource;
  DateTime? _inventoryAsOf;

  /// When the stock now on screen was read (a cached copy: when it was saved), so a sale can read it again first
  /// when it's older than ResilienceOptions.stockRecheckAge (SM-25). Null until stock has loaded.
  DateTime? _stockReadAt;

  /// Set by _loadInventoryAsync right after widget.centerIsConfigured answers, before either branch below it
  /// runs - null only during that one check itself. Read by _fetchPackagesForStockPage so StockPage's own
  /// re-fetch (and _onViewStockPressed's push) takes the same branch this page's own inventory did, without
  /// re-running the check a second time.
  bool? _centerConfigured;

  /// How many distinct lot guids this center's inventory had, and how many have resolved so far - set once
  /// _loadInventoryAsync's adhoc branch starts, ticked up by its onResolved callback as each one lands. Read
  /// only by _degradedInventoryNotice's own InventorySource.adhoc case; both stay 0 for the ordinary tiers.
  int _adhocGuidsTotal = 0;
  int _adhocGuidsResolved = 0;

  /// Set when the worker taps "Start Timer" in the cart's own dose summary (_sessionTimerRow) - the wall-clock
  /// moment the administration session actually began, read against widget.now() every tick to show how long
  /// it's been running. Null until started, cleared back to null by _resetSessionTimer (by hand, or
  /// automatically once sessionTimerMaxAge has passed). Persisted to widget.sessionTimerStore as soon as it's
  /// set (see _startSessionTimer) and restored from there on initState (_restoreSessionTimer) - unlike
  /// _pricingMode, a force-closed or OS-killed app should pick the stopwatch back up where it left off rather
  /// than silently losing track of when the session actually began.
  DateTime? _sessionTimerStart;

  /// Ticks once a second while _sessionTimerStart is set, purely to redraw the elapsed-time display -
  /// _sessionTimerRow always computes the actual elapsed time fresh from _sessionTimerStart against
  /// widget.now(), never from this timer's own tick count.
  Timer? _sessionTimerTicker;

  /// _publishTimerWidget's bookkeeping: one snapshot is worked out at a time ([_widgetPublishing]); a change while one
  /// is ([_widgetPublishAgain]) makes it go round once more; [_widgetLastSent] skips sending the same snapshot twice.
  bool _widgetPublishing = false;
  bool _widgetPublishAgain = false;
  String? _widgetLastSent;

  bool _selling = false;

  /// The cart's settings (SM-16): the built-in rules until the server's answer arrives, which may change the tax
  /// offered, the agreement split, the units allowed in one line and how old a draft may be to come back.
  CartSettings _cartSettings = CartSettings.fallback;
  late final Future<CartSettings> _cartSettingsFuture;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _pricingMode = widget.initialPricingMode;
    _cartSettingsFuture = _fetchCartSettingsOrFallback();
    _loadInventory();
    _restoreSlotsThenCart();
    _renewTimer = Timer.periodic(sessionCheckInterval, (_) => _maybeRenewSession());
    _maybeRenewSession(); // in case it was already close to expiry when this page opened
  }


  /// Adds [added]'s units to line [i] (inside a setState), unless the line would then hold more than the server's
  /// units-per-line cap (SM-16): then the line stays as it was and the worker is told. -> whether it merged.
  bool _mergeWithinLineCap(int i, CartLine added) {
    final cap = _cartSettings.maxUnitsPerLine;
    final total = _lines[i].qty + added.qty;
    // SM-17: never more than the lots hold either, so a sale never has units left over to put on the last lot
    final message = total > cap
        ? 'At most $cap units in one line.'
        : total > _lines[i].group.quantity
            ? 'Only ${_lines[i].group.quantity} of ${_lines[i].productGuid} in stock.'
            : null;
    if (message != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      });
      return false;
    }
    _lines[i] = _lines[i].withQty(_lines[i].qty + added.qty);
    return true;
  }

  /// The server's cart settings, or the built-in ones when it can't say. An async try/catch rather than
  /// `catchError`: a fetcher written as `(id) async => throw ...` is a `Future<Never>` at run time, and
  /// `catchError` on it can't return a CartSettings.
  Future<CartSettings> _fetchCartSettingsOrFallback() async {
    try {
      return await widget.fetchCartSettings(widget.center.id);
    } catch (_) {
      return CartSettings.fallback;
    }
  }

  /// Which carts this center has (and which was showing) comes first, so the draft and timer restored next are that
  /// cart's. Nothing saved, or another center's list, leaves the one first cart (CartSlots.initial).
  Future<void> _restoreSlotsThenCart() async {
    final slots = await widget.cartSlotsStore.load(widget.center.id);
    if (!mounted) return;
    if (slots != null) setState(() => _slots = slots);
    _restoreSessionTimer();
    await _restoreCartThenApplySettings();
    _publishTimerWidget(); // again: the timer above may have been sent before the lines it counts down against
  }

  /// Restores the draft first, then applies the settings. In the other order, applying them re-prices and saves
  /// the still-empty cart over the draft before it is read. The re-price after restoring doesn't save: the draft
  /// keeps the time it was last changed, which is what its life counts from.
  Future<void> _restoreCartThenApplySettings() async {
    final settings = await _cartSettingsFuture;
    await _restoreCart(settings);
    if (!mounted) return;
    setState(() => _cartSettings = settings);
    _recomputeCartPricing(persist: false);
  }

  /// Picks back up a draft cart left over from a previous run of the app on this same center, if cart_store.dart
  /// still has one - see that file's own comment for why this exists at all. A missing/unreadable/wrong-center
  /// file (CartStore.load's own job to sort out) means there's nothing to restore, which is the common case and
  /// not worth telling the worker about; actually restoring something IS worth telling them, since an
  /// unexpectedly non-empty cart on a screen that just opened would otherwise look like a bug.
  Future<void> _restoreCart(CartSettings settings) async {
    // A draft older than the cart's life isn't restored, as the server empties a cart nobody has changed that long.
    final id = _cartId;
    final restored = await widget.cartStore.load(widget.center.id, maxAge: settings.life, cartId: id);
    if (restored == null || restored.isEmpty || !mounted || id != _cartId) return;
    setState(() => _lines.addAll(restored));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Restored an unsold cart from last time - double-check it before selling.')),
    );
  }

  /// Fire-and-forget, deliberately, same reasoning as _logSaleAttribution: this is a convenience backstop
  /// against a killed app, never something the worker is blocked on or told about when it fails. Called after
  /// every change to _lines so the file on disk never lags further behind than the time it takes to write it.
  void _persistCart() {
    unawaited(widget.cartStore.save(widget.center.id, _lines, cartId: _cartId).catchError((e) {
      debugPrint('could not persist the draft cart (nothing the worker is doing is affected): $e');
    }));
    _publishTimerWidget(); // the lines are the dose a running timer counts down against (MC-D14)
  }

  /// Picks back up a running session timer left over from a previous run of the app on this same center, if
  /// widget.sessionTimerStore still has one - same reasoning as _restoreCart, for the same kind of
  /// force-closed/killed-app failure mode. A timer that's already past sessionTimerMaxAge (the app having been
  /// closed for a long while, not just a quick restart) is treated as expired rather than resumed - it's
  /// cleared from disk and the worker sees a fresh "Start Timer" button, the same end state _onSessionTimerTick
  /// below brings a still-running timer to once it ages out.
  /// The home-screen widget is brought up to date afterwards whichever way it went: this is where a page that just
  /// opened, or a cart that was just shown, has its timer settled.
  Future<void> _restoreSessionTimer() async {
    try {
      final id = _cartId;
      final start = await widget.sessionTimerStore.load(widget.center.id, cartId: id);
      if (start == null) return;
      if (widget.now().difference(start) >= sessionTimerMaxAge) {
        unawaited(widget.sessionTimerStore.clear(cartId: id).catchError((e) {
          debugPrint('could not clear the expired session timer (nothing the worker is doing is affected): $e');
        }));
        return;
      }
      if (!mounted || id != _cartId) return;
      _sessionTimerTicker?.cancel();
      setState(() => _sessionTimerStart = start);
      _sessionTimerTicker = Timer.periodic(const Duration(seconds: 1), (_) => _onSessionTimerTick());
    } finally {
      _publishTimerWidget();
    }
  }

  /// Starts (or restarts) the cart's own session stopwatch from now, tapped by the worker when the client's
  /// administration session actually begins - see _sessionTimerRow for the button/elapsed-display widget this
  /// drives. Persisted to widget.sessionTimerStore immediately, so a force-closed app can pick the same start
  /// time back up via _restoreSessionTimer.
  void _startSessionTimer() {
    _sessionTimerTicker?.cancel();
    final start = widget.now();
    setState(() => _sessionTimerStart = start);
    unawaited(widget.sessionTimerStore.save(widget.center.id, start, cartId: _cartId).catchError((e) {
      debugPrint('could not persist the session timer start (nothing the worker is doing is affected): $e');
    }));
    _sessionTimerTicker = Timer.periodic(const Duration(seconds: 1), (_) => _onSessionTimerTick());
    _publishTimerWidget();
  }

  /// The periodic ticker's own callback, once a second while _sessionTimerStart is set. Normally just redraws
  /// _sessionTimerRow's elapsed text (that widget always computes elapsed time fresh against widget.now(),
  /// never from this timer's own tick count) - but once sessionTimerMaxAge has passed, this resets the timer
  /// on its own instead, the same end state tapping "Reset" by hand reaches.
  void _onSessionTimerTick() {
    if (!mounted) return;
    final start = _sessionTimerStart;
    if (start != null && widget.now().difference(start) >= sessionTimerMaxAge) {
      _resetSessionTimer();
      return;
    }
    setState(() {});
  }

  /// Stops and clears the running session timer, back to the "Start Timer" button - either the worker's own
  /// way to reset it before the next sale, or _onSessionTimerTick resetting it automatically past
  /// sessionTimerMaxAge. Either way, clears widget.sessionTimerStore too, so there's nothing left to resume on
  /// the next launch.
  void _resetSessionTimer() {
    _sessionTimerTicker?.cancel();
    _sessionTimerTicker = null;
    setState(() => _sessionTimerStart = null);
    unawaited(widget.sessionTimerStore.clear(cartId: _cartId).catchError((e) {
      debugPrint('could not clear the persisted session timer (nothing the worker is doing is affected): $e');
    }));
    _publishTimerWidget();
  }

  /// Sends the home-screen widget (widget.cartTimerWidget, MC-D15) every cart's running timer as the carts list has
  /// them (_cartSummaries: the showing cart from memory, the others from disk - every store write here is done by the
  /// time its call returns, so disk is never behind). Fire-and-forget: the widget is a convenience, never something
  /// the worker waits on.
  void _publishTimerWidget() {
    if (!mounted) return;
    if (_widgetPublishing) {
      _widgetPublishAgain = true;
      return;
    }
    _widgetPublishing = true;
    unawaited(() async {
      try {
        do {
          _widgetPublishAgain = false;
          final summaries = await _cartSummaries();
          if (!mounted) return;
          final snapshot = cartTimerSnapshot(
            center: widget.center.licenseName,
            now: widget.now(),
            carts: [for (final s in summaries) (id: s.slot.id, name: s.slot.name, start: s.timerStart, dose: s.dose)],
          );
          final key = jsonEncode({...snapshot}..remove('writtenMs'));
          if (key == _widgetLastSent) continue;
          _widgetLastSent = key;
          await widget.cartTimerWidget.publish(snapshot);
        } while (_widgetPublishAgain && mounted);
      } catch (e) {
        debugPrint('could not update the cart timers widget (nothing the worker is doing is affected): $e');
      } finally {
        _widgetPublishing = false;
      }
    }());
  }

  @override
  void dispose() {
    _renewTimer?.cancel();
    _sessionTimerTicker?.cancel();
    _pkprController.dispose();
    _pkprFocus.dispose();
    _cartTotalController.dispose();
    _cartPerMgController.dispose();
    super.dispose();
  }

  /// Recomputes every line's priceCentsEach for the cart-wide modes (cart_pricing.dart's priceWholeCart) and
  /// persists the result - the one place that happens, called after anything that could change the outcome: a
  /// line added, edited, or removed, the pricing mode itself, the total/rate field, or the tax choice. A no-op
  /// on the prices themselves in "each" mode (every line already carries its own hand-typed price), but still
  /// clears any stale _pricingError left over from switching out of total/perMg, and still persists - the same
  /// single call _persistCart used to be called separately after every one of those same events.
  void _recomputeCartPricing({bool persist = true}) {
    // Built once up front, used by both the mg-cap check below and (in the cart-wide modes) priceWholeCart -
    // the mg-cap check runs unconditionally, in every pricing mode including "each", since it's about raw
    // psilocybin content, not price (see CartPricingLine.analyteMgPerUnit's own comment).
    final pricingLines = [
      for (final l in _lines)
        CartPricingLine(
          group: groupOf(l.productType),
          mgTpe: l.group.tpeMg.toDouble(),
          analyteMgPerUnit: l.group.weightPerUnit * l.group.analyteWeight,
          qty: l.qty,
        )
    ];
    final capError = analyteCapError(pricingLines);

    if (_pricingMode == CartPricingMode.each) {
      setState(() {
        _pricingError = null;
        _capError = capError;
      });
      if (persist) _persistCart();
      return;
    }
    final result = priceWholeCart(
      mode: _pricingMode,
      lines: pricingLines,
      totalText: _cartTotalController.text,
      perMgText: _cartPerMgController.text,
      tax: _cartTax,
      taxPercent: _cartSettings.taxPercent,
      agreementEdible: _cartSettings.agreementEdible,
      agreementDried: _cartSettings.agreementDried,
    );
    setState(() {
      _pricingError = result.error;
      _capError = capError;
      if (result.priceCentsEach != null) {
        for (var i = 0; i < _lines.length; i++) {
          _lines[i] = _lines[i].withPrice(result.priceCentsEach![i]);
        }
      }
    });
    if (persist) _persistCart();
  }

  Future<void> _maybeRenewSession() async {
    if (_session.isDemo) return; // DM-R4: never renewed
    if (!_session.needsRenewal(now: widget.now, margin: refreshMarginOf(widget.spec))) return;
    final client = widget.httpClientFactory();
    try {
      final renewed = await ensureFreshSession(_session, widget.spec, client: client, now: widget.now);
      if (!mounted) return;
      setState(() => _session = renewed);
      await widget.sessionStore.save(renewed.toJson());
    } on SessionExpired catch (e) {
      _renewTimer?.cancel();
      if (!mounted) return;
      await goToSignIn(context, spec: widget.spec, sessionStore: widget.sessionStore, message: e.message);
    } on SessionRenewalUnavailable {
      // The state is just unreachable or erroring right now, not a dead session - leave the session and the
      // timer alone and let the next tick (sessionCheckInterval later) try again on its own, the same way this
      // app already shrugs off any other transient network hiccup. Nothing here should interrupt whatever the
      // worker is doing on this screen right now, and nothing on disk changes.
    } finally {
      client.close();
    }
  }

  void _loadInventory() {
    setState(() {
      _inventory = null;
      _inventoryError = null;
      _inventorySource = null;
      _inventoryAsOf = null;
      _centerConfigured = null;
      _adhocGuidsTotal = 0;
      _adhocGuidsResolved = 0;
    });
    unawaited(_loadInventoryAsync());
  }

  /// The real body of _loadInventory, split out so it can `await` widget.centerIsConfigured before deciding
  /// which of the two branches below to run - see that field's own doc comment on this page, and
  /// coa_data_client.dart/coa_data_resolver.dart's own file comments for why an unconfigured center needs an
  /// entirely different path from [_resilient]'s usual three tiers, not just a fourth tier bolted onto them.
  Future<void> _loadInventoryAsync() async {
    bool configured;
    try {
      configured = await widget.centerIsConfigured(widget.center.id);
    } catch (_) {
      // The center-status check itself failing (network, Mazama's server down) says nothing about whether
      // this center is actually configured - and the ordinary tiers below already have their own state- and
      // cache-fallbacks for exactly that situation. Treating this as "assume configured" just means a worker
      // at a genuinely unconfigured center sees the SAME tier-2/tier-3 degraded messaging they'd have gotten
      // before this feature existed, never a hard failure caused by this one extra check.
      configured = true;
    }
    if (!mounted) return;
    setState(() => _centerConfigured = configured);

    if (configured) {
      _resilient.fetch(widget.center.id).then((result) {
        if (!mounted) return;
        setState(() {
          _inventory = result.packages;
          _inventorySource = result.source;
          _inventoryAsOf = result.asOf;
          _stockReadAt = result.asOf ?? widget.now();
        });
      }).catchError((e) {
        if (!mounted) return;
        setState(() => _inventoryError = e.toString());
      });
      return;
    }

    try {
      final deviceId = await widget.deviceIdStore.idOrCreate();
      final result = await widget.resolveAdhocInventory(
        stateId: widget.center.id,
        accessToken: _session.accessToken,
        workerEmail: _session.email,
        deviceId: deviceId,
        onInventoryLoaded: (packages) {
          if (!mounted) return;
          setState(() => _inventory = packages);
        },
        onResolved: (guid, updated) {
          if (!mounted) return;
          setState(() {
            final inv = _inventory;
            if (inv != null) {
              final i = inv.indexWhere((p) => p.productGuid == updated.productGuid && p.id == updated.id);
              if (i != -1) {
                final copy = List<Package>.from(inv);
                copy[i] = updated;
                _inventory = copy;
              }
            }
            _adhocGuidsResolved++;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _inventory = result.packages;
        _stockReadAt = widget.now();
        _inventorySource = InventorySource.adhoc;
        _adhocGuidsTotal = result.guidsTotal;
        _adhocGuidsResolved = result.guidsResolved;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _inventoryError = e.toString());
    }
  }

  /// What StockPage's own re-fetch (and the fresh fetch SelectCenterPage's picker would run for a different
  /// center after switching - see _onSwitchCenterPressed) should call instead of _resilient.fetchPackages
  /// directly, so either one takes the exact same branch (ordinary tiers, or the adhoc flow) this page's own
  /// inventory just did - reusing [_centerConfigured] rather than re-running widget.centerIsConfigured a
  /// second time for the same center in the same page view.
  Future<List<Package>> _fetchPackagesForStockPage(int stateId) async {
    if (_centerConfigured == false) {
      final deviceId = await widget.deviceIdStore.idOrCreate();
      final result = await widget.resolveAdhocInventory(
        stateId: stateId,
        accessToken: _session.accessToken,
        workerEmail: _session.email,
        deviceId: deviceId,
      );
      return result.packages;
    }
    return _resilient.fetchPackages(stateId);
  }

  Future<void> _onAddPkpr() async {
    final text = _pkprController.text.trim();
    final hex = stripPkprPrefix(text);
    if (hex.isEmpty) {
      setState(() => _lookupError = 'Enter a PKPR.');
      return;
    }
    // SM-27, SM-D22: the shared package id rule (id_patterns.g.dart, SM-D8) before anything is looked up
    if (!isPackageId('PKPR-$hex')) {
      setState(() => _lookupError = "PKPR-$hex isn't a package id (PKPR- and 4 to 16 letters or digits).");
      return;
    }
    final inventory = _inventory;
    if (inventory == null) {
      setState(() => _lookupError =
          _inventoryError == null ? 'Inventory is still loading - try again in a moment.' : 'Inventory did not load: $_inventoryError');
      return;
    }
    final needle = hex.toLowerCase();
    // Grouped first (packages_client.dart's groupByPkpr): the server sends one row per underlying lot/transfer,
    // and a typed PKPR should resolve to exactly one merged product, never to "which of several lots did you
    // mean" - a worker typing a PKPR off a label has no reason to know lots exist at all.
    final matches = groupByPkpr(inventory).where((g) => stripPkprPrefix(g.productGuid).toLowerCase() == needle).toList();
    if (matches.isEmpty) {
      setState(() => _lookupError = 'No PKPR $text in ${widget.center.licenseName}\'s inventory.');
      return;
    }
    setState(() => _lookupError = null);
    final priceEditable = _pricingMode == CartPricingMode.each;
    final added = await _showLineDialog(matches.single, priceEditable: priceEditable);
    if (added == null) return; // cancelled
    setState(() {
      // In "each" mode a matching price is part of what makes two adds the same line (a worker who priced
      // some units differently gets two lines, deliberately). In the cart-wide modes price isn't something a
      // worker chose at all - it's about to be overwritten by _recomputeCartPricing below regardless - so two
      // adds of the same PKPR and dose always merge there, whatever placeholder price this one happened to
      // carry in the meantime.
      final i = _lines.indexWhere((l) =>
          l.productGuid == added.productGuid &&
          (!priceEditable || l.priceCentsEach == added.priceCentsEach) &&
          l.dose == added.dose);
      if (i != -1) {
        if (!_mergeWithinLineCap(i, added)) return;
      } else {
        _lines.add(added);
      }
      _pkprController.clear();
    });
    _recomputeCartPricing();
    _pkprFocus.requestFocus();
    // Doesn't block the add (already done above) or the worker's next keystroke - this just puts the package's
    // label (the server's picture, else one drawn on the phone) up for a quick visual check against the physical
    // one still in their hand.
    unawaited(_showLabelDialog(matches.single));
    // Item 3b - same "never blocks the add" reasoning as the label-compare popup right above.
    unawaited(_ensureCoaForCartLine(matches.single));
  }

  /// Item 3b: for a CONFIGURED center, submits a lab report for every lot behind [group] that still has
  /// coaAvailable false (packages_client.dart's own Package field, carried through the merge - see
  /// merged_inventory.dart) - so a PKPR, HB or PL a worker just sold gets its COA (and, per item 4, its label) on
  /// file without anyone having to notice and go submit it by hand later. A lot whose COA the server already has
  /// but whose label it hasn't drawn yet is left alone (README R64): the server draws the label itself, and
  /// submitting would only cost two calls to the state system and an upload for an answer the server already has. A no-op for an
  /// UNCONFIGURED center: coa_data_resolver.dart's own resolveAdhocInventory already resolved what it could
  /// during the load itself, and Package's own coaAvailable/labelAvailable default true for a source (the
  /// adhoc flow) that never sets them, so the `where` below simply finds nothing to do there.
  ///
  /// A lot with no [Package.lotGuid] on file (possible if the state system's own read that would have supplied
  /// it never ran for this lot - see merged_inventory.dart's own _unknownCoaLabel/merge comment) is skipped:
  /// there is nothing to key the submission by. Every lot is tried independently and a failure on one (caught
  /// inside submitCoaForLot's own ConfiguredCoaSubmitError, or any other exception) never stops the rest - same
  /// "one miss is never fatal to the others" rule coa_data_resolver.dart's own worker() already follows.
  Future<void> _ensureCoaForCartLine(PkprGroup group) async {
    if (_centerConfigured != true) return;
    final needsWork = group.lots.where((l) => !l.coaAvailable && (l.lotGuid?.isNotEmpty ?? false));
    if (needsWork.isEmpty) return;
    final deviceId = await widget.deviceIdStore.idOrCreate();
    for (final lot in needsWork) {
      try {
        await widget.submitCoaForLot(
          lotGuid: lot.lotGuid!,
          representativePackageId: lot.id,
          accessToken: _session.accessToken,
          workerEmail: _session.email,
          deviceId: deviceId,
          statePsilocybin: lot.analyteWeight,
        );
      } catch (e) {
        // Swallowed on purpose - see this method's own doc comment. Nothing on this screen depends on this
        // submission having worked; the next load of this center simply still sees coaAvailable/labelAvailable
        // false for this lot until it resolves, whenever and however that ends up happening. When the report
        // couldn't reach Mazama's server, the lot is kept for a submission once it answers (README R56).
        if (isServerUnreachable(e)) {
          try {
            widget.keepCoaLotForLater(widget.center.id,
                lotGuid: lot.lotGuid!, packageId: lot.id, statePsilocybin: lot.analyteWeight);
          } catch (_) {
            // keeping it is best effort, as the submission itself
          }
        }
      }
    }
  }

  /// [group]'s label for the compare popup and the edit dialog: the server's picture (fetched fresh each time,
  /// never cached - a center's label files can change), else one drawn on the phone from the package's lab report
  /// (widget.drawLabel). Fails, with the phone's reason, only when neither has one. The demo never draws: it has no
  /// state system to read a lab report from.
  Future<_Label> _labelFor(PkprGroup group) async {
    try {
      return _ServerLabel(await widget.fetchLabel(widget.center.id, group.productGuid));
    } catch (_) {
      if (widget.demo != null) rethrow;
    }
    final key = group.productGuid.toUpperCase();
    final drawing = _drawnLabels[key] ??= _drawLabel(widget.center.id, group.productGuid,
        accessToken: _session.accessToken, strain: group.strain, labelInput: group.labelInput);
    try {
      return _PhoneLabel(await drawing);
    } catch (_) {
      _drawnLabels.remove(key);
      rethrow;
    }
  }

  /// widget.drawLabel, else the real phone drawing with this page's enrichment store, so what coa_core read from the lab
  /// report is kept for a later read from the state system alone (phone_label.dart, SM-D31). [labelInput] is the
  /// server's for the product (PkprGroup.labelInput, README R64): with it the label is drawn without any state call.
  Future<Map<String, Object?>> _drawLabel(int stateId, String pkpr,
      {required String accessToken, String strain = '', Map<String, Object?>? labelInput}) {
    final draw = widget.drawLabel;
    if (draw != null) return draw(stateId, pkpr, accessToken: accessToken, strain: strain);
    return phone_label.drawPhoneLabelSpec(stateId, pkpr,
        accessToken: accessToken, strain: strain, now: widget.now, enrichment: widget.enrichmentStore, labelInput: labelInput);
  }

  /// Pops up [group]'s label (_labelFor) so the worker can compare it against the physical label they just read
  /// the PKPR off of. A missing label (none on the server and none the phone can draw) is shown plainly rather
  /// than silently skipped, since "no picture to compare against" is itself something the worker should know.
  Future<void> _showLabelDialog(PkprGroup group) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Compare label · ${group.productGuid}'),
        content: SizedBox(width: 280, height: 280, child: _labelPicture(_labelFor(group))),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  /// The label picture itself, shared by the post-add compare popup (_showLabelDialog) and the edit-line
  /// dialog (_showLineDialog): a spinner while [label] is pending, the server's picture or the phone's drawing
  /// once it arrives, and a plain "no label" message with the reason - never a crash - when there is neither. The
  /// caller owns [label] so a dialog that rebuilds on every keystroke (the edit dialog's StatefulBuilder) doesn't
  /// fetch or draw the label again each time.
  Widget _labelPicture(Future<_Label> label) {
    return FutureBuilder<_Label>(
      future: label,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          // the server's own "no label" needs no explaining; why the phone couldn't draw one does
          final why = snapshot.error is label_client.LabelError ? '' : "\nThe phone couldn't draw one: ${snapshot.error}.";
          return Center(
            child: Text('No label on file for this package to compare against.$why', textAlign: TextAlign.center),
          );
        }
        return switch (snapshot.data!) {
          _ServerLabel(:final bytes) => Center(child: Image.memory(bytes, fit: BoxFit.contain)),
          _PhoneLabel(:final spec) => Center(
              child: SingleChildScrollView(
                child: LabelPreview(spec: spec, note: 'Drawn on this phone: no label on file at the server'),
              ),
            ),
        };
      },
    );
  }

  /// The two ways a worker can price a line - type a flat price for one unit, or type a $/mg (TPE) rate and
  /// let the group's own tpeMg (the real per-unit dose - see Package's own file comment for why that's tpeMg
  /// and never analyteWeight) work out what one unit costs (pricing.dart's perMgPriceCentsEach, the app's twin
  /// of pricing.py's per_mg_prices). Either way the result is a single priceCentsEach, same as CartLine has
  /// always stored - the mode only changes how that number gets typed in.
  static const _priceEach = 'each';
  static const _pricePerMg = 'perMg';

  /// Shows the quantity/price/dose dialog used both to add [group] (one merged PKPR - see PkprGroup's own
  /// comment) as a new line and, when [existing] is given, to edit one already in the cart (same fields,
  /// pre-filled from it, "Save" instead of "Add", and the result replaces that line rather than merging into
  /// another one - see _onEditLine). Either way this never touches _lines itself; the caller decides what to do
  /// with the CartLine it returns. Every number shown here (stock, the quantity cap) is group.quantity, the
  /// total across every lot - a worker typing a quantity has no reason to know it might end up split across
  /// more than one lot at sale time (buildSaleRecords' own job, invisibly).
  ///
  /// [priceEditable] is false whenever the cart itself is in one of the two cart-wide pricing modes
  /// (cart_pricing.dart) - the price section is hidden entirely rather than shown and disabled, since nothing
  /// typed here would do anything: the caller recomputes every line's real price right after this returns
  /// (_recomputeCartPricing). The returned CartLine still carries a priceCentsEach either way (0, or whatever
  /// [existing] already had) purely as a placeholder CartLine's constructor requires - never meant to be read.
  Future<CartLine?> _showLineDialog(PkprGroup group, {CartLine? existing, bool priceEditable = true}) {
    final qtyController = TextEditingController(text: '${existing?.qty ?? 1}');
    // Editing always starts back in "price each" mode, pre-filled with the line's current priceCentsEach -
    // the original per-mg rate (if that's how it was priced) isn't kept on CartLine, only the result, so
    // there's nothing to restore it from; the worker can switch back to per-mg and retype it if they want to.
    var mode = _priceEach;
    final priceController = TextEditingController(text: existing == null ? '' : (existing.priceCentsEach / 100).toStringAsFixed(2));
    final formKey = GlobalKey<FormState>();
    var dose = existing?.dose ?? doseInitial;
    // Editing a line already in the cart shows its label at the top, so the worker can see which package
    // they're changing. A fresh add skips it: _onAddPkpr already pops the separate compare-label dialog right
    // after the add. Started on the builder's first run (so the FutureBuilder is listening before a failed
    // fetch completes - started any earlier, a "no label" error escapes as an unhandled one), then kept, since
    // the builder reruns on every keystroke and must not refetch each time.
    Future<_Label>? label;
    return showDialog<CartLine>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (existing != null) label ??= _labelFor(group);
          return AlertDialog(
            // AlertDialog doesn't scroll its content by default - with the on-screen keyboard up (this dialog's
            // own quantity/price fields summon it) the available height shrinks enough that this Column no
            // longer fits, and without this it overflows with Flutter's own yellow/black warning banner right
            // over the dose selector. Scrollable keeps everything reachable instead, same as any other form
            // that might not fit above a keyboard.
            scrollable: true,
            title: Text(group.productType.isEmpty ? group.productGuid : group.productType),
            content: Form(
              key: formKey,
              // Live, not just on submit - the quantity cap below needs to tell the worker why Add/Save won't
              // go through before they even tap it, not just after.
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (label != null) ...[
                    SizedBox(width: 280, height: 200, child: _labelPicture(label!)),
                    const SizedBox(height: 12),
                  ],
                  Text(group.productGuid),
                  if (group.strain.isNotEmpty) Text(group.strain, style: Theme.of(context).textTheme.bodySmall),
                  Text('${group.quantity} in stock (as of last sync)', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: qtyController,
                    decoration: const InputDecoration(labelText: 'Quantity'),
                    keyboardType: TextInputType.number,
                    // The server's own inventory figure wins here, not the worker's typed guess: this is a hard
                    // cap, not a heads-up, the same way the price field already hard-caps at $10,000. A PKPR
                    // showing 0 (sold out everywhere) can't be added at all - there is nothing to add.
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      if (n == null || n < 1) return 'Enter a whole number, at least 1';
                      if (n > _cartSettings.maxUnitsPerLine) return 'At most ${_cartSettings.maxUnitsPerLine} units in one line.';
                      if (n > group.quantity) return 'Only ${group.quantity} in stock - reduce the quantity.';
                      return null;
                    },
                  ),
                  if (priceEditable) ...[
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: _priceEach, label: Text('Price each')),
                        ButtonSegment(value: _pricePerMg, label: Text('Price per mg')),
                      ],
                      selected: {mode},
                      onSelectionChanged: (selection) => setDialogState(() {
                        mode = selection.first;
                        priceController.clear();
                      }),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: ValueKey(mode), // a fresh FormField per mode, so switching modes clears any stale error text
                      controller: priceController,
                      decoration: InputDecoration(
                        // SM-D31: a product whose only figure is the state's psilocybin is priced per mg psilocybin
                        labelText: mode == _priceEach
                            ? 'Price each'
                            : group.mgFigure == MgFigure.psilocybin
                                ? 'Price per mg psilocybin'
                                : 'Price per mg (TPE)',
                        prefixText: '\$',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      autofocus: existing == null,
                      // Only needed so the "= $X each" preview below recomputes live as a per-mg rate is typed -
                      // the each-mode price has nothing downstream of it to keep in sync while typing.
                      onChanged: (_) => setDialogState(() {}),
                      validator: (v) => mode == _priceEach
                          ? (toCents(v ?? '') == null ? 'Enter a price from \$0 to \$10,000' : null)
                          : group.tpeMg <= 0
                              // SM-14, as the server: an unknown mg TPE is refused, never priced at nothing
                              ? "No ${group.mgLabel} is known for this product, so it can't be priced per mg"
                              : (perMgRateToCents(v ?? '') == null ? 'Enter a rate from \$0 to \$1,000 per mg' : null),
                    ),
                    if (mode == _pricePerMg && group.tpeMg > 0 && perMgRateToCents(priceController.text) != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '= ${money(perMgPriceCentsEach(perMgRateToCents(priceController.text)!, group.tpeMg.toDouble()))} each '
                            '(${group.tpeMg} ${group.mgLabel}/unit)',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                  ] else
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('Priced automatically by the cart\'s own pricing mode.', style: TextStyle(fontStyle: FontStyle.italic)),
                    ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: doseInitial, label: Text('Initial dose')),
                      ButtonSegment(value: doseSecondary, label: Text('Secondary dose')),
                    ],
                    selected: {dose},
                    onSelectionChanged: (selection) => setDialogState(() => dose = selection.first),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  if (!formKey.currentState!.validate()) return;
                  final qty = int.parse(qtyController.text.trim());
                  final cents = !priceEditable
                      ? (existing?.priceCentsEach ?? 0) // placeholder - _recomputeCartPricing overwrites this right after
                      : (mode == _priceEach
                          ? toCents(priceController.text)!
                          : perMgPriceCentsEach(perMgRateToCents(priceController.text)!, group.tpeMg.toDouble()));
                  Navigator.of(context).pop(CartLine(group: group, qty: qty, priceCentsEach: cents, dose: dose));
                },
                child: Text(existing == null ? 'Add' : 'Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Reopens the quantity/price/dose dialog for the line already at [i], pre-filled from it, and replaces that
  /// exact line with whatever comes back - never merges it into another line the way adding a fresh PKPR can,
  /// since the worker is deliberately changing this one, not adding more of something.
  Future<void> _onEditLine(int i) async {
    final edited =
        await _showLineDialog(_lines[i].group, existing: _lines[i], priceEditable: _pricingMode == CartPricingMode.each);
    if (edited == null || !mounted) return; // cancelled
    setState(() => _lines[i] = edited);
    _recomputeCartPricing();
  }

  /// Opens the native camera + on-device text recognizer (text_scanner.dart), sends what it read to the
  /// server's matcher (scan_match_client.dart - coa_core's, the same a label photo gets on the web) or, when the
  /// server can't answer, runs that matcher on this phone against the cart's stock (_matchScanLocally), and lands
  /// on exactly the same path manual entry uses: fills _pkprController with the resolved PKPR and calls
  /// _onAddPkpr(), so nothing downstream of that (the label-compare dialog, the quantity/price/dose dialog, merging
  /// into an existing line) needs to know a scan was ever involved.
  Future<void> _onScanPressed() async {
    List<String> lines;
    try {
      lines = await widget.scanLabelText();
    } on ScanCancelled {
      return; // the worker backed out of the camera screen - nothing went wrong, nothing to say
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read the camera: $e')));
      return;
    }
    ScanMatchResult result;
    try {
      result = await widget.scanMatch(widget.center.id, lines);
    } catch (e) {
      final local = _matchScanLocally(e, lines);
      if (!mounted) return;
      if (local == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not match the scan: $e')));
        return;
      }
      result = local;
    }
    if (!mounted) return;
    final guid = await _resolveScanGuid(result);
    if (guid == null || !mounted) return; // nothing found, or the worker dismissed the chooser
    _pkprController.text = stripPkprPrefix(guid);
    await _onAddPkpr();
  }

  /// The scan matched on this phone (widget.localScanMatch: coa_core through the FFI) against the stock the cart
  /// already holds, when the server's matcher failed with [error] because it couldn't answer - unreachable or
  /// failing, not a request it refused (ScanMatchError.serverUnavailable; anything that isn't a ScanMatchError is
  /// a failure to reach it too). Null - and the caller shows the server's error as before - when the server refused
  /// the request, no stock is loaded yet, or coa_core isn't built into this app.
  ScanMatchResult? _matchScanLocally(Object error, List<String> lines) {
    if (error is ScanMatchError && !error.serverUnavailable) return null;
    final inventory = _inventory;
    if (inventory == null) return null;
    return widget.localScanMatch(inventory, lines);
  }

  /// Picks one package id out of a scan's matches/guesses: the single match if there was exactly one, a short
  /// chooser dialog if there were several (same "choose, don't guess" reasoning _showLineDialog already has
  /// whenever more than one thing could be meant), or null (with a snackbar) if nothing was found at all.
  /// Deliberately never touches the cart itself - this only decides WHICH package; _onScanPressed hands the
  /// result to _onAddPkpr the same as if the worker had typed it.
  Future<String?> _resolveScanGuid(ScanMatchResult result) async {
    if (result.matches.isNotEmpty) {
      if (result.matches.length == 1) return result.matches.first.guid;
      return _showScanChooserDialog(
        'Which package?',
        [for (final m in result.matches) (guid: m.guid, title: m.name, subtitle: '${m.guid} · ${m.stock} in stock')],
      );
    }
    if (result.guesses.isNotEmpty) {
      return _showScanChooserDialog(
        'No exact lot number was read - best guesses',
        [for (final g in result.guesses) (guid: g.guid, title: g.name, subtitle: '${g.guid} · ${g.why.join(", ")}')],
      );
    }
    if (!mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No package found in that scan - enter the PKPR directly.')),
    );
    return null;
  }

  Future<String?> _showScanChooserDialog(String title, List<({String guid, String title, String subtitle})> options) {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 320,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final o in options)
                ListTile(title: Text(o.title), subtitle: Text(o.subtitle), onTap: () => Navigator.of(context).pop(o.guid)),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
      ),
    );
  }

  void _removeLine(int i) {
    setState(() => _lines.removeAt(i));
    _recomputeCartPricing();
  }

  /// Asks before throwing away unsold carts - shared by switching centers and signing out, the two ways a worker can
  /// leave this screen with unsold lines in it. Every cart counts, not only the one showing (MC-D6). Returns true if
  /// it's fine to proceed (no cart has lines, or the worker confirmed), false if they backed out. A confirmed discard
  /// also clears every cart's draft on disk - otherwise the very carts the worker just chose to throw away would
  /// quietly reappear the next time anyone opens this center, which would make the "Discard" button a lie.
  Future<bool> _confirmDiscardCart(String title) async {
    final unsold = await _unsoldCartIds();
    if (unsold.isEmpty) return true;
    if (!mounted) return false;
    final many = unsold.length > 1;
    final String what;
    if (many) {
      what = '${unsold.length} carts have not been sold yet, and leaving this screen discards them all. Continue?';
    } else if (unsold.single == _cartId) {
      what = 'The current cart has not been sold yet, and leaving this screen discards it. Continue?';
    } else {
      what = '"${_slots.byId(unsold.single)?.name}" has not been sold yet, and leaving this screen discards it. Continue?';
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(what),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(many ? 'Discard carts' : 'Discard cart')),
        ],
      ),
    );
    if (confirmed ?? false) {
      for (final c in _slots.carts) {
        await widget.cartStore.clear(cartId: c.id);
      }
      return true;
    }
    return false; // dismissed (e.g. tapped outside) counts as "no"
  }

  /// The ids of the carts with unsold lines: the showing one from memory, the others from their saved drafts.
  Future<List<String>> _unsoldCartIds() async {
    final out = <String>[];
    for (final c in _slots.carts) {
      if (c.id == _cartId) {
        if (_lines.isNotEmpty) out.add(c.id);
        continue;
      }
      final lines = await widget.cartStore.load(widget.center.id, cartId: c.id, maxAge: _cartSettings.life);
      if (lines != null && lines.isNotEmpty) out.add(c.id);
    }
    return out;
  }

  /// Pushes StockPage on top of this screen, rather than switching away from the cart the way
  /// _onSwitchCenterPressed does, so a worker checking what's left mid-sale doesn't lose anything already
  /// added. widget.fetchPackages is passed straight through, same as _onSwitchCenterPressed does for
  /// SelectCenterPage, so a widget test that already overrides this page's own inventory fixture sees the
  /// exact same fixture there too. StockPage itself never sells anything - it only ever hands back the PKPRs a
  /// worker multi-selected there (or nothing, if they popped it without selecting any), which _addGroupsToCart
  /// turns into real cart lines the same way typing a PKPR by hand already does.
  Future<void> _onViewStockPressed() async {
    final selected = await Navigator.of(context).push<List<PkprGroup>>(
      MaterialPageRoute(
        builder: (_) => StockPage(center: widget.center, fetchPackages: _fetchPackagesForStockPage, workerEmail: _session.email),
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    await _addGroupsToCart(selected);
  }

  /// Adds every PKPR a worker multi-selected on StockPage to the cart. In "each" pricing mode this walks
  /// through the usual qty/price/dose dialog for each one in turn - the same dialog a single typed-PKPR add
  /// already uses, so pricing a batch this way never asks for anything this app doesn't already ask for one at
  /// a time, and backing out of one (Cancel) just skips that one rather than losing the rest of the batch. In
  /// either cart-wide mode (total/perMg) a price typed per item wouldn't do anything - it's about to be
  /// overwritten by _recomputeCartPricing below regardless - so those go straight in at qty 1 with a
  /// placeholder price, and a worker can still adjust the quantity afterward by tapping the line like any
  /// other. Merging into an existing line uses the exact same rule _onAddPkpr already does.
  Future<void> _addGroupsToCart(List<PkprGroup> groups) async {
    final priceEditable = _pricingMode == CartPricingMode.each;
    for (final group in groups) {
      CartLine added;
      if (priceEditable) {
        if (!mounted) return;
        final line = await _showLineDialog(group, priceEditable: true);
        if (line == null) continue; // the worker backed out of just this one - keep going with the rest
        added = line;
      } else {
        added = CartLine(group: group, qty: 1, priceCentsEach: 0);
      }
      if (!mounted) return;
      setState(() {
        final i = _lines.indexWhere((l) =>
            l.productGuid == added.productGuid && (!priceEditable || l.priceCentsEach == added.priceCentsEach) && l.dose == added.dose);
        if (i != -1) {
          _mergeWithinLineCap(i, added);
        } else {
          _lines.add(added);
        }
      });
    }
    _recomputeCartPricing();
  }

  /// Back to the center picker (SelectCenterPage), for a worker whose account can act for more than one -
  /// select_center_page.dart's own _open() only ever reaches CartPage via pushReplacement, so without this
  /// there is no way back to it short of restarting the app. Clears the whole nav stack down to just the
  /// picker (the same pushAndRemoveUntil shape goToSignIn uses) rather than pushing on top of this CartPage,
  /// so switching centers twice in a row can't pile up a chain of abandoned carts underneath.
  Future<void> _onSwitchCenterPressed() async {
    if (!await _confirmDiscardCart('Switch service center?')) return;
    if (!mounted) return;
    final demo = widget.demo;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => demo != null
            // The demo stays the demo (its picker, its functions): nothing reached from it leaves the phone.
            ? SelectCenterPage.demo(
                demo: demo, spec: widget.spec, sessionStore: widget.sessionStore, resilienceOptions: widget.resilienceOptions)
            : SelectCenterPage(
          session: _session,
          spec: widget.spec,
          sessionStore: widget.sessionStore,
          fetchLicenses: widget.fetchLicenses,
          // The plain /p/packages fetch, not _resilient's: the next CartPage wraps it in its own merge and fallbacks,
          // and the stock page merges it itself (SP-D10); a state-only or cached fallback from here would reach the
          // stock page looking like the server's own rows.
          fetchCenterPackages: widget.fetchPackages,
          resilienceOptions: widget.resilienceOptions,
          fetchRawPackagesFromState: widget.fetchRawPackagesFromState,
          uploadInventorySnapshot: widget.uploadInventorySnapshot,
          submitCoaForLot: widget.submitCoaForLot,
          deviceIdStore: widget.deviceIdStore,
        ),
      ),
      (route) => false,
    );
  }

  /// A worker's own deliberate sign-out, not the "your session can't be renewed" kind goToSignIn also handles -
  /// same destination and same storage-clearing either way, just with no message banner on the sign-in form
  /// since nothing went wrong here.
  Future<void> _onSignOutPressed() async {
    if (!await _confirmDiscardCart('Sign out?')) return;
    if (!mounted) return;
    await goToSignIn(context, spec: widget.spec, sessionStore: widget.sessionStore);
  }

  /// Null when the cart's stock is fresh enough, or still sellable as the state has it now; else why the sale must not
  /// be sent (SM-25, SM-D20). Every lot a line draws from (allocateLots) is checked with saleLineRefusal, the sale
  /// worker's own rule. A state system that can't be read refuses the sale too: it is never sent unchecked.
  Future<String?> _recheckOldStock() async {
    final readAt = _stockReadAt;
    if (readAt != null && widget.now().difference(readAt) <= widget.resilienceOptions.stockRecheckAge) return null;
    final List<Object?> raw;
    try {
      raw = await widget.fetchRawPackagesFromState(widget.center.id, accessToken: _session.accessToken);
    } catch (e) {
      return "Couldn't check the stock with the state system ($e), so the sale was never attempted.";
    }
    final fresh = <int, Map<String, Object?>>{};
    for (final r in raw) {
      if (r is Map && r['id'] is num) fresh[(r['id'] as num).toInt()] = Map<String, Object?>.from(r);
    }
    for (final l in _lines) {
      for (final (lot, take) in allocateLots(l.group.lots, l.qty) ?? const <(Package, int)>[]) {
        final why = saleLineRefusal(fresh[lot.id], l.productGuid, take);
        if (why != null) return why;
      }
    }
    if (mounted) setState(() => _stockReadAt = widget.now());
    return null;
  }

  /// The first line holding more units than its lots have, or null (SM-17).
  CartLine? _overStockLine() {
    for (final l in _lines) {
      if (allocateLots(l.group.lots, l.qty) == null) return l;
    }
    return null;
  }

  Future<void> _onSellPressed() async {
    final over = _overStockLine();
    if (over != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Only ${over.group.quantity} of ${over.productGuid} in stock: reduce the line. Nothing was sent.')));
      return;
    }
    final saleDate = await _showSellDialog();
    if (saleDate == null || !mounted) return; // the worker cancelled
    await _sell(saleDate);
  }

  /// Shows the cart's own confirmation dialog (lines/total, a sale date defaulting to today but changeable via
  /// the platform date picker) and returns the date to sell as of, or null if the worker cancelled. Doesn't
  /// touch _lines or the network itself - that's _sell's job once this returns a real date.
  Future<DateTime?> _showSellDialog() {
    var saleDate = DateTime.now();
    String fmt(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final totalCents = _lines.fold<int>(0, (sum, l) => sum + l.totalCents);
    final totalUnits = _lines.fold<int>(0, (sum, l) => sum + l.qty);
    return showDialog<DateTime>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Confirm sale'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_lines.length} line(s), $totalUnits unit(s), total ${money(totalCents)}.'),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Sale date: '),
                  Text(fmt(saleDate)),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: saleDate,
                        // A sale can be backdated (a worker catching up on a busy day) but never postdated -
                        // same bound parseSaleDate enforces on the server side (selling.py/selling.dart).
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) setDialogState(() => saleDate = picked);
                    },
                    child: const Text('Change'),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(saleDate), child: const Text('Confirm sale')),
          ],
        ),
      ),
    );
  }

  /// Turns every cart line into one or more sale records, splitting a line's own qty across its underlying
  /// lots (group.lots - already sorted smallest-quantity-first, see PkprGroup's own comment) rather than
  /// trusting a single lot to cover the whole line. Each lot absorbs as much of the line's qty as it currently
  /// holds; whatever doesn't fit spills into the next lot, and so on - so the smallest lot/transfer is always
  /// the one that finishes depleting first, exactly the rotation public_packages' server-side comment wants,
  /// just carried out here (where the actual sale quantity is known) instead of guessed at by the server ahead
  /// of time. A worker never sees this happen: the cart only ever showed one merged line for this PKPR, and
  /// still does.
  ///
  /// If every lot together still falls short of what the line asks for - stock moved since this line was added
  /// or last edited, the one case _showLineDialog's own cap can't catch, since it only validates against the
  /// snapshot taken when the dialog opened - whatever's left over still goes out, against the largest lot,
  /// rather than being silently dropped: the state system's own count is always the one that actually decides
  /// whether a sale goes through, the same as every quantity mismatch already works elsewhere on this page.
  List<Map<String, Object?>> _buildSaleRecords(DateTime saleDate) {
    final records = <Map<String, Object?>>[];
    for (final l in _lines) {
      // SM-17: the lot that expires first gives units first (allocateLots, SM-D29). A line beyond every lot never
      // gets this far: _onSellPressed refuses it (_overStockLine), so nothing is ever put on the last lot.
      final takes = allocateLots(l.group.lots, l.qty);
      if (takes == null) throw StateError('${l.productGuid}: ${l.qty} units but only ${l.group.quantity} in stock');
      for (final (lot, take) in takes) {
        records.add(buildSale(
          {...lot.toSaleItem(), 'serviceCenterId': widget.center.id},
          l.priceCentsEach,
          saleDate,
          dose: l.dose,
          qty: take,
        ));
      }
    }
    return records;
  }

  /// Submits every current cart line as one sale (shared/flows/sale.yaml's `sale` flow): all lines go up in a
  /// single request so the state system gives them all the same sale number, matching how the real web app's
  /// own Sell button works (mazama_sales/src/mazama_sales/state/client.py's create_sales). Only clears the
  /// cart on a confirmed success - see _showSaleFailureDialog for why a failure is never treated as "safe to
  /// just clear and move on" or even "safe to just try again" without first checking which kind of failure it
  /// was.
  Future<void> _sell(DateTime saleDate) async {
    setState(() => _selling = true);
    final client = widget.httpClientFactory();
    // Built up front, before anything that can throw SessionExpired - purely local (reads _lines, widget.center,
    // saleDate), so there's no reason it can't be ready in time to report to _queueFailedSale if the session
    // can't be renewed below. Building it here instead of after the renewal check changes nothing about what
    // gets sent to the state: the exact same records are used either way.
    final records = _buildSaleRecords(saleDate);
    // Set just before the sale flow runs: an unexpected failure before then can't have sent anything.
    var saleFlowStarted = false;
    var saleConfirmed = false;
    try {
      // A write is exactly the kind of call ensureFreshSession exists to protect, and it's too important to
      // leave entirely to the periodic timer's own 30-second cadence lining up in time - check again right
      // before this one specifically.
      final fresh = await ensureFreshSession(_session, widget.spec, client: client, now: widget.now);
      if (!mounted) return;
      if (fresh.accessToken != _session.accessToken) {
        setState(() => _session = fresh);
        await widget.sessionStore.save(fresh.toJson());
      }

      // SM-25: stock read longer ago than stockRecheckAge is read from the state again, and a line that is gone or
      // can't be sold any more is refused with the sale worker's own words. Nothing has been sent at this point.
      final refusal = await _recheckOldStock();
      if (refusal != null) {
        client.close();
        if (!mounted) return;
        setState(() => _selling = false);
        await _showSaleFailureDialog(refusal, outcome: SaleOutcome.notSent);
        return;
      }

      final saleSpec = await widget.saleSpec;
      saleFlowStarted = true;
      final result = await runFlow(saleSpec, 'sale', {'access_token': _session.accessToken, 'records': records},
          client: client, allowedHosts: currentAllowedHosts());
      final created = result['created'];
      if (!looksLikeConfirmedSale(created, records.length)) {
        // The state answered with *something* (flow_runner.dart's own then_require already confirmed the body
        // wasn't empty), but not something that actually looks like a confirmed sale for every record just
        // sent - a changed response shape, or a logical-error body that happens to be non-empty, would both
        // otherwise slip past a plain truthy check and get waved through as a success. Treated exactly like
        // any other unconfirmed reply (see sale_outcome.dart): never safe to just clear the cart over this,
        // and queued for this center's own staff to review via the same webapp queue a SessionExpired failure
        // below already uses - this is in fact the single case that queue most needs to catch, since the state
        // may genuinely have this sale on file even though this device can't confirm it.
        unawaited(_queueFailedSale(
          records,
          '[uncertain] the state answered 200 but the response did not look like a confirmed sale: $created',
        ));
        // The network attempt is over by this point - what's left is a modal dialog the worker has to read and
        // dismiss, not more work in flight. _selling has to come down *before* that await, not after (left to
        // the finally block below): otherwise the Sell button keeps showing its spinner (an indeterminate,
        // perpetually-animating CircularProgressIndicator) for the whole time this dialog sits open waiting on
        // the worker, which in a widget test means pumpAndSettle can never reach a settled frame and times out.
        client.close();
        if (!mounted) return;
        setState(() => _selling = false);
        await _showSaleFailureDialog(
          'The state system answered, but not with what a confirmed sale normally looks like.',
          outcome: SaleOutcome.uncertain,
        );
        return;
      }

      // Fire-and-forget, deliberately: the sale itself is already done by this point (the line above is what
      // actually recorded it with the state), so a problem logging who made it must never look like the sale
      // failed, retry the sale, or hold up the snackbar/cart-clear below for a server this app otherwise never
      // depends on being reachable at all (see packages_client.dart/label_client.dart's own file comments).
      saleConfirmed = true;
      unawaited(_logSaleAttribution(records, created));

      if (!mounted) return;
      _rememberSoldDose(_cartId, _lines);
      setState(() => _lines.clear());
      _publishTimerWidget();
      // The sale just succeeded, so whatever draft was on disk for this cart is stale the instant this
      // runs - nothing left in it should ever come back on a future restore. Only this cart (MC-D7).
      await widget.cartStore.clear(cartId: _cartId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.demo != null
              ? 'Demo sale: nothing was sent. The demo stock stays as it was.'
              : 'Sale recorded with the state system.')));
    } on SessionExpired catch (e) {
      // This is specifically "the state's own sign-in refused to renew or re-authenticate" - the shape a
      // breaking change on the state's side would take (as opposed to the sale itself being refused for an
      // ordinary reason, which is the FlowError branch below and never queued this way). Fire-and-forget,
      // same reasoning as _logSaleAttribution: queuing this for review must never block, delay, or change the
      // trip back to sign-in that was already happening regardless.
      // Never e.message: it carries the renew flow's error text (session.dart's sessionFailureReportText).
      unawaited(_queueFailedSale(records, sessionFailureReportText(e)));
      client.close();
      if (!mounted) return;
      setState(() => _selling = false);
      await goToSignIn(context, spec: widget.spec, sessionStore: widget.sessionStore, message: e.message);
    } on SessionRenewalUnavailable catch (e) {
      // Nothing was sent at all - the state system just couldn't be reached to refresh the sign-in first. This
      // is NOT a dead session (unlike SessionExpired above), so this never signs the worker out or touches
      // sessionStore/the cart: the exact same session and cart are still sitting here once the state is
      // reachable again, so Sell can simply be pressed again. Still queued the same way a SessionExpired
      // failure is, so this center's own staff have visibility even if the worker gives up rather than
      // retrying.
      unawaited(_queueFailedSale(records, '[notSent] ${sessionFailureReportText(e)}'));
      // Same reasoning as the shape-mismatch branch above: _selling has to come down before this dialog await,
      // not after, or the Sell button's spinner keeps animating under the modal the whole time it's open.
      client.close();
      if (!mounted) return;
      setState(() => _selling = false);
      await _showSaleFailureDialog(
        'Could not reach the state system to refresh the sign-in, so the sale was never attempted.',
        outcome: SaleOutcome.notSent,
      );
    } on FlowError catch (e) {
      // Queued for this center's own staff to review (sale_failure_client.dart/the webapp's own sale-review
      // page) regardless of which way this was classified - not just the SessionExpired case above - so a
      // sale that didn't go through has a record somewhere other than a dialog the worker might just dismiss
      // and forget. The classification is computed once and reused for both the queue entry and the dialog, so
      // they can never disagree with each other about what kind of failure this was.
      final outcome = classifySaleFailure(e);
      unawaited(_queueFailedSale(records, '[${outcome.name}] ${e.message}'));
      // Same reasoning as the two branches above: bring _selling down before the dialog await, not after.
      client.close();
      if (!mounted) return;
      setState(() => _selling = false);
      await _showSaleFailureDialog(e.message, outcome: outcome);
    } catch (e) {
      // Anything else (a bug, a spec mistake, a failing local store). Once the sale flow has started this is
      // never assumed to be "not sent" - the same rule as salejobs.py's own catch-all - and, as there, only the
      // exception's type goes into the queue entry, not its text.
      debugPrint('unexpected ${e.runtimeType} while selling: $e');
      // The state already confirmed this sale (e.g. clearing the saved draft failed): nothing about the sale is in
      // doubt, so no dialog suggests it might be.
      if (saleConfirmed) return;
      final outcome = saleFlowStarted ? SaleOutcome.uncertain : SaleOutcome.notSent;
      unawaited(_queueFailedSale(records, '[${outcome.name}] unexpected ${e.runtimeType} while selling'));
      client.close();
      if (!mounted) return;
      setState(() => _selling = false);
      await _showSaleFailureDialog(
        saleFlowStarted
            ? 'Something unexpected (${e.runtimeType}) happened while sending the sale.'
            : 'Something unexpected (${e.runtimeType}) happened before the sale was sent.',
        outcome: outcome,
      );
    } finally {
      client.close();
      if (mounted) setState(() => _selling = false);
    }
  }

  /// Reports the sale just confirmed to Mazama's own server (see sale_log_client.dart's own file comment for
  /// why - attribution, not the sale itself) and swallows anything that goes wrong doing it. This is the one
  /// place in the whole page where a failure is deliberately never shown to the worker and never changes
  /// anything about the cart or the sale: by the time this runs the real sale already succeeded, so the worst
  /// case here is that one sale goes un-attributed in the weekly report - not that the sale itself is in doubt.
  Future<void> _logSaleAttribution(List<Map<String, Object?>> records, Object? response) async {
    try {
      final deviceId = await widget.deviceIdStore.idOrCreate();
      await widget.postSaleLog(widget.center.id, workerEmail: _session.email, deviceId: deviceId, request: records, response: response);
    } catch (e) {
      debugPrint('sale-log attribution failed (sale itself was not affected): $e');
    }
  }

  /// Reports any sale attempt this device could not confirm actually went through - not only the original
  /// "sign-in broke mid-sale" case (see sale_failure_client.dart's own file comment), but every branch in
  /// _sell above that doesn't end in a confirmed success: an ordinary rejected/unconfirmed FlowError, a
  /// shape-mismatched 200 that doesn't look like real confirmed records, and a session renewal that simply
  /// couldn't reach the state system at all. All of them land in the exact same center-facing review queue
  /// (the webapp's own /c/{slug}/sale-review page) a reviewer already uses to resubmit or discard a queued
  /// failure by hand - so a sale that didn't go through always has a record somewhere other than a dialog the
  /// worker might simply dismiss and never mention to anyone. Swallows anything that goes wrong doing it, same
  /// as _logSaleAttribution: this is a record for later human review, never something that can affect what the
  /// worker sees now, and nothing here ever retries or resubmits a sale itself.
  Future<void> _queueFailedSale(List<Map<String, Object?>> records, String reason) async {
    try {
      final deviceId = await widget.deviceIdStore.idOrCreate();
      await widget.postSaleFailure(widget.center.id, workerEmail: _session.email, deviceId: deviceId, reason: reason, request: records);
    } catch (e) {
      debugPrint('queuing the failed sale for review did not work (sign-in still proceeds): $e');
    }
  }

  /// Explains a failed sale in a way that actually matches what might have happened - see sale_outcome.dart.
  /// Either way the cart is left exactly as it was (never cleared on failure): a notSent failure means nothing
  /// changed server-side, so the worker can fix whatever was wrong and hit Sell again; an uncertain one means
  /// this device genuinely doesn't know, so the only safe move is to go check before anyone touches Sell again.
  /// [outcome] always comes from the caller, which knows what happened (classifySaleFailure for a FlowError);
  /// it is never re-derived from [message]'s wording (SM-12).
  Future<void> _showSaleFailureDialog(String message, {required SaleOutcome outcome}) {
    final notSent = outcome == SaleOutcome.notSent;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(notSent ? 'The sale was not sent' : 'The sale may or may not have been recorded'),
        content: Text(notSent
            ? '$message\n\nNothing was recorded with the state system - the cart is unchanged, so it is safe to try again.'
            : '$message\n\nThe state system did not confirm this clearly, so it is NOT safe to just try again - that '
                'risks reporting the same sale twice. Check the state system\'s own sales list for this center before '
                'resubmitting, or ask whoever manages that account.'),
        actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
      ),
    );
  }

  // ---- Several carts (specs/multi-cart) ----

  /// The cart button at the top right: tap for the carts sheet, long-press to bulk sell the showing cart. Its badge
  /// says how many carts there are once there's more than one. An InkResponse rather than an IconButton because an
  /// IconButton has no long press (and its tooltip would take the long press for itself).
  Widget _cartButton() {
    final count = _slots.carts.length;
    return Semantics(
      button: true,
      label: 'Carts',
      hint: 'Long press to bulk sell',
      child: InkResponse(
        key: const Key('cartsButton'),
        onTap: _selling ? null : _onCartsPressed,
        onLongPress: _selling ? null : _onBulkSellPressed,
        radius: 24,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Badge(
            isLabelVisible: count > 1,
            label: Text('$count'),
            child: const Icon(Icons.shopping_cart_outlined),
          ),
        ),
      ),
    );
  }

  /// Every cart with how many lines it has, its timer if one is running, and the dose its session is timed against
  /// (MC-D14): its lines, or - once it's been sold and is empty - what it sold. The showing cart's lines and timer
  /// come from memory, the others' from disk. A saved timer past sessionTimerMaxAge counts as not running, as it would
  /// when that cart is shown.
  Future<List<_CartSummary>> _cartSummaries() async {
    final out = <_CartSummary>[];
    for (final c in _slots.carts) {
      final showing = c.id == _cartId;
      final lines = showing
          ? List<CartLine>.of(_lines)
          : (await widget.cartStore.load(widget.center.id, cartId: c.id, maxAge: _cartSettings.life) ?? const <CartLine>[]);
      var start = showing ? _sessionTimerStart : await widget.sessionTimerStore.load(widget.center.id, cartId: c.id);
      if (start != null && widget.now().difference(start) >= sessionTimerMaxAge) start = null;
      final dose = lines.isNotEmpty
          ? (psilocybinMg: cartPsilocybinMg(lines), booster: lines.any((l) => l.dose == doseSecondary))
          : await widget.sessionTimerStore
              .loadSoldDose(widget.center.id, cartId: c.id, maxAge: sessionTimerMaxAge, now: widget.now);
      out.add((slot: c, lines: lines.length, timerStart: start, dose: dose));
    }
    return out;
  }

  /// MC-D14: remembers what cart [cartId] just sold ([lines], one sale's worth), so the carts list can still time its
  /// client's session once the sold cart is empty. Fire-and-forget: the sale is already done.
  void _rememberSoldDose(String cartId, List<CartLine> lines) {
    unawaited(widget.sessionTimerStore
        .saveSoldDose(widget.center.id, cartPsilocybinMg(lines),
            booster: lines.any((l) => l.dose == doseSecondary), cartId: cartId, now: widget.now)
        .catchError((e) {
      debugPrint('could not remember the sold dose (nothing the worker is doing is affected): $e');
    }));
  }

  Future<void> _onCartsPressed() async {
    if (_selling) return;
    final summaries = await _cartSummaries();
    if (!mounted) return;
    final action = await showModalBottomSheet<_CartAction>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(child: _cartsSheet(context, summaries)),
    );
    if (action == null || !mounted || _selling) return;
    switch (action.kind) {
      case 'show':
        if (action.id != _cartId) await _showCart(_slots.withActive(action.id));
      case 'new':
        await _onNewCart();
      case 'rename':
        await _onRenameCart(action.id);
      case 'delete':
        final lines = summaries.where((c) => c.slot.id == action.id).map((c) => c.lines).firstOrNull ?? 0;
        await _onDeleteCart(action.id, lines);
      case 'bulk':
        await _onBulkSellPressed();
    }
  }

  Widget _cartsSheet(BuildContext context, List<_CartSummary> summaries) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Carts', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final c in summaries)
            ListTile(
              key: ValueKey('cart-${c.slot.id}'),
              leading: Icon(c.slot.id == _cartId ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(c.slot.name),
              subtitle: Row(
                children: [
                  Text(c.lines == 0 ? 'Empty' : '${c.lines} line${c.lines == 1 ? '' : 's'}'),
                  if (c.timerStart != null) ...[
                    const Text(' · '),
                    Flexible(child: _TimerText(start: c.timerStart!, now: widget.now, dose: c.dose)),
                  ],
                ],
              ),
              selected: c.slot.id == _cartId,
              onTap: () => Navigator.of(context).pop((kind: 'show', id: c.slot.id)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop((kind: 'rename', id: c.slot.id)),
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Rename ${c.slot.name}',
                  ),
                  IconButton(
                    onPressed: _slots.canRemove ? () => Navigator.of(context).pop((kind: 'delete', id: c.slot.id)) : null,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete ${c.slot.name}',
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _slots.canAdd ? () => Navigator.of(context).pop((kind: 'new', id: '')) : null,
                  icon: const Icon(Icons.add_shopping_cart),
                  label: Text(_slots.canAdd ? 'New cart' : 'New cart (at most $maxCartsPerCenter)'),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop((kind: 'bulk', id: '')),
                  icon: const Icon(Icons.copy_all_outlined),
                  label: Text('Bulk sell ${_slots.active.name}…'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _saveSlots() {
    unawaited(widget.cartSlotsStore.save(widget.center.id, _slots).catchError((e) {
      debugPrint('could not save the list of carts (nothing the worker is doing is affected): $e');
    }));
  }

  /// Shows the cart [slots] says is showing, in place of the one showing now: this cart's pricing controls are kept
  /// for when it comes back (MC-D4), its lines and timer are already on disk (saved as they changed), and the other
  /// cart's lines, timer and pricing controls are brought in. Also how a new cart is shown and how the cart after a
  /// deleted one is.
  Future<void> _showCart(CartSlots slots) async {
    _pricingByCart[_cartId] = _CartPricing(_pricingMode, _cartTotalController.text, _cartPerMgController.text, _cartTax);
    final pricing = _pricingByCart[slots.activeId] ?? _CartPricing(widget.initialPricingMode, '', '', CartTaxMode.included);
    _sessionTimerTicker?.cancel();
    _sessionTimerTicker = null;
    setState(() {
      _slots = slots;
      _lines.clear();
      _sessionTimerStart = null;
      _pricingMode = pricing.mode;
      _cartTotalController.text = pricing.total;
      _cartPerMgController.text = pricing.perMg;
      _cartTax = pricing.tax;
      _pricingError = null;
      _capError = null;
    });
    _saveSlots();
    final id = slots.activeId;
    final restored = await widget.cartStore.load(widget.center.id, cartId: id, maxAge: _cartSettings.life);
    if (!mounted || id != _cartId) return;
    if (restored != null) setState(() => _lines.addAll(restored));
    _recomputeCartPricing(persist: false);
    await _restoreSessionTimer();
  }

  /// The name dialog for a new cart and for renaming one (MC-D3: 1 to 30 characters, unique here). -> the trimmed name,
  /// or null when cancelled.
  Future<String?> _askCartName({required String title, required String initial, String? forId}) {
    final controller = TextEditingController(text: initial);
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Cart name'),
            validator: (v) => _slots.nameError(v ?? '', forId: forId),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.of(context).pop(controller.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _onNewCart() async {
    if (!_slots.canAdd) return;
    final name = await _askCartName(title: 'New cart', initial: _slots.nextName());
    if (name == null || !mounted || !_slots.canAdd || _slots.nameError(name) != null) return;
    await _showCart(_slots.withNew(name, now: widget.now));
  }

  Future<void> _onRenameCart(String id) async {
    final slot = _slots.byId(id);
    if (slot == null) return;
    final name = await _askCartName(title: 'Rename cart', initial: slot.name, forId: id);
    if (name == null || !mounted || _slots.byId(id) == null || _slots.nameError(name, forId: id) != null) return;
    setState(() => _slots = _slots.renamed(id, name));
    _saveSlots();
    _publishTimerWidget();
  }

  /// MC-D5: asks first when the cart has lines; clears its draft and timer; the last cart is never deleted.
  Future<void> _onDeleteCart(String id, int lines) async {
    final slot = _slots.byId(id);
    if (slot == null || !_slots.canRemove) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${slot.name}"?'),
        content: Text(lines == 0
            ? 'The cart is empty.'
            : 'Its $lines line${lines == 1 ? ' has' : 's have'} not been sold, and deleting the cart discards ${lines == 1 ? 'it' : 'them'}.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete cart')),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted || _slots.byId(id) == null || !_slots.canRemove) return;
    final wasShowing = id == _cartId;
    final rest = _slots.removed(id);
    await widget.cartStore.clear(cartId: id);
    await widget.sessionTimerStore.clear(cartId: id);
    if (!mounted) return;
    if (wasShowing) {
      await _showCart(rest);
    } else {
      setState(() => _slots = rest);
      _saveSlots();
      _publishTimerWidget();
    }
    _pricingByCart.remove(id);
  }

  // ---- Bulk sell (specs/multi-cart MC-D8 to MC-D13) ----

  /// Long-press on the cart button (or "Bulk sell…" in the carts sheet): the showing cart sold as the same sale N
  /// times. Refused up front for the same reasons Sell is disabled or refused.
  Future<void> _onBulkSellPressed() async {
    if (_selling) return;
    final why = _lines.isEmpty ? 'add items to the cart first.' : (_pricingError ?? _capError);
    final over = why == null ? _overStockLine() : null;
    final refusal = why ?? (over == null ? null : 'only ${over.group.quantity} of ${over.productGuid} in stock: reduce the line.');
    if (refusal != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bulk sell: $refusal')));
      return;
    }
    final choice = await _showBulkSellDialog();
    if (choice == null || !mounted) return;
    await _bulkSell(choice.date, choice.perSale);
  }

  /// The bulk sell dialog (MC-R5): how many sales, the sale date (as Sell's dialog), what one sale and all of them come
  /// to, and whether there's stock for them all (allocateBulkSales). -> the date and every copy's lot draw, or null when
  /// cancelled.
  Future<({DateTime date, List<List<List<(Package, int)>>> perSale})?> _showBulkSellDialog() {
    var saleDate = DateTime.now();
    String fmt(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final countController = TextEditingController(text: '2');
    final formKey = GlobalKey<FormState>();
    final perSaleCents = _lines.fold<int>(0, (sum, l) => sum + l.totalCents);
    final perSaleUnits = _lines.fold<int>(0, (sum, l) => sum + l.qty);
    final List<BulkLine> bulkLines = [for (final l in _lines) (lots: l.group.lots, qty: l.qty)];
    String? countError(String? text) {
      final n = int.tryParse((text ?? '').trim());
      if (n == null || n < 1) return 'Enter a whole number, at least 1';
      if (n > maxBulkSales) return 'At most $maxBulkSales sales at once.';
      final short = allocateBulkSales(bulkLines, n).shortLine;
      if (short != null) {
        final guid = _lines[short].productGuid;
        final perSale = _lines.where((l) => l.productGuid == guid).fold<int>(0, (sum, l) => sum + l.qty);
        return 'Only ${_lines[short].group.quantity} of $guid in stock: $n sales need ${perSale * n}.';
      }
      return null;
    }

    return showDialog<({DateTime date, List<List<List<(Package, int)>>> perSale})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final n = countError(countController.text) == null ? int.parse(countController.text.trim()) : null;
          return AlertDialog(
            scrollable: true,
            title: Text('Bulk sell ${_slots.active.name}'),
            content: Form(
              key: formKey,
              autovalidateMode: AutovalidateMode.always,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Each sale: ${_lines.length} line(s), $perSaleUnits unit(s), ${money(perSaleCents)}.'),
                  const SizedBox(height: 4),
                  Text(
                    'Every sale is recorded separately with the state system and gets its own sale number.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: countController,
                    decoration: const InputDecoration(labelText: 'Number of sales'),
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    onChanged: (_) => setDialogState(() {}),
                    validator: countError,
                  ),
                  if (n != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('All $n sales: ${perSaleUnits * n} unit(s), ${money(perSaleCents * n)}.',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('Sale date: '),
                      Text(fmt(saleDate)),
                      const Spacer(),
                      TextButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: saleDate,
                            // the same bounds as Sell's own dialog: backdated up to a year, never postdated
                            firstDate: DateTime.now().subtract(const Duration(days: 365)),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) setDialogState(() => saleDate = picked);
                        },
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              FilledButton(
                onPressed: n == null
                    ? null
                    : () {
                        if (!formKey.currentState!.validate()) return;
                        final perSale = allocateBulkSales(bulkLines, n).perSale;
                        if (perSale == null) return;
                        Navigator.of(context).pop((date: saleDate, perSale: perSale));
                      },
                child: Text(n == null ? 'Confirm' : 'Confirm $n sales'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// One copy's sale records: each line's units from the lots [sale] draws them from, at the line's price and dose -
  /// the same records _buildSaleRecords makes for a single sale, with the lots decided for every copy up front.
  List<Map<String, Object?>> _bulkSaleRecords(List<List<(Package, int)>> sale, DateTime saleDate) => [
        for (var i = 0; i < _lines.length; i++)
          for (final (lot, take) in sale[i])
            buildSale(
              {...lot.toSaleItem(), 'serviceCenterId': widget.center.id},
              _lines[i].priceCentsEach,
              saleDate,
              dose: _lines[i].dose,
              qty: take,
            ),
      ];

  /// MC-D11: the stock is always read again before a bulk sale, and every lot checked for everything all the copies
  /// draw from it, with the sale worker's rule. Null when it can all be sold; else why not. A state system that can't
  /// be read refuses the bulk sale: it is never sent unchecked.
  Future<String?> _recheckBulkStock(List<List<List<(Package, int)>>> perSale) async {
    final List<Object?> raw;
    try {
      raw = await widget.fetchRawPackagesFromState(widget.center.id, accessToken: _session.accessToken);
    } catch (e) {
      return "Couldn't check the stock with the state system ($e), so no sale was attempted.";
    }
    final fresh = <int, Map<String, Object?>>{};
    for (final r in raw) {
      if (r is Map && r['id'] is num) fresh[(r['id'] as num).toInt()] = Map<String, Object?>.from(r);
    }
    for (final d in bulkDrawPerLot(perSale)) {
      final why = saleLineRefusal(fresh[d.lot.id], d.lot.productGuid, d.units);
      if (why != null) return why;
    }
    if (mounted) setState(() => _stockReadAt = widget.now());
    return null;
  }

  /// Sends the copies one at a time (MC-D12): the sign-in checked before each, the stock read again before the first.
  /// The first copy not confirmed stops the run; it is queued for review the way a failed single sale is, and the
  /// copies after it are never attempted. Nothing is ever retried. All confirmed: the cart is cleared. Otherwise the
  /// cart is kept and _showBulkResultDialog says what happened (MC-D13).
  Future<void> _bulkSell(DateTime saleDate, List<List<List<(Package, int)>>> perSale) async {
    final count = perSale.length;
    final cartId = _cartId;
    final sales = [for (final sale in perSale) _bulkSaleRecords(sale, saleDate)];
    setState(() => _selling = true);
    final client = widget.httpClientFactory();
    var recorded = 0;
    var stopMessage = '';
    var stopOutcome = SaleOutcome.notSent;
    SessionExpired? expired;
    try {
      for (var k = 0; k < count; k++) {
        final records = sales[k];
        final tag = '[bulk ${k + 1} of $count]';
        var flowStarted = false;
        try {
          final fresh = await ensureFreshSession(_session, widget.spec, client: client, now: widget.now);
          if (!mounted) return;
          if (fresh.accessToken != _session.accessToken) {
            setState(() => _session = fresh);
            await widget.sessionStore.save(fresh.toJson());
          }
          if (k == 0) {
            final refusal = await _recheckBulkStock(perSale);
            if (refusal != null) {
              stopMessage = refusal;
              stopOutcome = SaleOutcome.notSent;
              break;
            }
          }
          final saleSpec = await widget.saleSpec;
          flowStarted = true;
          final result = await runFlow(saleSpec, 'sale', {'access_token': _session.accessToken, 'records': records},
              client: client, allowedHosts: currentAllowedHosts());
          final created = result['created'];
          if (!looksLikeConfirmedSale(created, records.length)) {
            unawaited(_queueFailedSale(
                records, '$tag [uncertain] the state answered 200 but the response did not look like a confirmed sale: $created'));
            stopMessage = 'The state system answered, but not with what a confirmed sale normally looks like.';
            stopOutcome = SaleOutcome.uncertain;
            break;
          }
          recorded++;
          unawaited(_logSaleAttribution(records, created));
        } on SessionExpired catch (e) {
          final outcome = flowStarted ? SaleOutcome.uncertain : SaleOutcome.notSent;
          unawaited(_queueFailedSale(records, '$tag [${outcome.name}] ${sessionFailureReportText(e)}'));
          expired = e;
          stopMessage = e.message;
          stopOutcome = outcome;
          break;
        } on SessionRenewalUnavailable catch (e) {
          unawaited(_queueFailedSale(records, '$tag [notSent] ${sessionFailureReportText(e)}'));
          stopMessage = 'Could not reach the state system to refresh the sign-in, so this sale was never attempted.';
          stopOutcome = SaleOutcome.notSent;
          break;
        } on FlowError catch (e) {
          final outcome = classifySaleFailure(e);
          unawaited(_queueFailedSale(records, '$tag [${outcome.name}] ${e.message}'));
          stopMessage = e.message;
          stopOutcome = outcome;
          break;
        } catch (e) {
          debugPrint('unexpected ${e.runtimeType} while bulk selling: $e');
          final outcome = flowStarted ? SaleOutcome.uncertain : SaleOutcome.notSent;
          unawaited(_queueFailedSale(records, '$tag [${outcome.name}] unexpected ${e.runtimeType} while selling'));
          stopMessage = flowStarted
              ? 'Something unexpected (${e.runtimeType}) happened while sending the sale.'
              : 'Something unexpected (${e.runtimeType}) happened before the sale was sent.';
          stopOutcome = outcome;
          break;
        }
      }
    } finally {
      client.close();
      // MC-D13: stock has moved (or may have), so the next sale reads it again first
      if (mounted) {
        setState(() {
          _selling = false;
          _stockReadAt = null;
        });
      }
    }
    if (!mounted) return;
    if (recorded == count) {
      _rememberSoldDose(cartId, _lines); // one client's dose: every copy is the same sale
      setState(() => _lines.clear());
      _publishTimerWidget();
      await widget.cartStore.clear(cartId: cartId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.demo != null
              ? 'Demo: $count sales, nothing was sent. The demo stock stays as it was.'
              : '$count sales recorded with the state system.')));
      return;
    }
    await _showBulkResultDialog(recorded: recorded, count: count, message: stopMessage, outcome: stopOutcome);
    final dead = expired;
    if (dead != null && mounted) {
      await goToSignIn(context, spec: widget.spec, sessionStore: widget.sessionStore, message: dead.message);
    }
  }

  /// What a bulk sale that stopped part way did (MC-D13), in the single sale's own words for the copy that stopped it
  /// (_showSaleFailureDialog, SM-12): not sent and safe, or maybe recorded and NOT safe to just send again.
  Future<void> _showBulkResultDialog(
      {required int recorded, required int count, required String message, required SaleOutcome outcome}) {
    final notSent = outcome == SaleOutcome.notSent;
    final stopped = recorded + 1;
    final untried = count - stopped;
    final paragraphs = [
      '$recorded of $count sales were recorded with the state system.',
      notSent
          ? 'Sale $stopped was not sent: $message\nNothing about it was recorded with the state system.'
          : 'Sale $stopped may or may not have been recorded: $message\nThe state system did not confirm it clearly, so it '
              'is NOT safe to just send it again - that risks reporting the same sale twice. Check the state system\'s own '
              'sales list for this center first, or ask whoever manages that account.',
      if (untried > 0) 'The other $untried ${untried == 1 ? 'sale was' : 'sales were'} never attempted.',
      'The cart is unchanged. Before selling it again, set the number of sales to what is still owed.',
    ];
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(recorded == 0 && notSent ? 'The sales were not sent' : '$recorded of $count sales recorded'),
        content: Text(paragraphs.join('\n\n')),
        actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
      ),
    );
  }

  /// The minimum number of significant characters (the PKPR's own hex part, not counting an optional typed
  /// "pkpr-" prefix) before suggestions appear at all - short enough to be useful, long enough that every
  /// single-digit keystroke doesn't flash the whole inventory at the worker.
  static const _minSearchChars = 2;

  /// Builds the PKPR entry field as a RawAutocomplete, reusing this state's own controller/focus node (so
  /// _onAddPkpr, the Add button, and _pkprFocus.requestFocus() after a successful add all keep working exactly
  /// as before) and suggesting one merged PKPR per entry (groupByPkpr - the server sends a separate row per
  /// underlying lot/transfer, and a worker typing a PKPR has no reason to see the same one listed twice),
  /// matched against the PKPR's own hex part so "pkpr-" (typed or not, any case) never has to be typed to get a
  /// match.
  Widget _pkprField() {
    return RawAutocomplete<PkprGroup>(
      textEditingController: _pkprController,
      focusNode: _pkprFocus,
      displayStringForOption: (g) => g.productGuid,
      optionsBuilder: (TextEditingValue value) {
        final needle = stripPkprPrefix(value.text).toLowerCase();
        final inventory = _inventory;
        if (needle.length < _minSearchChars || inventory == null) return const Iterable<PkprGroup>.empty();
        return groupByPkpr(inventory).where((g) => stripPkprPrefix(g.productGuid).toLowerCase().contains(needle));
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) => TextField(
        controller: controller,
        focusNode: focusNode,
        decoration: InputDecoration(labelText: 'PKPR', errorText: _lookupError),
        onSubmitted: (_) {
          onFieldSubmitted();
          _onAddPkpr();
        },
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200, maxWidth: 280),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: options.length,
              itemBuilder: (context, i) {
                final option = options.elementAt(i);
                final subtitle = option.productType.isEmpty ? '' : option.productType;
                return ListTile(
                  title: Text(option.productGuid),
                  subtitle: Text('$subtitle${subtitle.isEmpty ? '' : ' · '}${option.quantity} in stock'),
                  onTap: () => onSelected(option),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The cart-wide pricing controls (cart_pricing.dart) - mode switch, plus, for the two shared modes, the $
  /// field and tax choice. Placed above the line list, not inside any one line's own dialog, since it applies
  /// to every line in the cart at once and a worker should see it change before wondering why a line's price
  /// just moved out from under them.
  Widget _pricingBar() {
    final sharedMode = _pricingMode != CartPricingMode.each;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<CartPricingMode>(
            segments: const [
              ButtonSegment(value: CartPricingMode.each, label: Text('Price each item')),
              ButtonSegment(value: CartPricingMode.total, label: Text('Whole cart total')),
              ButtonSegment(value: CartPricingMode.perMg, label: Text('Cart \$/mg')),
            ],
            selected: {_pricingMode},
            onSelectionChanged: (selection) {
              setState(() => _pricingMode = selection.first);
              _recomputeCartPricing();
            },
          ),
          if (sharedMode) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _pricingMode == CartPricingMode.total ? _cartTotalController : _cartPerMgController,
                    decoration: InputDecoration(
                      labelText: _pricingMode == CartPricingMode.total
                          ? 'Total price for the whole cart'
                          : _lines.any((l) => l.group.mgFigure == MgFigure.psilocybin)
                              // SM-D31: some lines' only figure is the state's psilocybin, and are priced by it
                              ? 'Price per mg (TPE; mg psilocybin where no TPE is known), whole cart'
                              : 'Price per mg (TPE), whole cart',
                      prefixText: '\$',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => _recomputeCartPricing(),
                  ),
                ),
                const SizedBox(width: 12),
                // "The state record has no tax field, so tax is included in the unit prices" - same reasoning
                // mazama_sales' own cart.html states directly; this only decides whether the typed figure above
                // already has that baked in, or still needs the server's tax percent added before it's shared out.
                SegmentedButton<CartTaxMode>(
                  segments: [
                    const ButtonSegment(value: CartTaxMode.included, label: Text('Tax included')),
                    ButtonSegment(value: CartTaxMode.addPercent, label: Text('+${_cartSettings.taxPercent}% tax')),
                  ],
                  selected: {_cartTax},
                  onSelectionChanged: (selection) {
                    setState(() => _cartTax = selection.first);
                    _recomputeCartPricing();
                  },
                ),
              ],
            ),
            if (_pricingError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_pricingError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              )
            else if (_lines.isNotEmpty)
              _groupBreakdown(),
          ],
        ],
      ),
    );
  }

  /// "Edibles + extracts $X · Whole / dried / homogenized $Y" - shown only when the cart actually has lines in
  /// both manufacturer-agreement groups, the same condition mazama_sales' own cart.html gates its own
  /// breakdown row on (`v.both`), so a cart with only one group doesn't show a pointless $0 row for the other.
  Widget _groupBreakdown() {
    final groups = _lines.map((l) => groupOf(l.productType)).toSet();
    if (groups.length < 2) return const SizedBox.shrink();
    int totalFor(String g) => _lines.where((l) => groupOf(l.productType) == g).fold<int>(0, (sum, l) => sum + l.totalCents);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        'Edibles + extracts ${money(totalFor('A'))} · Whole / dried / homogenized ${money(totalFor('B'))}'
        ' (split ${_cartSettings.agreementEdible}:${_cartSettings.agreementDried} by manufacturer agreement)',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  /// The count last given to widget.onDraftCountChanged (-1: none yet).
  int _reportedDraftCount = -1;

  /// Every change to _lines rebuilds this page, so build is the one place that sees each new count; the call
  /// waits for the frame to end because the host's setState can't run during this build.
  void _reportDraftCount() {
    final report = widget.onDraftCountChanged;
    if (report == null || _lines.length == _reportedDraftCount) return;
    _reportedDraftCount = _lines.length;
    final count = _lines.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) report(count);
    });
  }

  @override
  Widget build(BuildContext context) {
    _reportDraftCount();
    final totalCents = _lines.fold<int>(0, (sum, l) => sum + l.totalCents);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.center.licenseName),
            Text(_slots.active.name, key: const Key('cartName'), style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(onPressed: _onViewStockPressed, icon: const Icon(Icons.inventory_2_outlined), tooltip: 'View stock'),
          IconButton(onPressed: _onSwitchCenterPressed, icon: const Icon(Icons.store_outlined), tooltip: 'Switch center'),
          IconButton(onPressed: _onSignOutPressed, icon: const Icon(Icons.logout), tooltip: 'Sign out'),
          _cartButton(),
        ],
      ),
      body: ResponsiveBody(
        child: Column(
          children: [
            // Everything above Total/Sell scrolls as one: the banners above the PKPR field can run to several lines
            // (an outage's wording, the dose summary), and on a short screen a fixed column overflowed instead of
            // scrolling. Total/Sell below stays pinned. When it all fits, nothing moves.
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        _inventoryBanner(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: Row(
                            children: [
                              Expanded(child: _pkprField()),
                              const SizedBox(width: 8),
                              IconButton(
                                  onPressed: _onScanPressed, icon: const Icon(Icons.qr_code_scanner), tooltip: 'Scan'),
                              FilledButton(onPressed: _onAddPkpr, child: const Text('Add')),
                            ],
                          ),
                        ),
                        const Divider(height: 24),
                        _pricingBar(),
                        const Divider(height: 24),
                      ],
                    ),
                  ),
                  if (_lines.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('Nothing in the cart yet.')),
                    )
                  else
                    SliverList.separated(
                      itemCount: _lines.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final l = _lines[i];
                        final title = l.productType.isEmpty ? l.productGuid : l.productType;
                        final doseLabel = l.dose == doseSecondary ? ' · secondary dose' : '';
                        final strainLabel = l.group.strain.isEmpty ? '' : '${l.group.strain} · ';
                        return ListTile(
                          title: Text(title),
                          subtitle: Text(
                              '${l.productGuid} · $strainLabel${l.qty} x ${money(l.priceCentsEach)} · ${l.group.tpeMg}${l.group.mgLabel} each$doseLabel'),
                          onTap: () => _onEditLine(i), // same dialog a fresh add uses, pre-filled from this line
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(money(l.totalCents)),
                              IconButton(
                                  onPressed: () => _onEditLine(i), icon: const Icon(Icons.edit_outlined), tooltip: 'Edit'),
                              IconButton(onPressed: () => _removeLine(i), icon: const Icon(Icons.close), tooltip: 'Remove'),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_capError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_capError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)),
                          Text(money(totalCents), style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      FilledButton(
                        onPressed:
                            (_lines.isEmpty || _selling || _pricingError != null || _capError != null) ? null : _onSellPressed,
                        child: _selling
                            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Sell'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inventoryBanner() {
    if (_inventoryError != null) {
      return Material(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text('Inventory did not load: $_inventoryError')),
              TextButton(onPressed: _loadInventory, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_inventory == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Downloading inventory...'),
          ],
        ),
      );
    }
    final degraded = _degradedInventoryNotice();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (degraded != null) degraded,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: _cartDoseSummary(),
        ),
      ],
    );
  }

  /// A plain, non-blocking strip above the usual inventory banner whenever _inventorySource (set by
  /// _loadInventory) is anything other than live - see resilient_inventory.dart's own file comment for what
  /// each fallback tier can and can't promise. Null (nothing shown) for the live, ordinary case, so a worker
  /// whose inventory loaded the normal way sees no change at all from before this feature existed.
  Widget? _degradedInventoryNotice() {
    final source = _inventorySource;
    if (source == null || source == InventorySource.live) return null;
    final String text;
    IconData icon = Icons.cloud_off;
    if (source == InventorySource.state) {
      // Which strains/TPEs are Mazama's last figures and which are the state's estimates (resilient_inventory.dart).
      text = stateSourceNotice(_inventory ?? const []);
    } else if (source == InventorySource.adhoc) {
      // This center isn't configured in Mazama yet - there is no "server down" problem to retry past, so this
      // case gets its own icon/wording rather than reusing the cloud-off "something's unreachable" framing the
      // other two tiers share. See coa_data_resolver.dart's own file comment for what's actually happening:
      // every lot's strain/potency is read directly from its own lab report, not from a sync this center never
      // had. _adhocGuidsResolved/_adhocGuidsTotal (ticked up live by _loadInventoryAsync's onResolved) says how
      // much of that is still in flight - once they're equal, this strip is just informational, no spinner.
      icon = Icons.description_outlined;
      final total = _adhocGuidsTotal;
      final resolved = _adhocGuidsResolved;
      final progress = total == 0
          ? ''
          : resolved >= total
              ? ' (every lot resolved)'
              : ' - resolving lab reports: $resolved of $total lots so far';
      text = "This center isn't configured in Mazama yet - strain and potency are read directly from each "
          'lot\'s own lab report$progress.';
    } else {
      final asOf = _inventoryAsOf;
      final age = asOf == null ? '' : ' from ${_formatAge(widget.now().difference(asOf))} ago';
      text = 'Neither Mazama\'s server nor the state system could be reached - showing the last inventory '
          'downloaded$age. Counts may no longer be accurate.${cachedEstimatesNote(_inventory ?? const [])}';
    }
    return Material(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
            if (source != InventorySource.adhoc || _adhocGuidsResolved >= _adhocGuidsTotal)
              TextButton(onPressed: _loadInventory, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  /// A short, worker-facing duration ("5 minutes", "3 hours", "2 days") - only ever shown for a cached
  /// inventory's own age (_degradedInventoryNotice above), so it only needs to read sensibly up to a few days,
  /// never fractions of a second or exact clock time.
  String _formatAge(Duration d) {
    if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
    if (d.inHours >= 1) return '${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
    final minutes = d.inMinutes < 1 ? 1 : d.inMinutes;
    return '$minutes minute${minutes == 1 ? '' : 's'}';
  }

  /// Replaces the old static "N packaged product(s) in this center's inventory" banner line with the cart's
  /// own running dose total - the figure a worker actually needs while building a sale, not a static inventory
  /// count. Shows mg TPE (the real per-unit dose, l.group.tpeMg) and mg raw psilocybin (weightPerUnit x
  /// analyteWeight - see CartPricingLine.analyteMgPerUnit's own comment for why these are two different
  /// numbers, and why only the second one is what the service-center duration table and the 50mg cap both
  /// read) side by side, then the minimum administration-session duration the mg-psilocybin figure implies -
  /// primary dose alone, then primary + secondary ("w/ booster", the worker's own term for the secondary
  /// dose) - and the session stopwatch (_sessionTimerRow) a worker starts once the client actually begins.
  Widget _cartDoseSummary() {
    if (_lines.isEmpty) {
      // Nothing to total yet - the empty-cart message below covers this. A timer still running (the cart was just sold
      // and its client's session goes on) stays in view, so it can be seen and reset (MC-D14).
      return _sessionTimerStart == null ? const SizedBox.shrink() : Align(alignment: Alignment.centerLeft, child: _sessionTimerRow());
    }
    // SM-D31: a line whose only figure is the state's psilocybin adds no TPE; the TPE total then says it leaves them out
    final tpeLines = _lines.where((l) => l.group.mgFigure == MgFigure.tpe);
    final tpeMg = tpeLines.fold<double>(0, (sum, l) => sum + l.group.tpeMg * l.qty);
    final tpePart = tpeLines.isEmpty
        ? 'TPE not known'
        : '${tpeMg.toStringAsFixed(1)} mg TPE${tpeLines.length < _lines.length ? ' (where known)' : ''}';
    final totalPsilocybinMg = _lines.fold<double>(0, (sum, l) => sum + l.group.weightPerUnit * l.group.analyteWeight * l.qty);
    final primaryOnlyMg = _lines
        .where((l) => l.dose == doseInitial)
        .fold<double>(0, (sum, l) => sum + l.group.weightPerUnit * l.group.analyteWeight * l.qty);
    // Null above the 50mg cap - analyteCapError already refuses a sale that high outright (see _capError), so
    // there's nothing meaningful left to show here; this just never gets the chance to look wrong.
    final primaryDuration = minSessionDuration(primaryOnlyMg);
    final bothDosesDuration = minSessionDuration(totalPsilocybinMg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$tpePart · ${totalPsilocybinMg.toStringAsFixed(1)} mg psilocybin in the cart'),
        if (primaryDuration != null && bothDosesDuration != null)
          Text('Duration: ${formatSessionDuration(primaryDuration)} · ${formatSessionDuration(bothDosesDuration)} w/ booster'),
        const SizedBox(height: 4),
        _sessionTimerRow(),
      ],
    );
  }

  /// A simple stopwatch the worker starts once the client's administration session actually begins, so they
  /// can see how long it's been running without reaching for a separate clock. Counts up from the moment
  /// "Start Timer" is tapped (_startSessionTimer, against widget.now() rather than the wall clock directly, so
  /// this stays fake-clock-friendly in tests same as every other timed thing on this page) - "Reset" clears it
  /// back to the button, ready for the next sale.
  Widget _sessionTimerRow() {
    if (_sessionTimerStart == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(onPressed: _startSessionTimer, child: const Text('Start Timer')),
      );
    }
    final elapsed = widget.now().difference(_sessionTimerStart!);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Elapsed: ${formatElapsed(elapsed)}'),
        const SizedBox(width: 12),
        TextButton(onPressed: _resetSessionTimer, child: const Text('Reset')),
      ],
    );
  }
}

/// A package's label as the cart shows it: the server's picture, or one drawn on the phone (CartPage's _labelFor).
sealed class _Label {
  const _Label();
}

class _ServerLabel extends _Label {
  final Uint8List bytes;
  const _ServerLabel(this.bytes);
}

class _PhoneLabel extends _Label {
  final Map<String, Object?> spec;
  const _PhoneLabel(this.spec);
}

/// One cart's pricing controls while another cart is showing (MC-D4).
class _CartPricing {
  final CartPricingMode mode;
  final String total;
  final String perMg;
  final CartTaxMode tax;
  const _CartPricing(this.mode, this.total, this.perMg, this.tax);
}

/// What the carts sheet asks CartPage to do: show, rename or delete cart [id], make a new cart, or bulk sell.
typedef _CartAction = ({String kind, String id});

/// A cart as the carts sheet lists it.
typedef _CartSummary = ({CartSlot slot, int lines, DateTime? timerStart, ({double psilocybinMg, bool booster})? dose});

/// A cart's running timer as the carts list shows it (MC-D14): the time left in its client's session, redrawn every
/// second against [now] (sessionTimeLeftText), or how long it has run when there's no dose to time it against.
class _TimerText extends StatefulWidget {
  final DateTime start;
  final DateTime Function() now;
  final ({double psilocybinMg, bool booster})? dose;
  const _TimerText({required this.start, required this.now, required this.dose});

  @override
  State<_TimerText> createState() => _TimerTextState();
}

class _TimerTextState extends State<_TimerText> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = widget.now().difference(widget.start);
    final dose = widget.dose;
    final left = dose == null ? null : sessionTimeLeftText(dose.psilocybinMg, elapsed, booster: dose.booster);
    return Text(left ?? 'elapsed ${formatElapsed(elapsed)}', overflow: TextOverflow.ellipsis);
  }
}
