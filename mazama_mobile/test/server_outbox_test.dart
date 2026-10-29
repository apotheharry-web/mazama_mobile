// server_outbox.dart: sale-attribution logs and failed-sale reports kept on the phone until Mazama's server takes them
// (README R56) - persisted across restarts, sent oldest first one at a time, stopped by an unreachable server,
// refused ones kept as dead letters, a cap that never drops a failed-sale report, and a flush when the server answers.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/sale_failure_client.dart';
import 'package:mazama_mobile/sale_log_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_outbox.dart';

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
    _dir.deleteSync(recursive: true);
  });

  Future<void> scripted(OutboxEntry e) async {
    sent.add(e);
    final next = script.isEmpty ? null : script.removeAt(0);
    if (next != null) throw next(e);
  }

  ServerOutbox outbox({int cap = outboxCap, OutboxSender? send, Directory? dir}) => ServerOutbox(
      health: health,
      store: OutboxStore(dataDir: () => dir ?? _dir),
      send: send ?? scripted,
      startTimer: timers.start,
      now: () => DateTime.utc(2026, 10, 23, 18),
      cap: cap,
      random: Random(7));

  Future<String> log(ServerOutbox o, [int i = 0]) =>
      o.addSaleLog(231, workerEmail: 'w@example.com', deviceId: 'D-1', request: [{'n': i}], response: [{'saleNumber': 'S-$i'}]);
  Future<String> failure(ServerOutbox o, [int i = 0]) =>
      o.addSaleFailure(231, workerEmail: 'w@example.com', deviceId: 'D-1', reason: 'expired $i', request: [{'n': i}]);

  test('uuidV4: the version and variant bits, 36 characters, a new one each time', () {
    final ids = {for (var i = 0; i < 50; i++) uuidV4()};
    expect(ids, hasLength(50));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    }
  });

  test('a report queued while online is sent at once and leaves the queue', () async {
    final o = outbox();
    final id = await log(o);
    await pumpEventQueue();
    expect(sent.single.clientId, id);
    expect(o.pendingCount, 0);
  });

  test('queued while offline: kept on disk, survives a restart, sent oldest first once the server answers', () async {
    health.markUnreachable();
    final o = outbox();
    final a = await log(o, 1);
    final b = await failure(o, 2);
    final c = await log(o, 3);
    await pumpEventQueue();
    expect(sent, isEmpty);
    o.dispose();

    final again = outbox(); // the app restarted
    expect([for (final e in again.pending) e.clientId], [a, b, c]);
    expect(again.pending[1].kind, OutboxKind.saleFailure);
    expect(again.pending[1].reason, 'expired 2');
    expect(again.pending[0].response, [
      {'saleNumber': 'S-1'}
    ]);
    health.markReachable();
    await again.flush();
    expect([for (final e in sent) e.clientId], [a, b, c]);
    expect(again.pendingCount, 0);
    expect(OutboxStore(dataDir: () => _dir).load().pending, isEmpty);
  });

  test('an unreachable send keeps the report and stops; the next online flush picks it up again', () async {
    final o = outbox();
    health.markUnreachable();
    await log(o, 1);
    await log(o, 2);
    health.markReachable();
    script = [
      (e) {
        health.markUnreachable(); // as the link client does when a send finds no server
        return SaleLogError('cannot reach x: SocketException', unreachable: true);
      },
    ];
    await o.flush();
    expect(sent, hasLength(1)); // stopped after the first: no hammering a server that isn't there
    expect(o.pendingCount, 2);
    expect(o.pending.first.attempts, 1);
    health.markReachable();
    await o.flush();
    expect(sent, hasLength(3));
    expect(sent[0].clientId, sent[1].clientId); // the same report again, with the same clientId
    expect(o.pendingCount, 0);
  });

  test('a 4xx moves the report to the dead letters, kept with the reason, never sent again; the rest go on', () async {
    final o = outbox();
    health.markUnreachable();
    final bad = await failure(o, 1);
    await log(o, 2);
    health.markReachable();
    script = [(e) => SaleFailureError('request must be a non-empty list of sale records.', status: 400)];
    await o.flush();
    expect(sent, hasLength(2));
    expect(o.pendingCount, 0);
    expect(o.dead.single.clientId, bad);
    expect(o.dead.single.status, 400);
    expect(o.dead.single.lastError, 'request must be a non-empty list of sale records.');
    await o.flush();
    expect(sent, hasLength(2));
    expect(outbox().dead.single.clientId, bad); // kept on disk too
  });

  test("a 429 (or the server's own 5xx) keeps the report and waits a minute, then goes on", () async {
    final o = outbox();
    health.markUnreachable();
    await log(o, 1);
    await log(o, 2);
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
    expect(o.pendingCount, 0);

    script = [(e) => SaleLogError('The upload did not run.', status: 500, unreachable: true)];
    await log(o, 3);
    await pumpEventQueue();
    expect(o.pendingCount, 1);
    expect(o.waitingOutBusy, isTrue);
  });

  test('full: the oldest sale log makes room; a failed-sale report is never dropped', () async {
    health.markUnreachable();
    final o = outbox(cap: 3);
    await failure(o, 1);
    await log(o, 2);
    await log(o, 3);
    await log(o, 4); // drops log 2
    expect([for (final e in o.pending) e.request.single['n']], [1, 3, 4]);
    expect(o.droppedLogs, 1);
    await failure(o, 5); // drops log 3
    await failure(o, 6); // drops log 4
    await failure(o, 7); // nothing left to drop: queued past the cap
    expect([for (final e in o.pending) e.request.single['n']], [1, 5, 6, 7]);
    expect(o.droppedLogs, 3);
    await log(o, 8); // a sale log that doesn't fit
    expect(o.pendingCount, 4);
    expect(o.droppedLogs, 4);
    expect(outbox(cap: 3).droppedLogs, 4); // kept on disk
  });

  test('the real sender posts each kind to its own route with the clientId', () async {
    final o = outbox(send: sendOutboxEntry);
    health.markUnreachable();
    await log(o, 1);
    await failure(o, 2);
    final bodies = <String, Map<String, Object?>>{};
    final client = http_testing.MockClient((req) async {
      bodies[req.url.path] = jsonDecode(req.body) as Map<String, Object?>;
      return http.Response('{"ok": true}', 201);
    });
    for (final e in o.pending) {
      await switch (e.kind) {
        OutboxKind.saleLog => postSaleLog(e.stateId,
            workerEmail: e.workerEmail, deviceId: e.deviceId, request: e.request, response: e.response, clientId: e.clientId, client: client),
        OutboxKind.saleFailure => postSaleFailure(e.stateId,
            workerEmail: e.workerEmail, deviceId: e.deviceId, reason: e.reason!, request: e.request, clientId: e.clientId, client: client),
      };
    }
    expect(bodies['/p/sale-log/231']!['clientId'], o.pending[0].clientId);
    expect(bodies['/p/sale-failure/231']!['clientId'], o.pending[1].clientId);
    expect(bodies['/p/sale-failure/231']!['reason'], 'expired 2');
  });

  // Each body as an older build's file in a fresh folder, imported when the store first opens it (plan P-D5).
  Directory olderBuild(String folder, String body) {
    final dir = Directory('${_dir.path}/$folder')..createSync();
    File('${dir.path}/server_outbox.json').writeAsStringSync(body);
    return dir;
  }

  test('an unreadable file counts as an empty outbox; an unreadable entry is skipped', () {
    expect(outbox(dir: olderBuild('a', '{not json')).pendingCount, 0);
    final damaged = olderBuild('b', jsonEncode({
      'pending': [
        {'kind': 'sale_log', 'clientId': 'x'}, // damaged
        OutboxEntry(
                clientId: 'c-1',
                kind: OutboxKind.saleLog,
                stateId: 231,
                workerEmail: 'w',
                deviceId: 'd',
                request: _records,
                createdAt: DateTime.utc(2026, 10, 23))
            .toJson(),
      ],
    }));
    expect([for (final e in outbox(dir: damaged).pending) e.clientId], ['c-1']);
  });

  test('kept in the database, not in a file', () async {
    health.markUnreachable();
    await log(outbox());
    expect(File('${_dir.path}/server_outbox.json').existsSync(), isFalse);
    expect(File('${_dir.path}/server_outbox.json.tmp').existsSync(), isFalse);
    expect(LocalStore.forDir(_dir).read('server_outbox.json'), isNotNull);
  });

  test('records the sale exactly as given', () async {
    health.markUnreachable();
    final o = outbox();
    await o.addSaleLog(225, workerEmail: 'a@b.com', deviceId: 'D-9', request: _records, response: null);
    final e = outbox().pending.single;
    expect([e.stateId, e.workerEmail, e.deviceId, e.request, e.response, e.createdAt],
        [225, 'a@b.com', 'D-9', _records, null, DateTime.utc(2026, 10, 23, 18)]);
  });
}
