// Persists the in-progress cart (lines not yet sold) across app restarts, so a worker whose app gets killed
// mid-shopping - low battery, OS memory pressure, a crash - doesn't silently lose everything they'd already
// typed in. Kept as one JSON document per cart in the data folder's LocalStore (local_store.dart; the document has the
// name the file had, cart.json), in the folder session_store.dart's defaultSessionDataDir gives (and, through it, the
// path_provider-resolved directory initAppDataDir caches at startup).
//
// Deliberately scoped to that one failure mode. This never touches a sale once it's in flight with the state
// system: cart_page.dart's _sell doesn't persist here mid-sale, and a sale whose outcome is genuinely unknown
// (see sale_outcome.dart/classifySaleFailure) is never retried from here or anywhere else in this app - this
// only ever protects lines that haven't been sent yet, and is cleared the moment they either are sent or the
// worker deliberately discards them (see cart_page.dart's _onSellPressed/_confirmDiscardCart).
//
// Reads/writes below are synchronous LocalStore calls (once *Sync dart:io calls), not async ones, even though every
// method here is still `Future`-shaped (so nothing calling these has to change). A draft is a few KB at most, so
// blocking briefly costs nothing noticeable - and it sidesteps a real deadlock seen with the async file calls: cart_page.dart's _persistCart() fires
// save() off unawaited every time a line is added, so by the time a quick add-then-sell reaches clear(), an
// async writeAsString() to this exact path can still be in flight. Async File ops funnel through dart:io's
// single-worker _IOService, so a delete() queued behind a write() that never gets a chance to finish waits on
// it forever - and under flutter_test's fake-clock test binding, that write's own completion callback is
// exactly the kind of real (non-Timer) async event that pumpAndSettle's pumping never reliably drives forward,
// so it doesn't just run late, it can hang the test indefinitely (confirmed: forcing a timeout on the delete
// was the only way to get it to surface at all). Sync calls have no such queue to get stuck behind.
import 'dart:convert';
import 'dart:io';

import 'cart_page.dart' show CartLine;
import 'cart_slots.dart' show cartFileName, defaultCartId;
import 'local_store.dart';
import 'session_store.dart' show defaultSessionDataDir;

class CartStore {
  /// Overridable for tests, so a test never reads or writes the real app-data directory - same pattern as
  /// SessionStore.dataDir. Defaults to the same directory SessionStore itself uses: one file per kind of data
  /// in a shared per-app folder, not a separate folder per file.
  final Directory Function() dataDir;

  const CartStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  LocalStore get _store => LocalStore.forDir(dataDir());

  /// One document per cart (specs/multi-cart MC-D2): the first cart keeps cart.json, so a draft saved before there
  /// were several carts comes back as the first one.
  String _name(String cartId) => cartFileName('cart', cartId);

  /// Overwrites whatever draft was saved before, including with an empty list - a cart that's been emptied out
  /// (every line removed by hand, short of an actual sale or discard) is itself real state worth persisting
  /// exactly as the worker left it, not silently dropped back to "nothing saved".
  ///
  /// Saving stamps the draft with [now], so [load] can tell how long nobody has changed it (SM-16).
  Future<void> save(int centerId, List<CartLine> lines,
      {DateTime Function() now = DateTime.now, String cartId = defaultCartId}) async {
    final name = _name(cartId); // an id that isn't a cart id throws here, before anything is written
    _store.write(name, jsonEncode({
      'centerId': centerId,
      'savedAtMs': now().millisecondsSinceEpoch,
      'lines': lines.map((l) => l.toJson()).toList(),
    }));
  }

  /// Null if nothing is stored, what's there can't be read back (no file, a partial write from a crash mid-
  /// save, a future/older format, a line that doesn't round-trip through CartLine.fromJson), or - most often -
  /// what's stored belongs to a different service center than [centerId]: a draft cart from one center has no
  /// business reappearing at another one, even on the same device, so that's treated exactly like "nothing
  /// saved" rather than surfaced as an error the worker has to deal with.
  ///
  /// With [maxAge] (the cart's life, SM-16: the server empties a cart nobody has changed for that long), a draft
  /// saved longer ago than that is not restored either. A draft saved before drafts carried a time is restored.
  Future<List<CartLine>?> load(int centerId,
      {Duration? maxAge, DateTime Function() now = DateTime.now, String cartId = defaultCartId}) async {
    try {
      final name = _name(cartId);
      final text = _store.read(name)?.body;
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      if ((decoded['centerId'] as num?)?.toInt() != centerId) return null;
      final savedAtMs = decoded['savedAtMs'];
      if (maxAge != null && savedAtMs is int && now().millisecondsSinceEpoch - savedAtMs > maxAge.inMilliseconds) return null;
      final rawLines = decoded['lines'];
      if (rawLines is! List) return null;
      final lines = <CartLine>[];
      for (final rawLine in rawLines) {
        if (rawLine is! Map) return null;
        final line = CartLine.fromJson(Map<String, Object?>.from(rawLine));
        if (line == null) return null;
        lines.add(line);
      }
      return lines;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> clear({String cartId = defaultCartId}) async {
    final name = _name(cartId);
    _store.delete(name); // already gone (or never saved) is exactly the state this call is meant to produce
  }
}
