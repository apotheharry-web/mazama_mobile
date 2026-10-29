// server_health.dart: the one tracker of whether Mazama's server answers (README R56) - offline on an unreachable call,
// online on any answer, a probe on a backoff (15 s doubling to 5 min) and at once on coming back to the foreground.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/server_health.dart';

import 'fake_timers.dart';

void main() {
  late FakeTimers timers;
  late List<bool> answers; // what the probes answer, in order (false once the list runs out)
  late int probes;
  final t0 = DateTime.utc(2026, 10, 23, 18, 5);

  ServerHealth tracker({DateTime? remembered, void Function(DateTime?)? onChanged}) => ServerHealth(
        probe: () async {
          probes++;
          return answers.isEmpty ? false : answers.removeAt(0);
        },
        now: () => t0,
        startTimer: timers.start,
        rememberedOfflineSince: remembered,
        onOfflineSinceChanged: onChanged,
      );

  setUp(() {
    timers = FakeTimers();
    answers = [];
    probes = 0;
  });

  test('starts online; an unreachable call marks it offline since then and notifies once', () {
    final h = tracker();
    var notified = 0;
    h.addListener(() => notified++);
    expect([h.online, h.offlineSince], [true, null]);
    h.markUnreachable();
    h.markUnreachable(); // a second failure changes nothing
    expect([h.offline, h.offlineSince], [true, t0]);
    expect(notified, 1);
    expect(timers.pendingDelays, [probeFirstDelay]);
  });

  test('any answer marks it online again, cancels the probe and notifies', () {
    final h = tracker();
    h.markUnreachable();
    var notified = 0;
    h.addListener(() => notified++);
    h.markReachable();
    expect([h.online, h.offlineSince], [true, null]);
    expect(timers.active, isEmpty);
    expect(notified, 1);
    h.markReachable();
    expect(notified, 1);
  });

  test('the probe backs off: 15 s, then doubling, never more than 5 minutes', () async {
    final h = tracker();
    h.markUnreachable();
    final seen = <Duration>[];
    for (var i = 0; i < 8; i++) {
      seen.add(timers.active.single.delay);
      timers.active.single.fire();
      await pumpEventQueue();
    }
    expect(seen, [
      const Duration(seconds: 15),
      const Duration(seconds: 30),
      const Duration(seconds: 60),
      const Duration(seconds: 120),
      const Duration(seconds: 240),
      const Duration(minutes: 5),
      const Duration(minutes: 5),
      const Duration(minutes: 5),
    ]);
    expect(probes, 8);
    expect(h.offline, isTrue);
  });

  test('a probe that gets an answer brings it online and stops probing', () async {
    final h = tracker();
    h.markUnreachable();
    answers = [false, true];
    timers.active.single.fire();
    await pumpEventQueue();
    expect(h.offline, isTrue);
    timers.active.single.fire();
    await pumpEventQueue();
    expect(h.online, isTrue);
    expect(timers.active, isEmpty);
    // offline again later: the backoff starts over at 15 s
    h.markUnreachable();
    expect(timers.pendingDelays, [probeFirstDelay]);
  });

  test('coming back to the foreground probes at once instead of waiting for the timer', () async {
    final h = tracker();
    h.markUnreachable();
    answers = [true];
    h.onForeground();
    await pumpEventQueue();
    expect(probes, 1);
    expect(h.online, isTrue);
    expect(timers.active, isEmpty);
  });

  test('a foreground probe that fails leaves the next one scheduled', () async {
    final h = tracker();
    h.markUnreachable();
    h.onForeground();
    await pumpEventQueue();
    expect(probes, 1);
    expect(h.offline, isTrue);
    expect(timers.active, hasLength(1));
  });

  test('online, the foreground and checkNow do nothing', () async {
    final h = tracker();
    h.onForeground();
    expect(await h.checkNow(), isTrue);
    expect(probes, 0);
  });

  test('one probe at a time', () async {
    final gate = Completer<bool>();
    final h = ServerHealth(probe: () => gate.future, startTimer: timers.start);
    h.markUnreachable();
    final first = h.checkNow();
    expect(await h.checkNow(), isFalse); // a second call while one is out doesn't start another
    gate.complete(true);
    expect(await first, isTrue);
    expect(h.online, isTrue);
  });

  test('a probe that throws counts as no answer', () async {
    final h = ServerHealth(probe: () async => throw StateError('boom'), startTimer: timers.start);
    h.markUnreachable();
    expect(await h.checkNow(), isFalse);
    expect(h.offline, isTrue);
  });

  test('when it went offline is told to the keeper, and cleared when it answers', () {
    final told = <DateTime?>[];
    final h = tracker(onChanged: told.add);
    h.markUnreachable();
    h.markReachable();
    expect(told, [t0, null]);
  });

  test('a run that starts after one that ended offline starts offline from then and probes at once', () async {
    final earlier = DateTime.utc(2026, 10, 21, 9);
    final h = tracker(remembered: earlier);
    expect([h.offline, h.offlineSince], [true, earlier]);
    expect(timers.pendingDelays, [Duration.zero]);
    answers = [true];
    timers.active.single.fire();
    await pumpEventQueue();
    expect(h.online, isTrue);
  });

  // R87: the banner's close button hides it for this outage only; the next outage shows it again.
  test('the banner dismissed: for this outage only, cleared when the server answers', () {
    final h = tracker();
    var notified = 0;
    h.addListener(() => notified++);
    h.dismissBanner(); // online: nothing to dismiss
    expect([h.bannerDismissed, notified], [false, 0]);

    h.markUnreachable();
    h.dismissBanner();
    h.dismissBanner(); // twice changes nothing
    expect([h.offline, h.bannerDismissed, notified], [true, true, 2]);
    expect(timers.pendingDelays, [probeFirstDelay]); // still probing: dismissing hides the banner, nothing else

    h.markReachable();
    expect(h.bannerDismissed, isFalse);
    h.markUnreachable();
    expect([h.offline, h.bannerDismissed], [true, false]);
  });

  test('after dispose nothing changes and nothing is scheduled', () {
    final h = tracker();
    h.dispose();
    h.markUnreachable();
    expect(h.online, isTrue);
    expect(timers.active, isEmpty);
  });
}
