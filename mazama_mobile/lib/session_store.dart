// Persists the worker's session (access/refresh token + expiry) across app restarts, so they don't have to
// type their email and password again every time the app is closed. A single JSON file under this app's own
// data directory, written with dart:io directly rather than through a plugin like flutter_secure_storage -
// deferred as a hardening follow-up (Keystore/Keychain-backed encryption), not a blocker for a first sideloaded
// test build. The directory itself now comes from path_provider (see initAppDataDir below), which is the
// correct way to ask each platform for this app's own sandboxed storage location - plain dart:io has no
// portable way to answer that on Android/iOS.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Set once at app startup by [initAppDataDir], before anything else in the app touches a *Store class.
/// [defaultSessionDataDir] reads this if it's been set, so every store (session/cart/device-id) ends up
/// pointed at the same real, per-app, writable directory on every platform - without any of their
/// `dataDir: Directory Function()` fields needing to become async, which would otherwise ripple into every
/// test file that currently passes a synchronous fake (e.g. `dataDir: () => _tempDir`).
Directory? _cachedAppDataDir;

/// Resolves and caches this app's real data directory via path_provider. Call this once, early in `main()`,
/// before `runApp()` - see main.dart. Safe to call more than once (e.g. in a test harness); each call just
/// re-resolves and overwrites the cache. Until this has been called, [defaultSessionDataDir] falls back to
/// the hand-derived guess below, so desktop runs and any code path that forgets to call this still work, just
/// without the guarantee path_provider gives on a real device.
Future<void> initAppDataDir() async {
  _cachedAppDataDir = await getApplicationSupportDirectory();
}

/// Where the session file's directory is: the real, path_provider-resolved directory cached by
/// [initAppDataDir] once that's run (true on Android and iOS, and also on desktop once main.dart's startup
/// call completes), or - if nothing has called that yet - a hand-derived guess:
/// - Linux: $XDG_DATA_HOME/mazama_mobile, or ~/.local/share/mazama_mobile if XDG_DATA_HOME isn't set - the
///   standard the Linux desktop build (the one actually tested so far, via Xvfb) follows.
/// - macOS: ~/Library/Application Support/mazama_mobile.
/// - Windows: %APPDATA%\mazama_mobile.
/// - Android/iOS: dart:io alone has no portable way to find this app's own sandboxed storage directory, so
///   without [initAppDataDir] having run first this falls back to a plain relative path under the process's
///   current working directory, which on a real phone is not guaranteed to be writable or private to this
///   app. In practice this branch should never be hit on a real device - main.dart calls [initAppDataDir]
///   before anything else - this is just the honest fallback if that's ever skipped (e.g. a future entry
///   point that forgets to).
Directory defaultSessionDataDir() {
  final cached = _cachedAppDataDir;
  if (cached != null) return cached;
  if (Platform.isLinux) {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : '${Platform.environment['HOME'] ?? '.'}/.local/share';
    return Directory('$base/mazama_mobile');
  }
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '.';
    return Directory('$home/Library/Application Support/mazama_mobile');
  }
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ?? '.';
    return Directory('$appData\\mazama_mobile');
  }
  return Directory('mazama_mobile_data'); // Android/iOS stopgap if initAppDataDir was never called - see above.
}

class SessionStore {
  /// Overridable for tests, so a test never reads or writes the real app-data directory - same injectable-
  /// function pattern as CartPage's fetchPackages. Defaults to [defaultSessionDataDir].
  final Directory Function() dataDir;

  const SessionStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  File get _file => File('${dataDir().path}/session.json');

  // *Sync calls below, not the async dart:io ones, even though every method stays Future-shaped - see
  // cart_store.dart's file comment for why: a real async write/delete race on the same path can deadlock
  // inside flutter_test's fake-clock test binding, and these files are small enough that blocking briefly
  // costs nothing.
  Future<void> save(Map<String, Object?> session) async {
    dataDir().createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode(session));
  }

  /// Null if nothing is stored, or if what's there can't be read back as the JSON this class itself writes (no
  /// file yet, a partial write from a crash mid-save, some future or older format) - either way the caller's
  /// correct move is the same as having no stored session at all: fall back to a real sign-in.
  Future<Map<String, Object?>?> load() async {
    try {
      final text = _file.readAsStringSync();
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      _file.deleteSync();
    } on FileSystemException {
      // Already gone (or never existed) - exactly the state this call is meant to produce, so that's fine.
    }
  }
}
