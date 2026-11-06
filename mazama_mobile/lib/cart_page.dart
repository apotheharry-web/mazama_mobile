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
// A center can keep several carts at once: the cart button at the top right opens the list of
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
import 'coa_uploader.dart' show CoaUploadLot, QueueCoaUploads;
import 'center_status_client.dart' show CartSettings;
import 'center_status_client.dart' as center_status_client; // see CartPage.fetchCartSettings: same reason as below
import 'demo/demo_backend.dart'; // see CartPage.submitCoaForLot: avoids a same-name default-value ambiguity
import 'device_id.dart';
import 'dose.dart';
import 'features.g.dart';
import 'flow/flow_runner.dart';
import 'flow/flow_spec.dart';
import 'label_client.dart' as label_client; // see CartPage.fetchLabel: avoids a same-name default-value ambiguity
import 'label_preview.dart';
import 'licenses_client.dart';
import 'login_hosts_store.dart' show currentAllowedHosts;
import 'main.dart' show goToSignIn;
import 'mazama_core.dart' show CoreFunctions, MazamaCore;
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
import 'server_health.dart' show ServerHealth;
import 'server_link.dart' as server_link; // the defaults for the writes to Mazama's server
import 'selling.dart';
import 'session.dart';
import 'session_store.dart';
import 'session_timer_store.dart';
import 'resilience_options.dart';
import 'sync/center_stock.dart';
import 'sync/sync_datasets.dart' show Datasets, sourceServer, sourceState;
import 'sync/sync_tables.dart' show DatasetRow;
import 'sync/updated_line.dart' show updatedLine, updatedLineKey;
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

/// [lines] as the cap reads them (bulk_sale.dart's cartDrawLimits): each line's lots, units and dose.
List<DoseLine> doseLines(List<CartLine> lines) => [for (final l in lines) (lots: l.group.lots, qty: l.qty, dose: l.dose)];

/// The core's answer for [lines] sold once, counted from the figures of each lot that sale draws (not the product's
/// first lot alone) (cartDrawLimits, one draw and one cap call: what the cart shows, gates Sell on and times a session
/// by; refused when the core can't answer), and
/// [refusal], why the cap refuses it (the words beside Sell, which is then disabled), or null. Over the cap: "This sale
/// would total ...", or "This sale draws later lots and would total ..." when it draws past a product's first lot; any
/// other refusal in the core's own words (a figure that isn't a number, a unit whose psilocybin isn't known, the core
/// failing). A cart its lots can't cover is refused by the stock check when
/// Sell is pressed, and counted here as cartDrawLimits says; one the core can't draw at all has no figure
/// ([SaleLimits.failed]) and no cap words here: Sell refuses it when pressed with the draw's own words (a product whose
/// lots the core can't order, or the core failing: _saleRefusal), nothing sent. The product's first-lot figure is not
/// the cap's: it stays the line's tpeMg and price.
({SaleLimits limits, String? refusal}) cartDoseCheck(List<CartLine> lines, {CoreFunctions? core}) {
  final check = cartDrawLimits(doseLines(lines), 1, core: core);
  final v = check.limits.single;
  final perSale = check.perSale;
  final String? refusal;
  if (v.allowed || check.coreFailed) {
    refusal = null;
  } else {
    refusal = perSale == null ? v.error : copyRefusal(perSale, 0, v.error!, plain: true);
  }
  return (limits: v, refusal: refusal);
}

/// [lines]' limits as cartDoseCheck works them out.
SaleLimits cartSaleLimits(List<CartLine> lines, {CoreFunctions? core}) => cartDoseCheck(lines, core: core).limits;

/// What the cart's dose answer is kept against (CartPage's _cartLimitsNow): every lot of every line (its id, units left,
/// figures and draw-order inputs), the line's units and dose.
String _doseKey(List<CartLine> lines) => [
      for (final l in lines)
        [
          for (final lot in l.group.lots)
            [lot.id, lot.quantity, lot.weightPerUnit, lot.analyteWeight, lot.expires?.toIso8601String(), lot.stateOnly].join(','),
          l.qty,
          l.dose,
        ].join(';'),
    ].join('|');

/// How long a client's session lasts (the session table's length for [psilocybinMg], the booster included, the same
/// "w/ booster" figure the cart's dose summary shows) and how much of it is left [elapsed] in (sessionTimeLeft). The
/// length is the core's for that total (dose.dart's keptMgLimits).
String? sessionTimeLeftText(double psilocybinMg, Duration elapsed, {required bool booster}) =>
    sessionTimeLeft(keptMgLimits(psilocybinMg).session, elapsed, booster: booster);

/// How much of a session of [length] is left [elapsed] in, as the carts list shows a running timer: "1:52:10 left w/ booster" ("w/ booster" only when [booster]), then "Time up · 04:12 over" once it has run
/// out. Null when there is no length (over the limit per sale, or not known). The length is worked out once per cart
/// change, never per tick. [unknown]: the core couldn't work the length out, so it is the longest (6 hours), and
/// the text says so.
String? sessionTimeLeft(Duration? length, Duration elapsed, {required bool booster, bool unknown = false}) {
  if (length == null) return null;
  final text = _sessionTimeLeft(length, elapsed, booster: booster);
  return unknown ? "$text (the session length can't be worked out)" : text;
}

String _sessionTimeLeft(Duration length, Duration elapsed, {required bool booster}) {
  final left = length - elapsed;
  // A countdown never shows less time than is left: part of a second left counts as a whole one (a start time read
  // back from disk keeps only milliseconds, so this is the usual case, not an edge one).
  if (left > Duration.zero) {
    final shown = Duration(seconds: (left.inMicroseconds + Duration.microsecondsPerSecond - 1) ~/ Duration.microsecondsPerSecond);
    return '${formatElapsed(shown)} left${booster ? ' w/ booster' : ''}';
  }
  return 'Time up · ${formatElapsed(-left)} over';
}

/// A sale date as the Sell and Bulk sell dialogs show it: "2026-11-01".
String _saleDateText(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
  /// for a line the moment it's added (see mazama_sales/src/mazama_sales/selling/carts.py's own `add`).
  final String dose;

  CartLine({required this.group, required this.qty, required this.priceCentsEach, this.dose = doseInitial});

  String get productGuid => group.productGuid;
  String get productType => group.productType;

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

  /// The second of the steps around [fetchPackages] (see lib/sync/center_stock.dart's own file
  /// comment for all of them): a direct call to the real state system's own GetPackagedProducts, tried only when
  /// [fetchPackages] and the state's raw read both fail. Overridable for tests, so a widget test exercising a failed inventory load
  /// never makes a real network call for this fallback either - defaults to the real fetchPackagesFromState
  /// (state_packages_client.dart), referenced through the aliased import above for the same reason as
  /// fetchLabel.
  final Future<List<Package>> Function(int stateId, {required String accessToken}) fetchPackagesFromState;

  /// The RAW half of [fetchPackagesFromState] (state_packages_client.dart's fetchRawPackagesFromState) - used
  /// only for a CONFIGURED center's merged inventory load (sync/center_stock.dart, joined by sync/stock_merge.dart),
  /// since that merge needs mazama_sales' own enrichment (strain/tpeMg/coaAvailable/labelAvailable)
  /// layered onto the state's own fresher quantity, AND the unmapped records themselves to hand to
  /// [uploadInventorySnapshot] - [fetchPackagesFromState] above alone can't supply the second half.
  /// Overridable for tests for the same reason as fetchPackagesFromState. Defaults to the real
  /// fetchRawPackagesFromState, referenced through the aliased import above.
  final Future<List<Object?>> Function(int stateId, {required String accessToken}) fetchRawPackagesFromState;

  /// Posts a configured center's own fresh state read (sync/center_stock.dart's onStateRead, the raw
  /// records) back to mazama_sales' POST /p/inventory/{stateId}, so its mirror
  /// stays current from this device instead of waiting on the server's own sync.
  /// Called fire-and-forget after every successful merged load for a configured center - see
  /// _resilient (lib/sync/center_stock.dart's onStateRead). Overridable for tests for the same reason as fetchPackagesFromState. Defaults to the
  /// real upload through the app's server link (server_link.dart): while Mazama's server can't be reached the newest
  /// snapshot per center is kept and sent once it answers (catch_up_store.dart).
  final Future<Map<String, Object?>> Function(int stateId, List<Object?> records, {required String workerEmail, required String deviceId}) uploadInventorySnapshot;

  /// Checked once, right at the start of every _loadInventory, before [fetchPackages]/[fetchPackagesFromState]
  /// are ever tried - see coa_data_client.dart's own file comment. True (or this check itself failing, treated
  /// the same as true: see _loadInventoryAsync) runs the ordinary [_resilient] tiers. False switches this load entirely onto [resolveAdhocInventory] instead - a center Mazama's
  /// own server has never been configured for has nothing for [fetchPackages] (tier 1) to ever return anyway.
  /// Overridable for tests, so a widget test never makes a real network call for this either. Defaults to the
  /// real centerIsConfigured, referenced through the aliased import above for the same reason as fetchLabel.
  final Future<bool> Function(int stateId) centerIsConfigured;

  /// The cart's live settings from this center's server (tax percent, agreement split, units per line, cart
  /// life), or [CartSettings.fallback] when it can't say. Overridable for tests, so a widget test never makes a
  /// real network call for this either.
  final Future<CartSettings> Function(int stateId) fetchCartSettings;

  /// The shared core the cart prices with: null is this app's own (MazamaCore.instance); a test gives a
  /// fake to see the cart fail closed (a cart the core can't price can't be sold).
  final CoreFunctions? core;

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

  /// Run (fire-and-forget, from _ensureCoaForCartLine) right after a product is added to the cart at a
  /// CONFIGURED center, for each lot backing that PKPR that still has coaAvailable false - the
  /// "already built function" (configured_coa_submit.dart's submitCoaForLot, reusing coa_data_resolver.dart's
  /// own GetPackagedProductInfo -> newest-PDF -> downloadStateDocument -> uploadCoaParse chain) submitting that
  /// lot's lab report so mazama_sales can join it into the shared COA pipeline and queue a
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

  /// Called when [submitCoaForLot] failed because Mazama's server couldn't be reached: the lot is kept and
  /// submitted again once the server answers, with the session current then (server_link.dart's catch-up work).
  /// Overridable for tests; the real one keeps it in the app's catch-up file.
  final void Function(int stateId, {required String lotGuid, required int packageId, double? statePsilocybin}) keepCoaLotForLater;

  /// After each load of a CONFIGURED center that Mazama's server answered, every lot whose
  /// package says coaAvailable false is handed to the app's background uploader (coa_uploader.dart), which sends each
  /// report at the server's pace without holding up anything on this page. An unconfigured center's lots are queued
  /// by [resolveAdhocInventory] itself. Overridable for tests; the real one is the app's uploader (server_link.dart), the
  /// demo's does nothing.
  final QueueCoaUploads queueCoaUploads;

  /// Whether the background uploader has [lotGuid] waiting or being sent: the cart add's own submission
  /// (_ensureCoaForCartLine) skips such a lot, so its report isn't downloaded twice at once. Overridable for tests; the
  /// real one asks the app's uploader (server_link.dart), the demo's always says no.
  final bool Function(String lotGuid) coaUploadPending;

  /// The sync engine's datasets the cart keeps its stock in: every load keeps what it read as the center's
  /// center_stock copy, the last step (shown at any age with its age, sold from for up to 3 days, [stockTooOld]), and
  /// what Mazama's server last sent per package (strain, TPE, expiry) as the enrichment copy, filled back in when stock
  /// has to come from the state system alone (lib/sync/center_stock.dart, lib/sync/enrichment.dart). Null (the
  /// default) is the app's data folder's; tests pass their own folder's, so a widget test never reads or writes the
  /// real app-data directory, as cartStore/sessionTimerStore/deviceIdStore.
  final Datasets? datasets;

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
  /// report (phone_label.dart's drawPhoneLabelSpec - the shared mazama_core rules, run on the device), so the worker
  /// still has a label to compare against. Returns mazama_core's LabelSpec, drawn by LabelPreview; throws with the
  /// reason when even the phone can't make one (no lab report on file, a report that doesn't name the lot, ...).
  /// Overridable for tests, so a widget test never makes a real state-system call for it. Null (the default) is the real
  /// one, keeping what the phone read from the lab report in [datasets] (_drawLabel).
  final Future<Map<String, Object?>> Function(int stateId, String pkpr, {required String accessToken, String strain})? drawLabel;

  /// Forwarded straight through to the SelectCenterPage _onSwitchCenterPressed opens - same reasoning as
  /// SelectCenterPage's own field by this name: overridable so a widget test exercising "switch center" never
  /// makes a real GetApplicableLicenses call either. CartPage never calls this itself.
  final Future<List<License>> Function(String accessToken) fetchLicenses;

  /// Called (fire-and-forget, via _logSaleAttribution) right after a sale is confirmed with the state system,
  /// so Mazama's own server can log which worker made it - see sale_log_client.dart's own file comment for why.
  /// Overridable for tests, so a widget test never makes a real network call for this either, and can assert
  /// what this was called with without a sale-log failure ever being able to affect the sale itself. Defaults
  /// to the app's outbox (server_link.dart's queueSaleLog): the log is kept on the phone with a clientId
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
  /// Called with where the worker chose to take the photo from.
  final Future<List<String>> Function(ScanSource source) scanLabelText;

  /// Overridable for tests, so a widget test never makes a real network call for this either. Defaults to the
  /// real scanMatch (against Mazama's own public /p/scan-match/{state_id} - see scan_match_client.dart's own
  /// file comment), referenced through the aliased import above for the same reason as fetchLabel.
  final Future<ScanMatchResult> Function(int stateId, List<String> lines, {bool typed}) scanMatch;

  /// The same matcher (mazama_core's, through the FFI) run on this phone against the cart's own copy of the stock,
  /// for when [scanMatch] can't get an answer from the server (ScanMatchError.serverUnavailable); null from it
  /// when the core can't answer. Overridable for tests, defaulting to local_scan_match.dart's own.
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
  /// them), so they don't have to tap back to it themselves; defaults to the real app's default,
  /// CartPricingMode.total.
  final CartPricingMode initialPricingMode;

  /// Called with the draft cart's number of lines whenever it changes (and once when first known), so the page
  /// hosting this one (center_home_page.dart's Cart tab) can show it. Optional; null calls nothing.
  final ValueChanged<int>? onDraftCountChanged;

  /// Demo mode: the backend this cart's functions come from. Switch center stays in the demo, and
  /// a sale's success says nothing was sent. Null for a real sign-in.
  final DemoBackend? demo;

  /// The feature registry: the View stock button shows only while center_stock is on for this
  /// center's license type. The generated one in the app; tests pass a copy with features off.
  final Map<String, Feature> featureTable;

  /// Where the cart's own session stopwatch (_sessionTimerRow) persists its start time across app restarts -
  /// see session_timer_store.dart's own file comment for why. Overridable for tests, so a test never touches
  /// the real app-data directory for this either. Defaults to a real SessionTimerStore, same as cartStore's
  /// real-by-default pattern.
  final SessionTimerStore sessionTimerStore;

  /// Where this center's list of carts (names, which one is showing) is kept - see cart_slots.dart. Overridable for
  /// tests, real by default, as cartStore.
  final CartSlotsStore cartSlotsStore;

  /// The home-screen widget showing every cart's running timer (cart_timer_widget.dart): sent a fresh snapshot
  /// whenever a timer, a cart's lines or the list of carts changes. Overridable for tests; the real one does nothing
  /// where there's no native widget (a widget test).
  final CartTimerWidget cartTimerWidget;

  /// The app's server tracker (server_health.dart). Stock read from the state system alone (Mazama's
  /// server didn't answer, [InventorySource.state]) is loaded again once the tracker goes from offline to online: at
  /// once while the showing cart has no lines, else as soon as it has none (after a sale, or its lines removed), and
  /// never while a sale is being sent. Null: never (tests, the demo, the debug launch page).
  final ServerHealth? health;

  /// The center's stock as the sync engine keeps it (engine.watch of center_stock; null: none,
  /// as in tests and the demo). A copy newer than the one on screen is taken only while the cart has no lines and no
  /// sale is being sent; otherwise it waits until both hold (as the reload when the server comes back). Defaults to the
  /// app's link (server_link.dart's linkWatchStock), none while no link is set.
  final Stream<DatasetRow?>? Function(int stateId) watchStock;

  /// After a confirmed sale, asks for the center's stock to be refreshed (the sync engine's center_stock dataset,
  /// server_link.dart's linkRequestStockRefresh), never awaited. Overridable for tests.
  final void Function(int stateId) requestStockRefresh;

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
    this.core,
    this.resolveAdhocInventory = coa_data_resolver.resolveAdhocInventory,
    this.submitCoaForLot = server_link.linkSubmitCoaForLot,
    this.keepCoaLotForLater = server_link.rememberCoaLot,
    this.queueCoaUploads = server_link.queueCoaUploads,
    this.coaUploadPending = server_link.coaUploadPending,
    this.datasets,
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
    this.featureTable = features,
    this.health,
    this.requestStockRefresh = server_link.linkRequestStockRefresh,
    this.watchStock = server_link.linkWatchStock,
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

  /// The center's carts and which one is showing. _lines, _sessionTimerStart and the pricing
  /// controls below are always the showing cart's; the others' are on disk (lines, timer) or in _pricingByCart.
  CartSlots _slots = CartSlots.initial();
  String get _cartId => _slots.activeId;

  /// The pricing controls of every cart not showing, by cart id, while this page is open (each cart has its own). Not saved, the same
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

  /// Set by _recomputeCartPricing whenever the cart, sold now, would sell more than 50 mg of raw psilocybin in total on
  /// the lots it draws (each drawn lot's own figures), or can't be counted (a figure that isn't a number, a unit whose
  /// psilocybin isn't known, the core failing) (the core's cap, cartDoseCheck) - a wholly separate rule from _pricingError
  /// above (that one is about money; this one is about the state's own raw analyteWeight field and has
  /// nothing to do with price) and checked in every pricing mode, "each" included. Also blocks Sell, same as
  /// _pricingError, and shown near the Total/Sell row rather than next to the pricing controls, since it
  /// applies whether or not the cart-wide pricing controls are even showing.
  String? _capError;

  /// The core's answer for the cart sold now, on the lots it draws (cartDoseCheck), with the words beside Sell
  /// when it is refused, and the lines it was worked out for (_cartLimitsNow): the cap, the dose summary's total and
  /// session lengths, asked again only when the cart's lines change.
  ({SaleLimits limits, String? refusal})? _cartLimits;
  String? _cartLimitsKey;

  /// The cart's lines as their totals read them, each with its group (the core's group_of; null when it can't give one),
  /// worked out again only when a line's units, price or product type change; and their totals (the core's
  /// cartTotals; null when it can't add them up, and then the cart shows no total and can't be sold).
  List<CartTotalLine>? _totalLines;
  CartTotals? _cartTotals;
  String? _cartTotalsKey;

  void _refreshCartTotals() {
    final key = jsonEncode([for (final l in _lines) [l.qty, l.priceCentsEach, l.productType]]);
    if (key == _cartTotalsKey) return;
    final lines = <CartTotalLine>[
      for (final l in _lines) (qty: l.qty, priceCentsEach: l.priceCentsEach, group: groupOf(l.productType, core: widget.core)),
    ];
    _totalLines = lines;
    _cartTotals = cartTotals(lines, core: widget.core);
    _cartTotalsKey = key;
  }

  List<CartTotalLine> _totalLinesNow() {
    _refreshCartTotals();
    return _totalLines!;
  }

  CartTotals? _cartTotalsNow() {
    _refreshCartTotals();
    return _cartTotals;
  }

  /// The core's answer for the cart as it is now, on the lots its sale draws: kept while its lines (every lot's id,
  /// units left, figures and draw-order inputs; the line's units and dose) stay the same, asked again when they change.
  ({SaleLimits limits, String? refusal}) _cartLimitsNow() {
    final key = _doseKey(_lines);
    final kept = _cartLimits;
    if (kept != null && key == _cartLimitsKey) return kept;
    final fresh = cartDoseCheck(_lines);
    _cartLimits = fresh;
    _cartLimitsKey = key;
    return fresh;
  }

  /// Starts as widget.session but is kept up to date by _maybeRenewSession as it silently renews - the Sell
  /// action (and anything else this page does that needs a token) reads this field, never widget.session.
  late Session _session;

  /// Labels drawn on the phone this visit, by PKPR (_labelFor): a lab report doesn't change while the worker is
  /// at the counter, so adding the same package twice, or editing its line, doesn't download and read it again.
  /// A failed drawing isn't kept, so the next look tries again.
  final _drawnLabels = <String, Future<Map<String, Object?>>>{};
  Timer? _renewTimer;

  /// The center's stock (lib/sync/center_stock.dart): Mazama's server and the state at once,
  /// put together by the one merge rule (stock_merge.dart), else the state's own packages, else the stock last kept for
  /// the center at any age (shown with its age; [_onSellPressed] refuses to sell from it once it is older than
  /// ResilienceOptions.cacheMaxAge). The session is read fresh at every load (`() => _session`), so the state is read
  /// with whatever token _maybeRenewSession last put there. Whenever the state answered, that read is pushed to
  /// Mazama's server as the center's snapshot (widget.uploadInventorySnapshot), fire-and-forget: a failed push
  /// only means the server's copy stays one read behind. Handed down to StockPage/SelectCenterPage below
  /// (_fetchPackagesForStockPage) so they load the same way. Selling never goes through the sync engine.
  /// [CartPage.datasets], else the app's data folder's.
  late final Datasets _datasets = widget.datasets ?? Datasets.forDir(defaultSessionDataDir);

  late final CenterStock _resilient = CenterStock(
    fetchServer: widget.fetchPackages,
    fetchRawState: widget.fetchRawPackagesFromState,
    fetchFromState: widget.fetchPackagesFromState,
    datasets: _datasets,
    session: () => _session,
    now: widget.now,
    enableStateFallback: widget.resilienceOptions.enableStateFallback,
    onStateRead: (stateId, raw) => unawaited(() async {
      final deviceId = await widget.deviceIdStore.idOrCreate();
      await widget.uploadInventorySnapshot(stateId, raw, workerEmail: _session.email, deviceId: deviceId);
    }().catchError((_) {})),
  );

  /// Which tier _inventory actually came from, set by _loadInventory right alongside it - null until the first
  /// load finishes. Read by _body to show a banner whenever it's anything other than live: a worker should
  /// never mistake a cached or state-estimated count for Mazama's own real-time figure.
  InventorySource? _inventorySource;
  DateTime? _inventoryAsOf;

  /// When the stock now on screen was read (a kept copy: when it was read then), for the 3-day selling limit and the
  /// banner: never
  /// moved by a recheck or a sale. Null until stock has loaded.
  DateTime? _stockReadAt;

  /// When the state itself last confirmed the whole stock on screen (a load the state answered, or the bulk
  /// sale's read), and when it last confirmed each lot a sale re-read (by package id). A sale within
  /// ResilienceOptions.stockRecheckAge of either needs no read of its own. Null / empty after a load the state didn't
  /// answer (Mazama's server's rows alone, a kept copy), after a load a sale ran across or that ended under lines, after
  /// every sale sent whatever its outcome (the stock has moved, or may have), after an engine copy is taken, and when
  /// lines are brought back from a draft (they carry older lots).
  DateTime? _stateReadAt;
  final Map<int, DateTime> _lotsCheckedAt = {};

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

  /// The lots (lower case) onResolved has reported for this load, so a lot is counted once however many packages it has.
  final _adhocResolvedLots = <String>{};

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

  /// [CartPage.health] as last seen (offline or not), and whether the server came back while the stock showing is the
  /// state's alone, so it is loaded again once the cart is empty and no sale is being sent ([_reloadIfServerBack]).
  bool _wasOffline = false;
  bool _reloadWhenEmpty = false;

  void _onHealth() {
    final h = widget.health;
    if (h == null) return;
    final cameBack = _wasOffline && h.online;
    _wasOffline = h.offline;
    if (!cameBack || !mounted || _inventorySource != InventorySource.state) return;
    _reloadWhenEmpty = true;
    _reloadIfServerBack();
  }

  /// Loads the inventory again if the server came back while the stock was the state's alone ([_onHealth]) and the
  /// cart is now empty with no sale being sent. Called from the tracker, and wherever the cart may have just emptied
  /// (a line removed, a sale ended, another cart shown). Forgets the wait once the stock isn't the state's any more or
  /// the server is offline again (the next time it comes back starts it again).
  void _reloadIfServerBack() {
    _takeRefreshedStock(); // a refreshed copy waiting for the cart to empty
    if (!_reloadWhenEmpty || !mounted) return;
    if (_inventorySource != InventorySource.state || !(widget.health?.online ?? false)) {
      _reloadWhenEmpty = false;
      return;
    }
    if (_selling || _lines.isNotEmpty) return;
    _reloadWhenEmpty = false;
    _loadInventory();
  }

  /// The cart's settings: the built-in rules until the server's answer arrives, which may change the tax
  /// offered, the agreement split, the units allowed in one line and how old a draft may be to come back.
  CartSettings _cartSettings = CartSettings.fallback;

  /// False while [_cartSettings] are only the built-in ones because the server's (or a kept copy of them) couldn't be
  /// read: such a cart can't add tax or share a total between the two groups. False until they are read.
  bool _cartSettingsKnown = false;
  late final Future<(CartSettings, bool)> _cartSettingsFuture;

  /// The engine's copy of this center's stock, and the newest one not taken yet.
  StreamSubscription<DatasetRow?>? _stockWatch;
  DatasetRow? _refreshedStock;

  /// When a sale flow last started (any outcome: an uncertain sale may have moved stock too), a count raised when each
  /// sale flow starts and again when it ends (a load that a send ran across never vouches for its counts: counted
  /// rather than timed
  /// so a clock that doesn't move between the two can't hide it), and how many cart switches are between their clear and
  /// their restore (their lines are about to come back): no engine copy read before that sale, or taken in that gap,
  /// may go on screen (a count, so overlapping switches each hold it).
  DateTime? _stockMovedAt;
  int _saleSends = 0;
  int _switchingCarts = 0;

  /// When the load that failed started, so the rescue below takes only a copy read after it.
  DateTime? _loadStartedAt;

  void _onStockRow(DatasetRow? row) {
    if (row == null) return;
    _refreshedStock = row;
    _takeRefreshedStock();
  }

  /// Puts the engine's newer copy of the stock on screen, only when: the center is configured, the cart's own load has
  /// ended (or failed), the copy is newer than what is shown (and, after a failed load, was read after that load
  /// started), the copy was read after the last sale flow started, the showing cart has no lines, no sale is being
  /// sent, and no cart is being switched in.
  ///
  /// A copy taken never counts as the state's word: [_stateReadAt] and [_lotsCheckedAt] are cleared, so the next sale
  /// reads the state itself whatever the copy says. Only the cart's own state read at load, and the sale's own rechecks
  /// of the state, confirm stock. [_stockReadAt] becomes the copy's own read time (the 3-day limit and its age), and a
  /// copy older than the recheck age is shown as the kept copy with its
  /// age, as tier 3 is.
  void _takeRefreshedStock() {
    final row = _refreshedStock;
    if (row == null || !mounted) return;
    if (_centerConfigured != true || (_inventory == null && _inventoryError == null)) return;
    final failedLoad = _inventory == null;
    final against = failedLoad ? _loadStartedAt : _stockReadAt;
    if (against != null && !row.fetchedAt.isAfter(against)) {
      _refreshedStock = null; // not newer than what is shown, or older than the load that failed
      return;
    }
    final moved = _stockMovedAt;
    if (moved != null && !row.fetchedAt.isAfter(moved)) {
      _refreshedStock = null; // read before the last sale: its counts may still hold what that sale took
      return;
    }
    if (_selling || _switchingCarts > 0 || _lines.isNotEmpty) return; // waits for the cart to be empty and still
    _refreshedStock = null;
    final packages = centerStockPackages(row.body);
    if (packages == null) return;
    final old = stockTooOld(row.fetchedAt, widget.now(), widget.resilienceOptions.stockRecheckAge);
    setState(() {
      _inventory = packages;
      _inventoryError = null;
      _inventorySource = old
          ? InventorySource.cache
          : row.source == sourceState
              ? InventorySource.state
              : InventorySource.live;
      _inventoryAsOf = old ? row.fetchedAt : null;
      _stockReadAt = row.fetchedAt;
      _stateReadAt = null; // never the state's word: the next sale reads it
      _lotsCheckedAt.clear();
    });
    // A copy of the server's rows alone says which lots it holds no lab report for, as a load does. A merged
    // copy doesn't keep which of its rows the server sent (a row only the state listed has no report known, not a
    // missing one), so it queues nothing: the cart's next own load does, with the server's own keys.
    if (!old && row.source == sourceServer) {
      _queueMissingCoas(packages, serverKeys: {for (final p in packages) inventoryRowKey(p)});
    }
  }

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    try {
      _stockWatch = widget.watchStock(widget.center.id)?.listen(_onStockRow, onError: (Object _) {});
    } catch (_) {
      // no engine copy to follow: the cart loads its stock itself, as always
    }
    _pricingMode = widget.initialPricingMode;
    _cartSettingsFuture = _fetchCartSettingsOrFallback();
    _wasOffline = widget.health?.offline ?? false;
    widget.health?.addListener(_onHealth);
    _loadInventory();
    _restoreSlotsThenCart();
    _renewTimer = Timer.periodic(sessionCheckInterval, (_) => _maybeRenewSession());
    _maybeRenewSession(); // in case it was already close to expiry when this page opened
  }


  /// Adds [added]'s units to line [i] (inside a setState), unless the line would then hold more than the server's
  /// units-per-line cap: then the line stays as it was and the worker is told. -> whether it merged.
  bool _mergeWithinLineCap(int i, CartLine added) {
    final cap = _cartSettings.maxUnitsPerLine;
    final total = _lines[i].qty + added.qty;
    // never more than the lots hold either, so a sale never has units left over to put on the last lot, counting the
    // product's units in the cart's other lines too, which draw from the same lots
    final elsewhere = _unitsInCart(_lines[i].productGuid, except: _lines[i]);
    final message = _lines[i].group.drawRefused || added.group.drawRefused
        ? drawRefusedText(_lines[i].productGuid)
        : total > cap
        ? 'At most $cap units in one line.'
        : total + elsewhere > _lines[i].group.quantity
            ? elsewhere == 0
                ? 'Only ${_lines[i].group.quantity} of ${_lines[i].productGuid} in stock.'
                : 'Only ${_lines[i].group.quantity} of ${_lines[i].productGuid} in stock, $elsewhere of them in other lines.'
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

  /// Adds [added] as a new line (inside a setState), unless the product's units across every line would then
  /// be more than its lots hold: then the cart stays as it was and the worker is told. -> whether it was added.
  bool _addWithinStock(CartLine added) {
    if (added.group.drawRefused) {
      _tell(drawRefusedText(added.productGuid));
      return false;
    }
    final elsewhere = _unitsInCart(added.productGuid);
    if (elsewhere > 0 && added.qty + elsewhere > added.group.quantity) {
      _tell('Only ${added.group.quantity} of ${added.productGuid} in stock, $elsewhere of them already in the cart.');
      return false;
    }
    _lines.add(added);
    return true;
  }

  /// [message] in a snack bar after this frame (callers are inside a setState).
  void _tell(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  /// The units of [productGuid] the cart's lines hold, [except] that line - the lines of one product draw from
  /// the same lots.
  int _unitsInCart(String productGuid, {CartLine? except}) => _lines
      .where((l) => l.productGuid == productGuid && !identical(l, except))
      .fold<int>(0, (sum, l) => sum + l.qty);

  /// The server's cart settings, or the built-in ones when it can't say. An async try/catch rather than
  /// `catchError`: a fetcher written as `(id) async => throw ...` is a `Future<Never>` at run time, and
  /// `catchError` on it can't return a CartSettings.
  Future<(CartSettings, bool)> _fetchCartSettingsOrFallback() async {
    try {
      return (await widget.fetchCartSettings(widget.center.id), true);
    } catch (_) {
      return (CartSettings.fallback, false); // shown, but no tax added and no total split on them
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
    final (settings, known) = await _cartSettingsFuture;
    await _restoreCart(settings);
    if (!mounted) return;
    setState(() {
      _cartSettings = settings;
      _cartSettingsKnown = known;
    });
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
    setState(() {
      _lines.addAll(restored);
      // its lines carry the lots as they were when they were added: no earlier read vouches for them (I-D)
      _stateReadAt = null;
      _lotsCheckedAt.clear();
    });
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
    _publishTimerWidget(); // the lines are the dose a running timer counts down against
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

  /// Sends the home-screen widget (widget.cartTimerWidget) every cart's running timer as the carts list has
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
    unawaited(_stockWatch?.cancel());
    widget.health?.removeListener(_onHealth);
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
  /// clears any stale _pricingError left over from switching out of total/perMg, and still persists, so every one of
  /// those events saves the cart through this one call.
  void _recomputeCartPricing({bool persist = true}) {
    // Built once up front, used by both the mg-cap check below and (in the cart-wide modes) priceWholeCart -
    // the mg-cap check runs unconditionally, in every pricing mode including "each", since it's about raw
    // psilocybin content, not price (the state's weightPerUnit x analyteWeight, never mg TPE: dose.dart).
    // the group of every line: the shared core's (null when it can't answer: such a cart can't be priced as a whole)
    final groups = [for (final l in _lines) groupOf(l.productType, core: widget.core)];
    final pricingLines = [
      for (final (i, l) in _lines.indexed)
        CartPricingLine(
          group: groups[i] ?? '',
          mgTpe: l.group.tpeMg.toDouble(),
          qty: l.qty,
        )
    ];
    // the cap, counted from each lot the sale draws (one draw and one cap call per change to the cart): Sell is
    // disabled, with these words, wherever pressing it would be refused by the cap
    final capError = _lines.isEmpty ? null : _cartLimitsNow().refusal;

    if (_pricingMode == CartPricingMode.each) {
      setState(() {
        _pricingError = null;
        _capError = capError;
      });
      if (persist) _persistCart();
      return;
    }
    final result = groups.contains(null)
        ? CartPricingResult.err('core', coreFailedPriceMessage) // the core failed: the cart can't be priced or sold
        : priceWholeCart(
            mode: _pricingMode,
            lines: pricingLines,
            totalText: _cartTotalController.text,
            perMgText: _cartPerMgController.text,
            tax: _cartTax,
            taxPercent: _cartSettings.taxPercent,
            agreementEdible: _cartSettings.agreementEdible,
            agreementDried: _cartSettings.agreementDried,
            settingsKnown: _cartSettingsKnown,
            core: widget.core,
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
    if (_session.isDemo) return; // a demo session is never renewed
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
    _loadStartedAt = widget.now();
    // _stockReadAt stays the time of the stock the cart's lines were built from until this load ends (the 3-day limit
    // holds during a Retry); the newer check doesn't use it while no stock is shown.
    setState(() {
      _inventory = null;
      _inventoryError = null;
      _inventorySource = null;
      _inventoryAsOf = null;
      _centerConfigured = null;
      _adhocGuidsTotal = 0;
      _adhocGuidsResolved = 0;
      _adhocResolvedLots.clear();
    });
    unawaited(_loadInventoryAsync(_saleSends));
  }

  /// The real body of _loadInventory, split out so it can `await` widget.centerIsConfigured before deciding
  /// which of the two branches below to run - see that field's own doc comment on this page, and
  /// coa_data_client.dart/coa_data_resolver.dart's own file comments for why an unconfigured center needs an
  /// entirely different path from [_resilient]'s usual three tiers, not just a fourth tier bolted onto them.
  /// [sendsAtStart] is [_saleSends] when this load started: [_vouches] says whether its read may confirm the stock.
  Future<void> _loadInventoryAsync(int sendsAtStart) async {
    bool configured;
    try {
      configured = await widget.centerIsConfigured(widget.center.id);
    } catch (_) {
      // The center-status check itself failing (network, Mazama's server down) says nothing about whether
      // this center is actually configured - and the ordinary tiers below already have their own state- and
      // cache-fallbacks for exactly that situation. Treating this as "assume configured" just means a worker
      // at a genuinely unconfigured center sees the ordinary tier-2/tier-3 degraded messaging, never a hard
      // failure caused by this one extra check.
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
          _stateReadAt = result.stateRead && _vouches(sendsAtStart) ? widget.now() : null;
          _lotsCheckedAt.clear();
        });
        // Only Mazama's own answer says which lots it has no lab report for: a state-only or cached load marks every
        // lot unknown, not missing (sync/stock_merge.dart's _noCoaOrLabelKnown).
        if (result.source == InventorySource.live) _queueMissingCoas(result.packages, serverKeys: result.serverKeys);
        _takeRefreshedStock(); // an engine copy that came during the load, if newer
      }).catchError((e) {
        if (!mounted) return;
        setState(() => _inventoryError = e.toString());
        _takeRefreshedStock();
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
            // Counted once per lot (a lot with several packages is patched once per package), including a lot the
            // background uploader resolves after the load has returned.
            if (_adhocResolvedLots.add(guid.toLowerCase())) _adhocGuidsResolved++;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _inventory = result.packages;
        _stockReadAt = widget.now();
        _stateReadAt = _vouches(sendsAtStart) ? widget.now() : null; // the adhoc stock is the state's own read
        _lotsCheckedAt.clear();
        _inventorySource = InventorySource.adhoc;
        _adhocGuidsTotal = result.guidsTotal;
        _adhocGuidsResolved =
            result.guidsResolved > _adhocResolvedLots.length ? result.guidsResolved : _adhocResolvedLots.length;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _inventoryError = e.toString());
    }
  }

  /// Whether a load that started when [_saleSends] was [sendsAtStart] may count as the state confirming the stock it
  /// read, now that it has ended: not when a sale was sent while it ran (its counts may be from before that
  /// sale), and not when the cart has lines (they were built from an older stock, or restored from a draft,
  /// and carry those lots' counts). Either way the next sale reads the state itself.
  bool _vouches(int sendsAtStart) => _saleSends == sendsAtStart && _lines.isEmpty;

  /// Hands every lot of [packages] the server has no lab report for to the app's background uploader, one
  /// representative package each, with the state's psilocybin figure as the cart add sends it. Only rows the server
  /// itself sent count ([serverKeys]: a row only the state listed is coaAvailable false because the server was never
  /// asked, sync/stock_merge.dart's _noCoaOrLabelKnown), and a lot with any package whose report the server has is left
  /// alone. Never in the demo; never awaited, never in the way of the page.
  void _queueMissingCoas(List<Package> packages, {required Set<String>? serverKeys}) {
    if (widget.demo != null || _session.isDemo || serverKeys == null) return;
    final lots = <String, CoaUploadLot>{};
    final hasCoa = <String>{};
    for (final p in packages) {
      final guid = p.lotGuid;
      if (guid == null || guid.isEmpty) continue;
      final key = guid.toLowerCase();
      if (p.coaAvailable) {
        hasCoa.add(key);
        continue;
      }
      if (!serverKeys.contains(inventoryRowKey(p))) continue;
      lots.putIfAbsent(
          key, () => CoaUploadLot(lotGuid: guid, packageId: p.id, stateId: widget.center.id, statePsilocybin: p.analyteWeight));
    }
    lots.removeWhere((key, _) => hasCoa.contains(key));
    if (lots.isEmpty) return;
    try {
      widget.queueCoaUploads(lots.values.toList());
    } catch (e) {
      debugPrint('the lab reports could not be queued for upload (nothing on this page is affected): $e');
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
      _adhocListReadAt = widget.now();
      return result.packages;
    }
    return _resilient.fetchPackages(stateId);
  }

  /// When an adhoc center's stock list was last read (by [_fetchPackagesForStockPage], on the spot: nothing keeps it).
  DateTime? _adhocListReadAt;

  /// StockPage's age line: when the stock it was just handed was read. A configured center's
  /// is the center_stock dataset's time: every load of [_resilient] keeps what it read there, with its time, before it
  /// returns, and a kept copy it falls back to has its own; an adhoc center's is its read's.
  Future<DateTime?> _stockListReadAt(int stateId) async {
    if (_centerConfigured == false) return _adhocListReadAt;
    return keptCenterStock(_datasets, stateId)?.fetchedAt;
  }

  Future<void> _onAddPkpr() async {
    final text = _pkprController.text.trim();
    final hex = stripPkprPrefix(text);
    if (hex.isEmpty) {
      setState(() => _lookupError = 'Enter a PKPR.');
      return;
    }
    // the shared package id rule (id_patterns.g.dart) before anything is looked up
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
    if (matches.single.drawRefused) {
      setState(() => _lookupError = drawRefusedText(matches.single.productGuid));
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
        if (!_addWithinStock(added)) return;
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

  /// For a CONFIGURED center, submits a lab report for every lot behind [group] that still has
  /// coaAvailable false (packages_client.dart's own Package field, carried through the merge - see
  /// sync/stock_merge.dart) - so a PKPR, HB or PL a worker just sold gets its COA (and so its label) on
  /// file without anyone having to notice and go submit it by hand later. A lot whose COA the server already has
  /// but whose label it hasn't drawn yet is left alone: the server draws the label itself, and
  /// submitting would only cost two calls to the state system and an upload for an answer the server already has. A no-op for an
  /// UNCONFIGURED center: coa_data_resolver.dart's own resolveAdhocInventory already queued every lot it was missing
  /// during the load itself, and Package's own coaAvailable/labelAvailable default true for a source (the
  /// adhoc flow) that never sets them, so the `where` below simply finds nothing to do there.
  ///
  /// A lot with no [Package.lotGuid] on file (possible if the state system's own read that would have supplied
  /// it never ran for this lot - see sync/stock_merge.dart's own merge comment) is skipped:
  /// there is nothing to key the submission by. Every lot is tried independently and a failure on one (caught
  /// inside submitCoaForLot's own ConfiguredCoaSubmitError, or any other exception) never stops the rest - same
  /// "one miss is never fatal to the others" rule coa_data_resolver.dart's own worker() already follows.
  Future<void> _ensureCoaForCartLine(PkprGroup group) async {
    if (_centerConfigured != true) return;
    final needsWork = group.lots.where((l) => !l.coaAvailable && (l.lotGuid?.isNotEmpty ?? false)).where((l) {
      // already waiting or being sent by the background uploader: not downloaded twice at once
      try {
        return !widget.coaUploadPending(l.lotGuid!);
      } catch (_) {
        return true;
      }
    }).toList();
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
        // couldn't reach Mazama's server, the lot is kept for a submission once it answers.
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

  /// widget.drawLabel, else the real phone drawing with this page's datasets, so what mazama_core read from the lab
  /// report is kept for a later read from the state system alone (phone_label.dart). [labelInput] is the
  /// server's for the product (PkprGroup.labelInput): with it the label is drawn without any state call.
  Future<Map<String, Object?>> _drawLabel(int stateId, String pkpr,
      {required String accessToken, String strain = '', Map<String, Object?>? labelInput}) {
    final draw = widget.drawLabel;
    if (draw != null) return draw(stateId, pkpr, accessToken: accessToken, strain: strain);
    return phone_label.drawPhoneLabelSpec(stateId, pkpr,
        accessToken: accessToken, strain: strain, now: widget.now, enrichment: _datasets, labelInput: labelInput);
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
  /// and never analyteWeight) work out what one unit costs (cart_pricing.dart's linePrice, the shared core's, within the
  /// $10,000 unit cap). Either way the result is a single priceCentsEach, the one price CartLine stores -
  /// the mode only changes how that number gets typed in.
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
                  // units only the state knows, and their own figure; a note only
                  if (group.stateOnlyNote case final note?) Text(note, style: Theme.of(context).textTheme.bodySmall),
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
                      // the product's units in the cart's other lines draw from the same lots. Not the line an
                      // add of this dose merges into (its own check, _mergeWithinLineCap), nor the line being edited.
                      final elsewhere = _lines
                          .where((l) =>
                              l.productGuid == group.productGuid &&
                              !identical(l, existing) &&
                              (existing != null || l.dose != dose))
                          .fold<int>(0, (sum, l) => sum + l.qty);
                      if (n + elsewhere > group.quantity) {
                        return 'Only ${group.quantity} in stock, $elsewhere of them already in the cart - reduce the quantity.';
                      }
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
                        // a product whose only figure is the state's psilocybin is priced per mg psilocybin
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
                      // the shared core's line price: a price each, or the rate times the unit's mg
                      validator: (v) => switch (linePrice(perMg: mode == _pricePerMg, text: v ?? '', mg: group.tpeMg, core: widget.core).error) {
                            null => null,
                            'price' => 'Enter a price from \$0 to \$10,000',
                            // as on the server: an unknown mg TPE is refused, never priced at nothing
                            'no_mg' => "No ${group.mgLabel} is known for this product, so it can't be priced per mg",
                            'rate' => 'Enter a rate from \$0 to \$1,000 per mg',
                            'unit_cap' => 'A single unit would cost more than \$10,000', // a rate times the unit's mg over $10,000
                            _ => coreFailedPriceMessage, // the core failed: refused, never priced
                          },
                    ),
                    if (mode == _pricePerMg &&
                        linePrice(perMg: true, text: priceController.text, mg: group.tpeMg, core: widget.core).cents != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '= ${money(linePrice(perMg: true, text: priceController.text, mg: group.tpeMg, core: widget.core).cents!)} each '
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
                      : linePrice(perMg: mode == _pricePerMg, text: priceController.text, mg: group.tpeMg, core: widget.core).cents;
                  if (cents == null) return; // the core stopped answering since the check above: not added
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
  /// server's matcher (scan_match_client.dart - mazama_core's, the same a label photo gets on the web) or, when the
  /// server can't answer, runs that matcher on this phone against the cart's stock (_matchScanLocally), and lands
  /// on exactly the same path manual entry uses: fills _pkprController with the resolved PKPR and calls
  /// _onAddPkpr(), so nothing downstream of that (the label-compare dialog, the quantity/price/dose dialog, merging
  /// into an existing line) needs to know a scan was ever involved.
  Future<void> _onScanPressed() async {
    final source = await _chooseScanSource();
    if (source == null || !mounted) return; // the worker closed the choice - nothing to scan
    List<String> lines;
    try {
      lines = await widget.scanLabelText(source);
    } on ScanCancelled {
      return; // the worker backed out of the camera screen or the picker - nothing went wrong, nothing to say
    } catch (e) {
      if (!mounted) return;
      final what = source == ScanSource.camera ? 'the camera' : 'the photo';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read $what: $e')));
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

  /// Asks where the label's photo comes from: a new one from the camera, or one already among the phone's photos.
  /// Null when the worker closes the sheet without choosing.
  Future<ScanSource?> _chooseScanSource() => showModalBottomSheet<ScanSource>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.of(context).pop(ScanSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from photos'),
                onTap: () => Navigator.of(context).pop(ScanSource.photos),
              ),
            ],
          ),
        ),
      );

  /// The scan matched on this phone (widget.localScanMatch: mazama_core through the FFI) against the stock the cart
  /// already holds, when the server's matcher failed with [error] because it couldn't answer - unreachable or
  /// failing, not a request it refused (ScanMatchError.serverUnavailable; anything that isn't a ScanMatchError is
  /// a failure to reach it too). Null - and the caller shows the server's error - when the server refused
  /// the request, no stock is loaded yet, or the core can't answer.
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
    _reloadIfServerBack();
  }

  /// Asks before throwing away unsold carts - shared by switching centers and signing out, the two ways a worker can
  /// leave this screen with unsold lines in it. Every cart counts, not only the one showing. Returns true if
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
        builder: (_) => StockPage(
            center: widget.center,
            fetchPackages: _fetchPackagesForStockPage,
            readAt: _stockListReadAt,
            now: widget.now,
            workerEmail: _session.email,
            featureTable: widget.featureTable),
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
      if (group.drawRefused) {
        _tell(drawRefusedText(group.productGuid)); // just this one: the rest of the batch still goes in
        continue;
      }
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
          _addWithinStock(added);
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
          // and the stock page merges it itself; a state-only or cached fallback from here would reach the
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
  /// be sent. The state is read again only when the stock on screen is older than the recheck age (or a lot's figures
  /// are only a phone's upload). Every lot the sale draws from ([sale], _saleDraw) is checked with _freshStockRefusal, the
  /// sale worker's own rule, for the units all the cart's lines take from it together. A state system that
  /// can't be read refuses the sale too: it is never sent unchecked.
  Future<String?> _recheckOldStock(List<List<(Package, int)>> sale) async {
    final now = widget.now();
    final drawn = bulkDrawPerLot([sale]);
    final lots = [for (final d in drawn) d.lot];
    // a lot whose figures are only a phone's upload (/p/packages' confirmed false) is always read again
    if (!stockRecheckNeeded(lots,
        stateVouches: _confirmedRecently(_stateReadAt, now),
        lotVouched: (lot) => _confirmedRecently(_lotsCheckedAt[lot.id], now))) {
      return null;
    }
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
    final why = _freshStockRefusal(drawn, fresh);
    if (why != null) return why;
    // the cap again, on the state's figures as they are now, for the units the sale draws from each lot
    final overCap = _freshCapRefusal([sale], fresh);
    if (overCap != null) return overCap;
    final at = widget.now();
    for (final lot in lots) {
      _lotsCheckedAt[lot.id] = at; // only the lots read again: the rest of the stock on screen is as old as it was
    }
    return null;
  }

  /// Null when every lot drawn ([drawn], with the units all the lines and copies
  /// take from it) can still be sold as the state has it just now ([fresh], by id), else why not - the sale worker's own
  /// check, the shared core's selling.check_sale: the lot gone or another package's, no longer sellable for those
  /// units, or a value its records copy (productGuid, productType, weightPerUnit, analyteWeight) changed since the cart
  /// drew it. The cap is [_freshCapRefusal]'s. Refused when the core can't
  /// answer.
  String? _freshStockRefusal(List<({Package lot, int units})> drawn, Map<int, Map<String, Object?>> fresh) {
    try {
      final reply = MazamaCore.instance.sellingCheckSale({
        'lines': [for (final d in drawn) {'record_id': d.lot.id, 'guid': d.lot.productGuid, 'qty': d.units}],
        'fresh': fresh.values.toList(),
        // the phone reads only its own center's stock, and its records carry this center's id, not a copied one: so no
        // other-center check here and no serviceCenterId compared (the server's worker checks both)
        'center': null,
        'sent': [
          for (final d in drawn)
            {
              for (final e in d.lot.toSaleItem().entries)
                if (e.key != 'id') (e.key == 'productType' ? 'productGroup' : e.key): e.value,
              'serviceCenterId': fresh[d.lot.id]?['serviceCenterId'],
            },
        ],
        'cap': false,
      });
      final refusal = reply['refusal'];
      if (refusal is String) return refusal;
      if (refusal == null && reply.containsKey('refusal')) return null;
    } catch (e) {
      debugPrint('the stock check could not be made: $e');
    }
    return "This phone can't check the stock with the state system's records (its shared core failed), so the sale "
        'was never attempted.';
  }

  /// Null when every copy in [perSale] is within the cap on the state's figures as just read ([fresh], by record
  /// id; the lots drawn are all in it, _freshStockRefusal checked that), else why not, in the core's words. For a bulk sell
  /// (more than one copy) the first refused copy is named.
  String? _freshCapRefusal(List<List<List<(Package, int)>>> perSale, Map<int, Map<String, Object?>> fresh) {
    final copies = [
      for (final sale in perSale)
        [
          for (var i = 0; i < sale.length; i++)
            for (final (lot, take) in sale[i])
              (
                record: <String, Object?>{
                  'weightPerUnit': fresh[lot.id]?['weightPerUnit'],
                  'analyteWeight': fresh[lot.id]?['analyteWeight'],
                },
                qty: take,
                dose: _lines[i].dose,
              ),
        ],
    ];
    final verdicts = saleLimits(copies);
    for (var k = 0; k < verdicts.length; k++) {
      if (!verdicts[k].allowed) {
        return verdicts.length == 1
            ? 'As the state has it now: ${verdicts[k].error}'
            : 'Sale ${k + 1} of ${verdicts.length}, as the state has it now: ${verdicts[k].error}';
      }
    }
    return null;
  }

  /// Whether the state confirmed something at [at] recently enough for a sale at [now] to skip its own read: a
  /// time in the future (the clock moved back since) never counts, so the state is read then.
  bool _confirmedRecently(DateTime? at, DateTime now) =>
      at != null && !at.isAfter(now) && now.difference(at) <= widget.resilienceOptions.stockRecheckAge;

  /// Whether the stock on screen is too old to sell from (older than cacheMaxAge, 3 days by default) - the one test the
  /// Sell button and the stock banner both use: when the stock itself was read ([_stockReadAt]: a kept copy's own time; a recheck doesn't move it), on the
  /// page's clock.
  bool get _tooOldToSell {
    final readAt = _stockReadAt;
    return readAt != null && stockTooOld(readAt, widget.now(), widget.resilienceOptions.cacheMaxAge);
  }

  /// The sale's draw: for each line, in order, the (lot, units) it takes, the lot that expires first giving units
  /// first, every line of one product sharing its lots (as the server's one cart line per record; bulk sell's draw with
  /// one copy). [sale] is null
  /// when [shortLine], the first line the lots can't cover, is set.
  ({List<List<(Package, int)>>? sale, int? shortLine, bool coreFailed}) _saleDraw() {
    final r = allocateBulkSales([for (final l in _lines) (lots: l.group.lots, qty: l.qty)], 1);
    return (sale: r.perSale?.single, shortLine: r.shortLine, coreFailed: r.coreFailed);
  }

  /// The first line the product's lots can't cover once the lines before it have drawn theirs, or null.
  CartLine? _overStockLine() {
    final short = _saleDraw().shortLine;
    return short == null ? null : _lines[short];
  }

  /// Why [over] (_overStockLine) can't be sold, in a sentence starting "Only": the line itself when it is the
  /// product's only line, else all of the product's lines together.
  String _overStockText(CartLine over) {
    if (over.group.drawRefused) return drawRefusedText(over.productGuid);
    final lines = _lines.where((l) => l.productGuid == over.productGuid).toList();
    if (lines.length == 1) return 'Only ${over.group.quantity} of ${over.productGuid} in stock: reduce the line.';
    final need = lines.fold<int>(0, (sum, l) => sum + l.qty);
    return "Only ${over.group.quantity} of ${over.productGuid} in stock: the cart's ${lines.length} lines of it need "
        '$need. Reduce them.';
  }

  Future<void> _onSellPressed() async {
    // stock of any age is shown, but never sold from once it is older than cacheMaxAge.
    if (_tooOldToSell) {
      setState(() {}); // the stock strip offers Retry, whatever tier the stock came from
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(staleStockRefusal(widget.resilienceOptions.cacheMaxAge))));
      return;
    }
    final refusal = _saleRefusal();
    if (refusal != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(refusal)));
      return;
    }
    final saleDate = await _showSellDialog();
    if (saleDate == null || !mounted) return; // the worker cancelled
    await _sell(saleDate);
  }

  /// Null when the cart can be sold as one draw (_saleDraw): every line covered by its product's lots, and the sale
  /// within the cap on the lots it draws (the per-draw check bulk sell uses, for a single sale); else why not, ending "Nothing
  /// was sent.".
  String? _saleRefusal() {
    final draw = _saleDraw();
    final sale = draw.sale;
    final why = sale == null
        ? (draw.coreFailed ? drawCoreFailedText : _overStockText(_lines[draw.shortLine!]))
        : saleCapRefusal(sale);
    return why == null ? null : '$why Nothing was sent.';
  }

  /// The Pacific date of now, as a local calendar day for the date pickers. StateError when the core can't
  /// answer.
  DateTime _pacificToday() {
    final d = pacificToday(widget.now());
    return DateTime(d.year, d.month, d.day);
  }

  /// Why a sale can't be dated [date] (the core's check_sale_date against today's Pacific date), or null.
  String? _saleDateRefusal(DateTime date) {
    final DateTime today;
    try {
      today = _pacificToday();
    } on StateError {
      return saleDateRefusal('unchecked');
    }
    final why = checkSaleDate(date, today);
    return why == null ? null : saleDateRefusal(why);
  }

  /// What the Sell and Bulk sell dialogs open with: the Pacific today (the default date), the days a sale may be dated
  /// (the core's bounds, the ones check_sale_date holds, whatever the device's zone) and the cart's totals (the core's).
  /// Null when the core can't answer one of them: a snackbar says so, starting [prefix], and nothing is sent.
  ({DateTime today, ({DateTime earliest, DateTime latest}) days, CartTotals totals})? _saleDialogStart(String prefix) {
    final totals = _cartTotalsNow();
    if (totals == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$prefix${_sentence(coreFailedTotalMessage)} Nothing was sent.')));
      return null;
    }
    try {
      final today = _pacificToday();
      final b = saleDateBounds(today);
      final days = (earliest: DateTime(b.earliest.year, b.earliest.month, b.earliest.day), latest: DateTime(b.latest.year, b.latest.month, b.latest.day));
      return (today: today, days: days, totals: totals);
    } on StateError {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$prefix${saleDateRefusal('unchecked')} Nothing was sent.')));
      return null;
    }
  }

  /// [text] as a sentence: its first letter capitalised, a full stop at its end.
  static String _sentence(String text) => '${text[0].toUpperCase()}${text.substring(1)}.';

  /// "N line(s), U unit(s)": the start of both dialogs' totals line, the units the core's.
  String _linesAndUnits(CartTotals totals) => '${_lines.length} line(s), ${totals.units} unit(s)';

  /// A dialog's "Sale date: ... Change" row: the platform date picker offers only [days], the core's bounds (a sale can
  /// be backdated, a worker catching up on a busy day, up to 365 days, never postdated); [onPicked] gets the choice.
  Widget _saleDateRow(BuildContext context, DateTime saleDate, ({DateTime earliest, DateTime latest}) days,
          void Function(DateTime picked) onPicked) =>
      Row(
        children: [
          const Text('Sale date: '),
          Text(_saleDateText(saleDate)),
          const Spacer(),
          TextButton(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: saleDate,
                firstDate: days.earliest,
                lastDate: days.latest,
              );
              if (picked != null) onPicked(picked);
            },
            child: const Text('Change'),
          ),
        ],
      );

  /// Shows the cart's own confirmation dialog (lines/total, a sale date defaulting to today but changeable via
  /// the platform date picker) and returns the date to sell as of, or null if the worker cancelled. Doesn't
  /// touch _lines or the network itself - that's _sell's job once this returns a real date.
  Future<DateTime?> _showSellDialog() async {
    final start = _saleDialogStart('');
    if (start == null) return null;
    var saleDate = start.today;
    return showDialog<DateTime>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Confirm sale'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_linesAndUnits(start.totals)}, total ${money(start.totals.total)}.'),
              const SizedBox(height: 16),
              _saleDateRow(context, saleDate, start.days, (picked) => setDialogState(() => saleDate = picked)),
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

  /// The sign-in checked right before a send (a sale's, or each copy's of a bulk sale), renewed and saved when it has to
  /// be: SessionExpired and SessionRenewalUnavailable go to the caller. False when the page is gone meanwhile.
  Future<bool> _freshSessionToSend(http.Client client) async {
    final fresh = await ensureFreshSession(_session, widget.spec, client: client, now: widget.now);
    if (!mounted) return false;
    if (fresh.accessToken != _session.accessToken) {
      setState(() => _session = fresh);
      await widget.sessionStore.save(fresh.toJson());
    }
    return true;
  }

  /// Turns every cart line into one or more sale records: each line's units from the lots [sale] (_saleDraw) draws
  /// them from - the lot that expires first gives units first, the lines of one product sharing its
  /// lots - at the line's price and dose. A worker never sees the split: the cart shows one line per PKPR and
  /// dose. A line beyond every lot never gets this far (_saleRefusal), so nothing is ever put on the last lot. The
  /// same records bulk sell makes for each copy (_bulkSaleRecords).
  List<Map<String, Object?>> _buildSaleRecords(DateTime saleDate, List<List<(Package, int)>> sale) =>
      _bulkSaleRecords(sale, saleDate);

  /// Submits every current cart line as one sale (shared/flows/sale.yaml's `sale` flow): all lines go up in a
  /// single request so the state system gives them all the same sale number, matching how the real web app's
  /// own Sell button works (mazama_sales/src/mazama_sales/state/client.py's create_sales). Only clears the
  /// cart on a confirmed success - see _showSaleFailureDialog for why a failure is never treated as "safe to
  /// just clear and move on" or even "safe to just try again" without first checking which kind of failure it
  /// was.
  Future<void> _sell(DateTime saleDate) async {
    // One draw for everything below: the cap, the stock re-read and the records. Checked again here, since the
    // cart may have changed while the confirmation was open; refused, nothing is sent.
    final refusal = _saleRefusal();
    final sale = _saleDraw().sale;
    if (refusal != null || sale == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(refusal ?? 'The cart could not be drawn from its stock. Nothing was sent.')));
      return;
    }
    setState(() => _selling = true);
    final client = widget.httpClientFactory();
    // Built first inside the try, before anything that can throw SessionExpired - purely local (reads _lines,
    // widget.center, saleDate), so it is ready in time to report to _queueFailedSale if the session can't be renewed
    // below. A record the core refuses to build (a price or quantity out of bounds, a state record missing what a sale
    // record copies), a date it refuses (in the future, or more than 365 days back) or a core that can't answer ends
    // here as not sent, with its words, and the spinner stops.
    var records = const <Map<String, Object?>>[];
    // Set just before the sale flow runs: an unexpected failure before then can't have sent anything.
    var saleFlowStarted = false;
    var saleConfirmed = false;
    try {
      final dateRefusal = _saleDateRefusal(saleDate);
      if (dateRefusal != null) throw SaleRefused(dateRefusal);
      records = _buildSaleRecords(saleDate, sale);
      // A write is exactly the kind of call ensureFreshSession exists to protect, and it's too important to
      // leave entirely to the periodic timer's own 30-second cadence lining up in time - check again right
      // before this one specifically.
      if (!await _freshSessionToSend(client)) return;

      // stock read longer ago than stockRecheckAge is read from the state again, and a line that is gone or
      // can't be sold any more is refused with the sale worker's own words. Nothing has been sent at this point.
      final stockRefusal = await _recheckOldStock(sale);
      if (stockRefusal != null) {
        client.close();
        if (!mounted) return;
        setState(() => _selling = false);
        await _showSaleFailureDialog(stockRefusal, outcome: SaleOutcome.notSent);
        return;
      }

      final saleSpec = await widget.saleSpec;
      saleFlowStarted = true;
      _stockMovedAt = widget.now(); // the stock may move now: no copy read before this goes on screen
      _saleSends++;
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
      // The stock has moved: the next sale reads the state first, as after a bulk sale. _stockReadAt
      // stays the stock's own read time: the 3-day limit still refuses it once it is too old.
      _stateReadAt = null;
      _lotsCheckedAt.clear();

      if (!mounted) return;
      // the client's session timed by what the records sent, from the figures of the lots they draw
      _rememberSoldDose(_cartId, _lines, [sale]);
      setState(() => _lines.clear());
      _publishTimerWidget();
      // the center's stock is asked to refresh once the cart is cleared, never awaited (the sale is recorded).
      try {
        widget.requestStockRefresh(widget.center.id);
      } catch (e) {
        debugPrint('the stock refresh could not be asked for (the sale itself was not affected): $e');
      }
      // The sale just succeeded, so whatever draft was on disk for this cart is stale the instant this
      // runs - nothing left in it should ever come back on a future restore. Only this cart.
      await widget.cartStore.clear(cartId: _cartId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.demo != null
              ? 'Demo sale: nothing was sent. The demo stock stays as it was.'
              : 'Sale recorded with the state system.')));
    } on SaleRefused catch (e) {
      // Nothing was built, so nothing was sent: the worker can fix what's wrong (or the state's record) and sell again.
      client.close();
      if (!mounted) return;
      setState(() => _selling = false);
      await _showSaleFailureDialog('This sale can\'t be recorded: ${e.message}', outcome: SaleOutcome.notSent);
    } on SessionExpired catch (e) {
      // This is specifically "the state's own sign-in refused to renew or re-authenticate" - the shape a
      // breaking change on the state's side would take (as opposed to the sale itself being refused for an
      // ordinary reason, which is the FlowError branch below and never queued this way). Fire-and-forget,
      // same reasoning as _logSaleAttribution: queuing this for review must never block, delay, or change the
      // trip back to sign-in that was already happening regardless.
      // Never e.message: it carries the renew flow's error text (session.dart's sessionFailureReportText).
      unawaited(_queueFailedSale(records, '[${(saleFlowStarted ? SaleOutcome.uncertain : SaleOutcome.notSent).name}] ${sessionFailureReportText(e)}'));
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
      // no records yet (the core couldn't build them): nothing to report, nothing was sent
      if (records.isNotEmpty) {
        unawaited(_queueFailedSale(records, '[${outcome.name}] unexpected ${e.runtimeType} while selling'));
      }
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
      if (saleFlowStarted) {
        // whatever the outcome, the stock may have moved: the next sale reads the state first, as the bulk sale;
        // and a load that started while this was being sent (so after the count above went up) doesn't vouch
        _saleSends++;
        _stateReadAt = null;
        _lotsCheckedAt.clear();
      }
      if (mounted) setState(() => _selling = false);
      _reloadIfServerBack(); // the sale went through and emptied the cart, or it didn't and the cart waits as it is
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
  /// it is never re-derived from [message]'s wording.
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

  // ---- Several carts ----

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
  /// its lines, or - once it's been sold and is empty - what it sold. The showing cart's lines and timer
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
      final SessionDose? dose = lines.isNotEmpty
          ? sessionDoseOf(showing ? _cartLimitsNow().limits : cartSaleLimits(lines), booster: lines.any((l) => l.dose == doseSecondary))
          : await widget.sessionTimerStore
              .loadSoldSession(widget.center.id, cartId: c.id, maxAge: sessionTimerMaxAge, now: widget.now);
      out.add((slot: c, lines: lines.length, timerStart: start, dose: dose));
    }
    return out;
  }

  /// Remembers what cart [cartId] just sold ([lines], one sale's worth, drawn as [perSale]: one copy, or every
  /// copy of a bulk sell), so the carts list can still time its client's session once the sold cart is empty: the
  /// largest copy's mg and session length on the lots it drew (never the product's first-lot figure),
  /// all the core's (one call). Fire-and-forget: the sale is already done.
  void _rememberSoldDose(String cartId, List<CartLine> lines, List<List<List<(Package, int)>>> perSale) {
    final verdicts = saleLimits(drawnSaleLimitLines(perSale, [for (final l in lines) l.dose]));
    var mg = 0.0;
    int? minutes;
    for (final v in verdicts) {
      final m = v.psilocybinMgValue;
      if (m != null && m > mg) mg = m;
      final s = sessionDoseOf(v, booster: false).minutes; // the longest (6 hours) when the core couldn't answer
      if (s != null && (minutes == null || s > minutes)) minutes = s;
    }
    unawaited(widget.sessionTimerStore
        .saveSoldDose(widget.center.id, mg,
            booster: lines.any((l) => l.dose == doseSecondary), cartId: cartId, now: widget.now, minutes: minutes)
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
  /// for when it comes back, its lines and timer are already on disk (saved as they changed), and the other
  /// cart's lines, timer and pricing controls are brought in. Also how a new cart is shown and how the cart after a
  /// deleted one is.
  Future<void> _showCart(CartSlots slots) async {
    _pricingByCart[_cartId] = _CartPricing(_pricingMode, _cartTotalController.text, _cartPerMgController.text, _cartTax);
    final pricing = _pricingByCart[slots.activeId] ?? _CartPricing(widget.initialPricingMode, '', '', CartTaxMode.included);
    _sessionTimerTicker?.cancel();
    _sessionTimerTicker = null;
    _switchingCarts++; // no copy goes on screen between this clear and the restore below
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
      _cartLimits = null;
    });
    _saveSlots();
    final id = slots.activeId;
    List<CartLine>? restored;
    try {
      restored = await widget.cartStore.load(widget.center.id, cartId: id, maxAge: _cartSettings.life);
    } finally {
      _switchingCarts--; // this switch's own hold only (a later switch keeps its own), even when the load throws
    }
    final back = restored ?? const <CartLine>[];
    if (!mounted || id != _cartId) return; // another switch took over, or the page is gone
    if (back.isNotEmpty) {
      setState(() {
        _lines.addAll(back);
        // the other cart's lines carry the lots as they were when they were added: no read since vouches for them
        _stateReadAt = null;
        _lotsCheckedAt.clear();
      });
    }
    _recomputeCartPricing(persist: false);
    _reloadIfServerBack();
    await _restoreSessionTimer();
  }

  /// The name dialog for a new cart and for renaming one (1 to 30 characters, unique here). -> the trimmed name,
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

  /// Deletes a cart: asks first when the cart has lines; clears its draft and timer; the last cart is never deleted.
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

  // ---- Bulk sell: the showing cart sold as N copies of one sale ----

  /// Long-press on the cart button (or "Bulk sell…" in the carts sheet): the showing cart sold as the same sale N
  /// times. Refused up front for the same reasons Sell is disabled or refused.
  Future<void> _onBulkSellPressed() async {
    if (_selling) return;
    final why = _lines.isEmpty
        ? 'add items to the cart first.'
        : (_pricingError ?? _capError ?? (_cartTotalsNow() == null ? coreFailedTotalMessage : null));
    final over = why == null ? _overStockLine() : null;
    final overText = over == null ? null : _overStockText(over);
    final refusal = why ?? (overText == null ? null : '${overText[0].toLowerCase()}${overText.substring(1)}');
    if (refusal != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bulk sell: $refusal')));
      return;
    }
    final choice = await _showBulkSellDialog();
    if (choice == null || !mounted) return;
    await _bulkSell(choice.date, choice.perSale);
  }

  /// The bulk sell dialog: how many sales, the sale date (as Sell's dialog), what one sale and all of them come
  /// to, and whether there's stock for them all (allocateBulkSales). -> the date and every copy's lot draw, or null when
  /// cancelled.
  Future<({DateTime date, List<List<List<(Package, int)>>> perSale})?> _showBulkSellDialog() async {
    final start = _saleDialogStart('Bulk sell: '); // as Sell's own dialog
    if (start == null) return null;
    var saleDate = start.today;
    final countController = TextEditingController(text: '2');
    final formKey = GlobalKey<FormState>();
    final totalLines = _totalLinesNow();
    final List<BulkLine> bulkLines = [for (final l in _lines) (lots: l.group.lots, qty: l.qty)];
    String? countError(String? text) {
      final n = int.tryParse((text ?? '').trim());
      if (n == null || n < 1) return 'Enter a whole number, at least 1';
      if (n > maxBulkSales) return 'At most $maxBulkSales sales at once.';
      final draw = allocateBulkSales(bulkLines, n);
      if (draw.coreFailed) return drawCoreFailedText; // the core failed, the stock isn't short
      final short = draw.shortLine;
      if (short != null) {
        final guid = _lines[short].productGuid;
        final perSale = _lines.where((l) => l.productGuid == guid).fold<int>(0, (sum, l) => sum + l.qty);
        return 'Only ${_lines[short].group.quantity} of $guid in stock: $n sales need ${perSale * n}.';
      }
      // every copy within the cap on the lots it draws, not only the first copy's
      return bulkCapRefusal(draw.perSale!);
    }

    return showDialog<({DateTime date, List<List<List<(Package, int)>>> perSale})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final n = countError(countController.text) == null ? int.parse(countController.text.trim()) : null;
          // all n sales, the core's (null when it can't add them up: nothing can be confirmed)
          final all = n == null ? null : cartTotals(totalLines, sales: n, core: widget.core);
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
                  Text('Each sale: ${_linesAndUnits(start.totals)}, ${money(start.totals.total)}.'),
                  const SizedBox(height: 4),
                  Text(
                    'Every sale is recorded separately with the state system and gets its own sale number.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: countController,
                    decoration: const InputDecoration(labelText: 'Number of sales', errorMaxLines: 4),
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    onChanged: (_) => setDialogState(() {}),
                    validator: countError,
                  ),
                  if (n != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                          all == null
                              ? _sentence(coreFailedTotalMessage)
                              : 'All $n sales: ${all.allUnits} unit(s), ${money(all.allTotal)}.',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  const SizedBox(height: 16),
                  _saleDateRow(context, saleDate, start.days, (picked) => setDialogState(() => saleDate = picked)),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              FilledButton(
                onPressed: n == null || all == null
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

  /// The stock is always read again before a bulk sale, whatever its age, and every lot checked for everything all the copies
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
    final why = _freshStockRefusal(bulkDrawPerLot(perSale), fresh);
    if (why != null) return why;
    // every copy within the cap on the state's figures as they are now
    final overCap = _freshCapRefusal(perSale, fresh);
    if (overCap != null) return overCap;
    // (nothing stamped: after a bulk sale the next sale reads the state again in any case)
    return null;
  }

  /// Sends the copies one at a time: the sign-in checked before each, the stock read again before the first.
  /// The first copy not confirmed stops the run; it is queued for review the way a failed single sale is, and the
  /// copies after it are never attempted. Nothing is ever retried. All confirmed: the cart is cleared. Otherwise the
  /// cart is kept and _showBulkResultDialog says what happened.
  Future<void> _bulkSell(DateTime saleDate, List<List<List<(Package, int)>>> perSale) async {
    // no copy goes over the cap on the lots it draws (the dialog refuses this already; checked again here so
    // nothing is ever sent past it)
    final overCap = bulkCapRefusal(perSale);
    if (overCap != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bulk sell: $overCap')));
      return;
    }
    final count = perSale.length;
    final cartId = _cartId;
    // every copy's records built (and the date checked) before anything is sent; a refusal or a core
    // that can't answer stops the whole bulk sale here, nothing sent
    final List<List<Map<String, Object?>>> sales;
    try {
      final dateRefusal = _saleDateRefusal(saleDate);
      if (dateRefusal != null) throw SaleRefused(dateRefusal);
      sales = [for (final sale in perSale) _bulkSaleRecords(sale, saleDate)];
    } on SaleRefused catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bulk sell: ${e.message} Nothing was sent.')));
      return;
    } on StateError {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Bulk sell: this phone can't build the sale records (its shared core failed). Nothing was sent.")));
      return;
    }
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
          if (!await _freshSessionToSend(client)) return;
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
          _stockMovedAt = widget.now(); // as the single sale: no copy read before this copy's send goes on screen
          _saleSends++;
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
      // stock has moved (or may have), so the next sale reads it again first; and a load that started while the
      // last copy was being sent doesn't vouch for what it read
      _saleSends++;
      if (mounted) {
        setState(() {
          _selling = false;
          _stateReadAt = null;
          _lotsCheckedAt.clear(); // _stockReadAt stays the stock's own read time, for the 3-day limit
        });
      }
    }
    if (!mounted) return;
    if (recorded == count) {
      // one client's dose, timed by the largest copy (a later copy may draw stronger or weaker lots), each counted from
      // the figures of the lots it drew
      _rememberSoldDose(cartId, _lines, perSale);
      setState(() => _lines.clear());
      _publishTimerWidget();
      _reloadIfServerBack();
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

  /// What a bulk sale that stopped part way did, in the single sale's own words for the copy that stopped it
  /// (_showSaleFailureDialog): not sent and safe, or maybe recorded and NOT safe to just send again.
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
  /// as they do) and suggesting one merged PKPR per entry (groupByPkpr - the server sends a separate row per
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
                              // some lines' only figure is the state's psilocybin, and are priced by it
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
    final groups = {for (final l in _totalLinesNow()) l.group};
    final totals = _cartTotalsNow();
    if (groups.length != 2 || groups.contains(null) || totals == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        'Edibles + extracts ${money(totals.groupA)} · Whole / dried / homogenized ${money(totals.groupB)}'
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
    // the cart's totals, the core's; none (and no Sell) when it can't add the cart up
    final totals = _cartTotalsNow();
    String moneyOrNone(int? cents) => cents == null ? '—' : money(cents);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.center.licenseName),
            _cartNameLine(),
          ],
        ),
        actions: [
          if (featureOnForLicense('center_stock', widget.center.licenseType, table: widget.featureTable))
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
                        final summary = Text(
                            '${l.productGuid} · $strainLabel${l.qty} x ${money(l.priceCentsEach)} · ${l.group.tpeMg}${l.group.mgLabel} each$doseLabel');
                        // the line stays priced and capped by the product's figure; units
                        // only the state knows are noted under it with their own figure
                        final stateOnlyNote = l.group.stateOnlyNote;
                        return ListTile(
                          title: Text(title),
                          subtitle: stateOnlyNote == null
                              ? summary
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [summary, Text(stateOnlyNote)],
                                ),
                          onTap: () => _onEditLine(i), // same dialog a fresh add uses, pre-filled from this line
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(moneyOrNone(totals?.lineTotals[i])),
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
                  if (totals == null && _lines.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_sentence(coreFailedTotalMessage), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)),
                          Text(moneyOrNone(totals?.total), style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      FilledButton(
                        onPressed:
                            (_lines.isEmpty || _selling || _pricingError != null || _capError != null || totals == null)
                                ? null
                                : _onSellPressed,
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

  /// The app bar's second line: the cart's name and, once stock is shown, its age: when the stock on screen was read
  /// ([_stockReadAt], the time the 3-day limit counts from). It shares the name's line so the
  /// selling screen is no taller: a row of its own above the dose summary pushed the cart's lines under Total/Sell.
  /// The name keeps up to [_cartNameMaxWidth]; the age takes what is left, shortened with an ellipsis on a narrow phone.
  Widget _cartNameLine() {
    final style = Theme.of(context).textTheme.bodySmall;
    final readAt = _inventory == null ? null : _stockReadAt;
    final name = Text(_slots.active.name,
        key: const Key('cartName'), style: style, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false);
    if (readAt == null) return name;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: _cartNameMaxWidth), child: name),
        Text(' · ', style: style),
        Flexible(
          child: Text(updatedLine(readAt, widget.now()),
              key: updatedLineKey, style: style, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false),
        ),
      ],
    );
  }

  static const _cartNameMaxWidth = 140.0;

  Widget _inventoryBanner() {
    if (_inventoryError != null) {
      return Material(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text('Inventory did not load: $_inventoryError')),
              TextButton(onPressed: _selling ? null : _loadInventory, child: const Text('Retry')),
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

  /// A plain, non-blocking strip above the usual inventory banner when _inventorySource (set by _loadInventory) is
  /// the cache or the adhoc path - see lib/sync/center_stock.dart's own file comment for what each fallback step can and
  /// can't promise. Null (nothing shown) for the live, ordinary case, and for stock read from the state system alone
  /// ([InventorySource.state]): that only means Mazama's server didn't answer, which the app-wide banner says
  /// (server_link.dart); each line still says which figures are the state's (Package.mgFigure) - unless
  /// that stock is too old to sell from, when it offers Retry.
  Widget? _degradedInventoryNotice() {
    final source = _inventorySource;
    if (source == null) return null;
    final ownRead = source == InventorySource.live || source == InventorySource.state;
    if (ownRead && !_tooOldToSell) return null;
    final String text;
    IconData icon = Icons.cloud_off;
    if (ownRead) {
      // the 3-day limit refuses this stock, and its refusal says Retry: the strip offers it, as the kept copy's does
      icon = Icons.history;
      text = 'The stock on this phone is too old to sell from. Retry to load it again.';
    } else if (source == InventorySource.adhoc) {
      // This center isn't configured in Mazama yet - there is no "server down" problem to retry past, so this
      // case gets its own icon/wording rather than reusing the cloud-off "something's unreachable" framing the
      // cache tier has. See coa_data_resolver.dart's own file comment for what's actually happening:
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
      // Mazama's server didn't answer either: the app-wide banner says that; this is about the state.
      final tooOld = _tooOldToSell;
      text = 'The state system couldn\'t be reached - showing the last inventory '
          'downloaded$age. Counts may no longer be accurate.${cachedEstimatesNote(_inventory ?? const [])}'
          '${tooOld ? ' It is too old to sell from: Retry once the state system can be reached.' : ''}';
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
            // The adhoc banner shows only once the load has returned (_inventorySource is set then): Retry is offered
            // even while some lots are still being uploaded in the background or have no lab report on file.
            TextButton(onPressed: _selling ? null : _loadInventory, child: const Text('Retry')),
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

  /// The cart's own running dose total - the figure a worker actually needs while building a sale, not a static inventory
  /// count. Shows mg TPE (the real per-unit dose, l.group.tpeMg) and mg raw psilocybin (weightPerUnit x
  /// analyteWeight - mg TPE can run well above the raw psilocybin content alone, which is why these are two different
  /// numbers, and why only the second one is what the service-center duration table and the 50mg cap both
  /// read) side by side, then the minimum administration-session duration the mg-psilocybin figure implies -
  /// primary dose alone, then primary + secondary ("w/ booster", the worker's own term for the secondary
  /// dose) - and the session stopwatch (_sessionTimerRow) a worker starts once the client actually begins.
  Widget _cartDoseSummary() {
    if (_lines.isEmpty) {
      // Nothing to total yet - the empty-cart message below covers this. A timer still running (the cart was just sold
      // and its client's session goes on) stays in view, so it can be seen and reset.
      return _sessionTimerStart == null ? const SizedBox.shrink() : Align(alignment: Alignment.centerLeft, child: _sessionTimerRow());
    }
    // a line whose only figure is the state's psilocybin adds no TPE; the TPE total then says it leaves them out
    final tpeLines = _lines.where((l) => l.group.mgFigure == MgFigure.tpe);
    final tpeMg = tpeLines.fold<double>(0, (sum, l) => sum + l.group.tpeMg * l.qty);
    final tpePart = tpeLines.isEmpty
        ? 'TPE not known'
        : '${tpeMg.toStringAsFixed(1)} mg TPE${tpeLines.length < _lines.length ? ' (where known)' : ''}';
    // the core's answer for the cart sold now, counted from the lots it draws, asked again only when the cart's lines change
    final limits = _cartLimitsNow().limits;
    final totalPsilocybinMg = limits.psilocybinMgValue;
    // Null above the 50mg cap or when a figure isn't known - the cap refuses such a sale outright (see _capError), so
    // there's nothing meaningful left to show here; this just never gets the chance to look wrong.
    final primaryDuration = limits.sessionInitial;
    final bothDosesDuration = limits.session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(totalPsilocybinMg == null
            ? '$tpePart · mg psilocybin not known'
            : '$tpePart · ${totalPsilocybinMg.toStringAsFixed(1)} mg psilocybin in the cart'),
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

/// One cart's pricing controls while another cart is showing.
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
typedef _CartSummary = ({CartSlot slot, int lines, DateTime? timerStart, SessionDose? dose});

/// A cart's running timer as the carts list shows it: the time left in its client's session, redrawn every
/// second against [now] (sessionTimeLeft), or how long it has run when there's no dose to time it against.
class _TimerText extends StatefulWidget {
  final DateTime start;
  final DateTime Function() now;
  final SessionDose? dose;
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
    final minutes = dose?.minutes;
    final left = dose == null || minutes == null
        ? null
        : sessionTimeLeft(Duration(minutes: minutes), elapsed, booster: dose.booster, unknown: dose.unknown);
    return Text(left ?? 'elapsed ${formatElapsed(elapsed)}', overflow: TextOverflow.ellipsis);
  }
}
