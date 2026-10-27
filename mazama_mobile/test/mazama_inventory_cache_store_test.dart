// The last Mazama stock the server sent, kept on the phone with when (lib/mazama_inventory_cache_store.dart), for the
// Mazama inventory page while Mazama's server can't be reached.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  test('a damaged file counts as nothing kept', () async {
    File('${_dir.path}/mazama_inventory_cache.json').writeAsStringSync('{not json');
    expect(await store().load(), isNull);
    File('${_dir.path}/mazama_inventory_cache.json').writeAsStringSync('{"atMs": 1, "inventory": {"cells": 3}}');
    expect(await store().load(), isNull);
    File('${_dir.path}/mazama_inventory_cache.json').writeAsStringSync('[]');
    expect(await store().load(), isNull);
  });
}
