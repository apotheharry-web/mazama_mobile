// Work for Mazama's server that waits for it to answer again but doesn't go through the outbox (README R56,
// server_link.dart), because what it sends is only worked out at send time:
//   - lab reports to submit (configured_coa_submit.dart's submitCoaForLot, started by the cart when a package without a
//     report on file is added): the report is read from the state system with the worker's state token, so only which
//     lot is kept (lot id, one package id behind it, the center, the state's psilocybin), and the submission runs again
//     with the then-current session once the server answers. A lot leaves the list when its report is submitted, when
//     the state has no report on file for it (nothing to submit), or when its submission fails for another reason
//     (the server refused it, as the cart's own submission would be); at most [catchUpMaxLots] are kept, the oldest
//     dropped first (the cart tries a lot again whenever a package of it is added anyway).
//   - the inventory snapshot (POST /p/inventory, inventory_upload_client.dart): only the newest matters, so one per
//     center is kept, each new state read replacing it, and sent once the server answers. One the cart manages to
//     send meanwhile replaces it outright (it is newer), so a kept one never goes after a newer one.
// One JSON file (server_catch_up.json, *Sync calls as the other stores). Run by server_link.dart when the server tracker
// comes back online, at start-up and when a cart opens; a run that finds the server unreachable stops and waits.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'server_error.dart';
import 'server_health.dart';
import 'session_store.dart' show defaultSessionDataDir;

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

/// A center's newest state read, waiting to be uploaded.
class PendingSnapshot {
  const PendingSnapshot(
      {required this.stateId, required this.records, required this.workerEmail, required this.deviceId, required this.readAt});

  final int stateId;
  final List<Object?> records;
  final String workerEmail;
  final String deviceId;
  final DateTime readAt;

  Map<String, Object?> toJson() => {
        'stateId': stateId,
        'records': records,
        'workerEmail': workerEmail,
        'deviceId': deviceId,
        'readAtMs': readAt.millisecondsSinceEpoch,
      };

  static PendingSnapshot? fromJson(Object? j) {
    if (j is! Map) return null;
    final state = j['stateId'], records = j['records'], email = j['workerEmail'], device = j['deviceId'], at = j['readAtMs'];
    if (state is! int || records is! List || email is! String || device is! String || at is! int) return null;
    return PendingSnapshot(
        stateId: state,
        records: List<Object?>.from(records),
        workerEmail: email,
        deviceId: device,
        readAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true));
  }
}

class CatchUpState {
  const CatchUpState({this.lots = const [], this.snapshots = const {}});
  final List<PendingCoaLot> lots;
  final Map<int, PendingSnapshot> snapshots;
}

class CatchUpStore {
  const CatchUpStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  /// Overridable for tests, as the other stores.
  final Directory Function() dataDir;

  File get _file => File('${dataDir().path}/server_catch_up.json');

  CatchUpState load() {
    try {
      final d = jsonDecode(_file.readAsStringSync());
      if (d is! Map) return const CatchUpState();
      final lots = d['lots'];
      final snaps = d['snapshots'];
      return CatchUpState(
        lots: lots is List ? [for (final l in lots) PendingCoaLot.fromJson(l)].whereType<PendingCoaLot>().toList() : const [],
        snapshots: {
          if (snaps is List)
            for (final s in [for (final s in snaps) PendingSnapshot.fromJson(s)].whereType<PendingSnapshot>()) s.stateId: s,
        },
      );
    } on FileSystemException {
      return const CatchUpState();
    } on FormatException {
      return const CatchUpState();
    }
  }

  void save(CatchUpState state) {
    dataDir().createSync(recursive: true);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({
      'lots': [for (final l in state.lots) l.toJson()],
      'snapshots': [for (final s in state.snapshots.values) s.toJson()],
    }));
    tmp.renameSync(_file.path);
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

/// Uploads a kept snapshot (inventory_upload_client.dart's uploadInventorySnapshot). Throws on failure.
typedef SnapshotUploader = Future<void> Function(PendingSnapshot snapshot);

class CatchUpWork extends ChangeNotifier {
  CatchUpWork({
    required this.health,
    required this.submitCoa,
    required this.uploadSnapshot,
    required this.auth,
    this.store = const CatchUpStore(),
    this.now = DateTime.now,
    this.maxLots = catchUpMaxLots,
  }) {
    try {
      _state = store.load();
    } catch (_) {
      _state = const CatchUpState();
    }
  }

  final ServerHealth health;
  final CoaLotSubmitter submitCoa;
  final SnapshotUploader uploadSnapshot;

  /// The worker's current session (the one last saved, if still fresh) and this install's id; null when there is no
  /// usable session right now (the lab reports then wait for the next run).
  final Future<CatchUpAuth?> Function() auth;
  final CatchUpStore store;
  final DateTime Function() now;
  final int maxLots;

  late CatchUpState _state;
  bool _running = false;
  bool _runAgain = false;
  bool _disposed = false;

  List<PendingCoaLot> get lots => List.unmodifiable(_state.lots);
  Map<int, PendingSnapshot> get snapshots => Map.unmodifiable(_state.snapshots);

  void _set(CatchUpState next) {
    _state = next;
    try {
      store.save(next);
    } catch (e) {
      debugPrint('catch-up work could not be saved (kept in memory until the next write): $e');
    }
    if (!_disposed) notifyListeners();
  }

  /// Remembers [lotGuid] for a submission once the server answers (replacing an earlier entry for it).
  void addCoaLot({required String lotGuid, required int packageId, required int stateId, double? statePsilocybin}) {
    final lots = [..._state.lots]..removeWhere((l) => l.lotGuid.toLowerCase() == lotGuid.toLowerCase());
    lots.add(PendingCoaLot(
        lotGuid: lotGuid, packageId: packageId, stateId: stateId, statePsilocybin: statePsilocybin, addedAt: now().toUtc()));
    while (lots.length > maxLots) {
      lots.removeAt(0);
    }
    _set(CatchUpState(lots: lots, snapshots: _state.snapshots));
  }

  /// Keeps [records] as [stateId]'s newest state read to upload once the server answers (replacing an older one).
  void keepSnapshot(int stateId, List<Object?> records, {required String workerEmail, required String deviceId}) {
    _set(CatchUpState(lots: _state.lots, snapshots: {
      ..._state.snapshots,
      stateId: PendingSnapshot(stateId: stateId, records: records, workerEmail: workerEmail, deviceId: deviceId, readAt: now().toUtc()),
    }));
  }

  /// A newer snapshot of [stateId] reached the server: the kept one is older, never to be sent.
  void snapshotSent(int stateId) {
    if (!_state.snapshots.containsKey(stateId)) return;
    _set(CatchUpState(lots: _state.lots, snapshots: {..._state.snapshots}..remove(stateId)));
  }

  /// Sends what is waiting while the server answers: the snapshots, then the lab reports, oldest first. Stops at the
  /// first failure that means the server couldn't be reached. One run at a time; a call during one goes round once more.
  Future<void> flush() async {
    if (_disposed) return;
    if (_running) {
      _runAgain = true;
      return;
    }
    _running = true;
    try {
      do {
        _runAgain = false;
        await _run();
      } while (_runAgain && !_disposed);
    } finally {
      _running = false;
    }
  }

  Future<void> _run() async {
    for (final snap in [..._state.snapshots.values]) {
      if (_disposed || health.offline) return;
      try {
        await uploadSnapshot(snap);
      } catch (e) {
        if (isServerUnreachable(e)) return;
        // refused (a sync already running, too many records, ...): the next state read sends a fresher one anyway
      }
      final current = _state.snapshots[snap.stateId];
      if (identical(current, snap)) {
        _set(CatchUpState(lots: _state.lots, snapshots: {..._state.snapshots}..remove(snap.stateId)));
      }
    }
    if (_state.lots.isEmpty || _disposed || health.offline) return;
    CatchUpAuth? credentials;
    try {
      credentials = await auth();
    } catch (_) {
      credentials = null;
    }
    if (credentials == null) return; // no usable session now: the lots wait for the next run
    for (final lot in [..._state.lots]) {
      if (_disposed || health.offline) return;
      try {
        await submitCoa(lot, credentials);
      } catch (e) {
        if (isServerUnreachable(e)) return;
        // the server (or the state) refused it: dropped, as the cart's own submission would be
      }
      _set(CatchUpState(lots: [..._state.lots]..remove(lot), snapshots: _state.snapshots));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
