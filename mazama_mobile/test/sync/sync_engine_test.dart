// sync/sync_engine.dart: the one engine per app (specs/phone-sync PS-R1) - built on the local store, it moves today's
// queues in (PS-R9), sends what waits when woken, when the server answers again and in the foreground, and gives the
// banner its count. Fake clock, timers and senders.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_outbox.dart';
import 'package:mazama_mobile/sync/sync_engine.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';

import '../fake_timers.dart';

void main() {
  late Directory dir;
  late FakeTimers timers;
  late ServerHealth health;
  late List<String> sent;
  late int probes;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mazama_sync_engine_test_');
    timers = FakeTimers();
    probes = 0;
    health = ServerHealth(
        probe: () async {
          probes++;
          return false;
        },
        startTimer: timers.start);
    sent = [];
  });
  tearDown(() {
    health.dispose();
    LocalStore.debugCloseAll();
    dir.deleteSync(recursive: true);
  });

  Future<SendResult> record(QueueItem item) async {
    sent.add('${item.kind}:${item.key}');
    return const Done();
  }

  SyncEngine engine() {
    final e = SyncEngine(
      store: LocalStore.forDir(dir),
      health: health,
      now: () => DateTime.utc(2026, 10, 30, 12),
      startTimer: timers.start,
      senders: {for (final k in QueueKind.values) k: record},
    );
    addTearDown(e.dispose);
    return e;
  }

  test('wake sends sale logs before lab reports', () async {
    health.markUnreachable();
    final e = engine();
    e.queue.add(QueueKind.labReport, 'HB-1', {'lotGuid': 'HB-1'});
    e.queue.add(QueueKind.inventorySnapshot, '231', {});
    e.queue.add(QueueKind.saleLog, 'c-1', {});
    e.queue.add(QueueKind.saleFailure, 'c-2', {});
    health.markReachable(); // (the engine wakes on this too; the explicit wake below joins that run)
    e.wake();
    await pumpEventQueue();
    expect(sent, ['sale_log:c-1', 'sale_failure:c-2', 'inventory_snapshot:231', 'lab_report:hb-1']);
  });

  test('going online wakes the engine', () async {
    final e = engine();
    health.markUnreachable();
    e.queue.add(QueueKind.saleLog, 'c-1', {});
    e.queue.add(QueueKind.salesSnapshot, '231', {});
    e.wake(); // offline: nothing
    await pumpEventQueue();
    expect(sent, isEmpty);
    health.markReachable();
    await pumpEventQueue();
    expect(sent, ['sale_log:c-1', 'sales_snapshot:231']);
  });

  test('the foreground: offline, a probe at once; online, what waits is sent', () async {
    final e = engine();
    health.markUnreachable();
    e.queue.add(QueueKind.inventorySnapshot, '231', {});
    e.onForeground();
    await pumpEventQueue();
    expect(probes, 1);
    expect(sent, isEmpty);
    health.markReachable();
    await pumpEventQueue();
    sent.clear();
    e.queue.add(QueueKind.inventorySnapshot, '183', {});
    e.onForeground();
    await pumpEventQueue();
    expect(sent, ['inventory_snapshot:183']);
  });

  test('the banner count is the waiting reports', () {
    health.markUnreachable();
    final e = engine();
    e.queue.add(QueueKind.saleLog, 'c-1', {});
    e.queue.add(QueueKind.saleFailure, 'c-2', {});
    e.queue.add(QueueKind.labReport, 'HB-1', {});
    e.queue.add(QueueKind.inventorySnapshot, '231', {});
    expect(e.queue.waitingReports, 2);
  });

  test("the engine moves today's queues in when it starts", () async {
    final store = LocalStore.forDir(dir);
    store.write(
        'server_outbox.json',
        jsonEncode({
          'pending': [
            OutboxEntry(
                    clientId: 'c-9',
                    kind: OutboxKind.saleLog,
                    stateId: 231,
                    workerEmail: 'w',
                    deviceId: 'd',
                    request: const [{'n': 1}],
                    createdAt: DateTime.utc(2026, 10, 29))
                .toJson(),
          ],
        }));
    health.markUnreachable();
    final e = engine();
    expect(e.queue.waitingReports, 1);
    expect(store.read('server_outbox.json'), isNull);
    health.markReachable();
    await pumpEventQueue();
    expect(sent, ['sale_log:c-9']);
  });

  test('dispose: nothing more is sent', () async {
    final e = engine();
    health.markUnreachable();
    e.queue.add(QueueKind.saleLog, 'c-1', {});
    e.dispose();
    health.markReachable();
    await pumpEventQueue();
    expect(sent, isEmpty);
  });
}
