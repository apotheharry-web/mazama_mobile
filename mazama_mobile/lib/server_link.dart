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
//   - [ServerLink.catchUp] (catch_up_store.dart): lab reports that couldn't be submitted and the newest inventory
//     snapshot per center, sent again once the server answers, with what is current then.
//   - [ServerLink.replies] (reply_store.dart): the last good reply of each read, shown while the server can't be reached.
//   - [ServerLinkBanner]: one line above every page while the server can't be reached, saying since when, that selling
//     still works, and how many reports are waiting. Never in the demo (which has no server at all).
// When the tracker comes back online (and at start-up, and when the app returns to the foreground while online), the
// outbox and the catch-up work are sent ([ServerLink.wake]).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'catch_up_store.dart';
import 'coa_data_client.dart' show CoaData;
import 'configured_coa_submit.dart' as configured_coa_submit;
import 'demo/demo_banner.dart' show demoModeOn;
import 'device_id.dart';
import 'inventory_upload_client.dart' as inventory_upload_client;
import 'ping_client.dart';
import 'reply_store.dart';
import 'server_error.dart';
import 'server_health.dart';
import 'server_offline.dart';
import 'server_outbox.dart';
import 'session.dart';
import 'session_store.dart' show SessionStore, defaultSessionDataDir;

/// Keeps when the server went offline across app restarts (server_health.json), so the banner says since when even
/// after the phone restarted the app mid-outage.
class ServerHealthStore {
  const ServerHealthStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;
  final Directory Function() dataDir;

  File get _file => File('${dataDir().path}/server_health.json');

  DateTime? loadOfflineSince() {
    try {
      final d = jsonDecode(_file.readAsStringSync());
      final ms = d is Map ? d['offlineSinceMs'] : null;
      return ms is int ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true) : null;
    } catch (_) {
      return null;
    }
  }

  void saveOfflineSince(DateTime? since) {
    try {
      if (since == null) {
        if (_file.existsSync()) _file.deleteSync();
        return;
      }
      dataDir().createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode({'offlineSinceMs': since.millisecondsSinceEpoch}));
    } catch (_) {
      // best effort: the banner then counts from this run's first failure
    }
  }
}

class ServerLink {
  ServerLink({required this.health, required this.outbox, required this.catchUp, required this.replies}) {
    health.addListener(_onHealth);
    _wasOnline = health.online;
  }

  /// The app's real link, its files in [dataDir] (the app's data folder by default). [rememberOffline]: when the server
  /// went offline is kept across restarts (MazamaApp's link); the fallback [serverLink] doesn't, so nothing reaching it
  /// before MazamaApp (a test calling a client without a client of its own) can leave a later run starting offline.
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
    return ServerLink(
      health: health,
      outbox: ServerOutbox(health: health, store: OutboxStore(dataDir: dir)),
      catchUp: CatchUpWork(
        health: health,
        store: CatchUpStore(dataDir: dir),
        submitCoa: submitPendingCoaLot,
        uploadSnapshot: uploadPendingSnapshot,
        auth: () => savedSessionAuth(sessions, devices),
      ),
      replies: ReplyStore(dataDir: dir),
    );
  }

  final ServerHealth health;
  final ServerOutbox outbox;
  final CatchUpWork catchUp;
  final ReplyStore replies;

  bool _wasOnline = true;

  void _onHealth() {
    final online = health.online;
    if (online && !_wasOnline) wake();
    _wasOnline = online;
  }

  /// Sends what is waiting (the outbox, then the catch-up work) while the server answers.
  void wake() {
    if (health.offline) return;
    unawaited(outbox.flush().then((_) => catchUp.flush()));
  }

  /// The app came back to the foreground: offline, probe now; online, send anything still waiting.
  void onForeground() {
    if (health.offline) {
      health.onForeground();
    } else {
      wake();
    }
  }

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

  /// [CartPage.submitCoaForLot]'s default: submits [lotGuid]'s lab report (configured_coa_submit.dart). While the
  /// tracker counts the server as offline, fails at once as unreachable without reading anything from the state system
  /// (the cart then keeps the lot, [rememberCoaLot], for a submission once the server answers).
  Future<CoaData?> submitCoaForLot({
    required String lotGuid,
    required int representativePackageId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    double? statePsilocybin,
  }) async {
    if (health.offline) throw configured_coa_submit.ConfiguredCoaSubmitError(serverUnreachable, unreachable: true);
    return configured_coa_submit.submitCoaForLot(
        lotGuid: lotGuid,
        representativePackageId: representativePackageId,
        accessToken: accessToken,
        workerEmail: workerEmail,
        deviceId: deviceId,
        statePsilocybin: statePsilocybin);
  }

  void dispose() {
    health.removeListener(_onHealth);
    outbox.dispose();
    catchUp.dispose();
    health.dispose();
  }
}

/// The app's link: MazamaApp sets it ([useServerLink]); anything that reaches a /p/ route before that (none should)
/// gets one in the app's data folder.
ServerLink get serverLink => _serverLink ??= ServerLink.standard(rememberOffline: false);
ServerLink? _serverLink;

/// Makes [link] the app's link (MazamaApp, and tests that want their own).
void useServerLink(ServerLink link) => _serverLink = link;

/// [link] is going away (MazamaApp disposed): the next use of [serverLink] makes a fresh one, never a disposed one.
void releaseServerLink(ServerLink link) {
  if (identical(_serverLink, link)) _serverLink = null;
}

/// The catch-up work's submitter: a lot's report through configured_coa_submit.dart with the session current now.
Future<bool> submitPendingCoaLot(PendingCoaLot lot, CatchUpAuth auth) async =>
    await configured_coa_submit.submitCoaForLot(
        lotGuid: lot.lotGuid,
        representativePackageId: lot.packageId,
        accessToken: auth.accessToken,
        workerEmail: auth.workerEmail,
        deviceId: auth.deviceId,
        statePsilocybin: lot.statePsilocybin) !=
    null;

/// The catch-up work's uploader: a kept snapshot through inventory_upload_client.dart.
Future<void> uploadPendingSnapshot(PendingSnapshot s) => inventory_upload_client.uploadInventorySnapshot(s.stateId, s.records,
    workerEmail: s.workerEmail, deviceId: s.deviceId);

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

/// [CartPage.keepCoaLotForLater]'s default: a lot whose report couldn't reach the server waits in the app's catch-up
/// work (catch_up_store.dart).
void rememberCoaLot(int stateId, {required String lotGuid, required int packageId, double? statePsilocybin}) =>
    serverLink.catchUp.addCoaLot(lotGuid: lotGuid, packageId: packageId, stateId: stateId, statePsilocybin: statePsilocybin);

/// [CartPage.uploadInventorySnapshot]'s default, through the app's link.
Future<Map<String, Object?>> linkUploadInventorySnapshot(int stateId, List<Object?> records,
        {required String workerEmail, required String deviceId}) =>
    serverLink.uploadInventorySnapshot(stateId, records, workerEmail: workerEmail, deviceId: deviceId);

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
/// own banner. Shows nothing while online, and nothing in the demo.
class ServerLinkBanner extends StatelessWidget {
  const ServerLinkBanner({super.key, required this.link, required this.child, ValueNotifier<bool>? demoMode})
      : _demoMode = demoMode;

  final ServerLink link;
  final Widget child;
  final ValueNotifier<bool>? _demoMode;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([link.health, link.outbox, _demoMode ?? demoModeOn]),
      builder: (context, app) {
        final visible = link.health.offline && !(_demoMode ?? demoModeOn).value;
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
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        children: [
                          Icon(Icons.cloud_off, size: 18, color: scheme.onTertiaryContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              serverLinkBannerText(
                                  since: link.health.offlineSince,
                                  waiting: link.outbox.pendingCount,
                                  dropped: link.outbox.droppedLogs),
                              style: TextStyle(color: scheme.onTertiaryContainer),
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
