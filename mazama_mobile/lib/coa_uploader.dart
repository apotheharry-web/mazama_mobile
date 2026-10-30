// The phone's one background uploader of lab reports (specs/coa-upload, CU-R1..R6): every lot in a center's stock whose
// result Mazama's server doesn't have is sent, for both kinds of center, without holding up the load, the stock page or
// a sale.
//   - Who enqueues: coa_data_resolver.dart (a center the server doesn't track: the lots its batch lookup didn't return)
//     and cart_page.dart (a center the server tracks: the lots whose package says coaAvailable false). The cart's own
//     submission on a cart add (configured_coa_submit.dart, through server_link.dart) stays as it was.
//   - One per app ([ServerLink.coaUploads]), not one per page: a second load of a center adds only the lots that aren't
//     already waiting or being sent (CU-R2).
//   - Paced to the server's budget for C6 (routes.yaml coa_data_parse, coaDataParseRateLimitPerMinute): one start every
//     [coaUploadStartInterval] at most, [coaUploadMaxInFlight] in flight at most. Every start is on a timer, never
//     inside the enqueue call, so the load that enqueued always returns first.
//   - Each lot runs the existing chain (configured_coa_submit.dart's submitCoaForLot: GetPackagedProductInfo for one
//     package of the lot, the newest accepted potency PDF, DownloadDocument, POST /p/coa-data/parse) with the worker's
//     session as it is at send time.
//   - What the reply means (CU-R3, CU-R4):
//       200 with numbers: sent, and every caller that asked about the lot is told (the cart patches it in);
//       any other reply below 500 (202 queued, 202 held, 4xx refused): sent, nothing to patch;
//       429: busy - the run stops, the waiting lots are let go and none is marked; the next load enqueues them again;
//       5xx or no connection (server_error.dart's rule), for a lot actually being sent: that lot is kept on the
//       catch-up list (catch_up_store.dart), as a cart add's would be, and only while the list has room, so these
//       never push out a cart add's lot; the waiting lots are let go, unmarked, and the next load enqueues them again.
//       While the tracker counts the server offline nothing starts and the waiting lots are let go the same way, so
//       the catch-up list (sent unpaced once the server answers) never fills up from here;
//       no potency PDF on file at the state, or the state's read failing: skipped, nothing remembered.
//   - Sent lots are remembered for [coaSentKeepFor] (CU-D2, the server's own SH-D3), at most [coaSentMaxLots], the
//     oldest dropped first, in the sync engine's sync_sent table ([CoaSentStore]; older builds' coa_sent.json document
//     is moved in by sync_migration.dart). The waiting queue itself is only in memory: the next load fills it again.
//   - The pacing, the queue and the replies' meaning live in the sync engine's queue (lib/sync/sync_queue.dart, its
//     paced lab reports, specs/phone-sync PS-R4); CoaUploader is the facade the app's callers use.
//   - Never in the demo (CU-R6): nothing is enqueued while demo mode is on, and the demo's cart and resolver never call
//     this at all (demo_backend.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api_contract.g.dart' show coaDataParseRateLimitPerMinute;
import 'catch_up_store.dart';
import 'coa_data_client.dart' show CoaData, CoaDataError;
import 'configured_coa_submit.dart' as configured_coa_submit;
import 'demo/demo_banner.dart' show demoModeOn;
import 'local_store.dart';
import 'server_error.dart';
import 'server_health.dart';
import 'session_store.dart' show defaultSessionDataDir;
import 'sync/sync_queue.dart';
import 'sync/sync_tables.dart';

/// The least time between two uploads starting: the server's per-minute budget for /p/coa-data/parse spread evenly
/// (20 a minute: one every 3 s).
const coaUploadStartInterval = Duration(milliseconds: 60000 ~/ coaDataParseRateLimitPerMinute);

/// How many uploads may be under way at once.
const coaUploadMaxInFlight = 2;

/// How long a sent lot isn't sent again (CU-D2).
const coaSentKeepFor = Duration(hours: 24);

/// How many sent lots are remembered at most, the oldest dropped first (CU-R3).
const coaSentMaxLots = 2000;

/// One lot to send: its id, one package of it (GetPackagedProductInfo is keyed by a package id, never the lot's or the
/// center's), the center, and the state's psilocybin figure for it (the package's analyteWeight).
class CoaUploadLot {
  const CoaUploadLot({required this.lotGuid, required this.packageId, required this.stateId, this.statePsilocybin});

  final String lotGuid;
  final int packageId;
  final int stateId;
  final double? statePsilocybin;
}

/// Told when the server answered a lot's upload with its numbers.
typedef CoaLotResolved = void Function(String lotGuid, CoaData data);

/// Adds lots to the app's uploader ([CoaUploader.enqueue]); [onResolved] is told about each one the server answers
/// with numbers.
typedef QueueCoaUploads = void Function(List<CoaUploadLot> lots, {CoaLotResolved? onResolved});

/// Sends one lot's report: the parsed result on a 200, null when the state has no potency PDF on file for it. Throws
/// otherwise ([ConfiguredCoaSubmitError], with the server's status when it answered).
typedef CoaLotSend = Future<CoaData?> Function(CoaUploadLot lot, CatchUpAuth auth);

/// The real sender: configured_coa_submit.dart's chain, whose upload goes through the server link.
Future<CoaData?> sendCoaLot(CoaUploadLot lot, CatchUpAuth auth) => configured_coa_submit.submitCoaForLot(
      lotGuid: lot.lotGuid,
      representativePackageId: lot.packageId,
      accessToken: auth.accessToken,
      workerEmail: auth.workerEmail,
      deviceId: auth.deviceId,
      statePsilocybin: lot.statePsilocybin,
    );

/// The HTTP status Mazama's server answered an upload with, from the error it raised; null when it didn't answer (no
/// connection) or the failure was the state system's.
int? coaReplyStatus(Object? error) {
  if (error is configured_coa_submit.ConfiguredCoaSubmitError) return error.status;
  if (error is CoaDataError) return error.status;
  return null;
}

/// Whether a failed upload still counts as sent (CU-R3): the server answered it below 500 and it wasn't a 429.
bool countsAsSent(Object? error) {
  final status = coaReplyStatus(error);
  return status != null && status < 500 && status != 429;
}

const _labReport = 'lab_report';

SyncTables _tablesOf(Directory Function() dataDir) => SyncTables(LocalStore.forDir(dataDir()));

/// Where the sent lots are kept (the sync engine's sync_sent table, kind lab_report, in the folder's LocalStore).
class CoaSentStore {
  const CoaSentStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  /// Overridable for tests, as the other stores.
  final Directory Function() dataDir;

  /// The document older builds kept the sent lots in (moved into sync_sent by sync_migration.dart).
  static const documentName = 'coa_sent.json';

  /// Lot id (lower case) to when it was sent, oldest first; empty when nothing is kept or it can't be read.
  Map<String, DateTime> load() {
    try {
      return {for (final s in _tablesOf(dataDir).sentList(_labReport)) s.key: s.at};
    } catch (_) {
      return <String, DateTime>{};
    }
  }

  void save(Map<String, DateTime> sent) => _tablesOf(dataDir).replaceSent(_labReport, sent);
}

/// The lots this phone sent lately (CU-R3): none is sent again for [keepFor]; at most [maxLots] are kept, the oldest
/// dropped first. Read from [store]'s table at each call (the engine's queue writes it too), so making one touches no
/// file.
class CoaSentMemory {
  CoaSentMemory(
      {this.store = const CoaSentStore(), this.now = DateTime.now, this.keepFor = coaSentKeepFor, this.maxLots = coaSentMaxLots});

  final CoaSentStore store;
  final DateTime Function() now;
  final Duration keepFor;
  final int maxLots;

  /// How many lots are remembered (expired ones included until the next [markSent]).
  int get length {
    try {
      return _tablesOf(store.dataDir).sentList(_labReport).length;
    } catch (_) {
      return 0;
    }
  }

  /// Whether [lotGuid] (any case) was sent less than [keepFor] ago.
  bool wasSent(String lotGuid) {
    try {
      return _tablesOf(store.dataDir).wasSent(_labReport, lotGuid.toLowerCase(), now(), keepFor);
    } catch (_) {
      return false;
    }
  }

  /// Remembers [lotGuid] as sent now.
  void markSent(String lotGuid) {
    final key = lotGuid.toLowerCase();
    if (key.isEmpty) return;
    final at = now().toUtc();
    try {
      final tables = _tablesOf(store.dataDir);
      tables.store.transaction(() {
        tables.sent(_labReport, key, at);
        tables.pruneSent(_labReport, at, keepFor, maxLots);
      });
    } catch (e) {
      debugPrint('the sent lab reports could not be saved: $e');
    }
  }
}

Timer _realTimer(Duration delay, void Function() callback) => Timer(delay, callback);

bool _demoModeIsOn() => demoModeOn.value;

/// The engine's sender for a lab report, paced or kept: the lot's chain through [send] with the session current at send
/// time ([auth]). What each reply means is the file comment's.
QueueSender labReportQueueSender(CoaLotSend send, Future<CatchUpAuth?> Function() auth) => (item) async {
      final PendingCoaLot? lot;
      try {
        lot = PendingCoaLot.fromJson(jsonDecode(item.body));
      } on FormatException {
        return const Skipped();
      }
      if (lot == null) return const Skipped();
      CatchUpAuth? credentials;
      try {
        credentials = await auth();
      } catch (_) {
        credentials = null;
      }
      if (credentials == null) return const Busy(); // no usable session now: nothing can be sent
      try {
        final data = await send(
            CoaUploadLot(lotGuid: lot.lotGuid, packageId: lot.packageId, stateId: lot.stateId, statePsilocybin: lot.statePsilocybin),
            credentials);
        return data == null ? const Skipped() : Done(data); // null: no potency PDF on file at the state
      } catch (e) {
        if (coaReplyStatus(e) == 429) return const Busy();
        if (isServerUnreachable(e)) return Unreachable(error: '$e');
        if (countsAsSent(e)) return const Done(); // queued, held or refused: the server has its answer (CU-R3)
        return const Skipped(); // the state system's read failing: not sent; the next load tries again
      }
    };

/// The background uploader as the app's callers know it, over the sync engine's queue ([queue]: the engine's, from
/// ServerLink.standard; otherwise one of its own over [catchUp]'s tables, with [send], [auth], [now], [startTimer],
/// [isDemo], [startInterval] and [maxInFlight]).
class CoaUploader {
  CoaUploader({
    required this.health,
    required this.catchUp,
    required this.auth,
    CoaSentMemory? sent,
    this.send = sendCoaLot,
    this.now = DateTime.now,
    this.startTimer = _realTimer,
    this.isDemo = _demoModeIsOn,
    this.startInterval = coaUploadStartInterval,
    this.maxInFlight = coaUploadMaxInFlight,
    SyncQueue? queue,
  })  : sent = sent ?? CoaSentMemory(store: CoaSentStore(dataDir: catchUp.store.dataDir), now: now),
        _ownsQueue = queue == null,
        queue = queue ??
            SyncQueue(
              tables: catchUp.queue.tables,
              health: health,
              senders: {QueueKind.labReport: labReportQueueSender(send, auth)},
              now: now,
              startTimer: startTimer,
              isDemo: isDemo,
              labReportStartEvery: startInterval,
              labReportMaxInFlight: maxInFlight,
              labReportCap: catchUp.maxLots,
              sentKeep: sent?.keepFor ?? coaSentKeepFor,
              sentMax: sent?.maxLots ?? coaSentMaxLots,
            );

  final ServerHealth health;

  /// Where a lot goes when the server can't be reached (CU-R4).
  final CatchUpWork catchUp;

  /// The worker's session as it is now, and this install's id (server_link.dart's savedSessionAuth); null when there is
  /// no usable session (nothing is sent then: the next load enqueues the lots again).
  final Future<CatchUpAuth?> Function() auth;
  final CoaSentMemory sent;
  final CoaLotSend send;
  final DateTime Function() now;
  final StartTimer startTimer;

  /// True in demo mode (CU-R6): nothing is enqueued or started.
  final bool Function() isDemo;
  final Duration startInterval;
  final int maxInFlight;

  /// Where the lots wait and are paced (lib/sync/sync_queue.dart).
  final SyncQueue queue;
  final bool _ownsQueue;
  bool _disposed = false;

  /// How many lots wait to start.
  int get waiting => queue.labReportsWaiting;

  /// How many uploads are under way.
  int get inFlight => queue.labReportsInFlight;

  /// Nothing waiting and nothing under way.
  bool get idle => queue.labReportsIdle;

  /// Whether [lotGuid] (any case) is waiting or being sent: the cart's own submission on a cart add skips it, so the
  /// same report isn't downloaded twice at once.
  bool isPending(String lotGuid) => queue.labReportPending(lotGuid);

  /// Adds [lots] to the queue, leaving out any already waiting or being sent (whose [onResolved] is added to it), sent
  /// in the last [CoaSentMemory.keepFor], or waiting on the catch-up list. Returns at once; uploads start on a timer.
  void enqueue(List<CoaUploadLot> lots, {CoaLotResolved? onResolved}) {
    if (_disposed || isDemo() || lots.isEmpty) return;
    final at = now().toUtc();
    try {
      queue.offerLabReports(
        [
          for (final l in lots)
            (
              key: l.lotGuid,
              body: PendingCoaLot(
                      lotGuid: l.lotGuid, packageId: l.packageId, stateId: l.stateId, statePsilocybin: l.statePsilocybin, addedAt: at)
                  .toJson(),
            ),
        ],
        onDone: onResolved == null
            ? null
            : (item, value) {
                final lot = PendingCoaLot.fromJson(jsonDecode(item.body));
                if (lot != null && value is CoaData) onResolved(lot.lotGuid, value);
              },
      );
    } catch (e) {
      debugPrint('lab reports could not be queued for upload: $e');
    }
  }

  /// The app is closing: nothing more starts. The sent memory and the catch-up list are on disk already.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ownsQueue) queue.dispose();
  }
}
