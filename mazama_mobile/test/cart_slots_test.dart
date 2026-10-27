// specs/multi-cart MC-R2: a center's list of carts and the file it's kept in.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_slots.dart';

void main() {
  group('CartSlots', () {
    test('a center starts with one cart, "Cart 1", showing, under the old single cart\'s id', () {
      final s = CartSlots.initial();
      expect(s.carts.map((c) => c.name), ['Cart 1']);
      expect(s.activeId, defaultCartId);
      expect(s.canRemove, isFalse);
    });

    test('a new cart gets the next free "Cart n", its own id, and shows', () {
      final s = CartSlots.initial().withNew('Cart 2', now: () => DateTime(2026, 10, 22));
      expect(s.carts, hasLength(2));
      expect(s.activeId, s.carts.last.id);
      expect(s.carts.last.id, isNot(defaultCartId));
      expect(isCartId(s.carts.last.id), isTrue);
      expect(s.nextName(), 'Cart 3');
    });

    test('two carts made in the same millisecond still get different ids', () {
      final t = DateTime(2026, 10, 22);
      final s = CartSlots.initial().withNew('A', now: () => t).withNew('B', now: () => t);
      expect(s.carts.map((c) => c.id).toSet(), hasLength(3));
    });

    test('nextName fills the smallest gap', () {
      final s = CartSlots.initial().withNew('Cart 3');
      expect(s.nextName(), 'Cart 2');
    });

    test('names are trimmed, 1 to 30 characters, unique ignoring case', () {
      final s = CartSlots.initial();
      expect(s.nameError('  '), 'Enter a name.');
      expect(s.nameError('x' * 31), isNotNull);
      expect(s.nameError('x' * 30), isNull);
      expect(s.nameError(' cart 1 '), contains('already called'));
      expect(s.nameError('Cart 1', forId: defaultCartId), isNull); // renaming a cart to its own name
      expect(s.withNew('  Room B  ').active.name, 'Room B');
      expect(() => s.withNew('cart 1'), throwsArgumentError);
    });

    test('renaming keeps the id and which cart is showing', () {
      final s = CartSlots.initial().withNew('Cart 2');
      final r = s.renamed(defaultCartId, 'Front desk');
      expect(r.byId(defaultCartId)!.name, 'Front desk');
      expect(r.activeId, s.activeId);
    });

    test('at most $maxCartsPerCenter carts', () {
      var s = CartSlots.initial();
      for (var i = 2; i <= maxCartsPerCenter; i++) {
        s = s.withNew('Cart $i');
      }
      expect(s.canAdd, isFalse);
      expect(() => s.withNew('One more'), throwsStateError);
    });

    test('removing the showing cart shows the one before it (the next one when it was first)', () {
      final s = CartSlots.initial().withNew('Cart 2').withNew('Cart 3');
      final second = s.carts[1].id, third = s.carts[2].id;
      expect(s.removed(third).activeId, second);
      expect(s.withActive(defaultCartId).removed(defaultCartId).activeId, second);
      expect(s.removed(second).activeId, third); // not showing: the showing one stays
    });

    test('the last cart cannot be removed', () {
      expect(() => CartSlots.initial().removed(defaultCartId), throwsStateError);
    });

    test('round-trips through JSON for its own center only', () {
      final s = CartSlots.initial().withNew('Room B');
      final j = jsonDecode(jsonEncode(s.toJson(231)));
      final back = CartSlots.fromJson(j, 231)!;
      expect(back.carts.map((c) => (c.id, c.name)), s.carts.map((c) => (c.id, c.name)));
      expect(back.activeId, s.activeId);
      expect(CartSlots.fromJson(j, 999), isNull);
    });

    test('a list it did not write is not read', () {
      Map<String, Object?> list(Object? carts, Object? active) => {'centerId': 231, 'activeId': active, 'carts': carts};
      expect(CartSlots.fromJson(list([], 'main'), 231), isNull);
      expect(CartSlots.fromJson(list([{'id': 'main', 'name': 'A'}], 'other'), 231), isNull);
      expect(CartSlots.fromJson(list([{'id': '../x', 'name': 'A'}], '../x'), 231), isNull);
      expect(
          CartSlots.fromJson(list([{'id': 'main', 'name': 'A'}, {'id': 'main', 'name': 'B'}], 'main'), 231), isNull);
    });
  });

  test('cartFileName: the first cart keeps the old names, others get their id, a bad id is refused', () {
    expect(cartFileName('cart', defaultCartId), 'cart.json');
    expect(cartFileName('session_timer', 'c12'), 'session_timer_c12.json');
    expect(() => cartFileName('cart', 'a/b'), throwsArgumentError);
  });

  group('CartSlotsStore', () {
    late Directory tempDir;
    setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_slots_test_'));
    tearDown(() => tempDir.deleteSync(recursive: true));

    test('saves and loads one center\'s list; nothing saved, another center or a broken file is null', () async {
      final store = CartSlotsStore(dataDir: () => Directory('${tempDir.path}/nested'));
      expect(await store.load(231), isNull);
      final s = CartSlots.initial().withNew('Room B');
      await store.save(231, s);
      expect((await store.load(231))!.active.name, 'Room B');
      expect(await store.load(232), isNull);
      File('${tempDir.path}/nested/carts.json').writeAsStringSync('{not json');
      expect(await store.load(231), isNull);
    });
  });
}
