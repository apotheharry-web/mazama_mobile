// sync/sync_queue.dart: one queue for everything the phone still has to send (specs/phone-sync PS-R4), each kind with
// today's rules - the cases of server_outbox_test.dart, catch_up_store_test.dart (CatchUpWork) and coa_uploader_test.dart,
// same inputs and outcomes, against the queue itself. Fake clock, fake timers, fake senders: no real time, no network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';

import '../fake_timers.dart';

void main() {
  late Directory dir;
  late FakeTimers timers;
  late ServerHealth health;
  late SyncTables tables;
  late DateTime clock;
  late bool demo;
  var demoFails = false;

  /// Every send, in order, by kind.
  late List<QueueItem> sent;

  /// Per send of a report or snapshot: the result to give (Done when empty).
  late List<SendResult Function(QueueItem)> script;

  /// The lab reports' sends: each waits for the test to finish it.
  late List<({String key, DateTime at, Completer<SendResult> done})> labSends;

  final queues = <SyncQueue>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mazama_sync_queue_test_');
    timers = FakeTimers();
    health = ServerHealth(probe: () async => false, startTimer: timers.start);
    tables = SyncTables(LocalStore.forDir(dir));
    clock = DateTime.utc(2026, 10, 23, 18);
    demo = false;
    demoFails = false;
    sent = [];
    script = [];
    labSends = [];
  });
  tearDown(() {
    for (final q in queues) {
      q.dispose();
    }
    queues.clear();
    health.dispose();
    LocalStore.debugCloseAll();
    dir.deleteSync(recursive: true);
  });

  Future<SendResult> scripted(QueueItem item) async {
    sent.add(item);
    return script.isEmpty ? const Done() : script.removeAt(0)(item);
  }

  /// [pacedLab]: lab reports wait for the test (the uploader's cases); otherwise they are scripted like the rest
  /// (the catch-up list's cases).
  SyncQueue queue({int cap = 1000, int labReportCap = 200, bool pacedLab = false, SyncTables? over}) {
    final q = SyncQueue(
      tables: over ?? tables,
      health: health,
      now: () => clock,
      startTimer: timers.start,
      cap: cap,
      labReportCap: labReportCap,
      isDemo: () {
        if (demoFails) throw StateError('demo flag unreadable');
        return demo;
      },
      senders: {
        QueueKind.saleLog: scripted,
        QueueKind.saleFailure: scripted,
        QueueKind.inventorySnapshot: scripted,
        QueueKind.salesSnapshot: scripted,
        QueueKind.labReport: pacedLab
            ? (item) {
                final done = Completer<SendResult>();
                labSends.add((key: item.key, at: clock, done: done));
                return done.future;
              }
            : scripted,
      },
    );
    queues.add(q);
    return q;
  }

  int n(QueueItem i) => (jsonDecode(i.body) as Map)['n'] as int;
  String log(SyncQueue q, int i) => q.add(QueueKind.saleLog, 'log-$i', {'n': i});
  String failure(SyncQueue q, int i) => q.add(QueueKind.saleFailure, 'fail-$i', {'n': i});
  List<int> waiting(String kind) => [for (final i in tables.items(kind, state: 'waiting')) n(i)];
  List<int> reportsWaiting() {
    final all = [...tables.items('sale_log'), ...tables.items('sale_failure')].where((i) => i.state != 'dead').toList()
      ..sort((a, b) => a.id!.compareTo(b.id!));
    return [for (final i in all) n(i)];
  }

  group('sale logs and failed-sale reports (server_outbox_test.dart)', () {
    test('a report queued while online is sent at once and leaves the queue', () async {
      final q = queue();
      log(q, 1);
      await pumpEventQueue();
      expect([for (final s in sent) n(s)], [1]);
      expect(q.waitingReports, 0);
    });

    test('queued while offline: kept, survives a restart, sent oldest first once the server answers', () async {
      health.markUnreachable();
      final q = queue();
      log(q, 1);
      failure(q, 2);
      log(q, 3);
      await pumpEventQueue();
      expect(sent, isEmpty);
      q.dispose();
      final again = queue(); // the app restarted
      expect(again.waitingReports, 3);
      health.markReachable();
      await again.flush();
      expect([for (final s in sent) (s.kind, n(s))], [('sale_log', 1), ('sale_failure', 2), ('sale_log', 3)]);
      expect(again.waitingReports, 0);
    });

    test('an unreachable send keeps the report and stops; the next online flush picks it up again', () async {
      final q = queue();
      health.markUnreachable();
      log(q, 1);
      log(q, 2);
      health.markReachable();
      script = [
        (i) {
          health.markUnreachable(); // as the link client does when a send finds no server
          return const Unreachable(error: 'cannot reach x');
        },
      ];
      await q.flush();
      expect(sent, hasLength(1)); // no hammering a server that isn't there
      expect(q.waitingReports, 2);
      expect(tables.items('sale_log').first.attempts, 1);
      expect((jsonDecode(tables.items('sale_log').first.body) as Map)['lastError'], 'cannot reach x');
      health.markReachable();
      await q.flush();
      expect([for (final s in sent) n(s)], [1, 1, 2]);
      expect(q.waitingReports, 0);
    });

    test('a refusal moves the report to the dead letters, kept with the reason, never sent again; the rest go on',
        () async {
      final q = queue();
      health.markUnreachable();
      failure(q, 1);
      log(q, 2);
      health.markReachable();
      script = [(i) => const DeadLetter('request must be a non-empty list of sale records.', status: 400)];
      await q.flush();
      expect(sent, hasLength(2));
      expect(q.waitingReports, 0);
      final dead = tables.items('sale_failure', state: 'dead').single;
      expect([n(dead), dead.reason, (jsonDecode(dead.body) as Map)['status']],
          [1, 'request must be a non-empty list of sale records.', 400]);
      await q.flush();
      expect(sent, hasLength(2));
    });

    test('a dead letter is never sent again', () async {
      final q = queue();
      script = [(i) => const DeadLetter('refused', status: 400)];
      log(q, 1);
      await pumpEventQueue();
      for (var i = 0; i < 3; i++) {
        await q.flush();
      }
      health.markUnreachable();
      health.markReachable();
      await q.flush();
      expect(sent, hasLength(1));
      expect(tables.count('sale_log', state: 'dead'), 1);
    });

    test("a 429 (or the server's own 5xx) keeps the report and waits a minute, then goes on", () async {
      final q = queue();
      health.markUnreachable();
      log(q, 1);
      log(q, 2);
      health.markReachable();
      script = [(i) => const RetryAfter(Duration(seconds: 61), error: 'Too many requests', status: 429)];
      await q.flush();
      expect(sent, hasLength(1));
      expect(q.waitingOutBusy, isTrue);
      expect(timers.pendingDelays, [const Duration(seconds: 61)]);
      await q.flush(); // a wake meanwhile sends nothing
      expect(sent, hasLength(1));
      timers.active.single.fire();
      await pumpEventQueue();
      expect(sent, hasLength(3));
      expect(q.waitingReports, 0);

      // the server's own 5xx: unreachable, but the tracker stays online, so nothing else would wake the queue
      script = [(i) => const Unreachable(error: 'The upload did not run.', status: 500)];
      log(q, 3);
      await pumpEventQueue();
      expect(q.waitingReports, 1);
      expect(q.waitingOutBusy, isTrue);
      expect(timers.pendingDelays, [const Duration(seconds: 61)]);
    });

    test('full: the oldest sale log makes room; a failed-sale report is never dropped', () async {
      health.markUnreachable();
      final q = queue(cap: 3);
      failure(q, 1);
      log(q, 2);
      log(q, 3);
      log(q, 4); // drops log 2
      expect(reportsWaiting(), [1, 3, 4]);
      expect(q.droppedSaleLogs, 1);
      failure(q, 5); // drops log 3
      failure(q, 6); // drops log 4
      failure(q, 7); // nothing left to drop: queued past the cap
      expect(reportsWaiting(), [1, 5, 6, 7]);
      expect(q.droppedSaleLogs, 3);
      log(q, 8); // a sale log that doesn't fit
      expect(q.waitingReports, 4);
      expect(q.droppedSaleLogs, 4);
      expect(queue(cap: 3).droppedSaleLogs, 4); // kept across restarts
    });

    test('a failure past the cap is queued and the oldest log is dropped', () {
      health.markUnreachable();
      final q = queue(cap: 2);
      log(q, 1);
      log(q, 2);
      failure(q, 3);
      expect(reportsWaiting(), [2, 3]);
      expect(q.droppedSaleLogs, 1);
      failure(q, 4);
      failure(q, 5);
      expect(reportsWaiting(), [3, 4, 5]);
      expect(q.droppedSaleLogs, 2);
    });

    test('the banner count is the reports waiting, not the snapshots or lab reports', () {
      health.markUnreachable();
      final q = queue();
      log(q, 1);
      failure(q, 2);
      q.add(QueueKind.inventorySnapshot, '231', {'n': 3});
      q.add(QueueKind.labReport, 'HB-1', {'n': 4});
      expect(q.waitingReports, 2);
    });
  });

  group('a local database that fails', () {
    test('the banner count never throws: it is the last good count', () {
      health.markUnreachable();
      final flaky = _FlakyTables(tables.store);
      final q = queue(over: flaky);
      log(q, 1);
      failure(q, 2);
      expect(q.waitingReports, 2);
      flaky.fail = true;
      expect(q.waitingReports, 2);
      flaky.fail = false;
      expect(q.waitingReports, 2);
    });

    test('a report whose write fails is kept in memory, counted, and written at the next flush', () async {
      health.markUnreachable();
      final flaky = _FlakyTables(tables.store);
      final q = queue(over: flaky);
      flaky.fail = true;
      expect(log(q, 1), 'log-1'); // does not throw
      expect(q.waitingReports, 1);
      expect(reportsWaiting(), isEmpty);
      flaky.fail = false;
      health.markReachable();
      await q.flush();
      expect([for (final i in sent) n(i)], [1]); // written, then sent
      expect(q.waitingReports, 0);
    });
  });

  group('snapshots and kept lab reports (catch_up_store_test.dart)', () {
    String lot(SyncQueue q, String guid, int i) => q.add(QueueKind.labReport, guid, {'n': i, 'lotGuid': guid});

    test('lots kept while offline survive a restart and are sent then; the same lot again replaces it and goes last',
        () async {
      health.markUnreachable();
      final q = queue();
      lot(q, 'HB-aaaa0001', 101);
      lot(q, 'HB-bbbb0002', 102);
      lot(q, 'hb-AAAA0001', 103);
      await q.flush();
      expect(sent, isEmpty);
      final again = queue();
      expect(waiting('lab_report'), [102, 103]);
      health.markReachable();
      await again.flush();
      expect([for (final s in sent) n(s)], [102, 103]);
      expect(tables.items('lab_report'), isEmpty);
    });

    test('an unreachable server stops the run and keeps the lot; a refusal drops it', () async {
      final q = queue();
      lot(q, 'HB-1', 1);
      lot(q, 'HB-2', 2);
      lot(q, 'HB-3', 3);
      script = [(i) => const Skipped(), (i) => const Unreachable()];
      await q.flush();
      expect([for (final s in sent) n(s)], [1, 2]);
      expect(waiting('lab_report'), [2, 3]);
    });

    test('no usable session: the lots wait', () async {
      final q = queue();
      lot(q, 'HB-1', 1);
      script = [(i) => const Busy()];
      await q.flush();
      expect(waiting('lab_report'), [1]);
    });

    test('a kept lot sent is remembered as sent', () async {
      final q = queue();
      lot(q, 'HB-1', 1);
      await q.flush();
      expect(tables.wasSent('lab_report', 'hb-1', clock, const Duration(hours: 24)), isTrue);
    });

    test('at most labReportCap lots wait, the oldest dropped first', () {
      health.markUnreachable();
      final q = queue(labReportCap: 2);
      for (var i = 1; i <= 3; i++) {
        lot(q, 'HB-$i', i);
      }
      expect(waiting('lab_report'), [2, 3]);
    });

    test('snapshots: only the newest per center waits, and it is sent once', () async {
      health.markUnreachable();
      final q = queue();
      q.add(QueueKind.inventorySnapshot, '231', {'n': 3});
      clock = clock.add(const Duration(minutes: 5));
      q.add(QueueKind.inventorySnapshot, '231', {'n': 2}); // a newer read replaces it
      q.add(QueueKind.inventorySnapshot, '183', {'n': 1});
      expect(waiting('inventory_snapshot').toSet(), {2, 1});
      health.markReachable();
      await q.flush();
      expect({for (final s in sent) n(s)}, {2, 1});
      expect(tables.items('inventory_snapshot'), isEmpty);
      await q.flush();
      expect(sent, hasLength(2));
    });

    test('a newer snapshot that reached the server makes the kept one moot', () async {
      health.markUnreachable();
      final q = queue();
      q.add(QueueKind.inventorySnapshot, '231', {'n': 1});
      q.remove(QueueKind.inventorySnapshot, '231');
      health.markReachable();
      await q.flush();
      expect(sent, isEmpty);
    });

    test('a snapshot replaced while it was being sent: the newer one stays to be sent', () async {
      final q = queue();
      health.markUnreachable();
      q.add(QueueKind.inventorySnapshot, '231', {'n': 2});
      health.markReachable();
      script = [
        (i) {
          q.add(QueueKind.inventorySnapshot, '231', {'n': 3}); // the cart read the state again meanwhile
          return const Done();
        }
      ];
      await q.flush();
      expect([for (final s in sent) n(s)], [2]);
      expect(waiting('inventory_snapshot'), [3]);
    });

    test("an unreachable upload keeps the snapshot; the server's refusal drops it", () async {
      final q = queue();
      health.markUnreachable();
      q.add(QueueKind.inventorySnapshot, '231', {'n': 1});
      q.add(QueueKind.inventorySnapshot, '183', {'n': 2});
      health.markReachable();
      script = [(i) => const Unreachable()];
      await q.flush();
      expect(sent, hasLength(1));
      expect(tables.items('inventory_snapshot'), hasLength(2));
      script = [(i) => const Skipped(), (i) => const Skipped()];
      await q.flush();
      expect(tables.items('inventory_snapshot'), isEmpty);
    });

    test("a center's inventory and sales snapshots wait side by side, each replaced only by its own kind", () async {
      health.markUnreachable();
      final q = queue();
      q.add(QueueKind.inventorySnapshot, '231', {'n': 1});
      q.add(QueueKind.salesSnapshot, '231', {'n': 9});
      q.add(QueueKind.salesSnapshot, '231', {'n': 8});
      expect([waiting('inventory_snapshot'), waiting('sales_snapshot')], [
        [1],
        [8]
      ]);
      q.remove(QueueKind.salesSnapshot, '231');
      expect([waiting('inventory_snapshot'), waiting('sales_snapshot')], [[1], <int>[]]);
    });

    test('the snapshots go before the lab reports', () async {
      health.markUnreachable();
      final q = queue();
      lot(q, 'HB-1', 1);
      q.add(QueueKind.salesSnapshot, '231', {'n': 2});
      q.add(QueueKind.inventorySnapshot, '231', {'n': 3});
      health.markReachable();
      await q.flush();
      expect([for (final s in sent) s.kind], ['inventory_snapshot', 'sales_snapshot', 'lab_report']);
    });
  });

  group('lab reports the server is missing, paced (coa_uploader_test.dart)', () {
    Map<String, Object?> body(String guid) => {'lotGuid': guid, 'packageId': 1, 'stateId': 231};
    List<({String key, Map<String, Object?> body})> lots(List<String> guids) =>
        [for (final g in guids) (key: g, body: body(g))];

    Future<void> fire() async {
      timers.fireAll();
      await pumpEventQueue();
    }

    Future<void> finish(String guid, SendResult result) async {
      labSends.lastWhere((s) => s.key == guid.toLowerCase()).done.complete(result);
      await pumpEventQueue();
    }

    bool wasSent(String guid) => tables.wasSent('lab_report', guid.toLowerCase(), clock, const Duration(hours: 24));

    test('a start that throws does not stall the pacing: the waiting lots are let go and a later offer starts', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1']));
      demoFails = true;
      await fire(); // must not throw out of the timer
      expect(q.labReportsIdle, isTrue);
      demoFails = false;
      q.offerLabReports(lots(['HB-2']));
      await fire();
      expect([for (final s in labSends) s.key], ['hb-2']);
    });

    test('no lab report starts within 3 s of the last and never more than 2 at once', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1', 'HB-2', 'HB-3', 'HB-4']));
      expect(labSends, isEmpty); // never inside the call: the first start is on a timer
      expect(timers.pendingDelays, [Duration.zero]);
      await fire();
      expect([for (final s in labSends) s.key], ['hb-1']);
      expect(timers.pendingDelays, [const Duration(seconds: 3)]);
      clock = clock.add(const Duration(seconds: 1));
      await fire(); // a timer fired early still starts only one
      expect([for (final s in labSends) s.key], ['hb-1', 'hb-2']);
      expect(q.labReportsInFlight, 2);
      expect(timers.pendingDelays, isEmpty);
      clock = clock.add(const Duration(seconds: 1));
      await finish('HB-1', const Done('numbers'));
      expect(q.labReportsInFlight, 1);
      expect(timers.pendingDelays, [const Duration(seconds: 2)]); // 3 s after HB-2 started
      clock = clock.add(const Duration(seconds: 2));
      await fire();
      expect([for (final s in labSends) s.key], ['hb-1', 'hb-2', 'hb-3']);
    });

    test('no cap per load: every lot is sent, paced', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots([for (var i = 0; i < 25; i++) 'HB-$i']));
      var most = 0;
      for (var round = 0; round < 100 && !q.labReportsIdle; round++) {
        await fire();
        if (q.labReportsInFlight > most) most = q.labReportsInFlight;
        clock = clock.add(const Duration(seconds: 3));
        for (final s in [...labSends]) {
          if (!s.done.isCompleted) await finish(s.key, const Done());
        }
      }
      expect(labSends.map((s) => s.key).toSet(), hasLength(25));
      expect(most, lessThanOrEqualTo(2));
      for (var i = 1; i < labSends.length; i++) {
        expect(labSends[i].at.difference(labSends[i - 1].at), greaterThanOrEqualTo(const Duration(seconds: 3)));
      }
    });

    test('dedupe across two loads; each caller is told', () async {
      final q = queue(pacedLab: true);
      final first = <String>[], second = <String>[];
      q.offerLabReports(lots(['HB-1', 'HB-2']), onDone: (item, v) => first.add(item.key));
      await fire();
      q.offerLabReports(lots(['hb-1', 'HB-2', 'HB-3']), onDone: (item, v) => second.add(item.key));
      expect(q.labReportsWaiting, 2);
      expect(timers.active, hasLength(1));
      await finish('HB-1', const Done('n'));
      for (var i = 0; i < 5 && !q.labReportsIdle; i++) {
        await fire();
        for (final s in [...labSends]) {
          if (!s.done.isCompleted) await finish(s.key, const Done('n'));
        }
      }
      expect([for (final s in labSends) s.key], ['hb-1', 'hb-2', 'hb-3']);
      expect(first, ['hb-1', 'hb-2']);
      expect(second, ['hb-1', 'hb-2', 'hb-3']);
    });

    test('sent (with numbers or not) is remembered for 24 hours', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-a', 'HB-b']));
      await fire();
      await finish('HB-a', const Done('numbers'));
      await fire();
      await finish('HB-b', const Done()); // 202 queued, 4xx refused: sent, nothing to tell
      expect([wasSent('HB-a'), wasSent('hb-B')], [true, true]);
      q.offerLabReports(lots(['HB-a', 'HB-b']));
      expect(q.labReportsWaiting, 0);
      clock = clock.add(const Duration(hours: 24, seconds: 1));
      q.offerLabReports(lots(['HB-b']));
      expect(q.labReportsWaiting, 1);
    });

    test('unreachable: the lot being sent is kept (while there is room); the waiting ones are let go, unmarked',
        () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1', 'HB-2', 'HB-3']));
      await fire();
      await finish('HB-1', const Unreachable());
      expect([for (final i in tables.items('lab_report')) i.key], ['hb-1']);
      expect((jsonDecode(tables.items('lab_report').single.body) as Map)['lotGuid'], 'HB-1');
      expect(q.labReportsIdle, isTrue);
      expect(timers.active, isEmpty);
      q.offerLabReports(lots(['HB-1', 'HB-2']));
      expect(q.labReportsWaiting, 1); // HB-1 waits on the kept list
      expect([wasSent('HB-1'), wasSent('HB-2'), wasSent('HB-3')], [false, false, false]);
    });

    test("a full kept list takes no lot from the paced uploads, so a cart add's lot is never pushed out", () async {
      final q = queue(pacedLab: true, labReportCap: 2);
      q.add(QueueKind.labReport, 'HB-cart1', body('HB-cart1'));
      q.add(QueueKind.labReport, 'HB-cart2', body('HB-cart2'));
      q.offerLabReports(lots(['HB-1']));
      await fire();
      await finish('HB-1', const Unreachable());
      expect([for (final i in tables.items('lab_report')) i.key], ['hb-cart1', 'hb-cart2']);
    });

    test('offline: nothing starts, the waiting lots are let go, unmarked and unkept', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1', 'HB-2']));
      health.markUnreachable();
      await fire();
      expect(labSends, isEmpty);
      expect(tables.items('lab_report'), isEmpty);
      expect(q.labReportsIdle, isTrue);
      health.markReachable();
      q.offerLabReports(lots(['HB-1', 'HB-2']));
      expect(q.labReportsWaiting, 2);
    });

    test('pending: a lot waiting or being sent, in any case; not once it is done', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1', 'HB-2']));
      expect([q.labReportPending('hb-1'), q.labReportPending('HB-2'), q.labReportPending('HB-3')], [true, true, false]);
      await fire();
      expect(q.labReportPending('HB-1'), isTrue);
      await finish('HB-1', const Done('n'));
      expect(q.labReportPending('HB-1'), isFalse);
    });

    test('a 429 on a lab report stops the run and marks none sent', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1', 'HB-2', 'HB-3']));
      await fire();
      await finish('HB-1', const Busy());
      expect(q.labReportsWaiting, 0);
      expect(timers.active, isEmpty);
      await fire();
      expect([for (final s in labSends) s.key], ['hb-1']);
      expect(wasSent('HB-1'), isFalse);
      expect(tables.items('lab_report'), isEmpty);
      q.offerLabReports(lots(['HB-1', 'HB-2', 'HB-3']));
      expect(q.labReportsWaiting, 3);
    });

    test('skipped (no PDF, or the state read failed): not marked, not kept, the queue goes on', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1', 'HB-2']));
      await fire();
      await finish('HB-1', const Skipped());
      await fire();
      expect([for (final s in labSends) s.key], ['hb-1', 'hb-2']);
      expect(wasSent('HB-1'), isFalse);
      expect(tables.items('lab_report'), isEmpty);
    });

    test('a lot sent meanwhile (a cart add) is not started', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1', 'HB-2']));
      q.markSent(QueueKind.labReport, 'HB-1');
      await fire();
      expect([for (final s in labSends) s.key], ['hb-2']);
    });

    test('a lot resolved later is passed to the callback with its value', () async {
      final q = queue(pacedLab: true);
      final got = <(String, Object?)>[];
      q.offerLabReports(lots(['HB-1']), onDone: (item, v) => got.add(((jsonDecode(item.body) as Map)['lotGuid'] as String, v)));
      await fire();
      expect(got, isEmpty);
      await finish('HB-1', const Done('Blue Meanie'));
      expect(got, [('HB-1', 'Blue Meanie')]);
    });

    test('demo mode never uploads', () async {
      demo = true;
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1']));
      expect(q.labReportsWaiting, 0);
      expect(timers.active, isEmpty);
    });

    test("a demo flag that can't be read counts as the demo: no upload or lab report is queued or started", () async {
      demoFails = true;
      final q = queue(pacedLab: true);
      q.add(QueueKind.inventorySnapshot, '231', {'records': []});
      q.add(QueueKind.labReport, 'HB-9', {'lotGuid': 'HB-9'});
      q.offerLabReports(lots(['HB-1']));
      expect(tables.items('inventory_snapshot'), isEmpty);
      expect(tables.items('lab_report'), isEmpty);
      expect(q.labReportsWaiting, 0);
      demoFails = false;
    });

    test('dispose: nothing more starts', () async {
      final q = queue(pacedLab: true);
      q.offerLabReports(lots(['HB-1', 'HB-2']));
      q.dispose();
      await fire();
      expect(labSends, isEmpty);
      q.offerLabReports(lots(['HB-3']));
      expect(q.labReportsWaiting, 0);
    });
  });

  test('the order of a flush: the reports, then the snapshots, then the kept lab reports', () async {
    health.markUnreachable();
    final q = queue();
    q.add(QueueKind.labReport, 'HB-1', {'n': 1});
    q.add(QueueKind.inventorySnapshot, '231', {'n': 2});
    failure(q, 3);
    log(q, 4);
    health.markReachable();
    await q.flush();
    expect([for (final s in sent) n(s)], [3, 4, 2, 1]);
  });

  test('a sender that throws: a report becomes a dead letter, anything else is dropped; the queue never throws',
      () async {
    final q = SyncQueue(
      tables: tables,
      health: health,
      now: () => clock,
      startTimer: timers.start,
      senders: {
        QueueKind.saleLog: (i) async => throw StateError('bug'),
        QueueKind.inventorySnapshot: (i) async => throw StateError('bug'),
      },
    );
    queues.add(q);
    health.markUnreachable();
    log(q, 1);
    q.add(QueueKind.inventorySnapshot, '231', {'n': 2});
    health.markReachable();
    await q.flush();
    expect(tables.items('sale_log', state: 'dead').single.reason, contains('bug'));
    expect(tables.items('inventory_snapshot'), isEmpty);
  });

  test('an item left being sent by a stopped app waits again', () async {
    final q = queue();
    health.markUnreachable();
    log(q, 1);
    tables.markSending(tables.items('sale_log').single.id!);
    q.dispose();
    final again = queue();
    expect(again.waitingReports, 1);
    health.markReachable();
    await again.flush();
    expect([for (final s in sent) n(s)], [1]);
  });
}

/// Tables whose reads and writes of the queue can be made to fail.
class _FlakyTables extends SyncTables {
  _FlakyTables(super.store);

  bool fail = false;

  @override
  int count(String kind, {String state = queueWaiting}) {
    if (fail) throw StateError('database is busy');
    return super.count(kind, state: state);
  }

  @override
  int enqueue(QueueItem item) {
    if (fail) throw StateError('database is busy');
    return super.enqueue(item);
  }
}
