// sync/dataset_feed.dart and the engine's refreshing/refreshError (specs/phone-sync Task 8b Step 2): a page reading a
// dataset through the engine joins the refresh under way (the center home's on open) rather than asking a second, asks
// one itself when none runs, and shows the stored copy, or the error (nothing stored, or the server's own answer).
// Fake clock, timers and refreshers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/sheets_client.dart';
import 'package:mazama_mobile/stock_mix.dart';
import 'package:mazama_mobile/sync/dataset_feed.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/sync_engine.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';

import '../fake_timers.dart';

const _mix = MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [MixCell(strain: 'Golden Teacher', type: 'DH', mg: 3000)]);

void main() {
  final engines = <SyncEngine>[];
  late Directory dir;
  late FakeTimers timers;
  late ServerHealth health;
  final now = DateTime.utc(2026, 11, 1, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mazama_dataset_feed_test_');
    timers = FakeTimers();
    health = ServerHealth(probe: () async => false, startTimer: timers.start);
  });
  tearDown(() {
    for (final e in engines) {
      e.dispose();
    }
    engines.clear();
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
    engines.add(e); // disposed in tearDown, before the store is closed
    return e;
  }

  test('read joins the refresh under way rather than asking a second', () async {
    final e = engine();
    final gate = Completer<void>();
    var calls = 0;
    e.register(Dataset.mazamaInventory, (key) async {
      calls++;
      await gate.future;
      return (body: jsonEncode(_mix.toJson()), source: sourceServer);
    });
    expect(e.refreshes(Dataset.mazamaInventory), isTrue);
    expect(e.refreshes(Dataset.par), isFalse);
    expect(e.refreshing(Dataset.mazamaInventory, ''), isNull);

    unawaited(e.refresh(Dataset.mazamaInventory, '')); // the center home's, on open
    expect(e.refreshing(Dataset.mazamaInventory, ''), isNotNull);
    final read = mazamaInventoryFeed(e).read(); // the page's, as it is built
    gate.complete();
    expect(await read, isNull);
    await pumpEventQueue();
    expect(calls, 1);
    expect(e.refreshing(Dataset.mazamaInventory, ''), isNull);
    expect(mazamaInventoryFeed(e).decode(e.datasets.read(Dataset.mazamaInventory, '')!)!.cells.single.mg, 3000);
  });

  test('read asks a refresh when none runs, and answers with its error; a success clears it', () async {
    final e = engine();
    Object? fail = SheetsError('No such center.');
    var calls = 0;
    e.register(Dataset.sheets, (key) async {
      calls++;
      if (fail != null) throw fail;
      return (body: '[]', source: sourceServer);
    });
    final feed = sheetsFeed(e, 231);
    expect('${await feed.read()}', 'No such center.');
    expect(calls, 1);
    expect('${e.refreshError(Dataset.sheets, '231')}', 'No such center.');
    fail = null;
    expect(await feed.read(), isNull);
    expect(calls, 2);
    expect(e.refreshError(Dataset.sheets, '231'), isNull);
  });

  test("a refresh's outcome is noted before the watchers are told", () async {
    final e = engine();
    e.datasets.put(Dataset.sheets, '231', '[]', source: sourceServer, at: now.subtract(const Duration(hours: 1)));
    var fail = true;
    e.register(Dataset.sheets, (key) async {
      if (fail) throw SheetsError('No such center.');
      return (body: '[]', source: sourceServer);
    });
    final seen = <String?>[];
    final sub = e.watch(Dataset.sheets, '231').listen((_) => seen.add('${e.refreshError(Dataset.sheets, '231')}'));
    addTearDown(sub.cancel);
    await pumpEventQueue();
    await e.refresh(Dataset.sheets, '231');
    await pumpEventQueue();
    fail = false;
    await e.refresh(Dataset.sheets, '231');
    await pumpEventQueue();
    expect(seen, ['null', 'No such center.', 'null']); // stored, the failure recorded, the fresh copy
  });

  group('shows', () {
    final feed = DatasetFeed<MazamaInventory>(
      watch: () => const Stream.empty(),
      running: () => null,
      refresh: () async {},
      lastError: () => null,
      decode: mazamaInventoryFromJson,
    );
    final at = DateTime.utc(2026, 10, 31, 9);
    final row = DatasetRow(
        name: 'mazama_inventory', key: '', body: jsonEncode(_mix.toJson()), source: sourceServer, fetchedAt: at);

    test('the copy with its time, also while the server can\'t be reached', () {
      final ok = feed.shows(row, null);
      expect(ok.value!.cells.single.mg, 3000);
      expect(ok.at, at);
      expect(ok.error, isNull);
      expect(ok.note, isNull);
      expect(ok.fromCache, isFalse);
      final unreachable = feed.shows(row, MazamaInventoryError("Mazama's server can't be reached", unreachable: true));
      expect(unreachable.value, isNotNull);
      expect(unreachable.error, isNull);
      expect(unreachable.note, isNull); // R87: the banner says so, not the page
      expect(unreachable.fromCache, isTrue); // the page's rows reload when the server answers again
    });

    test("the server's own answer is a note beside the copy; with nothing stored, the error", () {
      // a refresh the engine makes by itself (every five minutes, the server back) answering 401 or 429 never takes
      // away the copy the worker is looking at
      final refused = feed.shows(row, MazamaInventoryError('Too many requests.'));
      expect(refused.value!.cells.single.mg, 3000);
      expect(refused.at, at);
      expect(refused.error, isNull);
      expect('${refused.note}', 'Too many requests.');
      expect(refused.fromCache, isFalse);
      expect(feed.shows(null, MazamaInventoryError('No manufacturer.')).error, isNotNull);
      final none = feed.shows(null, MazamaInventoryError("Mazama's server can't be reached", unreachable: true));
      expect(none.value, isNull);
      expect('${none.error}', "Mazama's server can't be reached");
    });

    test('before the read on open has ended, the stored copy (or nothing) whatever an earlier refresh said', () {
      final early = feed.shows(row, MazamaInventoryError('No manufacturer.'), settled: false);
      expect(early.value, isNotNull);
      expect(early.error, isNull);
      expect(early.note, isNull);
      final nothing = feed.shows(null, MazamaInventoryError('No manufacturer.'), settled: false);
      expect(nothing.value, isNull);
      expect(nothing.error, isNull); // the spinner
    });

    test('a copy moved in without a time has none; a damaged copy is an error once settled', () {
      final epoch = DatasetRow(
          name: 'mazama_inventory',
          key: '',
          body: row.body,
          source: sourceServer,
          fetchedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
      expect(feed.shows(epoch, null).at, isNull);
      final damaged =
          DatasetRow(name: 'mazama_inventory', key: '', body: '{"nope"', source: sourceServer, fetchedAt: at);
      expect(feed.shows(damaged, null).value, isNull);
      expect(feed.shows(damaged, null).error, isNotNull);
    });
  });
}
