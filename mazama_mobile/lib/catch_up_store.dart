// Work for Mazama's server that waits for it to answer again but isn't one of the sale reports (server_outbox.dart),
// because what it sends is only worked out at send time:
//   - lab reports to submit (configured_coa_submit.dart's submitCoaForLot, started by the cart when a package without a
//     report on file is added, or by the background uploader, coa_uploader.dart): the report is read from the state
//     system with the worker's state token, so only which lot is kept ([PendingCoaLot]: lot id, one package id behind
//     it, the center, the state's psilocybin), and the submission runs again with the then-current session once the
//     server answers (coa_uploader.dart's labReportQueueSender). A lot leaves the list when its report is submitted,
//     when the state has no report on file for it (nothing to submit), or when its submission fails for another reason
//     (the server refused it, as the cart's own submission would be); at most [catchUpMaxLots] are kept, the oldest
//     dropped first (the cart tries a lot again whenever a package of it is added anyway).
//   - the inventory snapshot (POST /p/ingest/packaged, inventory_upload_client.dart) and the sales snapshot (the Sales
//     page's read, POST /p/ingest/sales, sales_upload_client.dart) ([PendingSnapshot]): only the newest of each kind
//     matters, so one per kind per center is kept, each new state read of that kind replacing it, and sent once the
//     server answers ([snapshotQueueSender]). One the phone manages to send meanwhile replaces it outright (it is
//     newer), so a kept one never goes after a newer one.
// A run sends the snapshots before the lab reports, so a large sales snapshot can hold kept reports back by one upload.
// They wait in the sync engine's queue (lib/sync/sync_queue.dart: lab_report items keyed by lot id, inventory_snapshot
// and sales_snapshot items keyed by center); the app adds and lists them there through [CatchUpItems]. Sent when the
// server tracker comes back online, at start-up and when a cart opens; a run that finds the server unreachable stops
// and waits.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'inventory_upload_client.dart' show InventoryUploadError;
import 'sales_upload_client.dart' show SalesUploadError;
import 'server_error.dart';
import 'server_outbox.dart' show outboxRetryAfterBusy;
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

  /// [snapshotKindInventory] or [snapshotKindSales]; one with no kind reads as inventory.
  final String kind;
  final List<Object?> records;
  final String workerEmail;
  final String deviceId;
  final DateTime readAt;

  /// Its key in [CatchUpItems.keptSnapshots]: one per kind per center.
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

/// A snapshot's key in [CatchUpItems.keptSnapshots].
String snapshotKey(String kind, int stateId) => '$kind:$stateId';

/// What a catch-up run needs from the worker's session at send time.
class CatchUpAuth {
  const CatchUpAuth({required this.accessToken, required this.workerEmail, required this.deviceId});
  final String accessToken;
  final String workerEmail;
  final String deviceId;
}

/// Uploads a kept snapshot by its kind (server_link.dart's uploadPendingSnapshot: inventory_upload_client.dart or
/// sales_upload_client.dart). Throws on failure.
typedef SnapshotUploader = Future<void> Function(PendingSnapshot snapshot);

QueueKind? _snapshotQueueKind(String kind) => switch (kind) {
      snapshotKindInventory => QueueKind.inventorySnapshot,
      snapshotKindSales => QueueKind.salesSnapshot,
      _ => null,
    };

/// The engine's sender for a kept snapshot: [upload] it; unreachable, or a 408 (the server gave up reading its body),
/// stops the run and keeps it; a refusal drops it (the next state read sends a fresher one).
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
        if (snapshotTimedOut(e)) return RetryAfter(outboxRetryAfterBusy, error: '$e', status: 408);
        return const Skipped();
      }
    };

/// Whether a snapshot upload's error is the server's 408 (its body took over 30 s to arrive): not a refusal, so the
/// snapshot is kept (here and in server_link.dart's uploads).
bool snapshotTimedOut(Object? error) =>
    (error is InventoryUploadError && error.status == 408) || (error is SalesUploadError && error.status == 408);

/// The lab reports and snapshots waiting on the engine's queue, as the app adds and lists them.
extension CatchUpItems on SyncQueue {
  /// Keeps [lotGuid] for a submission once the server answers (replacing an earlier entry for it). Never throws.
  void addCoaLot({required String lotGuid, required int packageId, required int stateId, double? statePsilocybin}) {
    try {
      add(
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
  /// one of the same kind). A kind this build has no upload for is never kept. Never throws.
  void keepSnapshot(int stateId, List<Object?> records,
      {required String workerEmail, required String deviceId, String kind = snapshotKindInventory}) {
    final queueKind = _snapshotQueueKind(kind);
    if (queueKind == null) return;
    final snap = PendingSnapshot(
        stateId: stateId, kind: kind, records: records, workerEmail: workerEmail, deviceId: deviceId, readAt: now().toUtc());
    try {
      add(queueKind, '$stateId', snap.toJson());
    } catch (e) {
      debugPrint('a snapshot could not be kept for later: $e');
    }
  }

  /// A newer snapshot of [stateId] of [kind] reached the server: the kept one is older, never to be sent.
  void snapshotSent(int stateId, {String kind = snapshotKindInventory}) {
    final queueKind = _snapshotQueueKind(kind);
    if (queueKind == null) return;
    try {
      remove(queueKind, '$stateId');
    } catch (e) {
      debugPrint('a kept snapshot could not be dropped: $e');
    }
  }

  List<T> _kept<T>(QueueKind kind, T? Function(Object?) parse) {
    try {
      return [
        for (final i in tables.items(kind.stored))
          if (i.state != queueDead)
            if (parse(jsonDecode(i.body)) case final T v) v,
      ];
    } catch (e) {
      debugPrint('the catch-up work could not be read: $e');
      return const [];
    }
  }

  /// The lab reports kept for later, oldest first.
  List<PendingCoaLot> get keptCoaLots => List.unmodifiable(_kept(QueueKind.labReport, PendingCoaLot.fromJson));

  /// The snapshots waiting, by [snapshotKey].
  Map<String, PendingSnapshot> get keptSnapshots => Map.unmodifiable({
        for (final s in [
          ..._kept(QueueKind.inventorySnapshot, PendingSnapshot.fromJson),
          ..._kept(QueueKind.salesSnapshot, PendingSnapshot.fromJson),
        ])
          s.key: s,
      });
}
