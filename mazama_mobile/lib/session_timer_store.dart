// Persists the cart's own session stopwatch (cart_page.dart's _sessionTimerRow) across app restarts, so a
// worker whose app gets force-closed or killed by the OS mid-administration-session doesn't lose track of
// when it actually started - same reasoning, and the same JSON documents in the folder's LocalStore, as
// cart_store.dart. Scoped to a service center the same way CartStore scopes the draft
// cart: a timer started at one center has no business resuming at another, even on the same device.
import 'dart:convert';
import 'dart:io';

import 'cart_slots.dart' show cartFileName, defaultCartId;
import 'local_store.dart';
import 'session_store.dart' show defaultSessionDataDir;

class SessionTimerStore {
  /// Overridable for tests, so a test never reads or writes the real app-data directory - same pattern as
  /// CartStore.dataDir/SessionStore.dataDir. Defaults to that same shared per-app directory.
  final Directory Function() dataDir;

  const SessionTimerStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  LocalStore get _store => LocalStore.forDir(dataDir());

  /// One timer per cart (specs/multi-cart MC-D4): the first cart keeps session_timer.json, as CartStore keeps
  /// cart.json.
  String _name(String cartId) => cartFileName('session_timer', cartId);

  /// Overwrites whatever was saved before. [start] is the wall-clock moment "Start Timer" was tapped
  /// (widget.now() at that moment, not necessarily the real clock - see cart_page.dart's _startSessionTimer),
  /// stored as milliseconds since epoch so it round-trips exactly through JSON.
  Future<void> save(int centerId, DateTime start, {String cartId = defaultCartId}) async {
    final name = _name(cartId);
    _store.write(name, jsonEncode({'centerId': centerId, 'startMillis': start.millisecondsSinceEpoch}));
  }

  /// Null if nothing is stored, what's there can't be read back (no file, a partial write from a crash
  /// mid-save, a future/older format), or - same as CartStore.load - what's stored belongs to a different
  /// service center than [centerId]: a timer started at one center has no business resuming at another.
  Future<DateTime?> load(int centerId, {String cartId = defaultCartId}) async {
    try {
      final text = _store.read(_name(cartId))?.body;
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      if ((decoded['centerId'] as num?)?.toInt() != centerId) return null;
      final millis = (decoded['startMillis'] as num?)?.toInt();
      if (millis == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Called both when the worker taps "Reset" by hand and when the timer auto-resets for having run past
  /// sessionTimerMaxAge - either way, nothing should be left to resume from next launch. Also forgets the cart's
  /// sold dose ([saveSoldDose]): a reset timer is the end of that client's session. Both go in one transaction;
  /// nothing saved is exactly the state this call is meant to produce.
  Future<void> clear({String cartId = defaultCartId}) async {
    final timer = _name(cartId), dose = _doseName(cartId);
    final store = _store;
    store.transaction(() {
      store.delete(timer);
      store.delete(dose);
    });
  }

  String _doseName(String cartId) => cartFileName('session_dose', cartId);

  /// What a cart just sold, for timing its client's session once the sold cart is empty (specs/multi-cart MC-D14):
  /// [psilocybinMg], raw mg psilocybin with every dose, and whether any of it was a secondary dose ([booster]).
  /// Overwrites whatever that cart sold before; forgotten by [clear].
  Future<void> saveSoldDose(int centerId, double psilocybinMg,
      {required bool booster, String cartId = defaultCartId, DateTime Function() now = DateTime.now}) async {
    final name = _doseName(cartId);
    _store.write(name, jsonEncode({
      'centerId': centerId,
      'psilocybinMg': psilocybinMg,
      'booster': booster,
      'savedAtMs': now().millisecondsSinceEpoch,
    }));
  }

  /// The dose [saveSoldDose] last kept for the cart, or null: nothing kept, unreadable, another center's, or kept
  /// longer ago than [maxAge] (a session can't still be running then).
  Future<({double psilocybinMg, bool booster})?> loadSoldDose(int centerId,
      {String cartId = defaultCartId, Duration? maxAge, DateTime Function() now = DateTime.now}) async {
    try {
      final text = _store.read(_doseName(cartId))?.body;
      if (text == null) return null;
      final d = jsonDecode(text);
      if (d is! Map || (d['centerId'] as num?)?.toInt() != centerId) return null;
      final mg = d['psilocybinMg'], booster = d['booster'], savedAt = d['savedAtMs'];
      if (mg is! num || booster is! bool || savedAt is! int) return null;
      if (maxAge != null && now().millisecondsSinceEpoch - savedAt > maxAge.inMilliseconds) return null;
      return (psilocybinMg: mg.toDouble(), booster: booster);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
