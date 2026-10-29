// InventoryCacheStore itself has no Flutter dependency (plain dart:io, like SessionStore/CartStore), but lives
// under test/ alongside everything else in this app - same reasoning as cart_store_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/inventory_cache_store.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/packages_client.dart';

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_inventory_cache_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  // Nested one level down from tempDir, so `save` is also proving it creates the directory itself
  // (`create(recursive: true)`) rather than assuming it already exists - same reasoning as cart_store_test.
  InventoryCacheStore store() => InventoryCacheStore(dataDir: () => Directory('${tempDir.path}/nested'));

  final packages = [
    Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5, strain: 'Golden Teacher', tpeMg: 5, quantity: 10),
    Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0, strain: 'Enigma', tpeMg: 90, quantity: 3),
  ];
  final fetchedAt = DateTime.utc(2026, 10, 18, 12, 0);

  test('load returns null when nothing has been saved yet', () async {
    expect(await store().load(231), isNull);
  });

  test('save then load round-trips every package field and the timestamp exactly', () async {
    final s = store();
    await s.save(231, packages, fetchedAt);
    final restored = await s.load(231);
    expect(restored, isNotNull);
    expect(restored!.fetchedAt, fetchedAt);
    expect(restored.packages, hasLength(2));
    expect(restored.packages[0].productGuid, 'PKPR-ab12c');
    expect(restored.packages[0].strain, 'Golden Teacher');
    expect(restored.packages[0].tpeMg, 5);
    expect(restored.packages[1].quantity, 3);
  });

  test('a second save overwrites the first, not appends', () async {
    final s = store();
    await s.save(231, packages, fetchedAt);
    await s.save(231, [packages.first], fetchedAt.add(const Duration(hours: 1)));
    final restored = await s.load(231);
    expect(restored!.packages, hasLength(1));
    expect(restored.fetchedAt, fetchedAt.add(const Duration(hours: 1)));
  });

  test('a cache saved for one center is not returned when loading for a different center', () async {
    final s = store();
    await s.save(231, packages, fetchedAt);
    expect(await s.load(999), isNull);
  });

  test('clear removes a saved cache, and is a no-op if nothing was ever saved', () async {
    final s = store();
    await s.save(231, packages, fetchedAt);
    await s.clear();
    expect(await s.load(231), isNull);
    await s.clear(); // must not throw even though there is nothing left to delete
  });

  // An older build's file is imported when the store first opens the folder (local_store_import.dart), so these write
  // it before the store is first used there (plan P-D5).
  test('a corrupted file on disk reads back as null, not a crash', () async {
    await Directory('${tempDir.path}/nested').create(recursive: true);
    await File('${tempDir.path}/nested/inventory_cache.json').writeAsString('not json{{{');
    expect(await store().load(231), isNull);
  });

  test('a file missing a required field reads back as null, not a partial result', () async {
    await Directory('${tempDir.path}/nested').create(recursive: true);
    await File('${tempDir.path}/nested/inventory_cache.json').writeAsString('{"centerId": 231, "packages": []}'); // no fetchedAtMs
    expect(await store().load(231), isNull);
  });

  test('kept in the database, not in a file', () async {
    await store().save(231, packages, fetchedAt);
    expect(File('${tempDir.path}/nested/inventory_cache.json').existsSync(), isFalse);
    expect(LocalStore.forDir(Directory('${tempDir.path}/nested')).read('inventory_cache.json'), isNotNull);
  });

  test('two independent stores pointed at different directories do not see each other\'s data', () async {
    final a = InventoryCacheStore(dataDir: () => Directory('${tempDir.path}/a'));
    final b = InventoryCacheStore(dataDir: () => Directory('${tempDir.path}/b'));
    await a.save(231, packages, fetchedAt);
    expect(await b.load(231), isNull);
  });
}
