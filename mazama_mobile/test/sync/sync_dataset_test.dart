// sync/sync_datasets.dart and the engine's datasets (specs/phone-sync PS-R3, PS-R7): one row per page's worth of data
// with one age, watched by pages; a refresh writes it, a failed one only records the try; one refresh per key at a
// time; the foreground tick refreshes what is watched and older than five minutes, never in the background; the
// server answering again refreshes what is watched (README R87's reload). Fake clock, timers and refreshers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/center_status_client.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/sheets_client.dart';
import 'package:mazama_mobile/stock_mix.dart';
import 'package:mazama_mobile/stock_summary.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/sync_engine.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';
import 'package:mazama_mobile/sync/updated_line.dart';

import '../fake_timers.dart';

void main() {
  late Directory dir;
  late FakeTimers timers;
  late ServerHealth health;
  late DateTime now;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mazama_sync_dataset_test_');
    timers = FakeTimers();
    now = DateTime.utc(2026, 10, 30, 12);
    health = ServerHealth(probe: () async => false, startTimer: timers.start);
  });
  tearDown(() {
    health.dispose();
    LocalStore.debugCloseAll();
    dir.deleteSync(recursive: true);
  });

  SyncEngine engine() {
    final e = SyncEngine(
      store: LocalStore.forDir(dir),
      health: health,
      now: () => now,
      startTimer: timers.start,
      senders: {for (final k in QueueKind.values) k: (item) async => const Done()},
    );
    addTearDown(e.dispose);
    return e;
  }

  test('the stored names are the spec\'s', () {
    expect([for (final d in Dataset.values) d.stored], [
      'licenses',
      'center_status',
      'center_stock',
      'enrichment',
      'par',
      'sheets',
      'mazama_inventory',
      'coa_data',
      'recent_sales',
      'stock_rows',
      'mazama_licenses', // Task 10: the stock page's kept Mazama licenses (stock_cache_store.dart's, before)
    ]);
  });

  test('watch emits the stored body at once and again after a refresh', () async {
    final e = engine();
    e.datasets.put(Dataset.par, '231', '["old"]', source: sourceServer, at: now.subtract(const Duration(hours: 1)));
    var calls = 0;
    e.register(Dataset.par, (key) async {
      calls++;
      return (body: '["new $key"]', source: sourceServer);
    });
    final seen = <String?>[];
    final sub = e.watch(Dataset.par, '231').listen((row) => seen.add(row?.body));
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(seen, ['["old"]']);
    await e.refresh(Dataset.par, '231');
    await pumpEventQueue();
    expect(calls, 1);
    expect(seen, ['["old"]', '["new 231"]']);
    final row = e.datasets.read(Dataset.par, '231')!;
    expect([row.source, row.fetchedAt, row.lastError], [sourceServer, now, null]);
  });

  test('watch emits null at once when nothing is stored yet', () async {
    final e = engine();
    final seen = <DatasetRow?>[];
    final sub = e.watch(Dataset.sheets, '231').listen(seen.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(seen, [null]);
  });

  test('a failed refresh keeps the body and records the error', () async {
    final e = engine();
    final at = now.subtract(const Duration(hours: 2));
    e.datasets.put(Dataset.par, '231', '["good"]', source: sourceServer, at: at);
    e.register(Dataset.par, (key) async => throw StateError('no answer'));
    final seen = <DatasetRow?>[];
    final sub = e.watch(Dataset.par, '231').listen(seen.add);
    addTearDown(sub.cancel);
    await e.refresh(Dataset.par, '231'); // never throws
    await pumpEventQueue();
    final row = e.datasets.read(Dataset.par, '231')!;
    expect(row.body, '["good"]');
    expect(row.fetchedAt, at);
    expect(row.lastTry, now);
    expect(row.lastError, contains('no answer'));
    expect(seen.last!.body, '["good"]'); // the page is told, and keeps what it shows
    expect(seen.last!.lastError, contains('no answer'));
  });

  test('a refresher that throws at once is a failed refresh too, never thrown into the caller', () async {
    final e = engine();
    e.register(Dataset.sheets, (key) => throw StateError('sync throw'));
    await e.refresh(Dataset.sheets, '231');
    expect(e.datasets.read(Dataset.sheets, '231'), isNull); // nothing stored yet: nothing recorded
  });

  test('one refresh per key at a time; one asked for while it runs runs once more after it', () async {
    final e = engine();
    final gates = <Completer<void>>[];
    var calls = 0;
    var held = true; // each read waits for the test until it lets them all through
    e.register(Dataset.par, (key) async {
      calls++;
      if (held) {
        final g = Completer<void>();
        gates.add(g);
        await g.future;
      }
      return (body: '[$calls]', source: sourceServer);
    });
    final a = e.refresh(Dataset.par, '231');
    final b = e.refresh(Dataset.par, '231'); // while a runs: once more after it
    final c = e.refresh(Dataset.par, '231'); // still one more, not two
    final other = e.refresh(Dataset.par, '183');
    await pumpEventQueue();
    expect(calls, 2); // 231 and 183, never two of 231 at once
    gates[0].complete();
    await pumpEventQueue();
    expect(calls, 3); // 231 again, after the first ended
    gates[1].complete();
    gates[2].complete();
    await Future.wait([a, b, c, other]);
    expect(calls, 3);
    held = false;
    await e.refresh(Dataset.par, '231'); // nothing running: a new one
    expect(calls, 4);
  });

  test('a refresh is stamped with when it started, and an older read finishing last never replaces a newer copy',
      () async {
    final e = engine();
    final gate = Completer<void>();
    e.register(Dataset.par, (key) async {
      await gate.future;
      return (body: '["slow"]', source: sourceServer);
    });
    final started = now;
    final run = e.refresh(Dataset.par, '231');
    await pumpEventQueue();
    now = now.add(const Duration(seconds: 25)); // the read takes 25 s
    e.datasets.put(Dataset.par, '231', '["newer"]', source: sourceServer, at: started.add(const Duration(seconds: 10)));
    gate.complete();
    await run;
    final row = e.datasets.read(Dataset.par, '231')!;
    expect(row.body, '["newer"]'); // the slow read began before it: refused
    e.datasets.remove(Dataset.par, key: '231');
    final again = Completer<void>();
    e.register(Dataset.par, (key) async {
      await again.future;
      return (body: '["late"]', source: sourceServer);
    });
    final start2 = now;
    final run2 = e.refresh(Dataset.par, '231');
    await pumpEventQueue();
    now = now.add(const Duration(seconds: 25));
    again.complete();
    await run2;
    expect(e.datasets.read(Dataset.par, '231')!.fetchedAt, start2); // the read's start, not its end
  });

  test('a stored copy dated in the future (the clock moved back) never blocks a new one', () {
    final d = Datasets(SyncTables(LocalStore.forDir(dir)), now: () => now);
    d.put(Dataset.par, '231', '["future"]', source: sourceServer, at: now.add(const Duration(days: 1)));
    expect(d.put(Dataset.par, '231', '["now"]', source: sourceServer, at: now), isTrue);
    expect(d.read(Dataset.par, '231')!.body, '["now"]');
    expect(d.put(Dataset.par, '231', '["older"]', source: sourceServer, at: now.subtract(const Duration(minutes: 1))),
        isFalse);
  });

  test('the foreground tick refreshes only data older than five minutes', () async {
    final e = engine();
    final asked = <String>[];
    e.register(Dataset.par, (key) async {
      asked.add(key);
      return (body: '[]', source: sourceServer);
    });
    e.datasets.put(Dataset.par, 'old', '[]', source: sourceServer, at: now.subtract(const Duration(minutes: 6)));
    e.datasets.put(Dataset.par, 'fresh', '[]', source: sourceServer, at: now.subtract(const Duration(minutes: 4)));
    e.datasets.put(Dataset.par, 'unwatched', '[]', source: sourceServer, at: now.subtract(const Duration(days: 1)));
    final subs = [
      for (final k in ['old', 'fresh', 'none']) e.watch(Dataset.par, k).listen((_) {}),
    ];
    addTearDown(() async {
      for (final s in subs) {
        await s.cancel();
      }
    });
    await pumpEventQueue();
    e.foregroundTick();
    await pumpEventQueue();
    expect(asked..sort(), ['none', 'old']); // nothing stored counts as old; unwatched data is left alone
  });

  test('the five-minute timer runs while something is watched in the foreground', () async {
    final e = engine();
    var calls = 0;
    e.register(Dataset.par, (key) async {
      calls++;
      return (body: '[]', source: sourceServer);
    });
    expect(timers.active, isEmpty); // nothing watched: no timer
    final sub = e.watch(Dataset.par, '231').listen((_) {});
    await pumpEventQueue();
    expect(timers.pendingDelays, [syncForegroundEvery]);
    timers.fireAll();
    await pumpEventQueue();
    expect(calls, 1);
    expect(timers.pendingDelays, [syncForegroundEvery]); // armed again
    await sub.cancel();
    expect(timers.active, isEmpty); // nothing watched any more
  });

  test('no tick in the background', () async {
    final e = engine();
    var calls = 0;
    e.register(Dataset.par, (key) async {
      calls++;
      return (body: '[]', source: sourceServer);
    });
    final sub = e.watch(Dataset.par, '231').listen((_) {});
    addTearDown(sub.cancel);
    await pumpEventQueue();
    e.onBackground();
    expect(timers.active, isEmpty);
    e.foregroundTick();
    await pumpEventQueue();
    expect(calls, 0);
    e.onForeground(); // back: a tick at once, and the timer again
    await pumpEventQueue();
    expect(calls, 1);
    expect(timers.pendingDelays, contains(syncForegroundEvery));
  });

  test('a time in the future reads as just now and is not refreshed by the tick', () async {
    final e = engine();
    var calls = 0;
    e.register(Dataset.par, (key) async {
      calls++;
      return (body: '[]', source: sourceServer);
    });
    e.datasets.put(Dataset.par, '231', '[]', source: sourceServer, at: now.add(const Duration(minutes: 3)));
    final sub = e.watch(Dataset.par, '231').listen((_) {});
    addTearDown(sub.cancel);
    await pumpEventQueue();
    e.foregroundTick();
    await pumpEventQueue();
    expect(calls, 0);
    expect(updatedLine(now.add(const Duration(minutes: 3)), now), 'Updated just now');
    expect(datasetIsStale(now.add(const Duration(minutes: 3)), now), isFalse);
    // a clock moved back further than the refresh period counts as stale, so the data is not stuck until it catches up
    expect(datasetIsStale(now.add(const Duration(hours: 2)), now), isTrue);
  });

  test('the server answering again refreshes what is watched (a page reloads, README R87)', () async {
    final e = engine();
    var calls = 0;
    e.register(Dataset.mazamaInventory, (key) async {
      calls++;
      return (body: '{}', source: sourceServer);
    });
    final seen = <DatasetRow?>[];
    final sub = e.watch(Dataset.mazamaInventory, '').listen(seen.add);
    addTearDown(sub.cancel);
    health.markUnreachable();
    await pumpEventQueue();
    expect(calls, 0);
    health.markReachable();
    await pumpEventQueue();
    expect(calls, 1);
    expect(seen.last!.body, '{}');
  });

  test('the server answering again in the background refreshes nothing (PS-D6)', () async {
    final e = engine();
    var calls = 0;
    e.register(Dataset.mazamaInventory, (key) async {
      calls++;
      return (body: '{}', source: sourceServer);
    });
    final sub = e.watch(Dataset.mazamaInventory, '').listen((_) {});
    addTearDown(sub.cancel);
    health.markUnreachable();
    e.onBackground();
    await pumpEventQueue();
    health.markReachable(); // a probe answered while the app is in the background
    await pumpEventQueue();
    expect(calls, 0);
    e.onForeground(); // back: what is stale is refreshed then
    await pumpEventQueue();
    expect(calls, 1);
  });

  test('storing the same copy again, or a failure with nothing stored, tells no watcher', () async {
    final e = engine();
    final at = now.subtract(const Duration(minutes: 1));
    e.datasets.put(Dataset.par, '231', '[1]', source: sourceServer, at: at);
    final seen = <String?>[];
    final sub = e.watch(Dataset.par, '231').listen((row) => seen.add(row?.body));
    final none = <DatasetRow?>[];
    final sub2 = e.watch(Dataset.par, '183').listen(none.add);
    addTearDown(sub.cancel);
    addTearDown(sub2.cancel);
    await pumpEventQueue();
    e.datasets.put(Dataset.par, '231', '[1]', source: sourceServer, at: at); // the same copy
    e.datasets.failed(Dataset.par, '183', 'no answer'); // nothing stored for 183
    await pumpEventQueue();
    expect(seen, ['[1]']);
    expect(none, [null]);
    expect(e.datasets.read(Dataset.par, '183'), isNull);
    e.datasets.put(Dataset.par, '231', '[1]', source: sourceServer, at: now); // read again later: its age changed
    await pumpEventQueue();
    expect(seen, ['[1]', '[1]']);
  });

  test("a watch started while the database can't be opened is attached once it can", () async {
    var open = false;
    final d = Datasets.forDir(() {
      if (!open) throw const FileSystemException('busy');
      return dir;
    });
    final seen = <String?>[];
    final sub = d.watch(Dataset.sheets, '231').listen((row) => seen.add(row?.body));
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(seen, [null]);
    open = true;
    d.put(Dataset.sheets, '231', '[2]', source: sourceServer, at: now);
    await pumpEventQueue();
    expect(seen.last, '[2]');
    Datasets.forDir(() => dir).put(Dataset.sheets, '231', '[3]', source: sourceServer, at: now); // another handle
    await pumpEventQueue();
    expect(seen.last, '[3]');
  });

  test('a write through another handle on the same folder reaches the watchers', () async {
    final e = engine();
    final seen = <String?>[];
    final sub = e.watch(Dataset.sheets, '231').listen((row) => seen.add(row?.body));
    addTearDown(sub.cancel);
    await pumpEventQueue();
    Datasets.forDir(() => dir).put(Dataset.sheets, '231', '[1]', source: sourceServer, at: now);
    await pumpEventQueue();
    expect(seen, [null, '[1]']);
  });

  test('dispose: no refresh, no timer', () async {
    final e = engine();
    var calls = 0;
    e.register(Dataset.par, (key) async {
      calls++;
      return (body: '[]', source: sourceServer);
    });
    final sub = e.watch(Dataset.par, '231').listen((_) {});
    addTearDown(sub.cancel);
    await pumpEventQueue();
    e.dispose();
    expect(timers.active, isEmpty);
    await e.refresh(Dataset.par, '231');
    e.foregroundTick();
    await pumpEventQueue();
    expect(calls, 0);
  });

  test('every dataset kept is listed (the debug page)', () {
    final d = Datasets.forDir(() => dir);
    d.put(Dataset.sheets, '231', '[]', source: sourceServer, at: now);
    d.put(Dataset.par, '231', '[]', source: sourceServer, at: now);
    expect([for (final r in d.list()) '${r.name}/${r.key}'], ['par/231', 'sheets/231']);
  });

  // The server's reads (phase 2), ported from the old reply_store_test.dart's "the reads moved here".
  group("the server's reads", () {
    const levels = [ParLevel(strain: 'Golden Teacher', size: 25, par: 12)];
    final at = DateTime.utc(2026, 10, 21, 9, 30);
    Datasets datasets() => Datasets.forDir(() => dir);

    test('par: kept and read back, as the par dataset', () async {
      await parDataset(datasets(), 231).save(levels, at);
      final read = (await parDataset(datasets(), 231).load())!;
      expect([for (final l in read.value) l.toJson()], [for (final l in levels) l.toJson()]);
      expect(read.cachedAt, at);
      final row = datasets().read(Dataset.par, '231')!;
      expect([row.source, row.fetchedAt], [sourceServer, at]);
    });

    // Task 10: the classes that kept these (stock_cache_store.dart, mazama_inventory_cache_store.dart) are gone; their
    // documents, as an older build wrote them, are moved in on the folder's first open (sync_migration.dart).
    test("par and sheets: an older build's stock_cache document is moved in on the first open", () async {
      final sheet = ProductSheet.fromJson(const {
        'guid': 'HB-aaaa0001', 'name': 'GT', 'product': 'Dried', 'tested': '2026-09-01', 'path': '/p/lots/m/HB-aaaa0001',
        'strains': ['Golden Teacher'],
      });
      LocalStore.forDir(dir).write(
          'stock_cache_231.json',
          jsonEncode({
            'par': [for (final l in levels) l.toJson()],
            'parAtMs': at.millisecondsSinceEpoch,
            'sheets': [sheet.toJson()],
            'sheetsAtMs': at.millisecondsSinceEpoch,
          }));
      final par = (await parDataset(datasets(), 231).load())!;
      expect([par.value.single.par, par.cachedAt], [12, at]);
      final sheets = (await sheetsDataset(datasets(), 231).load())!;
      expect([sheets.value.single.toJson(), sheets.cachedAt], [sheet.toJson(), at]);
      expect(await parDataset(datasets(), 183).load(), isNull);
      expect(LocalStore.forDir(dir).read('stock_cache_231.json'), isNull); // nothing left in it
    });

    // Task 10 review, minor 1: a move that failed (caught and logged) is tried again on the next open in the same run,
    // not only at the next launch; one that keeps failing is tried a few times, not at every read.
    test("an older build's copy whose move failed is moved on the next open, in the same run", () async {
      LocalStore.forDir(dir).write('stock_cache_231.json',
          jsonEncode({'par': [for (final l in levels) l.toJson()], 'parAtMs': at.millisecondsSinceEpoch}));
      final tables = _FailingDatasetTables(LocalStore.forDir(dir), fails: 1);
      final d = Datasets(tables);
      expect(d.read(Dataset.par, '231'), isNull); // the first move failed, as a full disk would
      expect(LocalStore.forDir(dir).read('stock_cache_231.json'), isNotNull, reason: 'kept for the next try');
      final par = (await parDataset(d, 231).load())!;
      expect([par.value.single.par, par.cachedAt], [12, at]);
      expect(LocalStore.forDir(dir).read('stock_cache_231.json'), isNull);
    });

    test('a move that keeps failing is tried 3 times, then left for the next launch', () {
      LocalStore.forDir(dir).write('stock_cache_231.json', jsonEncode({'par': [for (final l in levels) l.toJson()]}));
      final tables = _FailingDatasetTables(LocalStore.forDir(dir), fails: 1000);
      final d = Datasets(tables);
      for (var i = 0; i < 6; i++) {
        expect(d.read(Dataset.par, '231'), isNull);
      }
      expect(tables.tries, 3);
      expect(LocalStore.forDir(dir).read('stock_cache_231.json'), isNotNull);
    });

    test("par kept without a time by an older build is shown with none", () async {
      LocalStore.forDir(dir).write('stock_cache_231.json', jsonEncode({'par': [for (final l in levels) l.toJson()]}));
      final par = (await parDataset(datasets(), 231).load())!;
      expect([par.value.single.par, par.cachedAt], [12, null]);
    });

    test("Mazama's stock: an older build's copy is moved in on the first open, every field kept; then kept here",
        () async {
      const inv = MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [
        MixCell(strain: 'Golden Teacher', type: 'DH', mg: 3888),
      ], lots: [
        MazamaLot(strain: 'Golden Teacher', lot: 'HB-aaaa0001', tpe: 8.64, detected: ['baeocystin'], path: '/p/lots/mazama/HB-aaaa0001', types: ['DH']),
      ]);
      // as mazama_inventory_cache_store.dart kept it
      LocalStore.forDir(dir)
          .write('mazama_inventory_cache.json', jsonEncode({'atMs': at.millisecondsSinceEpoch, 'inventory': inv.toJson()}));
      final read = (await mazamaInventoryDataset(datasets()).load())!;
      expect([read.fromCache, read.cachedAt, read.value.name], [true, at, 'Mazama Mushrooms LLC']);
      expect(read.value.cells.single.toJson(), {'strain': 'Golden Teacher', 'type': 'DH', 'mg': 3888});
      expect(read.value.lots.single.toJson(), inv.lots.single.toJson());
      expect(LocalStore.forDir(dir).read('mazama_inventory_cache.json'), isNull);
      final later = at.add(const Duration(days: 1));
      await mazamaInventoryDataset(datasets()).save(inv, later);
      expect((await mazamaInventoryDataset(datasets()).load())!.cachedAt, later);
    });

    test("an older build's damaged Mazama copy counts as nothing kept", () async {
      for (final (i, body) in ['{not json', '{"atMs": 1, "inventory": {"cells": 3}}', '[]'].indexed) {
        final older = Directory('${dir.path}/older$i')..createSync();
        LocalStore.forDir(older).write('mazama_inventory_cache.json', body);
        expect(await mazamaInventoryDataset(Datasets.forDir(() => older)).load(), isNull, reason: body);
      }
    });

    test("a reply the reply store kept is read as the dataset (moved on the folder's first use)", () async {
      // as reply_store.dart (removed in Task 10) kept it
      LocalStore.forDir(dir).write('server_replies/${Uri.encodeComponent('par/231')}.json',
          jsonEncode({'atMs': at.millisecondsSinceEpoch, 'value': [for (final l in levels) l.toJson()]}));
      final read = (await parDataset(datasets(), 231).load())!;
      expect([read.value.single.par, read.cachedAt], [12, at]);
      expect(LocalStore.forDir(dir).names('server_replies/'), isEmpty);
    });

    test('a stored copy that cannot be decoded counts as none', () async {
      datasets().put(Dataset.par, '231', '{"not": "a list"}', source: sourceServer, at: at);
      expect(await parDataset(datasets(), 231).load(), isNull);
    });

    test('the refreshers store what the keepers read back', () async {
      final e = engine();
      final sheet = ProductSheet.fromJson(const {
        'guid': 'HB-aaaa0001', 'name': 'GT', 'product': 'Dried', 'tested': '2026-09-01', 'path': '/p/lots/m/HB-aaaa0001',
        'strains': ['Golden Teacher'],
      });
      final asked = <String>[];
      serverReadRefreshers(
        fetchPar: (id) async {
          asked.add('par $id');
          return levels;
        },
        fetchSheets: (id) async => [sheet],
        fetchMazamaInventory: () async => MazamaInventory.fromJson(const {'name': 'Mazama', 'cells': [], 'lots': []}),
        fetchCenterStatus: (id) async => CenterStatus(
            configured: true,
            cart: const CartSettings(
                minutes: 60, taxPercent: 10, agreementEdible: 40, agreementDried: 90, dedupeSeconds: 20, maxUnitsPerLine: 9),
            mazamaLicenses: const ['mf-1']),
        fetchCoaData: (lots) async => {
          'HB-AAAA0001': CoaData(
              guid: 'HB-AAAA0001', strain: 'GT', psilocybin: 1.25, baeocystin: 0, norbaeocystin: 0, norpsilocin: 0, tpe: 1.5),
        },
      ).forEach(e.register);
      for (final (d, key) in [
        (Dataset.par, '231'),
        (Dataset.sheets, '231'),
        (Dataset.mazamaInventory, ''),
        (Dataset.centerStatus, '231'),
        (Dataset.coaData, 'hb-aaaa0001'),
        (Dataset.coaData, 'hb-none'),
      ]) {
        await e.refresh(d, key);
      }
      expect(asked, ['par 231']);
      expect((await parDataset(e.datasets, 231).load())!.value.single.par, 12);
      expect((await sheetsDataset(e.datasets, 231).load())!.value.single.toJson(), sheet.toJson());
      expect((await mazamaInventoryDataset(e.datasets).load())!.value.name, 'Mazama');
      final status = centerStatusFromBody(e.datasets.read(Dataset.centerStatus, '231')!.body)!;
      expect([status.configured, status.cart.minutes, status.cart.maxUnitsPerLine, status.mazamaLicenses], [true, 60, 9, ['mf-1']]);
      final coa = coaDataFromBody('hb-aaaa0001', e.datasets.read(Dataset.coaData, 'hb-aaaa0001')!.body)!;
      expect([coa.strain, coa.psilocybin, coa.psilocin, coa.tpe], ['GT', 1.25, null, 1.5]);
      expect(e.datasets.read(Dataset.coaData, 'hb-none')!.body, 'null'); // the server has none: stored as such
      expect(coaDataFromBody('hb-none', 'null'), isNull);
    });

    test('a refresher given a key that is not a center fails, recorded, never thrown', () async {
      final e = engine();
      serverReadRefreshers(
        fetchPar: (id) async => levels,
        fetchSheets: (id) async => const [],
        fetchMazamaInventory: () async => throw StateError('unused'),
        fetchCenterStatus: (id) async => throw StateError('unused'),
        fetchCoaData: (lots) async => const {},
      ).forEach(e.register);
      e.datasets.put(Dataset.par, 'x', '[]', source: sourceServer, at: at);
      await e.refresh(Dataset.par, 'x');
      expect(e.datasets.read(Dataset.par, 'x')!.lastError, isNotNull);
    });
  });
}

/// Tables whose first [fails] dataset writes throw, as a full disk would mid-move; [tries] counts the writes asked.
class _FailingDatasetTables extends SyncTables {
  _FailingDatasetTables(super.store, {required this.fails});
  final int fails;
  int tries = 0;

  @override
  void putDataset(String name, String key, String body, {required String source, required DateTime fetchedAt}) {
    if (++tries <= fails) throw StateError('disk full');
    super.putDataset(name, key, body, source: source, fetchedAt: fetchedAt);
  }
}
