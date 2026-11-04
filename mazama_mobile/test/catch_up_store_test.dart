// catch_up_store.dart: lab reports and inventory/sales snapshots that wait for Mazama's server on the sync engine's
// queue - the lots are submitted again with the session current then, only the newest snapshot per center is sent.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/coa_uploader.dart';
import 'package:mazama_mobile/configured_coa_submit.dart';
import 'package:mazama_mobile/inventory_upload_client.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/sales_upload_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';

import 'fake_timers.dart';

late Directory _dir;

CoaData _data(String guid) =>
    CoaData(guid: guid, strain: 'Golden Teacher', psilocybin: 10, psilocin: 1, baeocystin: 0, norbaeocystin: 0, norpsilocin: 0);

void main() {
  late ServerHealth health;
  late List<(String, String)> submitted; // (lot, token)
  late List<(int, int)> uploaded; // (center, records)
  late List<Object? Function(CoaUploadLot)> coaScript;
  late List<Object? Function(PendingSnapshot)> snapScript;
  late CatchUpAuth? auth;

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('mazama_catch_up_test_');
    health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
    submitted = [];
    uploaded = [];
    coaScript = [];
    snapScript = [];
    auth = const CatchUpAuth(accessToken: 'NOW-TOKEN', workerEmail: 'w@example.com', deviceId: 'D-1');
  });
  tearDown(() {
    health.dispose();
    LocalStore.debugCloseAll();
    _dir.deleteSync(recursive: true);
  });

  var clock = DateTime.utc(2026, 10, 23, 18);

  // The queue as the app's engine builds it, with the real senders over fakes: a second one over the same folder is
  // the app restarted.
  SyncQueue work({int maxLots = catchUpMaxLots, Future<void> Function(PendingSnapshot)? upload}) {
    final q = SyncQueue(
      tables: SyncTables(LocalStore.forDir(_dir)),
      health: health,
      now: () => clock,
      labReportCap: maxLots,
      senders: {
        QueueKind.labReport: labReportQueueSender((lot, a) async {
          submitted.add((lot.lotGuid, a.accessToken));
          final next = coaScript.isEmpty ? null : coaScript.removeAt(0)(lot);
          if (next != null) throw next;
          return _data(lot.lotGuid);
        }, () async => auth),
        for (final k in const [QueueKind.inventorySnapshot, QueueKind.salesSnapshot])
          k: snapshotQueueSender(upload ??
              (s) async {
                uploaded.add((s.stateId, s.records.length));
                final next = snapScript.isEmpty ? null : snapScript.removeAt(0)(s);
                if (next != null) throw next;
              }),
      },
    );
    addTearDown(q.dispose);
    return q;
  }

  test('lots kept while offline survive a restart and are submitted with the session current then', () async {
    health.markUnreachable();
    final w = work();
    w.addCoaLot(lotGuid: 'HB-aaaa0001', packageId: 101, stateId: 231, statePsilocybin: 4.5);
    w.addCoaLot(lotGuid: 'HB-bbbb0002', packageId: 102, stateId: 231);
    w.addCoaLot(lotGuid: 'hb-AAAA0001', packageId: 103, stateId: 231); // the same lot again: replaces, goes last
    await w.flush();
    expect(submitted, isEmpty);

    final again = work();
    expect([for (final l in again.keptCoaLots) (l.lotGuid, l.packageId)], [('HB-bbbb0002', 102), ('hb-AAAA0001', 103)]);
    health.markReachable();
    await again.flush();
    expect(submitted, [('HB-bbbb0002', 'NOW-TOKEN'), ('hb-AAAA0001', 'NOW-TOKEN')]);
    expect(again.keptCoaLots, isEmpty);
    expect(again.wasSent(QueueKind.labReport, 'HB-BBBB0002'), isTrue); // remembered as sent, any case
  });

  test('an unreachable server stops the run and keeps the lot; a refusal drops it', () async {
    final w = work();
    health.markUnreachable();
    w.addCoaLot(lotGuid: 'HB-1', packageId: 1, stateId: 231);
    w.addCoaLot(lotGuid: 'HB-2', packageId: 2, stateId: 231);
    w.addCoaLot(lotGuid: 'HB-3', packageId: 3, stateId: 231);
    health.markReachable();
    coaScript = [
      (_) => ConfiguredCoaSubmitError('Not a PDF.'),
      (_) => ConfiguredCoaSubmitError('cannot reach x', unreachable: true),
    ];
    await w.flush();
    expect([for (final s in submitted) s.$1], ['HB-1', 'HB-2']);
    expect([for (final l in w.keptCoaLots) l.lotGuid], ['HB-2', 'HB-3']);
    expect(w.wasSent(QueueKind.labReport, 'HB-1'), isFalse);
  });

  for (final status in [429, 408]) {
    test('a $status keeps the lot waiting, unmarked (408: the server never got its body)', () async {
      final w = work();
      health.markUnreachable();
      w.addCoaLot(lotGuid: 'HB-1', packageId: 1, stateId: 231);
      health.markReachable();
      coaScript = [(_) => ConfiguredCoaSubmitError('Not now', status: status)];
      await w.flush();
      expect(submitted, hasLength(1));
      expect([for (final l in w.keptCoaLots) l.lotGuid], ['HB-1']);
      expect(w.wasSent(QueueKind.labReport, 'HB-1'), isFalse);
    });
  }

  test("a snapshot the server timed out reading (408) is kept and sent again; it isn't a refusal", () async {
    final w = work();
    health.markUnreachable();
    w.keepSnapshot(231, [1], workerEmail: 'w', deviceId: 'd');
    w.keepSnapshot(231, [2], workerEmail: 'w', deviceId: 'd', kind: 'sales');
    health.markReachable();
    snapScript = [
      (_) => InventoryUploadError('The request took too long to send.', status: 408),
    ];
    await w.flush();
    expect(w.keptSnapshots.keys.toSet(), {'inventory:231', 'sales:231'});
    snapScript = [(_) => SalesUploadError('The request took too long to send.', status: 408)];
    await w.flush();
    expect(w.keptSnapshots.keys.toSet(), {'inventory:231', 'sales:231'});
    snapScript = [];
    await w.flush();
    expect(w.keptSnapshots, isEmpty);
  });

  test('no usable session: the lots wait', () async {
    auth = null;
    final w = work();
    w.addCoaLot(lotGuid: 'HB-1', packageId: 1, stateId: 231);
    await w.flush();
    expect(submitted, isEmpty);
    expect(w.keptCoaLots, hasLength(1));
  });

  test('at most maxLots wait, the oldest dropped first', () {
    final w = work(maxLots: 2);
    health.markUnreachable();
    for (var i = 1; i <= 3; i++) {
      w.addCoaLot(lotGuid: 'HB-$i', packageId: i, stateId: 231);
    }
    expect([for (final l in w.keptCoaLots) l.lotGuid], ['HB-2', 'HB-3']);
    expect(catchUpMaxLots, 200);
  });

  test('snapshots: only the newest per center waits, and it is sent once', () async {
    health.markUnreachable();
    final w = work();
    w.keepSnapshot(231, [1, 2, 3], workerEmail: 'w', deviceId: 'd');
    clock = clock.add(const Duration(minutes: 5));
    w.keepSnapshot(231, [1, 2], workerEmail: 'w', deviceId: 'd'); // a newer read replaces it
    w.keepSnapshot(183, [1], workerEmail: 'w', deviceId: 'd');
    expect(work().keptSnapshots.keys.toSet(), {'inventory:231', 'inventory:183'});
    expect(work().keptSnapshots['inventory:231']!.records, [1, 2]);
    health.markReachable();
    await w.flush();
    expect(uploaded.toSet(), {(231, 2), (183, 1)});
    expect(w.keptSnapshots, isEmpty);
    await w.flush();
    expect(uploaded, hasLength(2));
  });

  test('a newer snapshot that reached the server makes the kept one moot', () async {
    health.markUnreachable();
    final w = work();
    w.keepSnapshot(231, [1], workerEmail: 'w', deviceId: 'd');
    w.snapshotSent(231);
    health.markReachable();
    await w.flush();
    expect(uploaded, isEmpty);
  });

  test("an unreachable upload keeps the snapshot; the server's refusal drops it (the next read sends a fresher one)",
      () async {
    final w = work();
    health.markUnreachable();
    w.keepSnapshot(231, [1], workerEmail: 'w', deviceId: 'd');
    w.keepSnapshot(183, [1], workerEmail: 'w', deviceId: 'd');
    health.markReachable();
    snapScript = [(_) => InventoryUploadError('cannot reach x', unreachable: true)];
    await w.flush();
    expect(uploaded, hasLength(1));
    expect(w.keptSnapshots, hasLength(2));
    snapScript = [(_) => InventoryUploadError('A sync is already running')];
    await w.flush();
    expect(w.keptSnapshots, isEmpty);
  });

  test("a center's inventory and sales snapshots wait side by side, each replaced only by its own kind", () async {
    health.markUnreachable();
    final w = work();
    w.keepSnapshot(231, [1, 2, 3], workerEmail: 'w', deviceId: 'd');
    w.keepSnapshot(231, [9], workerEmail: 'w', deviceId: 'd', kind: 'sales');
    w.keepSnapshot(231, [8, 7], workerEmail: 'w', deviceId: 'd', kind: 'sales'); // a newer sales read replaces the sales one
    final again = work();
    expect(again.keptSnapshots.keys.toSet(), {'inventory:231', 'sales:231'});
    expect(again.keptSnapshots['inventory:231']!.records, [1, 2, 3]);
    expect(again.keptSnapshots['inventory:231']!.kind, 'inventory');
    expect(again.keptSnapshots['sales:231']!.records, [8, 7]);
    expect(again.keptSnapshots['sales:231']!.kind, 'sales');
    w.snapshotSent(231, kind: 'sales'); // a newer sales upload reached the server: only the sales one goes
    expect(w.keptSnapshots.keys, ['inventory:231']);
    w.keepSnapshot(231, [5], workerEmail: 'w', deviceId: 'd', kind: 'sales');
    w.snapshotSent(231); // inventory by default
    expect(w.keptSnapshots.keys, ['sales:231']);
    health.markReachable();
    final kinds = <String>[];
    final w2 = work(upload: (s) async => kinds.add('${s.kind}:${s.stateId}'));
    await w2.flush();
    expect(kinds, ['sales:231']);
    expect(w2.keptSnapshots, isEmpty);
  });

  test('a kind this build has no upload for is never kept; a snapshot with no kind reads as inventory', () {
    health.markUnreachable();
    final w = work();
    w.keepSnapshot(231, [1], workerEmail: 'w', deviceId: 'd', kind: 'harvest');
    w.snapshotSent(231, kind: 'harvest');
    expect(w.keptSnapshots, isEmpty);
    expect(SyncTables(LocalStore.forDir(_dir)).items('inventory_snapshot'), isEmpty);
    final noKind = PendingSnapshot.fromJson(
        {'stateId': 231, 'records': [1], 'workerEmail': 'w', 'deviceId': 'd', 'readAtMs': 1761242400000})!;
    expect([noKind.kind, noKind.key, noKind.toJson()['kind']], ['inventory', 'inventory:231', 'inventory']);
    expect(
        PendingSnapshot.fromJson(
            {'stateId': 231, 'kind': 'harvest', 'records': [1], 'workerEmail': 'w', 'deviceId': 'd', 'readAtMs': 1}),
        isNull);
  });

  test('kept in the sync queue, not in a document of its own', () {
    health.markUnreachable();
    final w = work();
    w.keepSnapshot(231, [9], workerEmail: 'w', deviceId: 'd', kind: 'sales');
    w.addCoaLot(lotGuid: 'HB-1', packageId: 1, stateId: 231);
    expect(LocalStore.forDir(_dir).read('server_catch_up.json'), isNull);
    final tables = SyncTables(LocalStore.forDir(_dir));
    expect((jsonDecode(tables.items('sales_snapshot').single.body) as Map)['records'], [9]);
    expect(tables.items('lab_report').single.key, 'hb-1');
  });

  test('CoaDataError says unreachable through ConfiguredCoaSubmitError', () {
    expect(CoaDataError('x', unreachable: true).unreachable, isTrue);
    expect(ConfiguredCoaSubmitError('x').unreachable, isFalse);
  });
}
