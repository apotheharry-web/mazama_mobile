// sales_upload_client.dart: a center's sales records, as the phone read them from the state system, go to the ingest
// route's `sales` dataset (POST /p/ingest/sales/{state_id}, specs/ingest IN-R7, specs/center-web CW-R10, CW-D16).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/reply_store.dart';
import 'package:mazama_mobile/sales_upload_client.dart';
import 'package:mazama_mobile/server_error.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_link.dart';
import 'package:mazama_mobile/server_outbox.dart';

import 'fake_timers.dart';

(http.Client, List<http.Request>) _serve(int status, Object? body) {
  final seen = <http.Request>[];
  final client = http_testing.MockClient((req) async {
    seen.add(req);
    return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
  });
  return (client, seen);
}

const _records = [
  {'saleNumber': 'S-1', 'dateOfSale': '2026-10-20T10:00:00', 'numberSold': 1},
  {'saleNumber': 'S-2', 'dateOfSale': '2026-10-21T10:00:00', 'numberSold': 2},
];

void main() {
  test('posts to /p/ingest/sales/225 with the app key and {workerEmail, deviceId, records}', () async {
    final (client, seen) = _serve(200, {'rows': 2, 'skipped': 0});
    final out = await uploadSalesSnapshot(225, _records, workerEmail: 'w@example.com', deviceId: 'D-1', client: client);
    expect(out, {'rows': 2, 'skipped': 0});
    final req = seen.single;
    expect(req.method, 'POST');
    expect(req.url.path, '/p/ingest/sales/225');
    expect(req.url.path, ingestPath('sales', 225));
    for (final h in appApiKeyHeaders.entries) {
      expect(req.headers[h.key], h.value);
    }
    expect(req.headers['content-type'], startsWith('application/json'));
    expect(jsonDecode(req.body), {'workerEmail': 'w@example.com', 'deviceId': 'D-1', 'records': _records});
  });

  test("refuses one more than the route's record limit, before sending", () async {
    final (client, seen) = _serve(200, {'rows': 0, 'skipped': 0});
    await expectLater(
      uploadSalesSnapshot(225, List.filled(ingestMaxRecords + 1, <String, Object?>{}),
          workerEmail: 'w', deviceId: 'd', client: client),
      throwsA(isA<SalesUploadError>().having((e) => e.unreachable, 'unreachable', isFalse)),
    );
    expect(seen, isEmpty);
    // exactly the limit is sent
    await uploadSalesSnapshot(225, List.filled(ingestMaxRecords, <String, Object?>{}),
        workerEmail: 'w', deviceId: 'd', client: client);
    expect(seen, hasLength(1));
  });

  test('newestSalesForUpload: at most the limit, the newest by date; under it, the same list', () {
    expect(identical(newestSalesForUpload(_records), _records), isTrue);
    final many = [
      {'id': 'undated'},
      {'id': 'new', 'dateOfSale': '10/28/2026'},
      {'id': 'old', 'dateOfSale': '2026-01-01T08:00:00Z'},
      {'id': 'mid', 'dateOfSale': '2026-06-01'},
    ];
    expect([for (final r in newestSalesForUpload(many, limit: 2)) (r as Map)['id']], ['new', 'mid']);
    expect([for (final r in newestSalesForUpload(many, limit: 3)) (r as Map)['id']], ['new', 'old', 'mid']); // order kept
  });

  test('a 5xx or no connection is unreachable; a refusal is not', () async {
    Future<Object?> err(http.Client c) async {
      try {
        await uploadSalesSnapshot(225, const [], workerEmail: 'w', deviceId: 'd', client: c);
      } catch (e) {
        return e;
      }
      return null;
    }

    expect(isServerUnreachable(await err(http_testing.MockClient((_) async => throw const SocketException('down')))), isTrue);
    expect(isServerUnreachable(await err(_serve(502, {'detail': 'x'}).$1)), isTrue);
    final refused = await err(_serve(400, {'detail': 'deviceId is required.'}).$1);
    expect(refused, isA<SalesUploadError>());
    expect(isServerUnreachable(refused), isFalse);
    expect((refused as SalesUploadError).message, 'deviceId is required.');
    expect(refused.status, 400);
  });

  // Review Focus (center-web plan T12, test_held_or_missing_route_is_not_an_error): an unapproved phone's held reply
  // is done, and an older server without the `sales` dataset (404) drops the snapshot: neither is kept to retry, and
  // the server link's caller is told nothing is wrong beyond a plain refusal (the Sales page shows no upload error).
  group('a held or missing route is not an error', () {
    late Directory dir;
    late FakeTimers timers;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('mazama_sales_upload_test_');
      timers = FakeTimers();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    ServerLink link(List<PendingSnapshot> uploaded, {Object? Function()? fail}) {
      final health = ServerHealth(probe: () async => false, startTimer: timers.start);
      return ServerLink(
        health: health,
        outbox: ServerOutbox(health: health, store: OutboxStore(dataDir: () => dir), send: (_) async {}, startTimer: timers.start),
        catchUp: CatchUpWork(
          health: health,
          store: CatchUpStore(dataDir: () => dir),
          submitCoa: (lot, auth) async => true,
          uploadSnapshot: (s) async {
            uploaded.add(s);
            final e = fail?.call();
            if (e != null) throw e;
          },
          auth: () async => null,
        ),
        replies: ReplyStore(dataDir: () => dir),
      );
    }

    test('a held 200 reply is done: returned as is, nothing kept', () async {
      final (client, seen) = _serve(200, {'rows': 0, 'skipped': 0, 'held': true});
      expect(await uploadSalesSnapshot(225, _records, workerEmail: 'w', deviceId: 'd', client: client),
          {'rows': 0, 'skipped': 0, 'held': true});
      final l = link([]);
      addTearDown(l.dispose);
      expect(await l.uploadSalesSnapshot(225, _records, workerEmail: 'w', deviceId: 'd', client: client),
          {'rows': 0, 'skipped': 0, 'held': true});
      expect(seen, hasLength(2));
      expect(l.catchUp.snapshots, isEmpty);
    });

    test('a 404 from an older server is a plain refusal (not unreachable) and keeps nothing', () async {
      final (client, _) = _serve(404, {'detail': 'Not Found'});
      final l = link([]);
      addTearDown(l.dispose);
      Object? error;
      try {
        await l.uploadSalesSnapshot(225, _records, workerEmail: 'w', deviceId: 'd', client: client);
      } catch (e) {
        error = e;
      }
      expect(error, isA<SalesUploadError>().having((e) => e.status, 'status', 404));
      expect(isServerUnreachable(error), isFalse);
      expect(l.catchUp.snapshots, isEmpty);
    });

    test('a kept sales snapshot that meets a 404 once the server answers is dropped, not retried', () async {
      final uploaded = <PendingSnapshot>[];
      final l = link(uploaded, fail: () => SalesUploadError('Not Found', status: 404));
      addTearDown(l.dispose);
      l.health.markUnreachable();
      await expectLater(l.uploadSalesSnapshot(225, _records, workerEmail: 'w', deviceId: 'd'),
          throwsA(isA<SalesUploadError>().having((e) => e.unreachable, 'unreachable', isTrue)));
      expect(l.catchUp.snapshots.keys, ['sales:225']);
      l.health.markReachable();
      await l.catchUp.flush();
      expect([for (final s in uploaded) (s.kind, s.stateId)], [('sales', 225)]);
      expect(l.catchUp.snapshots, isEmpty);
      await l.catchUp.flush();
      expect(uploaded, hasLength(1));
    });
  });
}
