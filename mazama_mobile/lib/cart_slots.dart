// Several carts at one center (specs/multi-cart): which carts a center has, what each is called, and which one the
// Cart screen is showing. Each cart's lines and timer are kept by CartStore/SessionTimerStore under the cart's id
// (cartFileName, the name of each one's document); this file keeps only the list itself, as the carts.json document
// beside them, scoped to a center the same way the cart draft is (a list saved at another center is never shown here).
//
// The same synchronous LocalStore calls as cart_store.dart (see its file comment for why).
import 'dart:convert';
import 'dart:io';

import 'local_store.dart';
import 'session_store.dart' show defaultSessionDataDir;

/// The first cart's id. Its files keep the names the single cart always had (cart.json, session_timer.json), so a
/// draft saved before there were several carts comes back as the first cart (MC-D2).
const defaultCartId = 'main';

/// MC-D3: how many carts one center may have at once.
const maxCartsPerCenter = 10;

/// MC-D3: the longest a cart's name may be, after trimming.
const maxCartNameLength = 30;

/// A cart id is only ever made by [CartSlots.withNew]: lower-case letters and digits, so it is safe in a file name.
final _cartIdPattern = RegExp(r'^[a-z0-9]{1,24}$');

bool isCartId(String id) => _cartIdPattern.hasMatch(id);

/// The file a cart's [kind] of data ('cart', 'session_timer') is kept in: `<kind>.json` for the first cart,
/// `<kind>_<id>.json` for any other. Throws on an id [isCartId] refuses, so nothing outside the data folder is
/// ever named.
String cartFileName(String kind, String cartId) {
  if (!isCartId(cartId)) throw ArgumentError.value(cartId, 'cartId', 'not a cart id');
  return cartId == defaultCartId ? '$kind.json' : '${kind}_$cartId.json';
}

class CartSlot {
  final String id;
  final String name;

  const CartSlot({required this.id, required this.name});

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  /// Null for anything this class didn't write.
  static CartSlot? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    if (id is! String || name is! String || !isCartId(id) || name.trim().isEmpty) return null;
    return CartSlot(id: id, name: name);
  }
}

/// A center's carts, in the order they were made, and which one is showing. Never empty; [activeId] is always one
/// of [carts]. Every change returns a new value; nothing here touches a file.
class CartSlots {
  final List<CartSlot> carts;
  final String activeId;

  CartSlots._(List<CartSlot> carts, this.activeId) : carts = List.unmodifiable(carts);

  /// What a center with nothing saved has: the first cart, showing.
  factory CartSlots.initial() => CartSlots._(const [CartSlot(id: defaultCartId, name: 'Cart 1')], defaultCartId);

  CartSlot get active => carts.firstWhere((c) => c.id == activeId);

  bool get canAdd => carts.length < maxCartsPerCenter;

  /// MC-D5: the last cart can't be deleted.
  bool get canRemove => carts.length > 1;

  CartSlot? byId(String id) {
    for (final c in carts) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// "Cart n" for the smallest n from 1 up that no cart is called yet.
  String nextName() {
    final taken = {for (final c in carts) c.name.trim().toLowerCase()};
    var n = 1;
    while (taken.contains('cart $n')) {
      n++;
    }
    return 'Cart $n';
  }

  /// Why [name] can't be the name of cart [forId] (null: a new cart), or null when it can (MC-D3).
  String? nameError(String name, {String? forId}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Enter a name.';
    if (trimmed.length > maxCartNameLength) return 'At most $maxCartNameLength characters.';
    final clash = carts.any((c) => c.id != forId && c.name.trim().toLowerCase() == trimmed.toLowerCase());
    return clash ? 'Another cart is already called "$trimmed".' : null;
  }

  /// A new cart called [name] (trimmed), showing. [now] only makes its id; two carts made in the same millisecond
  /// still get different ids. Throws when [canAdd] is false or [name] has a [nameError].
  CartSlots withNew(String name, {DateTime Function() now = DateTime.now}) {
    if (!canAdd) throw StateError('at most $maxCartsPerCenter carts');
    final why = nameError(name);
    if (why != null) throw ArgumentError.value(name, 'name', why);
    final base = 'c${now().millisecondsSinceEpoch.toRadixString(36)}';
    var id = base;
    for (var i = 2; byId(id) != null || id == defaultCartId; i++) {
      id = '$base$i';
    }
    return CartSlots._([...carts, CartSlot(id: id, name: name.trim())], id);
  }

  /// Throws when [id] isn't a cart here or [name] has a [nameError].
  CartSlots renamed(String id, String name) {
    if (byId(id) == null) throw ArgumentError.value(id, 'id', 'no such cart');
    final why = nameError(name, forId: id);
    if (why != null) throw ArgumentError.value(name, 'name', why);
    return CartSlots._([for (final c in carts) c.id == id ? CartSlot(id: id, name: name.trim()) : c], activeId);
  }

  /// Without cart [id]. When it was showing, the cart before it shows (the next one when it was first). Throws when
  /// [canRemove] is false or [id] isn't a cart here.
  CartSlots removed(String id) {
    final i = carts.indexWhere((c) => c.id == id);
    if (i == -1) throw ArgumentError.value(id, 'id', 'no such cart');
    if (!canRemove) throw StateError('the last cart cannot be removed');
    final rest = [...carts]..removeAt(i);
    final active = id != activeId ? activeId : rest[i == 0 ? 0 : i - 1].id;
    return CartSlots._(rest, active);
  }

  /// Showing cart [id] instead. Throws when it isn't a cart here.
  CartSlots withActive(String id) {
    if (byId(id) == null) throw ArgumentError.value(id, 'id', 'no such cart');
    return CartSlots._(carts, id);
  }

  Map<String, Object?> toJson(int centerId) =>
      {'centerId': centerId, 'activeId': activeId, 'carts': [for (final c in carts) c.toJson()]};

  /// Null for anything that isn't a list this class wrote for [centerId]: another center's, no carts, a bad cart, two
  /// carts with one id, or a showing cart that isn't in the list.
  static CartSlots? fromJson(Object? j, int centerId) {
    if (j is! Map || (j['centerId'] as num?)?.toInt() != centerId) return null;
    final raw = j['carts'], activeId = j['activeId'];
    if (raw is! List || raw.isEmpty || raw.length > maxCartsPerCenter || activeId is! String) return null;
    final carts = <CartSlot>[];
    for (final r in raw) {
      final c = CartSlot.fromJson(r);
      if (c == null || carts.any((o) => o.id == c.id)) return null;
      carts.add(c);
    }
    if (!carts.any((c) => c.id == activeId)) return null;
    return CartSlots._(carts, activeId);
  }
}

/// Keeps a center's [CartSlots] as the carts.json document of the folder's LocalStore. Overridable directory for
/// tests, as CartStore's.
class CartSlotsStore {
  final Directory Function() dataDir;

  const CartSlotsStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  static const _name = 'carts.json';

  Future<void> save(int centerId, CartSlots slots) async {
    LocalStore.forDir(dataDir()).write(_name, jsonEncode(slots.toJson(centerId)));
  }

  /// Null when nothing readable is saved for [centerId] (the caller starts from [CartSlots.initial]).
  Future<CartSlots?> load(int centerId) async {
    try {
      final text = LocalStore.forDir(dataDir()).read(_name)?.body;
      return text == null ? null : CartSlots.fromJson(jsonDecode(text), centerId);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
