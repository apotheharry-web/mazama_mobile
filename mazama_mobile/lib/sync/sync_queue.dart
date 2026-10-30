// One queue for everything the phone still has to send to Mazama's server (specs/phone-sync PS-D2, PS-R4), each kind
// keeping exactly the rules it had in its own store before (server_outbox.dart, catch_up_store.dart, coa_uploader.dart):
//
//   - sale_log, sale_failure (keyed by clientId): one line, oldest first, one at a time, while the tracker is online.
//     Done leaves the queue; Unreachable with the tracker offline waits for it (its coming back online flushes again);
//     RetryAfter (429/408), or Unreachable while the tracker still counts the server online (a 5xx in the server's own
//     words: nothing else would wake the queue), waits [outboxRetryAfterBusy] on a timer; DeadLetter is kept with its
//     reason, never sent again. At most [cap] wait: past it the oldest sale_log is dropped and counted
//     ([droppedSaleLogs], kept as the `sync_dropped_sale_logs` document); a sale_failure is never dropped.
//   - inventory_snapshot, sales_snapshot (keyed by center): only the newest per center, a newer one replacing it (one
//     replaced while it was being sent stays to be sent). Done or Skipped (refused: the next state read sends a fresher
//     one) leave the queue; Unreachable stops the run.
//   - lab_report (keyed by lot id, lower case), two ways, as before:
//       kept (catch-up): stored, at most [labReportCap] waiting, the oldest dropped; sent by [flush] one at a time
//       after the snapshots. Done or Skipped (no report on file, or refused) leave the queue; Unreachable or Busy (no
//       session now, or 429) stop the run and keep it.
//       paced (the background uploader, CU-R1..R6): [offerLabReports]; held only in memory (the next load fills it
//       again), one start every [labReportStartEvery] at most, [labReportMaxInFlight] at most, every start on a timer,
//       never inside the call that offered it. Done: remembered as sent, callers told when it carries a value; Busy
//       (429, no session): the waiting ones are let go, none marked; Unreachable: that lot becomes a kept one while
//       there is room (never pushing out a cart add's), the waiting ones let go; Skipped: nothing remembered. While the
//       tracker counts the server offline nothing starts and the waiting ones are let go. Never in the demo (CU-R6).
//     A lot is remembered as sent for [sentKeep], at most [sentMax] (sync_sent); one sent lately is not offered again.
//   - par saves and orders are never queued (the owner's rule): they are not a kind.
//
// The senders do the network work and say what happened ([SendResult]); the queue decides what that means. A flush
// never throws: a sender that throws turns a report into a dead letter and anything else into a skip. Selling never
// waits on any of this (PS-D3): the cart only adds.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../catch_up_store.dart' show catchUpMaxLots;
import '../coa_uploader.dart' show coaSentKeepFor, coaSentMaxLots, coaUploadMaxInFlight, coaUploadStartInterval;
import '../demo/demo_banner.dart' show demoModeOn;
import '../server_health.dart';
import '../server_outbox.dart' show outboxCap, outboxRetryAfterBusy;
import 'sync_tables.dart';

/// What is queued, with its stored name.
enum QueueKind {
  saleLog('sale_log'),
  saleFailure('sale_failure'),
  inventorySnapshot('inventory_snapshot'),
  salesSnapshot('sales_snapshot'),
  labReport('lab_report');

  const QueueKind(this.stored);
  final String stored;
}

/// Sends one item and says what happened. Should not throw (see the file comment for what a throw means).
typedef QueueSender = Future<SendResult> Function(QueueItem item);

/// Told about a paced lab report the server took, with what the sender returned ([Done.value]).
typedef LabReportDone = void Function(QueueItem item, Object? value);

/// What one send came to.
sealed class SendResult {
  const SendResult();
}

/// Taken by the server; [value] is what it answered, when the caller wants it (a lab report's numbers).
class Done extends SendResult {
  const Done([this.value]);
  final Object? value;
}

/// The server couldn't be reached (no connection, no answer, a 5xx).
class Unreachable extends SendResult {
  const Unreachable({this.error, this.status});
  final String? error;
  final int? status;
}

/// The server asked for a wait (429, 408).
class RetryAfter extends SendResult {
  const RetryAfter(this.delay, {this.error, this.status});
  final Duration delay;
  final String? error;
  final int? status;
}

/// Refused for good: kept with [reason], never sent again.
class DeadLetter extends SendResult {
  const DeadLetter(this.reason, {this.status});
  final String reason;
  final int? status;
}

/// Nothing to send, or refused in a way that leaves nothing to remember (a lab report with no PDF on file).
class Skipped extends SendResult {
  const Skipped();
}

/// Not now (a lab report's 429, or no usable session): the run stops, nothing is marked.
class Busy extends SendResult {
  const Busy();
}

/// Every item can be sent at once: the queue's waits are timers, as before, so a clock moved backwards never holds one.
final _atOnce = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

const _droppedDocument = 'sync_dropped_sale_logs';

const _reportKinds = [QueueKind.saleLog, QueueKind.saleFailure];
const _snapshotKinds = [QueueKind.inventorySnapshot, QueueKind.salesSnapshot];

Timer _realTimer(Duration d, void Function() f) => Timer(d, f);
bool _demoModeIsOn() => demoModeOn.value;

class SyncQueue extends ChangeNotifier {
  SyncQueue({
    required this.tables,
    required this.health,
    required Map<QueueKind, QueueSender> senders,
    DateTime Function()? now,
    this.labReportStartEvery = coaUploadStartInterval,
    this.labReportMaxInFlight = coaUploadMaxInFlight,
    StartTimer? startTimer,
    this.cap = outboxCap,
    this.labReportCap = catchUpMaxLots,
    this.sentKeep = coaSentKeepFor,
    this.sentMax = coaSentMaxLots,
    bool Function()? isDemo,
  })  : senders = Map.unmodifiable(senders),
        now = now ?? DateTime.now,
        startTimer = startTimer ?? _realTimer,
        isDemo = isDemo ?? _demoModeIsOn {
    try {
      tables.resetSending();
    } catch (e) {
      debugPrint('the queue could not be read: $e');
    }
  }

  final SyncTables tables;
  final ServerHealth health;
  final Map<QueueKind, QueueSender> senders;
  final DateTime Function() now;
  final Duration labReportStartEvery;
  final int labReportMaxInFlight;
  final StartTimer startTimer;
  final int cap;
  final int labReportCap;
  final Duration sentKeep;
  final int sentMax;
  final bool Function() isDemo;

  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  static String _keyOf(QueueKind kind, String key) => kind == QueueKind.labReport ? key.toLowerCase() : key;

  // ---- adding

  /// Queues [body] as [kind]'s item [key] (replacing the one waiting with that key) and applies the kind's cap, in one
  /// transaction; a report is then sent at once if the server answers. Returns [key]. Never sends inside the call.
  String add(QueueKind kind, String key, Map<String, Object?> body) {
    final k = _keyOf(kind, key);
    // CU-R6, PS-R8: the demo never queues an upload or a lab report (nor does a phone that can't tell whether it is one)
    if (!_reportKinds.contains(kind) && _demo()) return k;
    final at = now().toUtc();
    final item = QueueItem(kind: kind.stored, key: k, body: jsonEncode(body), queuedAt: at, nextAt: _atOnce);
    try {
      _store(kind, item);
    } catch (e) {
      if (!_reportKinds.contains(kind)) rethrow;
      // The database refused the write: a sale's report is kept in memory (as the outbox always did) and written at
      // the next flush, so it is not lost while the app runs.
      debugPrint('a report could not be stored, kept in memory: $e');
      _unsaved.removeWhere((u) => u.key == k && u.kind == item.kind);
      _unsaved.add(item);
      if (_unsaved.length > cap) {
        final i = _unsaved.indexWhere((u) => u.kind == QueueKind.saleLog.stored);
        if (i >= 0) _unsaved.removeAt(i);
      }
    }
    _changed();
    if (_reportKinds.contains(kind)) unawaited(_flushReports());
    return k;
  }

  /// Whether this is the demo. An unreadable flag counts as the demo (phase 4 review M1): a demo phone that can't read
  /// it must never send real data, while a real phone taken for the demo only waits (the catch-up and the next load
  /// offer the work again).
  bool _demo() {
    try {
      return isDemo();
    } catch (_) {
      return true;
    }
  }

  /// Reports whose database write failed, in memory until a flush can write them.
  final _unsaved = <QueueItem>[];

  void _store(QueueKind kind, QueueItem item) {
    tables.store.transaction(() {
      switch (kind) {
        case QueueKind.saleLog || QueueKind.saleFailure:
          var dropped = 0;
          var logs = tables.count(QueueKind.saleLog.stored); // waiting ones: one being sent is never dropped
          while (_waitingInDb() >= cap && logs > 0) {
            tables.dropOldest(QueueKind.saleLog.stored, logs - 1);
            logs--;
            dropped++;
          }
          if (kind == QueueKind.saleLog && _waitingInDb() >= cap) {
            dropped++; // a full queue of failed-sale reports: this sale log is the one that doesn't fit
          } else {
            tables.enqueue(item);
          }
          if (dropped > 0) _setDropped(droppedSaleLogs + dropped);
        case QueueKind.labReport:
          tables.enqueue(item);
          if (tables.count(kind.stored) > labReportCap) tables.dropOldest(kind.stored, labReportCap);
        case QueueKind.inventorySnapshot || QueueKind.salesSnapshot:
          tables.enqueue(item);
      }
    });
  }

  /// Writes the reports kept in memory; the ones the database still refuses stay.
  void _persistUnsaved() {
    for (final item in [..._unsaved]) {
      try {
        _store(QueueKind.values.firstWhere((k) => k.stored == item.kind), item);
        _unsaved.remove(item);
      } catch (_) {
        return; // still refusing: try again at the next flush
      }
    }
  }

  /// Removes [kind]'s waiting item [key]: a newer one reached the server meanwhile, so it is moot.
  void remove(QueueKind kind, String key) {
    tables.remove(kind.stored, _keyOf(kind, key));
    _changed();
  }

  int _live(QueueKind kind) => tables.count(kind.stored) + tables.count(kind.stored, state: queueSending);

  // ---- counts

  /// The sale logs and failed-sale reports still to send: the banner's count.
  /// Never throws (the banner builds from it, around every page): when the database can't be read it is the database's
  /// last count, plus the reports kept in memory.
  int get waitingReports {
    try {
      _lastInDb = _waitingInDb();
    } catch (e) {
      debugPrint('the waiting reports could not be counted: $e');
    }
    return _lastInDb + _unsaved.length;
  }

  int _lastInDb = 0;

  int _waitingInDb() => _live(QueueKind.saleLog) + _live(QueueKind.saleFailure);

  /// Sale logs dropped because the queue was full, across restarts.
  int get droppedSaleLogs {
    try {
      final v = jsonDecode(tables.store.read(_droppedDocument)?.body ?? '0');
      return v is int ? v : 0;
    } catch (_) {
      return 0;
    }
  }

  void _setDropped(int n) => tables.store.write(_droppedDocument, jsonEncode(n));

  /// Whether the reports are waiting out a 429/408.
  bool get waitingOutBusy => _busyTimer != null;

  // ---- sent memory

  /// Remembers [kind]'s [key] as sent now (forgetting what is older than [sentKeep], and all but the newest [sentMax]).
  void markSent(QueueKind kind, String key) {
    final k = _keyOf(kind, key);
    if (k.isEmpty) return;
    final at = now().toUtc();
    try {
      tables.store.transaction(() {
        tables.sent(kind.stored, k, at);
        tables.pruneSent(kind.stored, at, sentKeep, sentMax);
      });
    } catch (e) {
      debugPrint('what was sent could not be remembered: $e');
    }
  }

  /// Whether [kind]'s [key] was sent less than [sentKeep] ago.
  bool wasSent(QueueKind kind, String key) => tables.wasSent(kind.stored, _keyOf(kind, key), now(), sentKeep);

  // ---- sending

  Future<void>? _reportsRun, _restRun;
  bool _reportsAgain = false, _restAgain = false;
  Timer? _busyTimer;

  /// Sends what is waiting while the server answers: the reports, then the snapshots, then the kept lab reports. One
  /// run of each at a time; a call during one makes it go round once more, and completes when that is done.
  Future<void> flush() async {
    await _flushReports();
    await _flushRest();
  }

  Future<SendResult> _send(QueueKind kind, QueueItem item) async {
    final sender = senders[kind];
    if (sender == null) return const Skipped();
    try {
      return await sender(item);
    } catch (e) {
      debugPrint('a ${kind.stored} sender failed: $e');
      return _reportKinds.contains(kind) ? DeadLetter('$e') : const Skipped();
    }
  }

  /// [item]'s body with the try's [error] and [status] (a report's, for the debug page); null when it isn't a map.
  static String? _tried(QueueItem item, String? error, int? status) {
    if (error == null && status == null) return null;
    try {
      final b = jsonDecode(item.body);
      if (b is! Map) return null;
      return jsonEncode({...b, if (error != null) 'lastError': error, if (status != null) 'status': status});
    } catch (_) {
      return null;
    }
  }

  Future<void> _flushReports() {
    if (_disposed) return Future.value();
    final running = _reportsRun;
    if (running != null) {
      _reportsAgain = true; // goes round once more; the caller waits for that
      return running;
    }
    return _reportsRun = _runReports().whenComplete(() => _reportsRun = null);
  }

  Future<void> _runReports() async {
    try {
      do {
        _reportsAgain = false;
        await _reportsOnce();
      } while (_reportsAgain && !_disposed);
    } catch (e) {
      debugPrint('the reports could not be sent: $e');
    }
  }


  QueueItem? _nextReport() {
    QueueItem? best;
    for (final kind in _reportKinds) {
      if (!senders.containsKey(kind)) continue;
      final head = tables.due(kind.stored, now(), limit: 1).firstOrNull;
      if (head == null) continue;
      if (best == null ||
          head.queuedAt.isBefore(best.queuedAt) ||
          (head.queuedAt == best.queuedAt && head.id! < best.id!)) {
        best = head;
      }
    }
    return best;
  }

  Future<void> _reportsOnce() async {
    if (_unsaved.isNotEmpty) _persistUnsaved();
    while (!_disposed && health.online && _busyTimer == null) {
      final head = _nextReport();
      if (head == null) return;
      final kind = QueueKind.values.firstWhere((k) => k.stored == head.kind);
      tables.markSending(head.id!);
      final result = await _send(kind, head);
      if (_disposed) return;
      switch (result) {
        case Done() || Skipped():
          tables.done(head.id!);
        case DeadLetter(:final reason, :final status):
          tables.dead(head.id!, reason, body: _tried(head, reason, status));
        case Unreachable(:final error, :final status) when health.offline:
          tables.retryAt(head.id!, _atOnce, body: _tried(head, error, status));
          _changed();
          return; // the tracker is offline now: its coming back online flushes again
        case Unreachable(:final error, :final status):
          _waitOutBusy(head, outboxRetryAfterBusy, error, status);
          return;
        case RetryAfter(:final delay, :final error, :final status):
          _waitOutBusy(head, delay, error, status);
          return;
        case Busy():
          _waitOutBusy(head, outboxRetryAfterBusy, null, null);
          return;
      }
      _changed();
    }
  }

  void _waitOutBusy(QueueItem head, Duration delay, String? error, int? status) {
    tables.retryAt(head.id!, _atOnce, body: _tried(head, error, status));
    _busyTimer = startTimer(delay, () {
      _busyTimer = null;
      unawaited(_flushReports());
    });
    _changed();
  }

  Future<void> _flushRest() {
    if (_disposed) return Future.value();
    final running = _restRun;
    if (running != null) {
      _restAgain = true; // goes round once more; the caller waits for that
      return running;
    }
    return _restRun = _runRest().whenComplete(() => _restRun = null);
  }

  Future<void> _runRest() async {
    try {
      do {
        _restAgain = false;
        await _restOnce();
      } while (_restAgain && !_disposed);
    } catch (e) {
      debugPrint('the queued uploads could not be sent: $e');
    }
  }


  /// The snapshots, then the kept lab reports, each as it was when the run started; stops when the server can't be
  /// reached.
  Future<void> _restOnce() async {
    for (final kind in [..._snapshotKinds, QueueKind.labReport]) {
      if (!senders.containsKey(kind)) continue;
      for (final item in tables.due(kind.stored, now())) {
        if (_disposed || health.offline) return;
        tables.markSending(item.id!);
        final result = await _send(kind, item);
        if (_disposed) return;
        switch (result) {
          case Done():
            tables.done(item.id!);
            if (kind == QueueKind.labReport) markSent(kind, item.key);
          case Skipped():
            tables.done(item.id!);
          case DeadLetter(:final reason):
            tables.dead(item.id!, reason);
          case Unreachable() || RetryAfter() || Busy():
            tables.retryAt(item.id!, _atOnce);
            _changed();
            return;
        }
        _changed();
      }
    }
  }

  // ---- paced lab reports (the background uploader)

  final _paced = <QueueItem>[];
  final _listeners = <String, List<LabReportDone>>{};
  final _inFlight = <String>{};
  DateTime? _lastStart;
  Timer? _paceTimer;

  /// Paced lab reports waiting to start.
  int get labReportsWaiting => _paced.length;

  /// Paced lab reports under way.
  int get labReportsInFlight => _inFlight.length;

  /// Nothing paced waiting or under way.
  bool get labReportsIdle => _paced.isEmpty && _inFlight.isEmpty;

  /// Whether the lot [key] (any case) is waiting or being sent paced.
  bool labReportPending(String key) => _listeners.containsKey(key.toLowerCase());

  /// Offers [lots] to the paced uploads, leaving out any already waiting or under way (whose [onDone] is added to it),
  /// sent in the last [sentKeep], or kept. Returns at once; uploads start on a timer.
  void offerLabReports(List<({String key, Map<String, Object?> body})> lots, {LabReportDone? onDone}) {
    if (_disposed || _demo() || lots.isEmpty) return;
    final kept = {for (final i in tables.items(QueueKind.labReport.stored)) if (i.state != queueDead) i.key};
    final at = now().toUtc();
    for (final lot in lots) {
      final key = lot.key.toLowerCase();
      if (key.isEmpty) continue;
      final listeners = _listeners[key];
      if (listeners != null) {
        if (onDone != null) listeners.add(onDone);
        continue;
      }
      if (kept.contains(key) || wasSent(QueueKind.labReport, key)) continue;
      _paced.add(QueueItem(kind: QueueKind.labReport.stored, key: key, body: jsonEncode(lot.body), queuedAt: at, nextAt: _atOnce));
      _listeners[key] = [if (onDone != null) onDone];
    }
    _schedule();
  }

  void _schedule() {
    if (_disposed || _paceTimer != null || _paced.isEmpty || _inFlight.length >= labReportMaxInFlight) return;
    final last = _lastStart;
    var wait = last == null ? Duration.zero : labReportStartEvery - now().difference(last);
    if (wait.isNegative) wait = Duration.zero;
    _paceTimer = startTimer(wait, () {
      _paceTimer = null;
      try {
        _startNext();
      } catch (e) {
        // never stall the pacing: what could not start is let go, and the next load offers it again
        debugPrint('a lab report could not be started: $e');
        _letGo();
      }
    });
  }

  void _startNext() {
    if (_disposed) return;
    if (_demo() || health.offline) {
      _letGo(); // the waiting lots are let go, unmarked; the next load offers them again (CU-R4)
      return;
    }
    while (_paced.isNotEmpty && _inFlight.length < labReportMaxInFlight) {
      final item = _paced.removeAt(0);
      if (wasSent(QueueKind.labReport, item.key)) {
        _listeners.remove(item.key); // sent meanwhile (a cart add): nothing to start
        continue;
      }
      _inFlight.add(item.key);
      _lastStart = now();
      unawaited(_upload(item));
      break;
    }
    _schedule();
  }

  Future<void> _upload(QueueItem item) async {
    try {
      final result = await _send(QueueKind.labReport, item);
      if (_disposed) return;
      switch (result) {
        case Done(:final value):
          markSent(QueueKind.labReport, item.key);
          if (value != null) {
            for (final listener in [...?_listeners[item.key]]) {
              try {
                listener(item, value);
              } catch (e) {
                debugPrint('a lab report listener failed (the upload itself went through): $e');
              }
            }
          }
        case Busy() || RetryAfter():
          _letGo();
        case Unreachable():
          _keepForLater(item);
          _letGo();
        case Skipped() || DeadLetter():
          break; // not sent; the next load offers it again
      }
    } finally {
      _inFlight.remove(item.key);
      _listeners.remove(item.key);
      _schedule();
    }
  }

  void _keepForLater(QueueItem item) {
    try {
      if (_live(QueueKind.labReport) >= labReportCap) return; // never at the cost of a cart add's lot
      final body = jsonDecode(item.body);
      add(QueueKind.labReport, item.key, body is Map ? Map<String, Object?>.from(body) : const {});
    } catch (e) {
      debugPrint('a lab report could not be kept for later: $e');
    }
  }

  void _letGo() {
    for (final item in _paced) {
      _listeners.remove(item.key);
    }
    _paced.clear();
    _paceTimer?.cancel();
    _paceTimer = null;
  }

  /// Nothing more is sent or started; what is queued is in the database already.
  @override
  void dispose() {
    if (_disposed) return;
    _letGo();
    _busyTimer?.cancel();
    _busyTimer = null;
    _disposed = true;
    super.dispose();
  }
}
