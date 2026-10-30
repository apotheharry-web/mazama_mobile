// Work for Mazama's server that waits for it to answer again but doesn't go through the outbox (README R56,
// server_link.dart), because what it sends is only worked out at send time:
//   - lab reports to submit (configured_coa_submit.dart's submitCoaForLot, started by the cart when a package without a
//     report on file is added, or by the background uploader, coa_uploader.dart, CU-R4): the report is read from the state system with the worker's state token, so only which
//     lot is kept (lot id, one package id behind it, the center, the state's psilocybin), and the submission runs again
//     with the then-current session once the server answers. A lot leaves the list when its report is submitted, when
//     the state has no report on file for it (nothing to submit), or when its submission fails for another reason
//     (the server refused it, as the cart's own submission would be); at most [catchUpMaxLots] are kept, the oldest
//     dropped first (the cart tries a lot again whenever a package of it is added anyway).
//   - the inventory snapshot (POST /p/inventory, inventory_upload_client.dart) and the sales snapshot (the Sales page's
//     read, POST /p/ingest/sales, sales_upload_client.dart; specs/center-web CW-R10): only the newest of each kind
//     matters, so one per kind per center is kept, each new state read of that kind replacing it, and sent once the
//     server answers. One the phone manages to send meanwhile replaces it outright (it is newer), so a kept one never
//     goes after a newer one. (Interim: specs/phone-sync's engine takes these over, its migration carrying them.)
// A run sends the snapshots before the lab reports, so a large sales snapshot can hold kept reports back by one upload.
// Kept in the sync engine's queue (lib/sync/sync_queue.dart, specs/phone-sync PS-R4: lab_report items kept for later,
// keyed by lot id, and inventory_snapshot / sales_snapshot items keyed by center); CatchUpWork is the facade the app's
// callers use. CatchUpStore reads the server_catch_up.json document older builds kept (the inventory snapshots under
// `snapshots`, as before sales existed, the sales ones under `salesSnapshots`), which the engine moves in
// (sync_migration.dart). Run by server_link.dart when the server tracker comes back online, at start-up and when a
// cart opens; a run that finds the server unreachable stops and waits.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'coa_uploader.dart' show coaReplyStatus, countsAsSent;
import 'local_store.dart';
import 'server_error.dart';
import 'server_health.dart';
import 'session_store.dart' show defaultSessionDataDir;
import 'sync/sync_migration.dart' show openSyncTables;
import 'sync/sync_queue.dart';
import 'sync/sync_tables.dart' show queueDead;

/// How many lots wait for their lab report to be submitted (see the file comment).
const catchUpMaxLots = 200;

/// A lot whose lab report couldn't be submitted because the server couldn't be reached.
class PendingCoaLot {
  const PendingCoaLot(
      {required this.lotGuid, required this.packageId, required this.stateId, this.statePsilocybin, required this.addedAt});

  final String lotGuid;
  final int packageId;
  final int stateId;
  final double? statePsilocybin;
  final DateTime addedAt;

  Map<String, Object?> toJson() => {
        'lotGuid': lotGuid,
        'packageId': packageId,
        'stateId': stateId,
        'statePsilocybin': statePsilocybin,
        'addedAtMs': addedAt.millisecondsSinceEpoch,
      };

  static PendingCoaLot? fromJson(Object? j) {
    if (j is! Map) return null;
    final guid = j['lotGuid'], pkg = j['packageId'], state = j['stateId'], at = j['addedAtMs'], psi = j['statePsilocybin'];
    if (guid is! String || guid.isEmpty || pkg is! int || state is! int || at is! int) return null;
    return PendingCoaLot(
        lotGuid: guid,
        packageId: pkg,
        stateId: state,
        statePsilocybin: psi is num ? psi.toDouble() : null,
        addedAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true));
  }
}

/// The kinds of snapshot kept: a center's packaged products (the cart's read) and its sales (the Sales page's).
const snapshotKindInventory = 'inventory';
const snapshotKindSales = 'sales';

/// A center's newest state read of one [kind], waiting to be uploaded.
class PendingSnapshot {
  const PendingSnapshot(
      {required this.stateId,
      this.kind = snapshotKindInventory,
      required this.records,
      required this.workerEmail,
      required this.deviceId,
      required this.readAt});

  final int stateId;

  /// [snapshotKindInventory] or [snapshotKindSales]; a snapshot saved before kinds existed reads as inventory.
  final String kind;
  final List<Object?> records;
  final String workerEmail;
  final String deviceId;
  final DateTime readAt;

  /// Its key in [CatchUpState.snapshots]: one per kind per center.
  String get key => snapshotKey(kind, stateId);

  Map<String, Object?> toJson() => {
        'stateId': stateId,
        'kind': kind,
        'records': records,
        'workerEmail': workerEmail,
        'deviceId': deviceId,
        'readAtMs': readAt.millisecondsSinceEpoch,
      };

  static PendingSnapshot? fromJson(Object? j) {
    if (j is! Map) return null;
    final state = j['stateId'], records = j['records'], email = j['workerEmail'], device = j['deviceId'], at = j['readAtMs'];
    final kind = j['kind'] ?? snapshotKindInventory;
    if (state is! int || records is! List || email is! String || device is! String || at is! int) return null;
    // a kind this build doesn't know (a newer build's) is left out: never sent as inventory, which replaces the mirror
    if (kind != snapshotKindInventory && kind != snapshotKindSales) return null;
    return PendingSnapshot(
        stateId: state,
        kind: kind as String,
        records: List<Object?>.from(records),
        workerEmail: email,
        deviceId: device,
        readAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true));
  }
}

/// A snapshot's key in [CatchUpState.snapshots].
String snapshotKey(String kind, int stateId) => '$kind:$stateId';

class CatchUpState {
  const CatchUpState({this.lots = const [], this.snapshots = const {}});
  final List<PendingCoaLot> lots;

  /// Keyed by [snapshotKey] (`'$kind:$stateId'`).
  final Map<String, PendingSnapshot> snapshots;
}

class CatchUpStore {
  const CatchUpStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  /// Overridable for tests, as the other stores.
  final Directory Function() dataDir;

  /// The document's name (older builds' only copy of the list).
  static const documentName = 'server_catch_up.json';
  static const _name = documentName;
  static const _inventoryKey = 'snapshots';
  static const _salesKey = 'salesSnapshots';

  CatchUpState load() {
    try {
      final text = LocalStore.forDir(dataDir()).read(_name)?.body;
      if (text == null) return const CatchUpState();
      return parse(text);
    } on FileSystemException {
      return const CatchUpState();
    } on FormatException {
      return const CatchUpState();
    }
  }

  /// The document's [text] read; throws a FormatException when it isn't JSON.
  static CatchUpState parse(String text) {
    final d = jsonDecode(text);
    if (d is! Map) return const CatchUpState();
    final lots = d['lots'];
    // Each kind under its own key, read only as that kind: inventory where builds before sales snapshots keep it
    // (`snapshots`), sales under `salesSnapshots`, which those builds never read (one would send a sales snapshot to
    // /p/inventory, replacing the center's mirror).
    Iterable<PendingSnapshot> read(Object? list, String kind) => list is List
        ? [for (final s in list) PendingSnapshot.fromJson(s)].whereType<PendingSnapshot>().where((s) => s.kind == kind)
        : const [];
    return CatchUpState(
      lots: lots is List ? [for (final l in lots) PendingCoaLot.fromJson(l)].whereType<PendingCoaLot>().toList() : const [],
      snapshots: {
        for (final s in read(d[_inventoryKey], snapshotKindInventory)) s.key: s,
        for (final s in read(d[_salesKey], snapshotKindSales)) s.key: s,
      },
    );
  }

  void save(CatchUpState state) {
    LocalStore.forDir(dataDir()).write(_name, jsonEncode({
      'lots': [for (final l in state.lots) l.toJson()],
      _inventoryKey: [
        for (final s in state.snapshots.values)
          if (s.kind == snapshotKindInventory) s.toJson()
      ],
      _salesKey: [
        for (final s in state.snapshots.values)
          if (s.kind == snapshotKindSales) s.toJson()
      ],
    }));
  }
}

/// What a catch-up run needs from the worker's session at send time.
class CatchUpAuth {
  const CatchUpAuth({required this.accessToken, required this.workerEmail, required this.deviceId});
  final String accessToken;
  final String workerEmail;
  final String deviceId;
}

/// Submits a lot's lab report (configured_coa_submit.dart's submitCoaForLot): true when one was submitted, false when the
/// state has none on file. Throws on failure.
typedef CoaLotSubmitter = Future<bool> Function(PendingCoaLot lot, CatchUpAuth auth);

/// Uploads a kept snapshot by its kind (server_link.dart's uploadPendingSnapshot: inventory_upload_client.dart or
/// sales_upload_client.dart). Throws on failure.
typedef SnapshotUploader = Future<void> Function(PendingSnapshot snapshot);

QueueKind? _snapshotQueueKind(String kind) => switch (kind) {
      snapshotKindInventory => QueueKind.inventorySnapshot,
      snapshotKindSales => QueueKind.salesSnapshot,
      _ => null,
    };

/// The engine's sender for a kept snapshot: [upload] it; unreachable stops the run, a refusal drops it (the next state
/// read sends a fresher one).
QueueSender snapshotQueueSender(SnapshotUploader upload) => (item) async {
      final PendingSnapshot? snap;
      try {
        snap = PendingSnapshot.fromJson(jsonDecode(item.body));
      } on FormatException {
        return const Skipped();
      }
      if (snap == null) return const Skipped();
      try {
        await upload(snap);
        return const Done();
      } catch (e) {
        if (isServerUnreachable(e)) return Unreachable(error: '$e');
        return const Skipped();
      }
    };

/// The engine's sender for a kept lab report, through a [CoaLotSubmitter] with the session current at send time ([auth]):
/// no session, or a 429, waits; unreachable stops the run; submitted or answered, it is sent; refused otherwise (or
/// nothing on file at the state), dropped.
QueueSender keptLabReportSender(CoaLotSubmitter submit, Future<CatchUpAuth?> Function() auth) => (item) async {
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
      if (credentials == null) return const Busy();
      try {
        return await submit(lot, credentials) ? const Done() : const Skipped();
      } catch (e) {
        if (isServerUnreachable(e)) return Unreachable(error: '$e');
        if (coaReplyStatus(e) == 429) return const Busy();
        if (countsAsSent(e)) return const Done();
        return const Skipped();
      }
    };

/// The catch-up work as the app's callers know it, over the sync engine's queue ([queue]: the engine's, from
/// ServerLink.standard; otherwise one of its own over [store]'s folder, with [submitCoa], [uploadSnapshot], [auth],
/// [now] and [maxLots]).
class CatchUpWork extends ChangeNotifier {
  CatchUpWork({
    required this.health,
    required this.submitCoa,
    required this.uploadSnapshot,
    required this.auth,
    this.store = const CatchUpStore(),
    this.now = DateTime.now,
    this.maxLots = catchUpMaxLots,
    SyncQueue? queue,
  })  : _ownsQueue = queue == null,
        queue = queue ??
            SyncQueue(
              tables: openSyncTables(LocalStore.forDir(store.dataDir())),
              health: health,
              senders: {
                QueueKind.inventorySnapshot: snapshotQueueSender(uploadSnapshot),
                QueueKind.salesSnapshot: snapshotQueueSender(uploadSnapshot),
                QueueKind.labReport: keptLabReportSender(submitCoa, auth),
              },
              now: now,
              labReportCap: maxLots,
            ) {
    this.queue.addListener(_changed);
  }

  final ServerHealth health;
  final CoaLotSubmitter submitCoa;
  final SnapshotUploader uploadSnapshot;

  /// The worker's current session (the one last saved, if still fresh) and this install's id; null when there is no
  /// usable session right now (the lab reports then wait for the next run).
  final Future<CatchUpAuth?> Function() auth;

  /// The document older builds kept the list in (moved into [queue] when it is opened).
  final CatchUpStore store;
  final DateTime Function() now;
  final int maxLots;

  /// Where the work waits (lib/sync/sync_queue.dart).
  final SyncQueue queue;
  final bool _ownsQueue;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  List<T> _read<T>(QueueKind kind, T? Function(Object?) parse) {
    try {
      return [
        for (final i in queue.tables.items(kind.stored))
          if (i.state != queueDead)
            if (parse(jsonDecode(i.body)) case final T v) v,
      ];
    } catch (e) {
      debugPrint('the catch-up work could not be read: $e');
      return const [];
    }
  }

  List<PendingCoaLot> get lots => List.unmodifiable(_read(QueueKind.labReport, PendingCoaLot.fromJson));
  Map<String, PendingSnapshot> get snapshots => Map.unmodifiable({
        for (final s in [
          ..._read(QueueKind.inventorySnapshot, PendingSnapshot.fromJson),
          ..._read(QueueKind.salesSnapshot, PendingSnapshot.fromJson),
        ])
          s.key: s,
      });

  /// Remembers [lotGuid] for a submission once the server answers (replacing an earlier entry for it).
  void addCoaLot({required String lotGuid, required int packageId, required int stateId, double? statePsilocybin}) {
    try {
      queue.add(
          QueueKind.labReport,
          lotGuid,
          PendingCoaLot(
                  lotGuid: lotGuid, packageId: packageId, stateId: stateId, statePsilocybin: statePsilocybin, addedAt: now().toUtc())
              .toJson());
    } catch (e) {
      debugPrint('a lab report could not be kept for later: $e');
    }
  }

  /// Keeps [records] as [stateId]'s newest state read of [kind] to upload once the server answers (replacing an older
  /// one of the same kind). A kind this build has no upload for is never kept.
  void keepSnapshot(int stateId, List<Object?> records,
      {required String workerEmail, required String deviceId, String kind = snapshotKindInventory}) {
    final queueKind = _snapshotQueueKind(kind);
    if (queueKind == null) return;
    final snap = PendingSnapshot(
        stateId: stateId, kind: kind, records: records, workerEmail: workerEmail, deviceId: deviceId, readAt: now().toUtc());
    try {
      queue.add(queueKind, '$stateId', snap.toJson());
    } catch (e) {
      debugPrint('a snapshot could not be kept for later: $e');
    }
  }

  /// A newer snapshot of [stateId] of [kind] reached the server: the kept one is older, never to be sent.
  void snapshotSent(int stateId, {String kind = snapshotKindInventory}) {
    final queueKind = _snapshotQueueKind(kind);
    if (queueKind == null) return;
    try {
      queue.remove(queueKind, '$stateId');
    } catch (e) {
      debugPrint('a kept snapshot could not be dropped: $e');
    }
  }

  /// Sends what is waiting while the server answers: the snapshots, then the lab reports, oldest first. Stops at the
  /// first failure that means the server couldn't be reached.
  Future<void> flush() async {
    if (_disposed) return;
    await queue.flush();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    queue.removeListener(_changed);
    if (_ownsQueue) queue.dispose();
    super.dispose();
  }
}
