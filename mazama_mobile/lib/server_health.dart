// Whether Mazama's server is answering, one tracker for the whole app (README R56, server_link.dart). Every /p/ call
// goes through ServerLinkClient (server_link_client.dart), which tells this tracker how it ended:
//   - no connection, no answer in time, or a 5xx that isn't the server's own {"detail": ...} reply: offline (from now);
//   - any reply from the server itself (2xx, 4xx, or a 5xx with its own error envelope): online.
// While offline, every /p/ call fails at once with the same "can't be reached" error the clients already throw
// (no request is made), so the pages' fallbacks (stock from the state system, the copies kept on the phone, scan
// matching on the phone) show at once instead of after a timeout. Only [ServerHealth.probe] still reaches the server:
// 15 s after going offline, then doubling up to every 5 minutes, and at once whenever the app comes back to the
// foreground ([ServerHealth.onForeground]). A probe that gets an answer brings the tracker back online, which wakes
// the outbox and the catch-up work (server_link.dart).
//
// When the previous run of the app ended with the server offline (server_link.dart keeps when it went offline), the
// tracker starts offline from that time and probes at once: after a restart mid-outage the pages don't each wait out a
// timeout first, and if the server is back the probe brings everything online within a second or so.
//
// Selling never goes through here: the sale is sent straight to the state system, whatever this tracker says.
import 'dart:async';

import 'package:flutter/foundation.dart';

/// Starts a one-shot timer: [Timer.new] in the app, a recorder in tests.
typedef StartTimer = Timer Function(Duration delay, void Function() callback);

Timer _realTimer(Duration delay, void Function() callback) => Timer(delay, callback);

/// The first probe after going offline.
const probeFirstDelay = Duration(seconds: 15);

/// The longest wait between two probes (the delay doubles from [probeFirstDelay] after each probe that fails).
const probeMaxDelay = Duration(minutes: 5);

class ServerHealth extends ChangeNotifier {
  ServerHealth({
    required this.probe,
    this.now = DateTime.now,
    this.startTimer = _realTimer,
    DateTime? rememberedOfflineSince,
    this.onOfflineSinceChanged,
  }) {
    final since = rememberedOfflineSince;
    if (since != null) {
      _offline = true;
      _since = since.toUtc();
      _schedule(Duration.zero);
    }
  }

  /// Asks the server whether it answers (GET /p/ping, ping_client.dart): true when it does. Never throws (a throw counts
  /// as false).
  final Future<bool> Function() probe;
  final DateTime Function() now;
  final StartTimer startTimer;

  /// Told when the server goes offline (with since when) and when it answers again (null), so it can be kept for the
  /// next run of the app (server_link.dart).
  final void Function(DateTime? since)? onOfflineSinceChanged;

  bool _offline = false;
  DateTime? _since;
  Duration _nextDelay = probeFirstDelay;
  Timer? _timer;
  bool _probing = false;
  bool _disposed = false;

  bool get offline => _offline;
  bool get online => !_offline;

  /// When the server stopped answering (UTC); null while online.
  DateTime? get offlineSince => _offline ? _since : null;

  /// How long the next scheduled probe waits (for tests and the debug page).
  Duration get nextProbeDelay => _nextDelay;

  /// Whether a probe is waiting on its timer.
  bool get probeScheduled => _timer != null;

  /// A /p/ call ended without an answer from the server.
  void markUnreachable() {
    if (_disposed || _offline) return;
    _offline = true;
    _since = now().toUtc();
    _nextDelay = probeFirstDelay;
    onOfflineSinceChanged?.call(_since);
    _schedule(_nextDelay);
    notifyListeners();
  }

  /// A /p/ call (or a probe) got an answer from the server.
  void markReachable() {
    if (_disposed || !_offline) return;
    _offline = false;
    _since = null;
    _nextDelay = probeFirstDelay;
    _timer?.cancel();
    _timer = null;
    onOfflineSinceChanged?.call(null);
    notifyListeners();
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = startTimer(delay, () {
      _timer = null;
      unawaited(checkNow());
    });
  }

  /// Probes now, if offline (the scheduled re-check, the foreground re-check, the debug page's button): true when the
  /// server answered (the tracker is then online). A probe that fails schedules the next one, twice as far off (at
  /// most [probeMaxDelay]). One probe at a time: a call while one is out answers false without starting another.
  Future<bool> checkNow() async {
    if (_disposed) return false;
    if (!_offline) return true;
    if (_probing) return false;
    _probing = true;
    bool ok;
    try {
      ok = await probe();
    } catch (_) {
      ok = false;
    } finally {
      _probing = false;
    }
    if (_disposed) return ok;
    if (!_offline) return true; // a call got an answer meanwhile
    if (ok) {
      markReachable();
    } else {
      final doubled = _nextDelay * 2;
      _nextDelay = doubled > probeMaxDelay ? probeMaxDelay : doubled;
      _schedule(_nextDelay);
    }
    return ok;
  }

  /// The app came back to the foreground: while offline, probe at once rather than wait for the timer (which can be
  /// minutes off, and doesn't run while the phone keeps the app suspended).
  void onForeground() {
    if (_disposed || !_offline) return;
    _timer?.cancel();
    _timer = null;
    unawaited(checkNow().then((ok) {
      // a probe already out when this came in answered false without probing: make sure one is still scheduled
      if (!ok && _offline && !_disposed && _timer == null && !_probing) _schedule(_nextDelay);
    }));
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
