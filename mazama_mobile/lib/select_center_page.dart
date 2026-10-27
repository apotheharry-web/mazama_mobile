// Shown right after sign-in (or right after MazamaApp restores a saved session): asks the real state system
// (GetApplicableLicenses, see licenses_client.dart) which service center(s) the signed-in account can act for,
// and lands on CartPage for whichever one the worker is opening. A real captured HAR showed one account with
// THREE service-center licenses, not one - so this can't just auto-pick "the only one" unconditionally; it
// only skips the picker when there really is only one.
//
// Also re-checks the session is fresh (ensureFreshSession) before calling GetApplicableLicenses, same as
// CartPage does on its own periodic timer - this page can sit on screen for a while too (the picker, if there's
// more than one center) before the worker picks anything.
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'cart_page.dart';
import 'center_home_page.dart';
import 'center_status_client.dart' as center_status_client;
import 'center_stock_page.dart';
import 'coa_data_client.dart' as coa_data_client;
import 'debug_tools_page.dart';
import 'demo/demo_backend.dart';
import 'demo/demo_banner.dart';
import 'device_id.dart';
import 'flow/flow_spec.dart';
import 'inventory_portal_page.dart';
import 'licenses_client.dart';
import 'main.dart' show goToSignIn;
import 'packages_client.dart';
import 'product_names.dart';
import 'mazama_inventory_cache_store.dart';
import 'mazama_inventory_client.dart' as mazama_inventory_client;
import 'mazama_inventory_page.dart';
import 'order_client.dart' as order_client;
import 'order_form_page.dart';
import 'order_par_page.dart';
import 'par_client.dart' as par_client;
import 'sheets_client.dart' as sheets_client;
import 'reply_store.dart';
import 'resilience_options.dart';
import 'server_health.dart';
import 'server_link.dart' as server_link;
import 'session.dart';
import 'session_store.dart';
import 'state_packages_client.dart' as state_packages_client;
import 'stock_cache_store.dart';
import 'stock_rows.dart';
import 'stock_summary.dart';

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

  /// What the stock page keeps for when it can't reach everything (stock_cache_store.dart). Overridable for tests;
  /// by default in the session store's folder (so a page opened after "Switch center" keeps it there too).
  final StockCacheStore stockCacheStore;

  /// Where an older build kept the last Mazama stock the server sent: read once, when [replyStore] has none yet, and
  /// moved there. Overridable for tests; by default in the session store's folder.
  final MazamaInventoryCacheStore mazamaInventoryCacheStore;

  /// The last good reply of each read (reply_store.dart, README R56): par levels, the stock page's sheets and Mazama's
  /// stock, shown while the server can't be reached. Overridable for tests; by default in the session store's folder
  /// (the app's own folder, as the server link's).
  final ReplyStore replyStore;

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
    this.fetchParLevels = par_client.fetchParLevels,
    this.saveParLevels = par_client.saveParLevels,
    this.fetchMazamaInventory = _mazamaInventory,
    this.fetchProductSheets = _productSheets,
    this.submitOrder = _submitOrder,
    DeviceIdStore? deviceIdStore,
    this.fetchMazamaLicenses = _mazamaLicenses,
    StockCacheStore? stockCacheStore,
    MazamaInventoryCacheStore? mazamaInventoryCacheStore,
    ReplyStore? replyStore,
    this.demo,
  })  : deviceIdStore = deviceIdStore ?? DeviceIdStore(dataDir: sessionStore.dataDir),
        replyStore = replyStore ?? ReplyStore(dataDir: sessionStore.dataDir),
        stockCacheStore = stockCacheStore ?? StockCacheStore(dataDir: sessionStore.dataDir),
        mazamaInventoryCacheStore = mazamaInventoryCacheStore ?? MazamaInventoryCacheStore(dataDir: sessionStore.dataDir),
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
          fetchParLevels: demo.fetchParLevels,
          saveParLevels: demo.saveParLevels,
          fetchMazamaInventory: demo.fetchMazamaInventory,
          fetchProductSheets: demo.fetchProductSheets,
          submitOrder: demo.submitOrder,
          deviceIdStore: demo.deviceIdStore,
          fetchMazamaLicenses: demo.fetchMazamaLicenses,
          stockCacheStore: demo.stockCacheStore,
          mazamaInventoryCacheStore: MazamaInventoryCacheStore(dataDir: () => demo.dataDir),
          replyStore: ReplyStore(dataDir: () => demo.dataDir),
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

  void _load() {
    setState(() {
      _centers = null;
      _error = null;
      _autoOpening = false;
    });
    _ensureFreshThenFetch();
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
      if (!mounted) return;
      final centers = serviceCenters(all); // SM-21: the server's own rule
      setState(() => _centers = centers);
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
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      client.close();
    }
  }

  /// Pushes InventoryPortalPage (inventory_portal_page.dart) on top of this screen - a separate Mazama web
  /// app shown in-app via webview_flutter, not anything this page itself talks to or depends on. Reachable
  /// regardless of whether any service centers loaded, errored, or came back empty: it's not part of choosing
  /// a center, so nothing about this page's own load state should gate it.
  void _openInventoryPortal() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const InventoryPortalPage()));
  }

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
        cache: widget.stockCacheStore,
        strainOf: (name) => strainFromName(name, sharedCoaCore()),
      );

  /// The chosen center's stock page (SP-R12, SP-R13): its par levels are set before an order (SP-D19, MI-D21). The
  /// lot table's sheets are kept with when, and shown from that copy while the server can't be reached.
  CenterStockPage _stockPage(License center) {
    final kept = sheetsReplies(widget.replyStore, center.id, legacy: widget.stockCacheStore);
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
    final cache = widget.stockCacheStore;
    return OrderParPage(
      center: center,
      loadRows: () => _loadStock(center),
      loadPar: () => loadCenterPar(
          stateId: center.id, fetchPar: () => widget.fetchParLevels(center.id), replies: widget.replyStore, legacy: cache),
      loadParColumns: () => cache.loadParColumns(center.id),
      health: _health,
      saveParColumns: (columns) => cache.saveParColumns(center.id, columns),
      savePar: (levels) async {
        final stored = await widget.saveParLevels(center.id,
            workerEmail: _session.email, deviceId: await widget.deviceIdStore.idOrCreate(), levels: levels);
        try {
          await parReplies(widget.replyStore, center.id).save(stored, DateTime.now().toUtc());
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
        demo: d,
      );

  /// SP-D8, MI-D1: the chosen center's Mazama inventory | Stock | Cart home, opened on Stock.
  void _open(License center) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CenterHomePage(
          center: center,
          buildMazama: () => MazamaInventoryPage(
            load: widget.fetchMazamaInventory,
            kept: mazamaInventoryReplies(widget.replyStore, legacy: widget.mazamaInventoryCacheStore).load,
            keep: mazamaInventoryReplies(widget.replyStore).save,
            health: _health,
            orderForm: () => _orderPage(center),
          ),
          buildStock: () => _stockPage(center),
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
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _body(),
              ),
            ),
          ),
          // Always shown, whatever _body() above is doing (loading, errored, empty, or the real picker) -
          // a separate web app, not something a worker is blocked from reaching just because this account
          // happens to have no service-center access yet, or the license fetch is still in flight.
          // Not in the demo: the inventory web app is the real Mazama server (DM-D1).
          if (widget.demo == null)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: OutlinedButton.icon(
                onPressed: _openInventoryPortal,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Mazama Mushrooms Inventory'),
              ),
            ),
          ),
        ],
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
  }
}
