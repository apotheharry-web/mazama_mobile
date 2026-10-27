// An identifier for this app INSTALL, not the physical hardware - a random token generated the first time this
// file is read and persisted next to session.json/cart.json (see session_store.dart/cart_store.dart for the
// same dart:io-direct pattern and why a plugin like device_info_plus isn't used instead: iOS doesn't expose a
// true device id anyway - Apple only gives an app a vendor identifier that itself resets on reinstall, no
// better than what this file already does on its own).
//
// Sent alongside the worker's own email on every call to Mazama's own server (sale_log_client.dart,
// sale_failure_client.dart) - never to the state system itself, which has no use for it. The point is a trust
// signal for a human reviewing a queued sale failure (see mazama_sales' audit.confirmed_sale_count and the
// /sale-review page): a worker+device combination with a real history of confirmed sales is more likely to be
// a genuine worker caught by an outage than a first-time or spoofed request. It is NOT an identity or security
// control on its own - it resets on reinstall, several workers can share one device (a center's shared
// tablet), and nothing here stops a different value being sent. It only has to be stable across ordinary app
// use to be useful for that one purpose.
import 'dart:io';
import 'dart:math';

import 'session_store.dart' show defaultSessionDataDir;

String _randomId() {
  final rnd = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

class DeviceIdStore {
  /// Overridable for tests, so a test never reads or writes the real app-data directory - same pattern as
  /// SessionStore.dataDir/CartStore.dataDir. Defaults to the same directory those two use.
  final Directory Function() dataDir;

  const DeviceIdStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  File get _file => File('${dataDir().path}/device_id.txt');

  /// Returns the id already on disk, or generates one, saves it, and returns that - either way, the same value
  /// every time this is called again on this install, until the app is reinstalled or its data cleared. A
  /// corrupt or empty file is treated as "nothing saved yet" (same fallback SessionStore.load/CartStore.load
  /// use for their own corrupt-file case) rather than an error: a fresh id is just as usable as the one that
  /// was lost, since this was never meant to survive a reinstall anyway.
  // *Sync calls below, not the async dart:io ones - see cart_store.dart's file comment for why: a real async
  // write/read race on the same path can deadlock inside flutter_test's fake-clock test binding, and this file
  // is tiny, so blocking briefly costs nothing.
  Future<String> idOrCreate() async {
    try {
      final existing = _file.readAsStringSync().trim();
      if (existing.isNotEmpty) return existing;
    } on FileSystemException {
      // Nothing saved yet - fall through to generating one.
    }
    final id = _randomId();
    dataDir().createSync(recursive: true);
    _file.writeAsStringSync(id);
    return id;
  }

  /// Debug-only escape hatch (see debug_local_storage_page.dart) for simulating a fresh install without
  /// actually reinstalling: deletes whatever id is on disk and generates+saves a new one, same as a real
  /// first run would. Every real call site wants the STABLE id (idOrCreate above) - this exists purely so a
  /// developer can deliberately force a new one to watch install-scoped behavior (the audit trail's own
  /// worker+device trust signal, sale_log_client.dart's own file comment) reset.
  Future<String> reset() async {
    try {
      _file.deleteSync();
    } on FileSystemException {
      // Nothing to delete - fine, idOrCreate below still generates a fresh one.
    }
    return idOrCreate();
  }
}
