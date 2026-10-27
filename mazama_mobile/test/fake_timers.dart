// Timers a test fires by hand (server_health.dart's and server_outbox.dart's StartTimer): each is recorded with its
// delay and runs only when the test calls fire, so backoff and retry delays are checked without waiting.
import 'dart:async';

class FakeTimer implements Timer {
  FakeTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  /// Runs the callback, once, if still active.
  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}

class FakeTimers {
  final all = <FakeTimer>[];

  Timer start(Duration delay, void Function() callback) {
    final t = FakeTimer(delay, callback);
    all.add(t);
    return t;
  }

  List<FakeTimer> get active => [for (final t in all) if (t.isActive) t];

  /// The delays of the timers still waiting.
  List<Duration> get pendingDelays => [for (final t in active) t.delay];

  /// Fires every timer still waiting (not ones they start).
  void fireAll() {
    for (final t in active) {
      t.fire();
    }
  }
}
