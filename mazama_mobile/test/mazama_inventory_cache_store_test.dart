// The last Mazama stock the server sent, kept on the phone with when (lib/mazama_inventory_cache_store.dart), for the
// Mazama inventory page while Mazama's server can't be reached.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/mazama_inventory_cache_store.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/stock_mix.dart';

late Directory _dir;

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_inventory_cache_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

  MazamaInventoryCacheStore store() => MazamaInventoryCacheStore(dataDir: () => _dir);

  test('nothing kept is null', () async {
    expect(await store().load(), isNull);
  });

  test('a mix round-trips with its time, across a fresh store (an app restart)', () async {
    final at = DateTime.utc(2026, 10, 21, 9, 30);
    await store().save(
        const MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [
          MixCell(strain: 'Golden Teacher', type: 'DH', mg: 3888),
        ], lots: [
          MazamaLot(strain: 'Golden Teacher', lot: 'HB-aaaa0001', tpe: 8.64, detected: ['baeocystin'], path: '/p/lots/mazama/HB-aaaa0001', types: ['DH']),
        ]),
        at);

    final kept = await MazamaInventoryCacheStore(dataDir: () => _dir).load();
    expect(kept!.fromCache, isTrue);
    expect(kept.cachedAt, at);
    expect(kept.value.name, 'Mazama Mushrooms LLC');
    expect(kept.value.cells.single.toJson(), {'strain': 'Golden Teacher', 'type': 'DH', 'mg': 3888});
    expect(kept.value.lots.single.toJson(), {
      'strain': 'Golden Teacher',
      'lot': 'HB-aaaa0001',
      'tpe': 8.64,
      'psilocybin': null,
      'psilocin': null,
      'detected': ['baeocystin'],
      'types': ['DH'],
      'path': '/p/lots/mazama/HB-aaaa0001'
    });
  });

  // Each body as an older build's file in a fresh folder, imported when the store first opens it (plan P-D5).
  test('a damaged file counts as nothing kept', () async {
    for (final (i, body) in ['{not json', '{"atMs": 1, "inventory": {"cells": 3}}', '[]'].indexed) {
      final dir = Directory('${_dir.path}/older$i')..createSync();
      File('${dir.path}/mazama_inventory_cache.json').writeAsStringSync(body);
      expect(await MazamaInventoryCacheStore(dataDir: () => dir).load(), isNull, reason: body);
    }
  });

  test('kept in the database, not in a file', () async {
    await store().save(const MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [], lots: []), DateTime.utc(2026, 10, 21));
    expect(File('${_dir.path}/mazama_inventory_cache.json').existsSync(), isFalse);
    expect(LocalStore.forDir(_dir).read('mazama_inventory_cache.json'), isNotNull);
  });
}
