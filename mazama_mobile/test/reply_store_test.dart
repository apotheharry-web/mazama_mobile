// reply_store.dart: the last good reply of each read from Mazama's server (README R56), keyed by route and parameters,
// with when, and the three reads moved onto it (par levels, sheets, Mazama's stock) reading an older build's copy once.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/mazama_inventory_cache_store.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/par_client.dart';
import 'package:mazama_mobile/reply_store.dart';
import 'package:mazama_mobile/sheets_client.dart';
import 'package:mazama_mobile/stock_cache_store.dart';
import 'package:mazama_mobile/stock_summary.dart';

late Directory _dir;

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_reply_store_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

  ReplyStore store() => ReplyStore(dataDir: () => _dir);
  final at = DateTime.utc(2026, 10, 21, 9, 30);

  test('keys: the route and its parameters', () {
    expect(replyKey('par', [231]), 'par/231');
    expect(replyKey('mazama_inventory'), 'mazama_inventory');
  });

  test('round trip: a reply kept with when, read back by another instance; keys listed', () {
    store().save('par/231', [1, 2], at);
    final kept = ReplyStore(dataDir: () => _dir).load('par/231')!;
    expect(kept.value, [1, 2]);
    expect(kept.at, at);
    expect(store().load('par/183'), isNull);
    store().save('mazama_inventory', {'a': 1}, at);
    expect(store().keys(), ['mazama_inventory', 'par/231']);
  });

  test('read: a reply is kept; unreachable, the kept one with its time; a 4xx is still an error', () async {
    final fresh = await store().read<List<int>>('x/1',
        fetch: () async => [1], encode: (v) => v, decode: (j) => List<int>.from(j as List), now: () => at);
    expect([fresh.value, fresh.fromCache], [[1], false]);
    final offline = await store().read<List<int>>('x/1',
        fetch: () async => throw ParError('cannot reach', unreachable: true),
        encode: (v) => v,
        decode: (j) => List<int>.from(j as List));
    expect([offline.value, offline.fromCache, offline.cachedAt], [[1], true, at]);
    await expectLater(
        store().read<List<int>>('x/1',
            fetch: () async => throw ParError('No such service center.'), encode: (v) => v, decode: (j) => List<int>.from(j as List)),
        throwsA(isA<ParError>()));
    await expectLater(
        store().read<List<int>>('x/2',
            fetch: () async => throw ParError('down', unreachable: true), encode: (v) => v, decode: (j) => List<int>.from(j as List)),
        throwsA(isA<ParError>()));
  });

  // As an older build's file, written before the store first opens the folder (imported then; plan P-D5).
  test('a damaged file counts as nothing kept', () async {
    Directory('${_dir.path}/server_replies').createSync();
    File('${_dir.path}/server_replies/${Uri.encodeComponent('par/231')}.json').writeAsStringSync('{"atMs": "x"');
    expect(store().load('par/231'), isNull);
  });

  test('kept in the database, not in files; keys come back decoded and sorted', () async {
    store().save('par/231', [1], at);
    store().save('packages/231', [2], at);
    expect(Directory('${_dir.path}/server_replies').existsSync(), isFalse);
    expect(LocalStore.forDir(_dir).read('server_replies/${Uri.encodeComponent('par/231')}.json'), isNotNull);
    expect(store().keys(), ['packages/231', 'par/231']);
  });

  group('the reads moved here', () {
    const levels = [ParLevel(strain: 'Golden Teacher', size: 25, par: 12)];

    test('par: kept and read back', () async {
      final kept = parReplies(store(), 231);
      await kept.save(levels, at);
      final read = (await parReplies(store(), 231).load())!;
      expect([for (final l in read.value) l.toJson()], [for (final l in levels) l.toJson()]);
      expect(read.cachedAt, at);
    });

    test("par: an older build's copy is read once and moved here", () async {
      final legacy = StockCacheStore(dataDir: () => _dir);
      await legacy.savePar(231, levels, at: at);
      final read = (await parReplies(store(), 231, legacy: legacy).load())!;
      expect(read.value.single.par, 12);
      expect(read.cachedAt, at);
      expect(store().load('par/231')!.at, at); // moved
      expect((await parReplies(store(), 183, legacy: legacy).load()), isNull);
    });

    test("sheets: an older build's copy is read once and moved here", () async {
      final legacy = StockCacheStore(dataDir: () => _dir);
      final sheet = ProductSheet.fromJson(const {
        'guid': 'HB-aaaa0001', 'name': 'GT', 'product': 'Dried', 'tested': '2026-09-01', 'path': '/p/lots/m/HB-aaaa0001',
        'strains': ['Golden Teacher'],
      });
      await legacy.saveSheets(231, [sheet], at: at);
      final read = (await sheetsReplies(store(), 231, legacy: legacy).load())!;
      expect(read.value.single.toJson(), sheet.toJson());
      expect(store().load('sheets/231'), isNotNull);
    });

    test("Mazama's stock: an older build's copy is read once and moved here; then kept here", () async {
      final legacy = MazamaInventoryCacheStore(dataDir: () => _dir);
      final inv = MazamaInventory.fromJson(const {'name': 'Mazama', 'cells': [], 'lots': []});
      await legacy.save(inv, at);
      final read = (await mazamaInventoryReplies(store(), legacy: legacy).load())!;
      expect(read.value.name, 'Mazama');
      expect(read.cachedAt, at);
      final later = at.add(const Duration(days: 1));
      await mazamaInventoryReplies(store()).save(inv, later);
      expect((await mazamaInventoryReplies(store(), legacy: legacy).load())!.cachedAt, later);
    });
  });
}
