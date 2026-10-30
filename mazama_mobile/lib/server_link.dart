// The phone's one link to Mazama's server (README R56): every call to a /p/ route goes through it. Designed for the
// server being down for days; selling never goes through it (the sale is sent straight to the state system) and is
// never slowed or blocked by it.
//
// The pieces, one of each for the whole app ([serverLink], set by MazamaApp):
//   - [ServerLink.health] (server_health.dart): online, or offline since when. Every /p/ client's default http.Client
//     is a ServerLinkClient (server_link_client.dart) that reports to it and, while offline, fails at once without a
//     request, so the pages' own fallbacks show straight away. A probe (GET /p/ping) re-checks on a backoff
//     (15 s doubling to 5 min) and whenever the app comes back to the foreground.
//   - [ServerLink.outbox] (server_outbox.dart): sale-attribution logs and failed-sale reports, kept on the phone with a
//     clientId until the server takes them. Par saves and orders are never queued: they say "try again later".
//   - [ServerLink.catchUp] (catch_up_store.dart): lab reports that couldn't be submitted and the newest inventory and
//     sales snapshots per center, sent again once the server answers, with what is current then.
//   - The reads the pages show while their source can't be reached (par levels, sheets, Mazama's stock, the Sales tab's
//     state read, a center's stock) are the engine's datasets (lib/sync/sync_datasets.dart, specs/phone-sync), each
//     kept with when it was read; what an older build kept elsewhere is moved there on start (sync_migration.dart).
//   - [ServerLink.coaUploads] (coa_uploader.dart): every lab report the server is missing, sent in the background at the
//     server's pace (specs/coa-upload); a lot whose report couldn't reach the server goes on the catch-up list.
//   - [ServerLink.engine] (lib/sync/sync_engine.dart, specs/phone-sync): the outbox, the catch-up work and the uploader
//     are facades over its one queue; it wakes them when the tracker comes back online.
//   - [ServerLinkBanner]: one line above every page while the server can't be reached, saying since when, that selling
//     still works, and how many reports are waiting (the engine's count). Never in the demo (which has no server at all). It is the only
//     notice of the outage: the pages say nothing of their own about it (README R87), and its close button hides it
//     for the rest of that outage ([ServerHealth.dismissBanner]); the next outage shows it again.
// When the tracker comes back online (and at start-up, and when the app returns to the foreground while online), the
// outbox and the catch-up work are sent ([ServerLink.wake]).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'catch_up_store.dart';
import 'center_status_client.dart' as center_status_client;
import 'coa_data_client.dart' show CoaData, fetchCoaDataBatch;
import 'coa_uploader.dart';
import 'configured_coa_submit.dart' as configured_coa_submit;
import 'demo/demo_banner.dart' show demoModeOn;
import 'device_id.dart';
import 'inventory_upload_client.dart' as inventory_upload_client;
import 'local_store.dart';
import 'mazama_inventory_client.dart' as mazama_inventory_client;
import 'par_client.dart' as par_client;
import 'ping_client.dart';
import 'sales_upload_client.dart' as sales_upload_client;
import 'server_error.dart';
import 'server_health.dart';
import 'sync/server_read.dart' show serverUnreachable;
import 'sync/updated_line.dart' show formatAsOf;
import 'server_outbox.dart';
import 'session.dart';
import 'session_store.dart' show SessionStore, defaultSessionDataDir;
import 'sheets_client.dart' as sheets_client;
import 'enrichment_store.dart';
import 'inventory_cache_store.dart';
import 'packages_client.dart' as packages_client;
import 'state_packages_client.dart' as state_packages_client;
import 'sync/center_stock.dart' show CenterStock, centerStockRefresher;
import 'sync/sync_datasets.dart' show Dataset, serverReadRefreshers;
import 'sync/sync_engine.dart';
import 'sync/sync_queue.dart' show QueueKind;
import 'sync/sync_tables.dart' show DatasetRow;

/// Keeps when the server went offline across app restarts (the server_health.json document of the folder's
/// LocalStore), so the banner says since when even after the phone restarted the app mid-outage.
class ServerHealthStore {
  const ServerHealthStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;
  final Directory Function() dataDir;

  static const _name = 'server_health.json';

  DateTime? loadOfflineSince() {
    try {
      final text = LocalStore.forDir(dataDir()).read(_name)?.body;
      if (text == null) return null;
      final d = jsonDecode(text);
      final ms = d is Map ? d['offlineSinceMs'] : null;
      return ms is int ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true) : null;
    } catch (_) {
      return null;
    }
  }

  void saveOfflineSince(DateTime? since) {
    try {
      final store = LocalStore.forDir(dataDir());
      if (since == null) {
        store.delete(_name);
        return;
      }
      store.write(_name, jsonEncode({'offlineSinceMs': since.millisecondsSinceEpoch}));
    } catch (_) {
      // best effort: the banner then counts from this run's first failure
    }
  }
}

class ServerLink {
  /// [coaUploads] defaults to an uploader over [health] and [catchUp], remembering what it sent beside the catch-up
  /// work; [engine] to one over the parts' own queues (a link made from its parts, as tests do).
  ServerLink(
      {required this.health,
      required this.outbox,
      required this.catchUp,
      CoaUploader? coaUploads,
      SyncEngine? engine})
      : coaUploads = coaUploads ?? CoaUploader(health: health, catchUp: catchUp, auth: catchUp.auth) {
    this.engine = engine ?? SyncEngine.over(health: health, queues: [outbox.queue, catchUp.queue, this.coaUploads.queue]);
  }

  /// The app's real link, its files in [dataDir] (the app's data folder by default): one sync engine
  /// (lib/sync/sync_engine.dart) with the real senders, and the outbox, catch-up work and uploader over its queue.
  /// [rememberOffline]: when the server went offline is kept across restarts (MazamaApp's link); the fallback
  /// [serverLink] doesn't, so nothing reaching it before MazamaApp (a test calling a client without a client of its
  /// own) can leave a later run starting offline.
  factory ServerLink.standard({Directory Function()? dataDir, SessionStore? sessionStore, bool rememberOffline = true}) {
    final dir = dataDir ?? defaultSessionDataDir;
    final healthStore = ServerHealthStore(dataDir: dir);
    final health = ServerHealth(
      probe: serverAnswers,
      rememberedOfflineSince: rememberOffline ? healthStore.loadOfflineSince() : null,
      onOfflineSinceChanged: rememberOffline ? healthStore.saveOfflineSince : null,
    );
    final sessions = sessionStore ?? SessionStore(dataDir: dir);
    final devices = DeviceIdStore(dataDir: dir);
    Future<CatchUpAuth?> auth() => savedSessionAuth(sessions, devices);
    final senders = {
      QueueKind.saleLog: outboxQueueSender(sendOutboxEntry),
      QueueKind.saleFailure: outboxQueueSender(sendOutboxEntry),
      QueueKind.inventorySnapshot: snapshotQueueSender(uploadPendingSnapshot),
      QueueKind.salesSnapshot: snapshotQueueSender(uploadPendingSnapshot),
      // one sender for the kept lab reports and the paced ones: the same chain, with the session current at send time
      QueueKind.labReport: labReportQueueSender(sendCoaLot, auth),
    };
    SyncEngine engine;
    try {
      engine = SyncEngine(store: LocalStore.forDir(dir()), health: health, senders: senders);
    } catch (e) {
      // The local database can't be opened (busy, read-only, disk full during its upgrade): the app still starts and
      // selling goes on; the queue then lives in memory for this run only.
      debugPrint('the local store could not be opened, the sync queue is kept in memory: $e');
      // The datasets are then this in-memory database's too, while the pages' own handles (Datasets.forDir) keep
      // trying the file: both best effort, as the reply store was in this case.
      engine = SyncEngine(store: LocalStore.inMemory(), health: health, senders: senders);
    }
    // specs/phone-sync phase 2: the server's reads as datasets, each read with today's client through the link
    serverReadRefreshers(
      fetchPar: (id) => par_client.fetchParLevels(id),
      fetchSheets: (id) => sheets_client.fetchProductSheets(id),
      fetchMazamaInventory: () => mazama_inventory_client.fetchMazamaInventory(),
      fetchCenterStatus: (id) => center_status_client.fetchCenterStatus(id),
      fetchCoaData: (lots) => fetchCoaDataBatch(lots),
    ).forEach(engine.register);
    // One memory of the lab reports sent, whichever way they went (the uploader, the catch-up work, a cart add).
    final sent = CoaSentMemory(store: CoaSentStore(dataDir: dir));
    final catchUp = CatchUpWork(
      health: health,
      store: CatchUpStore(dataDir: dir),
      submitCoa: (lot, auth) => submitPendingCoaLot(lot, auth, sent: sent),
      uploadSnapshot: uploadPendingSnapshot,
      auth: auth,
      queue: engine.queue,
    );
    // specs/phone-sync phase 4: a center's stock, read as the cart reads it, with the saved session (none while it
    // needs renewing, or in the demo); every state read is kept as the center's snapshot for the server.
    engine.register(
        Dataset.centerStock,
        centerStockRefresher(() async {
          if (demoModeOn.value) return null; // the demo has its own engine (demo_engine.dart): nothing of it comes here
          final session = Session.fromJson(await sessions.load());
          if (session == null || session.isDemo || session.needsRenewal()) return null;
          final deviceId = await devices.idOrCreate();
          return CenterStock(
            fetchServer: (id) => packages_client.fetchPackages(id),
            fetchRawState: (id, {required accessToken}) =>
                state_packages_client.fetchRawPackagesFromState(id, accessToken: accessToken),
            fetchFromState: (id, {required accessToken}) =>
                state_packages_client.fetchPackagesFromState(id, accessToken: accessToken),
            cache: InventoryCacheStore(dataDir: dir),
            enrichment: EnrichmentStore(dataDir: dir),
            session: () => session,
            onStateRead: (id, raw) => catchUp.keepSnapshot(id, raw, workerEmail: session.email, deviceId: deviceId),
          );
        }));
    return ServerLink(
      health: health,
      outbox: ServerOutbox(health: health, store: OutboxStore(dataDir: dir), queue: engine.queue),
      catchUp: catchUp,
      coaUploads: CoaUploader(health: health, catchUp: catchUp, auth: auth, sent: sent, queue: engine.queue),
      engine: engine,
    );
  }

  final ServerHealth health;
  final ServerOutbox outbox;
  final CatchUpWork catchUp;
  final CoaUploader coaUploads;

  /// The phone's sync engine (specs/phone-sync): everything the link still has to send waits in its queue.
  late final SyncEngine engine;

  /// Sends what is waiting (the reports, then the snapshots and kept lab reports) while the server answers. The engine
  /// also does this by itself whenever the tracker comes back online.
  void wake() => engine.wake();

  /// The app came back to the foreground: offline, probe now; online, send anything still waiting; what pages watch
  /// is refreshed when it is older than five minutes (specs/phone-sync PS-D6).
  void onForeground() => engine.onForeground();

  /// The app went to the background: the engine refreshes nothing until it is back.
  void onBackground() => engine.onBackground();

  /// [CartPage.uploadInventorySnapshot]'s default: uploads [records] (inventory_upload_client.dart). While the server
  /// can't be reached the snapshot is kept instead (only the newest per center) and sent once it answers; one that
  /// reaches the server makes any kept older one moot.
  Future<Map<String, Object?>> uploadInventorySnapshot(int stateId, List<Object?> records,
      {required String workerEmail, required String deviceId, http.Client? client}) async {
    if (health.offline) {
      catchUp.keepSnapshot(stateId, records, workerEmail: workerEmail, deviceId: deviceId);
      throw inventory_upload_client.InventoryUploadError(serverUnreachable, unreachable: true);
    }
    try {
      final out = await inventory_upload_client.uploadInventorySnapshot(stateId, records,
          workerEmail: workerEmail, deviceId: deviceId, client: client);
      catchUp.snapshotSent(stateId);
      return out;
    } catch (e) {
      if (isServerUnreachable(e)) catchUp.keepSnapshot(stateId, records, workerEmail: workerEmail, deviceId: deviceId);
      rethrow;
    }
  }

  /// The Sales page's upload (specs/center-web CW-R10): [records], the center's sales as just read from the state
  /// system, go to the ingest route (sales_upload_client.dart), as [uploadInventorySnapshot]: while the server can't be
  /// reached the read is kept instead (only the newest per center) and sent once it answers; one that reaches the
  /// server makes any kept older one moot. A refusal (an older server's 404 included) keeps nothing. A read over the
  /// route's record limit is cut to its newest records first (sales_upload_client.dart's newestSalesForUpload).
  Future<Map<String, Object?>> uploadSalesSnapshot(int stateId, List<Object?> read,
      {required String workerEmail, required String deviceId, http.Client? client}) async {
    final records = sales_upload_client.newestSalesForUpload(read);
    void keep() => catchUp.keepSnapshot(stateId, records,
        workerEmail: workerEmail, deviceId: deviceId, kind: snapshotKindSales);
    if (health.offline) {
      keep();
      throw sales_upload_client.SalesUploadError(serverUnreachable, unreachable: true);
    }
    try {
      final out = await sales_upload_client.uploadSalesSnapshot(stateId, records,
          workerEmail: workerEmail, deviceId: deviceId, client: client);
      catchUp.snapshotSent(stateId, kind: snapshotKindSales);
      return out;
    } catch (e) {
      if (isServerUnreachable(e)) keep();
      rethrow;
    }
  }

  /// [CartPage.submitCoaForLot]'s default: submits [lotGuid]'s lab report (configured_coa_submit.dart). While the
  /// tracker counts the server as offline, fails at once as unreachable without reading anything from the state system
  /// (the cart then keeps the lot, [rememberCoaLot], for a submission once the server answers). A lot the server
  /// answered is remembered as sent, so the background uploader doesn't send it again (CU-R3).
  Future<CoaData?> submitCoaForLot({
    required String lotGuid,
    required int representativePackageId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    double? statePsilocybin,
    http.Client? client,
  }) async {
    if (health.offline) throw configured_coa_submit.ConfiguredCoaSubmitError(serverUnreachable, unreachable: true);
    try {
      final data = await configured_coa_submit.submitCoaForLot(
          lotGuid: lotGuid,
          representativePackageId: representativePackageId,
          accessToken: accessToken,
          workerEmail: workerEmail,
          deviceId: deviceId,
          statePsilocybin: statePsilocybin,
          client: client);
      if (data != null) coaUploads.sent.markSent(lotGuid);
      return data;
    } catch (e) {
      if (countsAsSent(e)) coaUploads.sent.markSent(lotGuid);
      rethrow;
    }
  }

  void dispose() {
    coaUploads.dispose();
    outbox.dispose();
    catchUp.dispose();
    engine.dispose(); // after the facades, which stop listening to its queue first
    health.dispose();
  }
}

/// The app's link: MazamaApp sets it ([useServerLink]); anything that reaches a /p/ route before that (none should)
/// gets one in the app's data folder.
ServerLink get serverLink => _serverLink ??= ServerLink.standard(rememberOffline: false);
ServerLink? _serverLink;

/// [CartPage.requestStockRefresh]'s default (specs/phone-sync PS-R6): asks the app's sync engine to refresh [stateId]'s
/// center_stock dataset after a confirmed sale, never awaited; nothing happens while no refresher is registered for it.
void linkRequestStockRefresh(int stateId) => unawaited(serverLink.engine.refresh(Dataset.centerStock, '$stateId'));

/// [CartPage.watchStock]'s default (specs/phone-sync Task 8b): the app's engine's copy of [stateId]'s stock; null
/// while no link has been made the app's (a page built before MazamaApp, a test): never builds one for it.
Stream<DatasetRow?>? linkWatchStock(int stateId) => _serverLink?.engine.watch(Dataset.centerStock, '$stateId');

/// Makes [link] the app's link (MazamaApp, and tests that want their own).
void useServerLink(ServerLink link) => _serverLink = link;

/// [link] is going away (MazamaApp disposed): the next use of [serverLink] makes a fresh one, never a disposed one.
void releaseServerLink(ServerLink link) {
  if (identical(_serverLink, link)) _serverLink = null;
}

/// The catch-up work's submitter: a lot's report through configured_coa_submit.dart with the session current now. A lot
/// the server answered is remembered in [sent] (CU-R3), when given.
Future<bool> submitPendingCoaLot(PendingCoaLot lot, CatchUpAuth auth, {CoaSentMemory? sent, http.Client? client}) async {
  try {
    final data = await configured_coa_submit.submitCoaForLot(
        lotGuid: lot.lotGuid,
        representativePackageId: lot.packageId,
        accessToken: auth.accessToken,
        workerEmail: auth.workerEmail,
        deviceId: auth.deviceId,
        statePsilocybin: lot.statePsilocybin,
        client: client);
    if (data != null) sent?.markSent(lot.lotGuid);
    return data != null;
  } catch (e) {
    if (countsAsSent(e)) sent?.markSent(lot.lotGuid);
    rethrow;
  }
}

/// The catch-up work's uploader: a kept snapshot through its kind's client (inventory_upload_client.dart, or
/// sales_upload_client.dart for [snapshotKindSales]). Any other kind is never sent (an inventory upload replaces the
/// center's whole mirror, so nothing else may go there).
Future<void> uploadPendingSnapshot(PendingSnapshot s, {http.Client? client}) => switch (s.kind) {
      snapshotKindSales => sales_upload_client.uploadSalesSnapshot(s.stateId, s.records,
          workerEmail: s.workerEmail, deviceId: s.deviceId, client: client),
      snapshotKindInventory => inventory_upload_client.uploadInventorySnapshot(s.stateId, s.records,
          workerEmail: s.workerEmail, deviceId: s.deviceId, client: client),
      _ => Future.error(ArgumentError('no upload for a ${s.kind} snapshot')),
    };

/// The worker's session as last saved (the cart renews and saves it), when it isn't about to expire, with this
/// install's id; null otherwise (the lab reports then wait: this never signs in or renews by itself).
Future<CatchUpAuth?> savedSessionAuth(SessionStore sessions, DeviceIdStore devices, {DateTime Function() now = DateTime.now}) async {
  final session = Session.fromJson(await sessions.load());
  if (session == null || session.isDemo || session.needsRenewal(now: now)) return null;
  return CatchUpAuth(accessToken: session.accessToken, workerEmail: session.email, deviceId: await devices.idOrCreate());
}

/// [CartPage.postSaleLog]'s default: the log goes in the outbox (sent now if the server answers, else later).
Future<void> queueSaleLog(int stateId,
        {required String workerEmail, required String deviceId, required List<Map<String, Object?>> request, required Object? response}) =>
    serverLink.outbox.addSaleLog(stateId, workerEmail: workerEmail, deviceId: deviceId, request: request, response: response);

/// [CartPage.postSaleFailure]'s default: the report goes in the outbox, as [queueSaleLog].
Future<void> queueSaleFailure(int stateId,
        {required String workerEmail, required String deviceId, required String reason, required List<Map<String, Object?>> request}) =>
    serverLink.outbox.addSaleFailure(stateId, workerEmail: workerEmail, deviceId: deviceId, reason: reason, request: request);

/// [CartPage.submitCoaForLot]'s default, through the app's link.
Future<CoaData?> linkSubmitCoaForLot({
  required String lotGuid,
  required int representativePackageId,
  required String accessToken,
  required String workerEmail,
  required String deviceId,
  double? statePsilocybin,
}) =>
    serverLink.submitCoaForLot(
        lotGuid: lotGuid,
        representativePackageId: representativePackageId,
        accessToken: accessToken,
        workerEmail: workerEmail,
        deviceId: deviceId,
        statePsilocybin: statePsilocybin);

/// [CartPage.queueCoaUploads]'s default, and the adhoc resolver's (coa_data_resolver.dart): [lots] go to the app's
/// background uploader (coa_uploader.dart), which sends each report the server is missing at the server's pace.
void queueCoaUploads(List<CoaUploadLot> lots, {CoaLotResolved? onResolved}) =>
    serverLink.coaUploads.enqueue(lots, onResolved: onResolved);

/// [CartPage.coaUploadPending]'s default: whether the app's background uploader has [lotGuid] waiting or being sent.
bool coaUploadPending(String lotGuid) => serverLink.coaUploads.isPending(lotGuid);

/// [CartPage.keepCoaLotForLater]'s default: a lot whose report couldn't reach the server waits in the app's catch-up
/// work (catch_up_store.dart).
void rememberCoaLot(int stateId, {required String lotGuid, required int packageId, double? statePsilocybin}) =>
    serverLink.catchUp.addCoaLot(lotGuid: lotGuid, packageId: packageId, stateId: stateId, statePsilocybin: statePsilocybin);

/// [CartPage.uploadInventorySnapshot]'s default, through the app's link.
Future<Map<String, Object?>> linkUploadInventorySnapshot(int stateId, List<Object?> records,
        {required String workerEmail, required String deviceId}) =>
    serverLink.uploadInventorySnapshot(stateId, records, workerEmail: workerEmail, deviceId: deviceId);

/// The Sales page's upload's default, through the app's link.
Future<Map<String, Object?>> linkUploadSalesSnapshot(int stateId, List<Object?> records,
        {required String workerEmail, required String deviceId}) =>
    serverLink.uploadSalesSnapshot(stateId, records, workerEmail: workerEmail, deviceId: deviceId);

/// What the banner says while the server can't be reached ([since]: when it stopped answering; [waiting]: reports in the
/// outbox; [dropped]: sale logs dropped because the outbox was full).
String serverLinkBannerText({required DateTime? since, required int waiting, int dropped = 0}) {
  final lead = since == null ? "Mazama's server can't be reached." : "Mazama's server can't be reached since ${formatAsOf(since)}.";
  final reports = waiting == 0
      ? ''
      : waiting == 1
          ? ' 1 report is waiting to be sent.'
          : ' $waiting reports are waiting to be sent.';
  final lost = dropped == 0 ? '' : ' $dropped older sale ${dropped == 1 ? 'log was' : 'logs were'} dropped for room.';
  return '$lead Selling still works.$reports$lost';
}

/// The app-wide banner while Mazama's server can't be reached: above every page (MazamaApp's builder), under the demo's
/// own banner. Shows nothing while online, nothing in the demo, and nothing once dismissed for this outage (its close
/// button, README R87: kept on the tracker, so it holds across pages, and cleared when the server answers again).
class ServerLinkBanner extends StatelessWidget {
  const ServerLinkBanner({super.key, required this.link, required this.child, ValueNotifier<bool>? demoMode})
      : _demoMode = demoMode;

  final ServerLink link;
  final Widget child;
  final ValueNotifier<bool>? _demoMode;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([link.health, link.engine.changes, _demoMode ?? demoModeOn]),
      builder: (context, app) {
        final visible = link.health.offline && !link.health.bannerDismissed && !(_demoMode ?? demoModeOn).value;
        final scheme = Theme.of(context).colorScheme;
        return Column(
          children: [
            if (visible)
              Material(
                key: const ValueKey('server-link-banner'),
                color: scheme.tertiaryContainer,
                child: SafeArea(
                  bottom: false,
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
                      child: Row(
                        children: [
                          Icon(Icons.cloud_off, size: 18, color: scheme.onTertiaryContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              serverLinkBannerText(
                                  since: link.health.offlineSince,
                                  waiting: link.engine.queue.waitingReports,
                                  dropped: link.engine.queue.droppedSaleLogs),
                              style: TextStyle(color: scheme.onTertiaryContainer),
                            ),
                          ),
                          // No tooltip: the banner sits above the Navigator, so there is no Overlay for one to show
                          // in. Its own semantics node instead: a button a screen reader announces as "Dismiss", with
                          // the tap, standing in for the IconButton's (excluded, so the label isn't lost or doubled).
                          Semantics(
                            container: true,
                            button: true,
                            label: 'Dismiss',
                            onTap: link.health.dismissBanner,
                            excludeSemantics: true,
                            child: IconButton(
                              key: const ValueKey('server-link-banner-dismiss'),
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.close, size: 18, color: scheme.onTertiaryContainer),
                              onPressed: link.health.dismissBanner,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            else
              const SizedBox.shrink(key: ValueKey('server-link-banner-off')),
            Expanded(child: MediaQuery.removePadding(context: context, removeTop: visible, child: app ?? const SizedBox.shrink())),
          ],
        );
      },
      child: child,
    );
  }
}
