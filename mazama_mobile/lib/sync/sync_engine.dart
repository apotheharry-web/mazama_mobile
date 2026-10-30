// The phone's one sync engine (specs/phone-sync PS-R1), one per app as the server link is: built on the local store
// with injected senders, clock and timers, it moves today's queues in on start (PS-R9, sync_migration.dart), owns the
// queue (PS-R4, sync_queue.dart), and sends what waits when woken: when the server tracker comes back online, at
// start-up (MazamaApp calls [wake]), and when the app returns to the foreground while online (offline, the tracker
// probes instead). The banner's count is [SyncQueue.waitingReports].
//
// It also owns the datasets (PS-R3, sync_datasets.dart): a refresher per dataset ([register]); [refresh] runs one per
// dataset and key at a time, writes what it read, or records only the failure, and never throws; [watch] is what a page
// reads. While the app is in the foreground and something is watched, a timer refreshes every
// [syncForegroundEvery] what is watched and older than that ([foregroundTick], PS-D6); never in the background
// ([onBackground]). When the server answers again in the foreground, what is watched is refreshed (README R87's
// reload, for the pages that watch: none yet in phase 2, whose pages still reload through their own health listener).
// Selling never calls it (PS-D3).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../local_store.dart';
import '../server_health.dart';
import 'sync_datasets.dart';
import 'sync_migration.dart';
import 'sync_queue.dart';
import 'sync_tables.dart';

/// PS-D6: what is watched is refreshed this often while the app is in the foreground.
const syncForegroundEvery = Duration(minutes: 5);

/// Whether data read at [fetchedAt] is due for a refresh at [now]: [every] old or more, or that far in the future (the
/// phone's clock moved back: refreshed rather than stuck until the clock catches up). A time just ahead counts as
/// just now.
bool datasetIsStale(DateTime fetchedAt, DateTime now, [Duration every = syncForegroundEvery]) {
  final age = now.difference(fetchedAt);
  return age >= every || -age >= every;
}

class SyncEngine {
  SyncEngine({
    required LocalStore store,
    required this.health,
    required Map<QueueKind, QueueSender> senders,
    DateTime Function()? now,
    StartTimer? startTimer,
    bool Function()? isDemo,
  }) : _queues = [
          SyncQueue(
              tables: openSyncTables(store),
              health: health,
              senders: senders,
              now: now,
              startTimer: startTimer,
              isDemo: isDemo),
        ],
        _ownsQueues = true {
    _listen();
  }

  /// An engine over queues built elsewhere: for tests only (a ServerLink made from its parts), where each part has a
  /// queue of its own over one database (the app's link builds one queue, [ServerLink.standard]). Woken, it flushes
  /// each in turn; [queue] (the first) counts what waits in all of them, and its tables hold the datasets.
  SyncEngine.over({required this.health, required List<SyncQueue> queues})
      : assert(queues.isNotEmpty),
        _queues = [
          for (var i = 0; i < queues.length; i++)
            if (!queues.take(i).any((q) => identical(q, queues[i]))) queues[i],
        ],
        _ownsQueues = false {
    _listen();
  }

  final ServerHealth health;
  final List<SyncQueue> _queues;
  final bool _ownsQueues;
  bool _wasOnline = true;
  bool _disposed = false;

  /// What the phone knows (PS-R3), in the queue's database.
  late final Datasets datasets = Datasets(queue.tables, now: queue.now);

  final Map<Dataset, Refresher> _refreshers = {};
  final Map<(Dataset, String), Future<void>> _refreshing = {};

  /// Refreshes asked for while one of the same dataset and key was running: it runs once more after (review I1, phase
  /// 4: a refresh a sale asks for must read after that sale, never be answered by a read that started before it).
  final Set<(Dataset, String)> _again = {};

  /// What pages watch, with how many watchers each.
  final Map<(Dataset, String), int> _watched = {};
  bool _foreground = true;
  Timer? _tick;

  /// Everything the phone still has to send.
  SyncQueue get queue => _queues.first;

  /// Changes whenever anything queued changes (the banner listens).
  Listenable get changes => Listenable.merge(_queues);

  void _listen() {
    _wasOnline = health.online;
    health.addListener(_onHealth);
  }

  void _onHealth() {
    final online = health.online;
    if (online && !_wasOnline) {
      wake();
      // Datasets only in the foreground (PS-D6: the tracker may probe in the background); coming back, onForeground's
      // tick refreshes whatever is stale then.
      if (_foreground) {
        for (final (d, key) in _watched.keys.toList()) {
          unawaited(refresh(d, key));
        }
      }
    }
    _wasOnline = online;
  }

  /// Sends what is waiting while the server answers. Returns at once.
  void wake() {
    if (_disposed || health.offline) return;
    unawaited(_flushAll());
  }

  Future<void> _flushAll() async {
    for (final q in _queues) {
      if (_disposed) return;
      try {
        await q.flush();
      } catch (e) {
        debugPrint('the sync queue could not be sent: $e');
      }
    }
  }

  /// The app came back to the foreground: offline, probe now; online, send anything still waiting. What is watched
  /// and older than [syncForegroundEvery] is refreshed, and the timer runs again.
  void onForeground() {
    if (_disposed) return;
    if (health.offline) {
      health.onForeground();
    } else {
      wake();
    }
    _foreground = true;
    foregroundTick();
    _arm();
  }

  /// The app went to the background: no refresh until it comes back (PS-D6: never a background fetch).
  void onBackground() {
    _foreground = false;
    _disarm();
  }

  // ---- datasets

  /// [d]'s refresher (one per dataset; a second replaces the first).
  void register(Dataset d, Refresher refresher) => _refreshers[d] = refresher;

  /// Reads [d]'s copy for [key] afresh with its refresher and stores it, stamped with when the read started; a failure
  /// only records the try and its error. One at a time per dataset and key: a call while one runs makes it run once more
  /// when it ends (however many such calls), and gets the future of both. Never throws; nothing happens for a dataset
  /// with no refresher, or once disposed.
  Future<void> refresh(Dataset d, String key) {
    final id = (d, key);
    final running = _refreshing[id];
    if (running != null) {
      _again.add(id);
      return running;
    }
    final refresher = _refreshers[d];
    if (_disposed || refresher == null) return Future.value();
    final run = _refreshRuns(id, refresher);
    _refreshing[id] = run;
    unawaited(run.whenComplete(() {
      _refreshing.remove(id);
    }));
    return run;
  }

  Future<void> _refreshRuns((Dataset, String) id, Refresher refresher) async {
    do {
      _again.remove(id);
      await _refreshOnce(id.$1, id.$2, refresher);
    } while (_again.contains(id) && !_disposed);
    _again.remove(id);
  }

  Future<void> _refreshOnce(Dataset d, String key, Refresher refresher) async {
    final startedAt = queue.now(); // the copy is as old as the read's start, never stamped later than its data
    try {
      final got = await refresher(key);
      if (_disposed) return;
      datasets.put(d, key, got.body, source: got.source, at: startedAt);
    } catch (e) {
      if (_disposed) return;
      datasets.failed(d, key, '$e');
    }
  }

  /// [d]'s copy for [key] as stored now (null when none), then again after every refresh of it (PS-R7). While it is
  /// listened to, it counts as watched: refreshed by [foregroundTick] and when the server answers again.
  Stream<DatasetRow?> watch(Dataset d, String key) {
    final id = (d, key);
    return datasets.watch(d, key, onListen: () {
      _watched[id] = (_watched[id] ?? 0) + 1;
      _arm();
    }, onCancel: () {
      final n = (_watched[id] ?? 1) - 1;
      if (n <= 0) {
        _watched.remove(id);
      } else {
        _watched[id] = n;
      }
      if (_watched.isEmpty) _disarm();
    });
  }

  /// Refreshes what is watched and stale ([datasetIsStale]; nothing stored counts as stale); nothing in the
  /// background.
  void foregroundTick() {
    if (_disposed || !_foreground) return;
    final now = queue.now();
    for (final (d, key) in _watched.keys.toList()) {
      if (!_refreshers.containsKey(d)) continue;
      final row = datasets.read(d, key);
      if (row == null || datasetIsStale(row.fetchedAt, now)) unawaited(refresh(d, key));
    }
  }

  void _arm() {
    if (_disposed || !_foreground || _watched.isEmpty || (_tick?.isActive ?? false)) return;
    _tick = queue.startTimer(syncForegroundEvery, () {
      _tick = null;
      foregroundTick();
      _arm();
    });
  }

  void _disarm() {
    _tick?.cancel();
    _tick = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disarm();
    _watched.clear();
    health.removeListener(_onHealth);
    if (_ownsQueues) {
      for (final q in _queues) {
        q.dispose();
      }
    }
  }
}
