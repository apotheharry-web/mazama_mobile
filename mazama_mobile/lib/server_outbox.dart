// The phone's outbox for reports to Mazama's server that must not be lost while it can't be reached (README R56,
// server_link.dart): the sale-attribution log sent after every confirmed sale (POST /p/sale-log) and the failed-sale
// report sent for every sale that didn't go through (POST /p/sale-failure). Both used to be dropped when the server
// was down; Mazama's server can be down for days, and a failed-sale report is what a center's staff review.
//
// Each report gets a clientId (a UUID v4) when it is queued and keeps it; the server records a clientId once per center
// and answers a repeat as already done (appreport.py), so sending one again after a lost reply is safe.
//
// One JSON document in the data folder's LocalStore (server_outbox.json, synchronous calls as the other stores), so the queue
// survives the app being closed. Sent oldest first, one at a time, when the server tracker comes back online (and at
// start-up, and right after a report is queued while online):
//   - a 2xx (or the server's "already have it", the same 201): the report leaves the queue;
//   - the server can't be reached (no connection, no answer in time, a 5xx; or the tracker already counts it as
//     offline): the report stays, and sending stops until the tracker is online again;
//   - 429 (too many requests: a long queue meets the route's per-minute limit), 408, or a 5xx in the server's own
//     words (the server answered, so the tracker stays online): the report stays, and sending tries again in a minute;
//   - any other 4xx (or anything unexpected): the report moves to the dead letters, kept with the server's reason,
//     never sent again and never deleted (the debug page lists them, debug_server_link_page.dart).
//
// Size: at most [outboxCap] reports wait. A report is one cart's sale records (a few KB), so the file stays a few MB
// at most, and 1000 is well over a week of sales at a busy center with the server down. When it is full, the oldest
// sale-attribution log is dropped to make room (they are the lesser record: the sale itself is at the state already)
// and counted in [ServerOutbox.droppedLogs], which the banner and the debug page show. A failed-sale report is never
// dropped: with nothing else to drop it is queued past the cap.
//
// Never queued here: par levels and orders (they stay blocked with "try again later": the owner's decision), and the
// inventory snapshot and lab reports, which need the newest state read or the worker's state token at send time
// (catch_up_store.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'sale_failure_client.dart' as sale_failure_client;
import 'sale_log_client.dart' as sale_log_client;
import 'server_error.dart';
import 'server_health.dart';
import 'session_store.dart' show defaultSessionDataDir;

/// How many reports may wait (see the file comment for why this many, and what happens past it).
const outboxCap = 1000;

/// How long sending waits after a 429 (the server's per-minute limit) or a 408.
const outboxRetryAfterBusy = Duration(seconds: 61);

/// A random UUID v4, as the phone gives each queued report ([random]: tests pass a seeded one).
String uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// What a queued report is.
enum OutboxKind { saleLog, saleFailure }

const _kindNames = {OutboxKind.saleLog: 'sale_log', OutboxKind.saleFailure: 'sale_failure'};

/// One report waiting (or, as a dead letter, refused). [request] is the sale records; [response] what the state
/// answered (sale logs only); [reason] why the sale didn't go through (failed-sale reports only).
class OutboxEntry {
  const OutboxEntry({
    required this.clientId,
    required this.kind,
    required this.stateId,
    required this.workerEmail,
    required this.deviceId,
    required this.request,
    this.response,
    this.reason,
    required this.createdAt,
    this.attempts = 0,
    this.lastError,
    this.status,
  });

  final String clientId;
  final OutboxKind kind;
  final int stateId;
  final String workerEmail;
  final String deviceId;
  final List<Map<String, Object?>> request;
  final Object? response;
  final String? reason;
  final DateTime createdAt;

  /// Sends tried so far, and the last one's error (and, for a dead letter, the status the server refused it with).
  final int attempts;
  final String? lastError;
  final int? status;

  OutboxEntry tried(String error, {int? status}) => OutboxEntry(
      clientId: clientId,
      kind: kind,
      stateId: stateId,
      workerEmail: workerEmail,
      deviceId: deviceId,
      request: request,
      response: response,
      reason: reason,
      createdAt: createdAt,
      attempts: attempts + 1,
      lastError: error,
      status: status ?? this.status);

  Map<String, Object?> toJson() => {
        'clientId': clientId,
        'kind': _kindNames[kind],
        'stateId': stateId,
        'workerEmail': workerEmail,
        'deviceId': deviceId,
        'request': request,
        'response': response,
        'reason': reason,
        'createdAtMs': createdAt.millisecondsSinceEpoch,
        'attempts': attempts,
        'lastError': lastError,
        'status': status,
      };

  /// Null for anything this class didn't write (an older or damaged entry).
  static OutboxEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = _kindNames.entries.where((e) => e.value == j['kind']).map((e) => e.key).firstOrNull;
    final clientId = j['clientId'];
    final stateId = j['stateId'];
    final email = j['workerEmail'];
    final device = j['deviceId'];
    final request = j['request'];
    final created = j['createdAtMs'];
    if (kind == null || clientId is! String || stateId is! int || email is! String || device is! String) return null;
    if (request is! List || request.any((r) => r is! Map) || created is! int) return null;
    final reason = j['reason'];
    if (kind == OutboxKind.saleFailure && reason is! String) return null;
    final attempts = j['attempts'];
    final lastError = j['lastError'];
    final status = j['status'];
    return OutboxEntry(
      clientId: clientId,
      kind: kind,
      stateId: stateId,
      workerEmail: email,
      deviceId: device,
      request: [for (final r in request) Map<String, Object?>.from(r as Map)],
      response: j['response'],
      reason: reason is String ? reason : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(created, isUtc: true),
      attempts: attempts is int ? attempts : 0,
      lastError: lastError is String ? lastError : null,
      status: status is int ? status : null,
    );
  }
}

/// What [OutboxStore] keeps: the queue (oldest first), the dead letters, and how many sale logs were dropped for room.
class OutboxState {
  const OutboxState({this.pending = const [], this.dead = const [], this.droppedLogs = 0});
  final List<OutboxEntry> pending;
  final List<OutboxEntry> dead;
  final int droppedLogs;
}

class OutboxStore {
  const OutboxStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  /// Overridable for tests, as the other stores.
  final Directory Function() dataDir;

  static const _name = 'server_outbox.json';

  /// What was kept; an empty state when nothing (readable) was. Entries that can't be read are skipped, not lost
  /// silently: the document is only rewritten from what was read, so an unreadable entry goes on the next write.
  OutboxState load() {
    try {
      final text = LocalStore.forDir(dataDir()).read(_name)?.body;
      if (text == null) return const OutboxState();
      final decoded = jsonDecode(text);
      if (decoded is! Map) return const OutboxState();
      List<OutboxEntry> list(Object? v) => v is List ? [for (final e in v) OutboxEntry.fromJson(e)].whereType<OutboxEntry>().toList() : const [];
      final dropped = decoded['droppedLogs'];
      return OutboxState(pending: list(decoded['pending']), dead: list(decoded['dead']), droppedLogs: dropped is int ? dropped : 0);
    } on FileSystemException {
      return const OutboxState();
    } on FormatException {
      return const OutboxState();
    }
  }

  void save(OutboxState state) {
    // One write, one transaction: a crash mid-write leaves the previous queue whole.
    LocalStore.forDir(dataDir()).write(_name, jsonEncode({
      'pending': [for (final e in state.pending) e.toJson()],
      'dead': [for (final e in state.dead) e.toJson()],
      'droppedLogs': state.droppedLogs,
    }));
  }
}

/// Sends one queued report; throws on anything but a success (server_error.dart's rules say which failures mean the
/// server couldn't be reached; a ServerRequestError's status says 429/408).
typedef OutboxSender = Future<void> Function(OutboxEntry entry);

/// The real sender: the report's own client (sale_log_client.dart / sale_failure_client.dart), with its clientId.
Future<void> sendOutboxEntry(OutboxEntry e) => switch (e.kind) {
      OutboxKind.saleLog => sale_log_client.postSaleLog(e.stateId,
          workerEmail: e.workerEmail, deviceId: e.deviceId, request: e.request, response: e.response, clientId: e.clientId),
      OutboxKind.saleFailure => sale_failure_client.postSaleFailure(e.stateId,
          workerEmail: e.workerEmail, deviceId: e.deviceId, reason: e.reason ?? '', request: e.request, clientId: e.clientId),
    };

int? _statusOf(Object error) => error is sale_log_client.SaleLogError
    ? error.status
    : error is sale_failure_client.SaleFailureError
        ? error.status
        : null;

class ServerOutbox extends ChangeNotifier {
  ServerOutbox({
    required this.health,
    this.store = const OutboxStore(),
    this.send = sendOutboxEntry,
    this.now = DateTime.now,
    this.startTimer = _timer,
    this.cap = outboxCap,
    Random? random,
  }) : _random = random {
    try {
      _state = store.load();
    } catch (_) {
      _state = const OutboxState();
    }
  }

  static Timer _timer(Duration d, void Function() f) => Timer(d, f);

  final ServerHealth health;
  final OutboxStore store;
  final OutboxSender send;
  final DateTime Function() now;
  final StartTimer startTimer;
  final int cap;
  final Random? _random;

  late OutboxState _state;
  bool _flushing = false;
  bool _flushAgain = false;
  Timer? _busyTimer;
  bool _disposed = false;

  /// Reports waiting, oldest first.
  List<OutboxEntry> get pending => List.unmodifiable(_state.pending);

  /// Reports the server refused (kept, never sent again).
  List<OutboxEntry> get dead => List.unmodifiable(_state.dead);

  int get pendingCount => _state.pending.length;

  /// How many sale-attribution logs were dropped because the queue was full (see the file comment).
  int get droppedLogs => _state.droppedLogs;

  /// Whether sending is waiting out a 429/408.
  bool get waitingOutBusy => _busyTimer != null;

  void _set(OutboxState next) {
    _state = next;
    try {
      store.save(next);
    } catch (e) {
      debugPrint('the outbox could not be saved (kept in memory until the next write): $e');
    }
    if (!_disposed) notifyListeners();
  }

  /// Queues a confirmed sale's attribution log (sale_log_client.dart) and sends it now if the server is answering.
  Future<String> addSaleLog(int stateId,
          {required String workerEmail, required String deviceId, required List<Map<String, Object?>> request, required Object? response}) =>
      _add(OutboxEntry(
          clientId: uuidV4(_random),
          kind: OutboxKind.saleLog,
          stateId: stateId,
          workerEmail: workerEmail,
          deviceId: deviceId,
          request: request,
          response: response,
          createdAt: now().toUtc()));

  /// Queues a failed-sale report (sale_failure_client.dart) and sends it now if the server is answering.
  Future<String> addSaleFailure(int stateId,
          {required String workerEmail, required String deviceId, required String reason, required List<Map<String, Object?>> request}) =>
      _add(OutboxEntry(
          clientId: uuidV4(_random),
          kind: OutboxKind.saleFailure,
          stateId: stateId,
          workerEmail: workerEmail,
          deviceId: deviceId,
          request: request,
          reason: reason,
          createdAt: now().toUtc()));

  Future<String> _add(OutboxEntry entry) async {
    final queue = [..._state.pending];
    var dropped = _state.droppedLogs;
    while (queue.length >= cap) {
      final i = queue.indexWhere((e) => e.kind == OutboxKind.saleLog);
      if (i == -1) break; // only failed-sale reports left: never dropped, so this one goes past the cap
      queue.removeAt(i);
      dropped++;
    }
    if (queue.length >= cap && entry.kind == OutboxKind.saleLog) {
      dropped++; // a full queue of failed-sale reports: this sale log is the one that doesn't fit
    } else {
      queue.add(entry);
    }
    _set(OutboxState(pending: queue, dead: _state.dead, droppedLogs: dropped));
    unawaited(flush());
    return entry.clientId;
  }

  /// Sends what's waiting, oldest first, one at a time, until the queue is empty or the server can't take more just
  /// now (see the file comment). One flush at a time; a call during one makes it go round once more.
  Future<void> flush() async {
    if (_disposed) return;
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    _flushing = true;
    try {
      do {
        _flushAgain = false;
        await _flushOnce();
      } while (_flushAgain && !_disposed);
    } finally {
      _flushing = false;
    }
  }

  Future<void> _flushOnce() async {
    while (!_disposed && _state.pending.isNotEmpty && health.online && _busyTimer == null) {
      final head = _state.pending.first;
      try {
        await send(head);
      } catch (e) {
        if (_disposed) return;
        final status = _statusOf(e);
        if (isServerUnreachable(e) && health.offline) {
          _replaceHead(head.tried('$e', status: status));
          return; // the tracker is offline now: its coming back online flushes again
        }
        // 429/408, or a 5xx the server answered itself (the tracker stays online, so nothing else would wake this)
        if (status == 429 || status == 408 || isServerUnreachable(e)) {
          _replaceHead(head.tried('$e', status: status));
          _busyTimer = startTimer(outboxRetryAfterBusy, () {
            _busyTimer = null;
            unawaited(flush());
          });
          if (!_disposed) notifyListeners();
          return;
        }
        _set(OutboxState(
            pending: [..._state.pending]..remove(head),
            dead: [..._state.dead, head.tried('$e', status: status)],
            droppedLogs: _state.droppedLogs));
        continue;
      }
      if (_disposed) return;
      _set(OutboxState(pending: [..._state.pending]..remove(head), dead: _state.dead, droppedLogs: _state.droppedLogs));
    }
  }

  void _replaceHead(OutboxEntry updated) {
    final queue = [..._state.pending];
    final i = queue.indexWhere((e) => e.clientId == updated.clientId);
    if (i != -1) queue[i] = updated;
    _set(OutboxState(pending: queue, dead: _state.dead, droppedLogs: _state.droppedLogs));
  }

  @override
  void dispose() {
    _disposed = true;
    _busyTimer?.cancel();
    _busyTimer = null;
    super.dispose();
  }
}
