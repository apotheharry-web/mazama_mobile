// catch_up_store.dart: lab reports and inventory snapshots that wait for Mazama's server (README R56) - the lots are
// submitted again with the session current then, only the newest snapshot per center is sent.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/configured_coa_submit.dart';
import 'package:mazama_mobile/inventory_upload_client.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/server_health.dart';

import 'fake_timers.dart';

late Directory _dir;

void main() {
  late ServerHealth health;
  late List<(String, String)> submitted; // (lot, token)
  late List<(int, int)> uploaded; // (center, records)
  late List<Object? Function(PendingCoaLot)> coaScript;
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
    _dir.deleteSync(recursive: true);
  });

  var clock = DateTime.utc(2026, 10, 23, 18);

  CatchUpWork work({int maxLots = catchUpMaxLots}) => CatchUpWork(
        health: health,
        store: CatchUpStore(dataDir: () => _dir),
        now: () => clock,
        maxLots: maxLots,
        auth: () async => auth,
        submitCoa: (lot, a) async {
          submitted.add((lot.lotGuid, a.accessToken));
          final next = coaScript.isEmpty ? null : coaScript.removeAt(0)(lot);
          if (next != null) throw next;
          return true;
        },
        uploadSnapshot: (s) async {
          uploaded.add((s.stateId, s.records.length));
          final next = snapScript.isEmpty ? null : snapScript.removeAt(0)(s);
          if (next != null) throw next;
        },
      );

  test('lots kept while offline survive a restart and are submitted with the session current then', () async {
    health.markUnreachable();
    final w = work();
    w.addCoaLot(lotGuid: 'HB-aaaa0001', packageId: 101, stateId: 231, statePsilocybin: 4.5);
    w.addCoaLot(lotGuid: 'HB-bbbb0002', packageId: 102, stateId: 231);
    w.addCoaLot(lotGuid: 'hb-AAAA0001', packageId: 103, stateId: 231); // the same lot again: replaces, goes last
    await w.flush();
    expect(submitted, isEmpty);

    final again = work();
    expect([for (final l in again.lots) (l.lotGuid, l.packageId)], [('HB-bbbb0002', 102), ('hb-AAAA0001', 103)]);
    health.markReachable();
    await again.flush();
    expect(submitted, [('HB-bbbb0002', 'NOW-TOKEN'), ('hb-AAAA0001', 'NOW-TOKEN')]);
    expect(again.lots, isEmpty);
  });

  test('an unreachable server stops the run and keeps the lot; a refusal drops it', () async {
    final w = work();
    w.addCoaLot(lotGuid: 'HB-1', packageId: 1, stateId: 231);
    w.addCoaLot(lotGuid: 'HB-2', packageId: 2, stateId: 231);
    w.addCoaLot(lotGuid: 'HB-3', packageId: 3, stateId: 231);
    coaScript = [
      (_) => ConfiguredCoaSubmitError('Not a PDF.'),
      (_) => ConfiguredCoaSubmitError('cannot reach x', unreachable: true),
    ];
    await w.flush();
    expect([for (final s in submitted) s.$1], ['HB-1', 'HB-2']);
    expect([for (final l in w.lots) l.lotGuid], ['HB-2', 'HB-3']);
  });

  test('no usable session: the lots wait', () async {
    auth = null;
    final w = work();
    w.addCoaLot(lotGuid: 'HB-1', packageId: 1, stateId: 231);
    await w.flush();
    expect(submitted, isEmpty);
    expect(w.lots, hasLength(1));
  });

  test('at most maxLots wait, the oldest dropped first', () {
    final w = work(maxLots: 2);
    health.markUnreachable();
    for (var i = 1; i <= 3; i++) {
      w.addCoaLot(lotGuid: 'HB-$i', packageId: i, stateId: 231);
    }
    expect([for (final l in w.lots) l.lotGuid], ['HB-2', 'HB-3']);
  });

  test('snapshots: only the newest per center waits, and it is sent once', () async {
    health.markUnreachable();
    final w = work();
    w.keepSnapshot(231, [1, 2, 3], workerEmail: 'w', deviceId: 'd');
    clock = clock.add(const Duration(minutes: 5));
    w.keepSnapshot(231, [1, 2], workerEmail: 'w', deviceId: 'd'); // a newer read replaces it
    w.keepSnapshot(183, [1], workerEmail: 'w', deviceId: 'd');
    expect(work().snapshots.keys.toSet(), {'inventory:231', 'inventory:183'});
    expect(work().snapshots['inventory:231']!.records, [1, 2]);
    health.markReachable();
    await w.flush();
    expect(uploaded.toSet(), {(231, 2), (183, 1)});
    expect(w.snapshots, isEmpty);
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
    expect(w.snapshots, hasLength(2));
    snapScript = [(_) => InventoryUploadError('A sync is already running')];
    await w.flush();
    expect(w.snapshots, isEmpty);
  });

  test("a center's inventory and sales snapshots wait side by side, each replaced only by its own kind", () async {
    health.markUnreachable();
    final w = work();
    w.keepSnapshot(231, [1, 2, 3], workerEmail: 'w', deviceId: 'd');
    w.keepSnapshot(231, [9], workerEmail: 'w', deviceId: 'd', kind: 'sales');
    w.keepSnapshot(231, [8, 7], workerEmail: 'w', deviceId: 'd', kind: 'sales'); // a newer sales read replaces the sales one
    final again = work();
    expect(again.snapshots.keys.toSet(), {'inventory:231', 'sales:231'});
    expect(again.snapshots['inventory:231']!.records, [1, 2, 3]);
    expect(again.snapshots['inventory:231']!.kind, 'inventory');
    expect(again.snapshots['sales:231']!.records, [8, 7]);
    expect(again.snapshots['sales:231']!.kind, 'sales');
    w.snapshotSent(231, kind: 'sales'); // a newer sales upload reached the server: only the sales one goes
    expect(w.snapshots.keys, ['inventory:231']);
    w.keepSnapshot(231, [5], workerEmail: 'w', deviceId: 'd', kind: 'sales');
    w.snapshotSent(231); // inventory by default
    expect(w.snapshots.keys, ['sales:231']);
    health.markReachable();
    snapScript = [];
    final kinds = <String>[];
    final w2 = CatchUpWork(
      health: health,
      store: CatchUpStore(dataDir: () => _dir),
      auth: () async => auth,
      submitCoa: (lot, a) async => true,
      uploadSnapshot: (s) async => kinds.add('${s.kind}:${s.stateId}'),
    );
    await w2.flush();
    expect(kinds, ['sales:231']);
    expect(w2.snapshots, isEmpty);
    w2.dispose();
  });

  // Review I-2: a build from before sales snapshots reads `snapshots` as inventory and would send a sales one to
  // /p/inventory (which replaces the mirror). The work now waits in the sync queue (specs/phone-sync), so there is no
  // document for such a build to read at all; the old document's writer still keeps sales snapshots out of `snapshots`.
  test("an older build's reader finds no sales snapshot: no document is kept, and the old one keeps them apart", () {
    health.markUnreachable();
    final w = work();
    w.keepSnapshot(231, [9], workerEmail: 'w', deviceId: 'd', kind: 'sales');
    expect(LocalStore.forDir(_dir).read('server_catch_up.json'), isNull);
    w.keepSnapshot(231, [1, 2], workerEmail: 'w', deviceId: 'd');
    expect(work().snapshots.keys.toSet(), {'inventory:231', 'sales:231'});
    expect(work().snapshots['sales:231']!.records, [9]);
    // the reader at main before sales: d['snapshots'], each entry an inventory snapshot keyed by stateId
    List<int> oldReader(Map d) => [
          if (d['snapshots'] is List)
            for (final s in d['snapshots'] as List)
              if (s is Map && s['stateId'] is int && s['records'] is List && s['workerEmail'] is String &&
                  s['deviceId'] is String && s['readAtMs'] is int)
                s['stateId'] as int,
        ];
    CatchUpStore(dataDir: () => _dir).save(CatchUpState(snapshots: w.snapshots));
    final both = jsonDecode(LocalStore.forDir(_dir).read('server_catch_up.json')!.body) as Map;
    expect(oldReader(both), [231]);
    expect((both['snapshots'] as List).single['records'], [1, 2]);
  });

  test('a snapshot saved before kinds existed reads as inventory', () {
    LocalStore.forDir(_dir).write(
        'server_catch_up.json',
        '{"lots": [], "snapshots": [{"stateId": 231, "records": [1], "workerEmail": "w", "deviceId": "d", '
            '"readAtMs": 1761242400000}]}');
    final w = work();
    expect(w.snapshots.keys, ['inventory:231']);
    expect(w.snapshots['inventory:231']!.kind, 'inventory');
    expect(w.snapshots['inventory:231']!.toJson()['kind'], 'inventory');
  });

  test('only inventory is read from snapshots and only sales from salesSnapshots; other kinds are never read', () {
    String snap(int id, String kind, int r) =>
        '{"stateId": $id, "kind": "$kind", "records": [$r], "workerEmail": "w", "deviceId": "d", "readAtMs": 1761242400000}';
    LocalStore.forDir(_dir).write(
        'server_catch_up.json',
        '{"lots": [], "snapshots": [${snap(231, 'harvest', 1)}, ${snap(183, 'sales', 2)}, ${snap(225, 'inventory', 3)}], '
            '"salesSnapshots": [${snap(231, 'sales', 4)}, ${snap(183, 'inventory', 5)}, ${snap(225, 'harvest', 6)}]}');
    expect(work().snapshots.keys.toSet(), {'inventory:225', 'sales:231'});
  });

  test('CoaDataError says unreachable through ConfiguredCoaSubmitError', () {
    expect(CoaDataError('x', unreachable: true).unreachable, isTrue);
    expect(ConfiguredCoaSubmitError('x').unreachable, isFalse);
  });
}
