// CartStore itself has no Flutter dependency (plain dart:io, like SessionStore), but lives under test/
// alongside everything else in this app - same reasoning as session_store_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_slots.dart' show cartFileName, defaultCartId;
import 'package:mazama_mobile/cart_store.dart';
import 'package:mazama_mobile/local_store.dart';
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

  test('a damaged document reads back as null, not a crash', () async {
    LocalStore.forDir(Directory('${tempDir.path}/nested')).write('cart.json', 'not json{{{');
    expect(await store().load(231), isNull);
  });

  test('a line missing a required field reads back as null for the whole cart, not a partial list', () async {
    LocalStore.forDir(Directory('${tempDir.path}/nested')).write(
        'cart.json', '{"centerId": 231, "lines": [{"lots": [{"productGuid": "PKPR-x"}], "qty": 1}]}'); // no priceCentsEach, no dose
    expect(await store().load(231), isNull);
  });

  test('two independent stores pointed at different directories do not see each other\'s data', () async {
    final a = CartStore(dataDir: () => Directory('${tempDir.path}/a'));
    final b = CartStore(dataDir: () => Directory('${tempDir.path}/b'));
    await a.save(231, [line]);
    expect(await b.load(231), isNull);
  });

  // A draft nobody has changed for the cart's life (rules.yaml cart.minutes, or the server's live value) is
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
      // The same draft without its time, as a draft saved before drafts carried one.
      final saved = LocalStore.forDir(Directory('${tempDir.path}/nested')).read('cart.json')!.body;
      final old = jsonDecode(saved) as Map<String, Object?>..remove('savedAtMs');
      final olderBuild = Directory('${tempDir.path}/older');
      LocalStore.forDir(olderBuild).write('cart.json', jsonEncode(old));
      expect(
          await CartStore(dataDir: () => olderBuild)
              .load(231, maxAge: const Duration(minutes: 1), now: () => t0.add(const Duration(days: 30))),
          hasLength(1));
    });
  });

  group('several carts (specs/multi-cart MC-R1)', () {
    test('each cart id keeps its own lines; the first cart is the old cart.json', () async {
      final s = store();
      await s.save(231, [line]);
      await s.save(231, [line, line.withQty(5)], cartId: 'c2');
      expect(await s.load(231), hasLength(1));
      expect(await s.load(231, cartId: 'c2'), hasLength(2));
      expect(File('${tempDir.path}/nested/cart.json').existsSync(), isFalse, reason: 'kept in the database, not a file');
      expect(LocalStore.forDir(Directory('${tempDir.path}/nested')).read('cart.json'), isNotNull);
      expect(LocalStore.forDir(Directory('${tempDir.path}/nested')).read('cart_c2.json'), isNotNull);
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

  group('SALE-12 (specs/core row 7): a lot keeps its sale values as received', () {
    test('a whole-number weight from the server stays a whole number through a saved draft', () async {
      final lot = Package.fromJson({'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'id': 101, 'weightPerUnit': 1,
          'analyteWeight': 7, 'quantity': 10});
      expect(lot.toSaleItem(), {'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'id': 101, 'weightPerUnit': 1, 'analyteWeight': 7});
      expect(lot.toSaleItem()['weightPerUnit'], isA<int>());
      final s = store();
      await s.save(231, [CartLine(group: PkprGroup([lot]), qty: 1, priceCentsEach: 100)]);
      final item = (await s.load(231))!.single.group.lots.single.toSaleItem();
      expect(item['weightPerUnit'], isA<int>());
      expect(item, {'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'id': 101, 'weightPerUnit': 1, 'analyteWeight': 7});
    });

    test('a value the state didn\'t send stays missing, so the core refuses the sale instead of sending "" or 0', () {
      final lot = Package.fromJson({'productGuid': 'PKPR-ab12c', 'id': 101, 'weightPerUnit': 0.5, 'quantity': 10});
      expect(lot.toSaleItem(), {'productGuid': 'PKPR-ab12c', 'id': 101, 'weightPerUnit': 0.5});
      expect(lot.productType, ''); // what the screens show is unchanged
    });

    test("an older build's draft, saved before lots kept their sale values, still comes back and sells as saved", () async {
      final dir = Directory('${tempDir.path}/nested')..createSync(recursive: true);
      LocalStore.forDir(dir).write(cartFileName('cart', defaultCartId), jsonEncode({
        'centerId': 231,
        'lines': [
          {
            'lots': [
              {'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'id': 101, 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
                'strain': '', 'tpeMg': 0, 'quantity': 10, 'coaAvailable': true, 'labelAvailable': true, 'mazama': false,
                'expired': false, 'unitMgTpe': null, 'description': ''},
            ],
            'qty': 2,
            'priceCentsEach': 1250,
            'dose': 'initial',
          },
        ],
      }));
      final restored = await store().load(231);
      expect(restored, hasLength(1));
      expect(restored!.single.group.lots.single.toSaleItem(),
          {'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'id': 101, 'weightPerUnit': 5.0, 'analyteWeight': 4.5});
    });
  });
}
