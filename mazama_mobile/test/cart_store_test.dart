// CartStore itself has no Flutter dependency (plain dart:io, like SessionStore), but lives under test/
// alongside everything else in this app - same reasoning as session_store_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/cart_page.dart' show CartLine;

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_store_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  // Nested one level down from tempDir, so `save` is also proving it creates the directory itself
  // (`create(recursive: true)`) rather than assuming it already exists - same reasoning as session_store_test.
  CartStore store() => CartStore(dataDir: () => Directory('${tempDir.path}/nested'));

  final line = CartLine(
    group: PkprGroup(
        [Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 10)]),
    qty: 2,
    priceCentsEach: 1250,
  );

  test('load returns null when nothing has been saved yet', () async {
    expect(await store().load(231), isNull);
  });

  test('save then load round-trips every field of every line exactly', () async {
    final s = store();
    await s.save(231, [line]);
    final restored = await s.load(231);
    expect(restored, hasLength(1));
    expect(restored!.single.productGuid, 'PKPR-ab12c');
    expect(restored.single.productType, 'Extract');
    expect(restored.single.group.lots.single.id, 101);
    expect(restored.single.group.lots.single.weightPerUnit, 5.0);
    expect(restored.single.group.analyteWeight, 4.5);
    expect(restored.single.group.lots.single.quantity, 10);
    expect(restored.single.qty, 2);
    expect(restored.single.priceCentsEach, 1250);
    expect(restored.single.dose, 'initial'); // doseInitial - the default this line never overrode
  });

  test('a line spanning multiple lots round-trips every lot, sorted smallest quantity first', () async {
    final multiLot = CartLine(
      group: PkprGroup([
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 105, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 10),
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 4),
      ]),
      qty: 6,
      priceCentsEach: 1250,
    );
    final s = store();
    await s.save(231, [multiLot]);
    final restored = await s.load(231);
    expect(restored!.single.group.lots.map((l) => l.id), [101, 105]); // re-sorted ascending by quantity on restore, not insertion order
    expect(restored.single.group.quantity, 14); // 10 + 4, summed across both lots
  });

  test('a saved empty cart round-trips as an empty list, not as "nothing saved"', () async {
    final s = store();
    await s.save(231, [line]);
    await s.save(231, []); // the worker removed the only line, rather than discarding the whole cart
    expect(await s.load(231), isEmpty);
  });

  test('a second save overwrites the first, not appends', () async {
    final s = store();
    await s.save(231, [line]);
    await s.save(231, [line.withQty(5)]);
    final restored = await s.load(231);
    expect(restored, hasLength(1));
    expect(restored!.single.qty, 5);
  });

  test('a cart saved for one center is not returned when loading for a different center', () async {
    final s = store();
    await s.save(231, [line]);
    expect(await s.load(999), isNull);
  });

  test('clear removes a saved cart, and is a no-op if nothing was ever saved', () async {
    final s = store();
    await s.save(231, [line]);
    await s.clear();
    expect(await s.load(231), isNull);
    await s.clear(); // must not throw even though there is nothing left to delete
  });

  test('a corrupted file on disk reads back as null, not a crash', () async {
    final s = store();
    await s.save(231, [line]); // creates the directory for us
    await File('${tempDir.path}/nested/cart.json').writeAsString('not json{{{');
    expect(await s.load(231), isNull);
  });

  test('a line missing a required field reads back as null for the whole cart, not a partial list', () async {
    final s = store();
    await Directory('${tempDir.path}/nested').create(recursive: true);
    await File('${tempDir.path}/nested/cart.json').writeAsString(
        '{"centerId": 231, "lines": [{"lots": [{"productGuid": "PKPR-x"}], "qty": 1}]}'); // no priceCentsEach, no dose
    expect(await s.load(231), isNull);
  });

  test('two independent stores pointed at different directories do not see each other\'s data', () async {
    final a = CartStore(dataDir: () => Directory('${tempDir.path}/a'));
    final b = CartStore(dataDir: () => Directory('${tempDir.path}/b'));
    await a.save(231, [line]);
    expect(await b.load(231), isNull);
  });

  // SM-16: a draft nobody has changed for the cart's life (rules.yaml cart.minutes, or the server's live value) is
  // not restored, as the server empties a cart nobody has changed for that long.
  group('cart life', () {
    final t0 = DateTime.utc(2026, 10, 21, 9);
    test('a draft saved within maxAge is restored, an older one is not', () async {
      final s = store();
      await s.save(231, [line], now: () => t0);
      expect(await s.load(231, maxAge: const Duration(minutes: 1080), now: () => t0.add(const Duration(minutes: 1079))), hasLength(1));
      expect(await s.load(231, maxAge: const Duration(minutes: 1080), now: () => t0.add(const Duration(minutes: 1081))), isNull);
    });

    test('without maxAge, and for a draft saved before drafts carried a time, nothing expires', () async {
      final s = store();
      await s.save(231, [line], now: () => t0);
      expect(await s.load(231, now: () => t0.add(const Duration(days: 30))), hasLength(1));
      final f = File('${tempDir.path}/nested/cart.json');
      final old = jsonDecode(f.readAsStringSync()) as Map<String, Object?>..remove('savedAtMs');
      f.writeAsStringSync(jsonEncode(old));
      expect(await s.load(231, maxAge: const Duration(minutes: 1), now: () => t0.add(const Duration(days: 30))), hasLength(1));
    });
  });

  group('several carts (specs/multi-cart MC-R1)', () {
    test('each cart id keeps its own lines; the first cart is the old cart.json', () async {
      final s = store();
      await s.save(231, [line]);
      await s.save(231, [line, line.withQty(5)], cartId: 'c2');
      expect(await s.load(231), hasLength(1));
      expect(await s.load(231, cartId: 'c2'), hasLength(2));
      expect(File('${tempDir.path}/nested/cart.json').existsSync(), isTrue);
      expect(File('${tempDir.path}/nested/cart_c2.json').existsSync(), isTrue);
    });

    test('clearing one cart leaves the others', () async {
      final s = store();
      await s.save(231, [line]);
      await s.save(231, [line], cartId: 'c2');
      await s.clear(cartId: 'c2');
      expect(await s.load(231, cartId: 'c2'), isNull);
      expect(await s.load(231), hasLength(1));
    });

    test('an id that is not a cart id is refused, never used as a file name', () async {
      await expectLater(store().save(231, [line], cartId: '../x'), throwsArgumentError);
    });
  });
}
