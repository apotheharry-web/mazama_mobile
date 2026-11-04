// server_outbox.dart: sale-attribution logs and failed-sale reports kept on the phone, on the sync engine's queue, until
// Mazama's server takes them - persisted across restarts, sent oldest first one at a time, stopped by an unreachable
// server, refused ones kept as dead letters, a cap that never drops a failed-sale report, and a flush when the server
// answers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/sale_failure_client.dart';
import 'package:mazama_mobile/sale_log_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_outbox.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';

import 'fake_timers.dart';

late Directory _dir;

const _records = [
  {'productGuid': 'PKPR-ab12c', 'numberSold': 1},
];

void main() {
  late FakeTimers timers;
  late ServerHealth health;
  late List<OutboxEntry> sent;
  late List<Object Function(OutboxEntry)?> script; // per send: null succeeds, else returns the error to throw

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('mazama_outbox_test_');
    timers = FakeTimers();
    health = ServerHealth(probe: () async => false, startTimer: timers.start);
    sent = [];
    script = [];
  });
  tearDown(() {
    health.dispose();
    LocalStore.debugCloseAll();
    _dir.deleteSync(recursive: true);
  });

  Future<void> scripted(OutboxEntry e) async {
    sent.add(e);
    final next = script.isEmpty ? null : script.removeAt(0);
    if (next != null) throw next(e);
  }

  // The queue as the app's engine builds it, over the folder's database: a second one over the same folder is the app
  // restarted.
  SyncQueue outbox({int cap = outboxCap, OutboxSender? send}) {
    final q = SyncQueue(
        tables: SyncTables(LocalStore.forDir(_dir)),
        health: health,
        senders: {
          QueueKind.saleLog: outboxQueueSender(send ?? scripted),
          QueueKind.saleFailure: outboxQueueSender(send ?? scripted),
        },
        startTimer: timers.start,
        now: () => DateTime.utc(2026, 10, 23, 18),
        cap: cap);
    addTearDown(q.dispose);
    return q;
  }

  String log(SyncQueue o, [int i = 0]) =>
      o.addSaleLog(231, workerEmail: 'w@example.com', deviceId: 'D-1', request: [{'n': i}], response: [{'saleNumber': 'S-$i'}]);
  String failure(SyncQueue o, [int i = 0]) =>
      o.addSaleFailure(231, workerEmail: 'w@example.com', deviceId: 'D-1', reason: 'expired $i', request: [{'n': i}]);
  List<OutboxEntry> pending(SyncQueue o) => o.saleReports(dead: false);

  test('uuidV4: the version and variant bits, 36 characters, a new one each time', () {
    final ids = {for (var i = 0; i < 50; i++) uuidV4()};
    expect(ids, hasLength(50));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    }
  });

  test('a report queued while online is sent at once and leaves the queue', () async {
    final o = outbox();
    final id = log(o);
    await pumpEventQueue();
    expect(sent.single.clientId, id);
    expect(o.waitingReports, 0);
  });

  test('queued while offline: kept in the database, survives a restart, sent oldest first once the server answers',
      () async {
    health.markUnreachable();
    final o = outbox();
    final a = log(o, 1);
    final b = failure(o, 2);
    final c = log(o, 3);
    await pumpEventQueue();
    expect(sent, isEmpty);
    o.dispose();

    final again = outbox(); // the app restarted
    expect([for (final e in pending(again)) e.clientId], [a, b, c]);
    expect(pending(again)[1].kind, OutboxKind.saleFailure);
    expect(pending(again)[1].reason, 'expired 2');
    expect(pending(again)[0].response, [
      {'saleNumber': 'S-1'}
    ]);
    health.markReachable();
    await again.flush();
    expect([for (final e in sent) e.clientId], [a, b, c]);
    expect(again.waitingReports, 0);
    expect(SyncTables(LocalStore.forDir(_dir)).items('sale_log'), isEmpty);
    expect(SyncTables(LocalStore.forDir(_dir)).items('sale_failure'), isEmpty);
  });

  test('an unreachable send keeps the report and stops; the next online flush picks it up again', () async {
    final o = outbox();
    health.markUnreachable();
    log(o, 1);
    log(o, 2);
    health.markReachable();
    script = [
      (e) {
        health.markUnreachable(); // as the link client does when a send finds no server
        return SaleLogError('cannot reach x: SocketException', unreachable: true);
      },
    ];
    await o.flush();
    expect(sent, hasLength(1)); // stopped after the first: no hammering a server that isn't there
    expect(o.waitingReports, 2);
    expect(pending(o).first.attempts, 1);
    health.markReachable();
    await o.flush();
    expect(sent, hasLength(3));
    expect(sent[0].clientId, sent[1].clientId); // the same report again, with the same clientId
    expect(o.waitingReports, 0);
  });

  test('a 4xx moves the report to the dead letters, kept with the reason, never sent again; the rest go on', () async {
    final o = outbox();
    health.markUnreachable();
    final bad = failure(o, 1);
    log(o, 2);
    health.markReachable();
    script = [(e) => SaleFailureError('request must be a non-empty list of sale records.', status: 400)];
    await o.flush();
    expect(sent, hasLength(2));
    expect(o.waitingReports, 0);
    final dead = o.saleReports(dead: true);
    expect(dead.single.clientId, bad);
    expect(dead.single.status, 400);
    expect(dead.single.lastError, 'request must be a non-empty list of sale records.');
    await o.flush();
    expect(sent, hasLength(2));
    expect(outbox().saleReports(dead: true).single.clientId, bad); // kept in the database too
  });

  test("a 429 (or the server's own 5xx) keeps the report and waits a minute, then goes on", () async {
    final o = outbox();
    health.markUnreachable();
    log(o, 1);
    log(o, 2);
    health.markReachable();
    script = [(e) => SaleLogError('Too many requests', status: 429)];
    await o.flush();
    expect(sent, hasLength(1));
    expect(o.waitingOutBusy, isTrue);
    expect(timers.pendingDelays, [outboxRetryAfterBusy]);
    await o.flush(); // a wake meanwhile sends nothing
    expect(sent, hasLength(1));
    timers.active.single.fire();
    await pumpEventQueue();
    expect(sent, hasLength(3));
    expect(o.waitingReports, 0);

    script = [(e) => SaleLogError('The upload did not run.', status: 500, unreachable: true)];
    log(o, 3);
    await pumpEventQueue();
    expect(o.waitingReports, 1);
    expect(o.waitingOutBusy, isTrue);
  });

  test('full: the oldest sale log makes room; a failed-sale report is never dropped', () async {
    health.markUnreachable();
    final o = outbox(cap: 3);
    failure(o, 1);
    log(o, 2);
    log(o, 3);
    log(o, 4); // drops log 2
    expect([for (final e in pending(o)) e.request.single['n']], [1, 3, 4]);
    expect(o.droppedSaleLogs, 1);
    failure(o, 5); // drops log 3
    failure(o, 6); // drops log 4
    failure(o, 7); // nothing left to drop: queued past the cap
    expect([for (final e in pending(o)) e.request.single['n']], [1, 5, 6, 7]);
    expect(o.droppedSaleLogs, 3);
    log(o, 8); // a sale log that doesn't fit
    expect(o.waitingReports, 4);
    expect(o.droppedSaleLogs, 4);
    expect(outbox(cap: 3).droppedSaleLogs, 4); // kept in the database
  });

  test('the real sender posts each kind to its own route with the clientId', () async {
    final o = outbox(send: sendOutboxEntry);
    health.markUnreachable();
    log(o, 1);
    failure(o, 2);
    final bodies = <String, Map<String, Object?>>{};
    final client = http_testing.MockClient((req) async {
      bodies[req.url.path] = jsonDecode(req.body) as Map<String, Object?>;
      return http.Response('{"ok": true}', 201);
    });
    for (final e in pending(o)) {
      await switch (e.kind) {
        OutboxKind.saleLog => postSaleLog(e.stateId,
            workerEmail: e.workerEmail, deviceId: e.deviceId, request: e.request, response: e.response, clientId: e.clientId, client: client),
        OutboxKind.saleFailure => postSaleFailure(e.stateId,
            workerEmail: e.workerEmail, deviceId: e.deviceId, reason: e.reason!, request: e.request, clientId: e.clientId, client: client),
      };
    }
    expect(bodies['/p/sale-log/231']!['clientId'], pending(o)[0].clientId);
    expect(bodies['/p/sale-failure/231']!['clientId'], pending(o)[1].clientId);
    expect(bodies['/p/sale-failure/231']!['reason'], 'expired 2');
  });

  test('a queued report this build cannot read is left out of the list, and a dead letter when sent', () async {
    health.markUnreachable();
    final o = outbox();
    final tables = SyncTables(LocalStore.forDir(_dir));
    final at = DateTime.utc(2026, 10, 23);
    tables.enqueue(QueueItem(
        kind: 'sale_log', key: 'x', body: jsonEncode({'kind': 'sale_log', 'clientId': 'x'}), queuedAt: at, nextAt: at));
    tables.enqueue(QueueItem(
        kind: 'sale_log',
        key: 'c-1',
        body: jsonEncode(OutboxEntry(
                clientId: 'c-1',
                kind: OutboxKind.saleLog,
                stateId: 231,
                workerEmail: 'w',
                deviceId: 'd',
                request: _records,
                createdAt: at)
            .toJson()),
        queuedAt: at.add(const Duration(seconds: 1)),
        nextAt: at));
    expect([for (final e in pending(o)) e.clientId], ['c-1']);
    health.markReachable();
    await o.flush();
    expect([for (final e in sent) e.clientId], ['c-1']);
    expect([for (final i in tables.items('sale_log')) (i.key, i.state)], [('x', queueDead)]);
  });

  test('kept in the sync queue, not in a file or a document of its own (specs/phone-sync)', () async {
    health.markUnreachable();
    log(outbox());
    expect(File('${_dir.path}/server_outbox.json').existsSync(), isFalse);
    expect(LocalStore.forDir(_dir).read('server_outbox.json'), isNull);
    expect(SyncTables(LocalStore.forDir(_dir)).items('sale_log'), hasLength(1));
  });

  test('records the sale exactly as given', () async {
    health.markUnreachable();
    final o = outbox();
    o.addSaleLog(225, workerEmail: 'a@b.com', deviceId: 'D-9', request: _records, response: null);
    final e = pending(outbox()).single;
    expect([e.stateId, e.workerEmail, e.deviceId, e.request, e.response, e.createdAt],
        [225, 'a@b.com', 'D-9', _records, null, DateTime.utc(2026, 10, 23, 18)]);
  });
}
