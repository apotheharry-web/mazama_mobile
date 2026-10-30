// Shown right after sign-in (or right after MazamaApp restores a saved session): asks the real state system
// (GetApplicableLicenses, see licenses_client.dart) which service center(s) the signed-in account can act for,
// and lands on CartPage for whichever one the worker is opening. A real captured HAR showed one account with
// THREE service-center licenses, not one - so this can't just auto-pick "the only one" unconditionally; it
// only skips the picker when there really is only one.
//
// Also re-checks the session is fresh (ensureFreshSession) before calling GetApplicableLicenses, same as
// CartPage does on its own periodic timer - this page can sit on screen for a while too (the picker, if there's
// more than one center) before the worker picks anything.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_update_card.dart';
import 'app_update_check.dart';
import 'cart_page.dart';
import 'center_home_page.dart';
import 'center_status_client.dart' as center_status_client;
import 'center_stock_page.dart';
import 'coa_data_client.dart' as coa_data_client;
import 'debug_tools_page.dart';
import 'demo/demo_backend.dart';
import 'demo/demo_banner.dart';
import 'device_id.dart';
import 'features.g.dart';
import 'flow/flow_spec.dart';
import 'licenses_client.dart';
import 'main.dart' show goToSignIn;
import 'packages_client.dart';
import 'product_names.dart';
import 'mazama_inventory_client.dart' as mazama_inventory_client;
import 'mazama_inventory_page.dart';
import 'order_client.dart' as order_client;
import 'order_form_page.dart';
import 'order_par_page.dart';
import 'par_client.dart' as par_client;
import 'par_columns.dart';
import 'sheets_client.dart' as sheets_client;
import 'resilience_options.dart';
import 'sales_page.dart';
import 'server_health.dart';
import 'server_link.dart' as server_link;
import 'session.dart';
import 'session_store.dart';
import 'state_packages_client.dart' as state_packages_client;
import 'stock_rows.dart';
import 'stock_summary.dart';
import 'sync/sync_datasets.dart';
import 'sync/updated_line.dart';

class SelectCenterPage extends StatefulWidget {
  /// The signed-in worker's current session. May be replaced with a renewed one (see _ensureFreshThenFetch)
  /// before this page is done with it - whatever CartPage ultimately gets is always the freshest copy.
  final Session session;
  final FlowSpec spec;
  final SessionStore sessionStore;

  /// Overridable for tests, so a widget test never makes a real network call - defaults to the real
  /// fetchApplicableLicenses against the live state system.
  final Future<List<License>> Function(String accessToken) fetchLicenses;

  /// Forwarded straight through to whichever CartPage this page opens - see CartPage's own fetchPackages
  /// field for why. Named differently from the top-level fetchPackages function it defaults to, so the two
  /// don't shadow each other in this constructor.
  final Future<List<Package>> Function(int stateId) fetchCenterPackages;

  /// Forwarded straight through to whichever CartPage this page opens - see CartPage's own field by this name
  /// (and resilience_options.dart's file comment) for what it controls. Defaults to `const ResilienceOptions()`
  /// so a call site that never passes one (every existing test, and main.dart unless it's been given its own)
  /// gets today's behavior unchanged.
  final ResilienceOptions resilienceOptions;

  /// Forwarded straight through to whichever CartPage this page opens - see CartPage's own field by this name
  /// for what it's for (item 2's merge, run on every load, not just a tier-2 fallback). Overridable for tests
  /// for the same reason as fetchCenterPackages: a widget test exercising this page's own auto-open/tap-through
  /// never makes a real network call either. Defaults to the real fetchRawPackagesFromState, referenced
  /// through an aliased import for the same reason as CartPage's own default does.
  final Future<List<Object?>> Function(int stateId, {required String accessToken}) fetchRawPackagesFromState;

  /// Forwarded straight through to whichever CartPage this page opens - see CartPage's own field by this name.
  /// Overridable for tests, same reasoning as fetchRawPackagesFromState above. Defaults to the upload through the
  /// app's server link (server_link.dart: the newest snapshot waits while the server can't be reached).
  final Future<Map<String, Object?>> Function(int stateId, List<Object?> records, {required String workerEmail, required String deviceId}) uploadInventorySnapshot;

  /// The Sales page's read (specs/center-web CW-R10): the center's GetSalesRecords from the state system with the
  /// session's token. Overridable for tests (a live network call otherwise); the demo's in demo mode.
  final Future<List<Object?>> Function(int stateId, {required String accessToken}) fetchSalesRecords;

  /// The Sales page's upload of every record read: through the app's server link by default (server_link.dart: the
  /// newest read waits while the server can't be reached). Overridable for tests; the demo's sends nothing.
  final Future<Map<String, Object?>> Function(int stateId, List<Object?> records,
      {required String workerEmail, required String deviceId}) uploadSalesSnapshot;

  /// Forwarded straight through to whichever CartPage this page opens - see CartPage's own field by this name.
  /// Overridable for tests, same reasoning as fetchRawPackagesFromState above. Defaults to the submission through
  /// the app's server link (server_link.dart).
  final Future<coa_data_client.CoaData?> Function({
    required String lotGuid,
    required int representativePackageId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    double? statePsilocybin,
  }) submitCoaForLot;

  /// The center's par levels (SP-R9), set or confirmed when ordering (MI-D21): read, and saved as the signed-in worker on this install's device id
  /// (SP-D5). Overridable for tests, defaulting to the real par_client.dart calls.
  final Future<List<ParLevel>> Function(int stateId) fetchParLevels;
  final Future<List<ParLevel>> Function(int stateId,
      {required String workerEmail, required String deviceId, required List<ParLevel> levels}) saveParLevels;

  /// The Mazama inventory page's mix (specs/mazama-inventory MI-R3): route C12 by default, the demo's in demo mode.
  /// Overridable for tests.
  final Future<mazama_inventory_client.MazamaInventory> Function() fetchMazamaInventory;

  /// The stock page's product information sheets (specs/stock-page SP-D11): route C13 by default, the demo's in demo
  /// mode. Overridable for tests.
  final Future<List<sheets_client.ProductSheet>> Function(int stateId) fetchProductSheets;

  /// Sends an order from the Mazama inventory page's form (specs/mazama-inventory MI-R6): route C14 by default, the
  /// demo's in demo mode. Overridable for tests.
  final Future<order_client.OrderReceipt> Function(int stateId,
      {required String workerEmail,
      required String deviceId,
      required List<order_client.OrderLine> lines,
      required String note}) submitOrder;

  /// This install's id, sent with a par save (device_id.dart). Overridable for tests; by default in the session
  /// store's folder.
  final DeviceIdStore deviceIdStore;

  /// SP-R8, SP-R13: Mazama's manufacturer licenses from /p/center-status, kept for drawing state-only stock.
  /// Overridable for tests.
  final Future<List<String>> Function(int stateId) fetchMazamaLicenses;

  /// The par table's columns chosen on this phone (par_columns.dart, SP-D14). Overridable for tests; by default in the
  /// session store's folder (so a page opened after "Switch center" keeps them there too).
  final ParColumnsStore parColumnsStore;

  /// What the phone knows (the sync engine's datasets, specs/phone-sync): par levels, the stock page's sheets, drawn
  /// rows and Mazama licenses, Mazama's stock and the Sales tab's read, shown while their source can't be reached. Overridable for tests; by default in
  /// the session store's folder (the app's own folder, the engine's database), the demo's in its own folder.
  final Datasets datasets;

  /// The feature registry (specs/features FR-3) the picker, the center home's tabs and their pages follow: the
  /// generated one in the app (fixed per release, FT-D2); tests pass a copy with features off.
  final Map<String, Feature> featureTable;

  /// specs/app-updates AU-D10: the checker whose offer the picker and the center home show (the app's, from
  /// app_update_check.dart's appUpdateChecker, when null); never in the demo.
  final AppUpdateChecker? updateChecker;

  SelectCenterPage({
    super.key,
    required this.session,
    required this.spec,
    required this.sessionStore,
    Future<List<License>> Function(String)? fetchLicenses,
    Future<List<Package>> Function(int)? fetchCenterPackages,
    this.resilienceOptions = const ResilienceOptions(),
    this.fetchRawPackagesFromState = state_packages_client.fetchRawPackagesFromState,
    this.uploadInventorySnapshot = server_link.linkUploadInventorySnapshot,
    this.submitCoaForLot = server_link.linkSubmitCoaForLot,
    this.fetchSalesRecords = fetchSalesRecordsFromState,
    this.uploadSalesSnapshot = server_link.linkUploadSalesSnapshot,
    this.fetchParLevels = par_client.fetchParLevels,
    this.saveParLevels = par_client.saveParLevels,
    this.fetchMazamaInventory = _mazamaInventory,
    this.fetchProductSheets = _productSheets,
    this.submitOrder = _submitOrder,
    DeviceIdStore? deviceIdStore,
    this.fetchMazamaLicenses = _mazamaLicenses,
    ParColumnsStore? parColumnsStore,
    Datasets? datasets,
    this.demo,
    this.featureTable = features,
    this.updateChecker,
  })  : deviceIdStore = deviceIdStore ?? DeviceIdStore(dataDir: sessionStore.dataDir),
        datasets = datasets ?? Datasets.forDir(sessionStore.dataDir),
        parColumnsStore = parColumnsStore ?? ParColumnsStore(dataDir: sessionStore.dataDir),
        fetchLicenses = fetchLicenses ?? fetchApplicableLicenses,
        fetchCenterPackages = fetchCenterPackages ?? fetchPackages;

  /// Demo mode (specs/demo-mode): the backend every function above comes from, forwarded to the cart (and back here
  /// through Switch center) so nothing reached from the demo leaves the phone. Null for a real sign-in.
  final DemoBackend? demo;

  /// The demo center's picker: every function from [demo], the demo session (never saved or renewed).
  SelectCenterPage.demo({
    Key? key,
    required DemoBackend demo,
    required FlowSpec spec,
    required SessionStore sessionStore,
    ResilienceOptions resilienceOptions = const ResilienceOptions(),
  }) : this(
          key: key,
          session: demo.session,
          spec: spec,
          sessionStore: sessionStore,
          fetchLicenses: demo.fetchLicenses,
          fetchCenterPackages: demo.fetchPackages,
          resilienceOptions: resilienceOptions,
          fetchRawPackagesFromState: demo.fetchRawPackagesFromState,
          uploadInventorySnapshot: demo.uploadInventorySnapshot,
          submitCoaForLot: demo.submitCoaForLot,
          fetchSalesRecords: demo.fetchSalesRecords,
          uploadSalesSnapshot: demo.uploadSalesSnapshot,
          fetchParLevels: demo.fetchParLevels,
          saveParLevels: demo.saveParLevels,
          fetchMazamaInventory: demo.fetchMazamaInventory,
          fetchProductSheets: demo.fetchProductSheets,
          submitOrder: demo.submitOrder,
          deviceIdStore: demo.deviceIdStore,
          fetchMazamaLicenses: demo.fetchMazamaLicenses,
          parColumnsStore: ParColumnsStore(dataDir: () => demo.dataDir),
          datasets: demo.engine.datasets, // the demo's own database (PS-R8)
          demo: demo,
        );

  @override
  State<SelectCenterPage> createState() => _SelectCenterPageState();
}

Future<order_client.OrderReceipt> _submitOrder(int stateId,
        {required String workerEmail,
        required String deviceId,
        required List<order_client.OrderLine> lines,
        required String note}) =>
    order_client.submitOrder(stateId, workerEmail: workerEmail, deviceId: deviceId, lines: lines, note: note);

Future<List<sheets_client.ProductSheet>> _productSheets(int stateId) => sheets_client.fetchProductSheets(stateId);

Future<mazama_inventory_client.MazamaInventory> _mazamaInventory() => mazama_inventory_client.fetchMazamaInventory();

Future<List<String>> _mazamaLicenses(int stateId) async =>
    (await center_status_client.fetchCenterStatus(stateId)).mazamaLicenses;

class _SelectCenterPageState extends State<SelectCenterPage> {
  List<License>? _centers;
  String? _error;
  bool _autoOpening = false;

  /// specs/phone-sync PS-R3, PS-R7: the licenses shown are this worker's copy kept from the last good read (shown at
  /// once while the state is asked, and kept on screen when it can't be reached), read then; null when they are the
  /// state's answer just now.
  DateTime? _keptAt;

  /// Starts as widget.session but may be swapped for a renewed one - _open() always hands CartPage this copy,
  /// never widget.session directly, so CartPage never starts out with a session that's already stale.
  late Session _session;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    if (widget.demo != null) setDemoMode(true);
    _load();
  }

  Future<void> _load() {
    final kept = _keptLicenses();
    setState(() {
      _centers = kept?.$1;
      _error = null;
      _autoOpening = false;
      _keptAt = kept?.$2;
    });
    return _ensureFreshThenFetch();
  }

  /// The state couldn't be reached: this worker's kept licenses stay on screen (with their age) if there are any, and
  /// true; else false, for the error as before.
  bool _keepShowingKept() {
    final kept = _keptLicenses();
    if (kept == null) return false;
    setState(() {
      _centers = kept.$1;
      _keptAt = kept.$2;
    });
    return true;
  }

  Future<void> _ensureFreshThenFetch() async {
    final client = http.Client();
    try {
      final fresh = await ensureFreshSession(_session, widget.spec, client: client);
      if (fresh.accessToken != _session.accessToken) {
        await widget.sessionStore.save(fresh.toJson());
      }
      if (!mounted) return;
      _session = fresh;

      final all = await widget.fetchLicenses(_session.accessToken);
      _keepLicenses(all);
      if (!mounted) return;
      // SM-21: the server's own rule; FR-3: and only license types with a feature on for them (Q3)
      final centers = serviceCenters(all).where((l) => licenseTypeListed(l.licenseType, table: widget.featureTable)).toList();
      setState(() {
        _centers = centers;
        _keptAt = null;
      });
      if (centers.length == 1) {
        // Only one license to act for at all - skip the picker, but only after this frame finishes building,
        // since navigating straight out of a Future callback mid-build is the kind of thing that produces
        // "setState called during build" errors depending on exactly when the Future resolves.
        setState(() => _autoOpening = true);
        WidgetsBinding.instance.addPostFrameCallback((_) => _open(centers.single));
      }
    } on SessionExpired catch (e) {
      if (!mounted) return;
      await goToSignIn(context, spec: widget.spec, sessionStore: widget.sessionStore, message: e.message);
    } on SessionRenewalUnavailable catch (e) {
      // Not a dead session - just the state system being unreachable or erroring right now. Surfaced through
      // the same retryable _error UI as any other fetch failure below (a "Try again" button, nothing cleared
      // on disk), rather than forcing a sign-in over a problem that has nothing to do with this account's
      // credentials.
      if (!mounted) return;
      if (_keepShowingKept()) return; // PS-R3: unreachable, this worker's kept licenses
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      // PS-R3: only when the state couldn't be reached; any other failure (a refusal, a bug) is the error, as before
      final unreachable = (e is LicensesError && e.unreachable) || e is SocketException || e is TimeoutException;
      if (unreachable && _keepShowingKept()) return;
      setState(() => _error = e.toString());
    } finally {
      client.close();
    }
  }

  /// The licenses dataset's key: the signed-in worker's (another worker on this phone never sees them).
  String get _licensesKey => _session.email.trim().toLowerCase();

  /// Keeps [all], the state's answer, as this worker's licenses dataset (best effort).
  void _keepLicenses(List<License> all) {
    try {
      widget.datasets.put(
          Dataset.licenses,
          _licensesKey,
          jsonEncode([
            for (final l in all)
              {'id': l.id, 'licenseId': l.licenseId, 'licenseName': l.licenseName, 'licenseType': l.licenseType}
          ]),
          source: widget.demo != null ? sourceDemo : sourceState); // PS-R8: the demo's rows say demo
    } catch (_) {
      // nothing kept this time
    }
  }

  /// The service centers of the licenses kept, with when they were read; null when none (or none readable).
  (List<License>, DateTime)? _keptLicenses() {
    try {
      final row = widget.datasets.read(Dataset.licenses, _licensesKey);
      if (row == null) return null;
      final body = jsonDecode(row.body);
      if (body is! List) return null;
      final centers = serviceCenters(licensesFromJson(List<Object?>.from(body)))
          .where((l) => licenseTypeListed(l.licenseType, table: widget.featureTable))
          .toList();
      return centers.isEmpty ? null : (centers, row.fetchedAt);
    } catch (_) {
      return null;
    }
  }

  /// FR-3: whether [feature] is on for [center]'s license type.
  bool _on(String feature, License center) => featureOnForLicense(feature, center.licenseType, table: widget.featureTable);

  /// Whether no saved cart (draft) of any of [centers] holds a line.
  Future<bool> _allCartsEmpty(List<License> centers) async {
    for (final c in centers) {
      if (!await centerCartsEmpty(c.id, dataDir: widget.sessionStore.dataDir)) return false;
    }
    return true;
  }

  /// The update checker whose offer this picker and its center homes show; none in the demo (DM-D1).
  AppUpdateChecker? get _updates => widget.demo != null ? null : (widget.updateChecker ?? appUpdateChecker);

  /// Debug-build-only entry point to DebugToolsPage, the hub for every kDebugMode-only diagnostic screen this
  /// app has (that file's own header comment has the full reasoning) - kDebugMode is a compile-time constant,
  /// so this button (and the import above) are simply never compiled into a profile/release build at all, not
  /// just hidden at runtime. Passes whichever center is already loaded here, if any, as a starting state-id
  /// convenience for whichever tool is opened from the hub - not a restriction: every tool's own field is
  /// still freely editable.
  void _openDebugDiagnostics() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DebugToolsPage(
        session: _session,
        spec: widget.spec,
        sessionStore: widget.sessionStore,
        initialStateId: (_centers != null && _centers!.isNotEmpty) ? _centers!.first.id : null,
      ),
    ));
  }

  /// The app's server tracker for the pages' "reload when it answers again" (server_link.dart); none in the demo.
  ServerHealth? get _health => widget.demo == null ? server_link.serverLink.health : null;

  /// A state token for the stock page's state reads: the session as last saved (CartPage renews it while it is open),
  /// renewed first when it is about to expire (ensureFreshSession, the cart's own rule), the renewal saved. Throws
  /// SessionExpired when it can't be renewed: the page then asks the worker to sign in again.
  Future<String> _freshStateToken() async {
    final current = Session.fromJson(await widget.sessionStore.load()) ?? _session;
    final client = http.Client();
    try {
      final fresh = await ensureFreshSession(current, widget.spec, client: client);
      if (fresh.accessToken != current.accessToken) await widget.sessionStore.save(fresh.toJson());
      _session = fresh;
      return fresh.accessToken;
    } finally {
      client.close();
    }
  }

  /// The chosen center's stock rows (SP-R12, SP-R13, SP-D9, SP-D10), for the stock page and the order's par step: the
  /// cart's merged inventory (the lots /p/packages returned, with the state's live quantities), else the state's own
  /// records, else the last drawn here (stock_rows.dart).
  Future<StockLoad> _loadStock(License center) => loadCenterStock(
        stateId: center.id,
        fetchServerPackages: () => widget.fetchCenterPackages(center.id),
        fetchStateRecords: () async => widget.fetchRawPackagesFromState(center.id, accessToken: await _freshStateToken()),
        fetchMazamaLicenses: () => widget.fetchMazamaLicenses(center.id),
        datasets: widget.datasets,
        strainOf: strainFromName,
      );

  /// The chosen center's stock page (SP-R12, SP-R13): its par levels are set before an order (SP-D19, MI-D21). The
  /// lot table's sheets are kept with when, and shown from that copy while the server can't be reached.
  CenterStockPage _stockPage(License center) {
    final kept = sheetsDataset(widget.datasets, center.id);
    return CenterStockPage(
      center: center,
      loadRows: () => _loadStock(center),
      onSignInAgain: (context) => goToSignIn(context,
          spec: widget.spec, sessionStore: widget.sessionStore, message: 'Your state system sign-in has expired - please sign in again.'),
      loadSheets: () => widget.fetchProductSheets(center.id),
      keepSheets: kept.save,
      keptSheets: kept.load,
      health: _health,
    );
  }

  /// MI-D21: the order's first step, the center's par levels set or confirmed: par from the server, else the copy kept
  /// for offline, and saved as the session's worker on this install's device id (SP-D5); then the order form (MI-D6),
  /// starting from the levels confirmed.
  OrderParPage _orderPage(License center) {
    final columns = widget.parColumnsStore;
    return OrderParPage(
      center: center,
      loadRows: () => _loadStock(center),
      loadPar: () => loadCenterPar(
          stateId: center.id, fetchPar: () => widget.fetchParLevels(center.id), datasets: widget.datasets),
      loadParColumns: () => columns.load(center.id),
      health: _health,
      saveParColumns: (chosen) => columns.save(center.id, chosen),
      savePar: (levels) async {
        final stored = await widget.saveParLevels(center.id,
            workerEmail: _session.email, deviceId: await widget.deviceIdStore.idOrCreate(), levels: levels);
        try {
          await parDataset(widget.datasets, center.id).save(stored, DateTime.now().toUtc());
        } catch (_) {
          // the copy for offline is best effort; the server has the levels
        }
        return stored;
      },
      orderForm: (levels) => OrderFormPage(
        center: center,
        loadPar: () async => levels,
        submit: (lines, note) async => widget.submitOrder(center.id,
            workerEmail: _session.email, deviceId: await widget.deviceIdStore.idOrCreate(), lines: lines, note: note),
      ),
    );
  }

  /// The demo's cart: every function from the demo backend, its stores in the demo's own folder, and the sale through
  /// the demo's confirming client (DM-R1).
  CartPage _demoCart(DemoBackend d, License center, ValueChanged<int> onDraftCountChanged) => CartPage(
        session: _session,
        center: center,
        spec: widget.spec,
        sessionStore: widget.sessionStore,
        fetchPackages: d.fetchPackages,
        fetchPackagesFromState: d.fetchPackagesFromState,
        fetchRawPackagesFromState: d.fetchRawPackagesFromState,
        uploadInventorySnapshot: d.uploadInventorySnapshot,
        centerIsConfigured: d.centerIsConfigured,
        fetchCartSettings: d.fetchCartSettings,
        resolveAdhocInventory: d.resolveAdhocInventory,
        submitCoaForLot: d.submitCoaForLot,
        keepCoaLotForLater: d.keepCoaLotForLater,
        queueCoaUploads: d.queueCoaUploads,
        coaUploadPending: d.coaUploadPending,
        inventoryCacheStore: d.inventoryCacheStore,
        enrichmentStore: d.enrichmentStore,
        cartStore: d.cartStore,
        sessionTimerStore: d.sessionTimerStore,
        cartSlotsStore: d.cartSlotsStore,
        resilienceOptions: widget.resilienceOptions,
        fetchLabel: d.fetchLabel,
        fetchLicenses: d.fetchLicenses,
        postSaleLog: d.postSaleLog,
        postSaleFailure: d.postSaleFailure,
        scanMatch: d.scanMatch,
        deviceIdStore: d.deviceIdStore,
        httpClientFactory: d.saleClient,
        onDraftCountChanged: onDraftCountChanged,
        requestStockRefresh: (_) {}, // the demo's stock stays as it was (DM-R1)
        demo: d,
        featureTable: widget.featureTable,
      );

  /// The chosen center's Sales page (CW-R10): its sales read with a fresh state token, every record read uploaded as
  /// the session's worker on this install's device id (never in the demo).
  SalesPage _salesPage(License center) => SalesPage(
        stateId: center.id,
        load: () async => widget.fetchSalesRecords(center.id, accessToken: await _freshStateToken()),
        upload: (records) async {
          await widget.uploadSalesSnapshot(center.id, records,
              workerEmail: _session.email, deviceId: await widget.deviceIdStore.idOrCreate());
        },
        datasets: widget.datasets,
        demo: widget.demo != null,
      );

  /// SP-D8, MI-D1, CW-R10: the chosen center's Mazama inventory | Stock | Cart | Sales home, opened on Stock.
  void _open(License center) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CenterHomePage(
          center: center,
          featureTable: widget.featureTable,
          buildMazama: () => MazamaInventoryPage(
            load: widget.fetchMazamaInventory,
            kept: mazamaInventoryDataset(widget.datasets).load,
            keep: mazamaInventoryDataset(widget.datasets).save,
            health: _health,
            orderForm: _on('ordering', center) ? () => _orderPage(center) : null,
          ),
          buildStock: () => _stockPage(center),
          buildSales: () => _salesPage(center),
          buildUpdateCard: _updates == null
              ? null
              : (draftCount) => AppUpdateCard(
                    checker: _updates!,
                    cartsEmpty: () async =>
                        draftCount == 0 && await centerCartsEmpty(center.id, dataDir: widget.sessionStore.dataDir),
                  ),
          buildCart: (onDraftCountChanged) => widget.demo != null
              ? _demoCart(widget.demo!, center, onDraftCountChanged)
              : CartPage(
            session: _session,
            center: center,
            spec: widget.spec,
            sessionStore: widget.sessionStore,
            fetchPackages: widget.fetchCenterPackages,
            resilienceOptions: widget.resilienceOptions,
            fetchRawPackagesFromState: widget.fetchRawPackagesFromState,
            uploadInventorySnapshot: widget.uploadInventorySnapshot,
            submitCoaForLot: widget.submitCoaForLot,
            onDraftCountChanged: onDraftCountChanged,
            health: _health,
            featureTable: widget.featureTable,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a service center'),
        // See _openDebugDiagnostics' own comment - kDebugMode means this action (and everything it could
        // reach) simply isn't compiled into a profile/release build, not just hidden behind a runtime check.
        actions: [
          if (kDebugMode)
            IconButton(
              onPressed: _openDebugDiagnostics,
              icon: const Icon(Icons.bug_report_outlined),
              tooltip: 'Adhoc-COA diagnostics (debug)',
            ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _body(),
        ),
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: _load, child: const Text('Try again')),
        ],
      );
    }
    if (_centers == null || _autoOpening) {
      return const CircularProgressIndicator();
    }
    if (_centers!.isEmpty) {
      return const Text(
        'This account has no service-center access on the state system. Ask whoever manages licenses there to add it.',
        textAlign: TextAlign.center,
      );
    }
    final updates = _updates;
    final list = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // AU-D10: on the picker, no saved cart of any listed center may hold a line (review I2)
          if (updates != null && _centers!.any((c) => _on('app_updates', c)))
            AppUpdateCard(checker: updates, cartsEmpty: () => _allCartsEmpty(_centers!)),
          // this worker's licenses as kept (at once, and while the state can't be reached), their age, and Try again
          if (_keptAt != null) ...[
            UpdatedLine.at(_keptAt),
            TextButton(key: const ValueKey('licenses-retry'), onPressed: _load, child: const Text('Try again')),
          ],
          for (final c in _centers!) ...[
            Card(
              child: ListTile(
                title: Text(c.licenseName),
                subtitle: Text(c.licenseId),
                onTap: () => _open(c),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
    // PS-R7: pulling the list down reads the licenses again (the picker is one of MI-D5's three pull-downs)
    return RefreshIndicator(
      key: const ValueKey('licenses-refresh'),
      onRefresh: _load,
      child: ListView(
        shrinkWrap: true,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [Center(child: list)],
      ),
    );
  }
}
