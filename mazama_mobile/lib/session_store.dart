// Persists the worker's session (access/refresh token + expiry) across app restarts, so they don't have to type their
// email and password again every time the app is closed. Kept by a SecretStore (secret_store.dart): Keychain/Keystore
// on Android and iOS, never mazama.db or a file there (specs/foundations LS-R4); elsewhere (flutter test, the desktop
// builds) the data folder's `session` document. Builds before that wrote session.json in the data folder: the first
// call moves it into the secret store and deletes it (never renames it: it holds the tokens, LS-R5). The data folder
// itself comes from path_provider (see initAppDataDir below), which is the correct way to ask each platform for this
// app's own sandboxed storage location - plain dart:io has no portable way to answer that on Android/iOS.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'local_store.dart';
import 'secret_store.dart';

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

/// Tests only: points [defaultSessionDataDir] at [dir] (a temp folder), or back to its default with null, so a page or
/// store a test builds with its default stores never touches the real data folder (test/temp_app_data_dir.dart).
@visibleForTesting
void setAppDataDirForTest(Directory? dir) => _cachedAppDataDir = dir;

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

  /// The session's store for a data folder. Defaults to [secretStoreFor]; tests give an in-memory one.
  final SecretStore Function(Directory dir) secrets;

  /// The data folder's non-secret install marker, a LocalStore document (never the tokens). iOS keeps Keychain items
  /// after the app is deleted, where session.json went with the app; mazama.db goes with the app on every platform. So
  /// a folder without the marker is a fresh install (or a set-aside database), and a session kept from before it is not
  /// this install's: it is deleted, and the worker signs in (final review I-2). On the update launch the Keychain is
  /// empty anyway (older builds never wrote it), and session.json is moved after the marker is written.
  static const installMarker = 'session_install';

  /// Opening a folder (the marker, the session.json move) in progress, by folder: concurrent calls share one, so a
  /// save racing the first launch's move can't be overwritten by it (final review M-2).
  static final Map<String, Future<bool>> _opening = {};

  const SessionStore({Directory Function()? dataDir, SecretStore Function(Directory dir)? secrets})
      : dataDir = dataDir ?? defaultSessionDataDir,
        secrets = secrets ?? secretStoreFor;

  /// Saves [session]. When the secret store can't keep it (a locked keychain, a restored Android backup), nothing is
  /// kept and the worker signs in again next launch (LS-R4): never a fallback to a plain file, and no throw. A save
  /// that replaced what the store held writes the [installMarker] too when its opening could not: what is kept is now
  /// this install's, so a later opening must not delete it (re-review N-1).
  Future<void> save(Map<String, Object?> session) async {
    final (store, thisInstalls) = await _open();
    try {
      await store.write(jsonEncode(session));
    } catch (_) {
      return; // nothing kept: see above
    }
    if (thisInstalls) return;
    try {
      _markThisInstall(_localOf(dataDir()));
    } catch (_) {
      // The marker stays unwritten: the next opening deletes this session, and the worker signs in once more.
    }
  }

  /// Null if nothing is stored, or if what's there can't be read back as the JSON this class itself writes (nothing
  /// saved yet, the secret store failing, some future or older format, a session from before this install that could
  /// not be deleted) - either way the caller's correct move is the same as having no stored session at all: fall back
  /// to a real sign-in.
  Future<Map<String, Object?>?> load() async {
    final (store, thisInstalls) = await _open();
    if (!thisInstalls) return null;
    try {
      final text = await store.read();
      if (text == null) return null;
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    final (store, _) = await _open();
    try {
      await store.delete();
    } catch (_) {
      // Nothing could be kept there either, so there is nothing left to forget.
    }
  }

  /// The folder's secret store, and whether what it holds is this install's ([installMarker]), once the folder is
  /// opened: one opening at a time per folder ([_opening]).
  Future<(SecretStore, bool)> _open() async {
    final dir = dataDir();
    final store = secrets(dir);
    final key = dir.absolute.path;
    final opening = _opening[key] ??= _openFolder(dir, store).whenComplete(() {
      _opening.remove(key); // a block, not `=>`: whenComplete would wait on the removed future, i.e. on itself
    });
    return (store, await opening);
  }

  /// A fresh install's folder first loses any session kept from before it ([installMarker]); then an older build's
  /// session.json is moved in (LS-R5): written to the secret store unless one is kept already (it is newer), and the
  /// file deleted whatever happened, readable or not, so the tokens never stay in a plain file. False when a session
  /// from before this install could not be deleted (the secret store failing), or when the marker can't be read at all
  /// (mazama.db busy, read-only or not openable: whose session it is can't be told): it is then never loaded, and the
  /// worker signs in again. Never throws (re-review N-2): main.dart awaits [load] at start-up.
  static Future<bool> _openFolder(Directory dir, SecretStore store) async {
    var thisInstalls = true;
    try {
      final local = _localOf(dir);
      if (local.read(installMarker) == null) {
        await store.delete();
        _markThisInstall(local);
      }
    } catch (_) {
      thisInstalls = false; // tried again on the next call
    }
    final legacy = File('${dir.path}/session.json');
    if (!legacy.existsSync()) return thisInstalls;
    try {
      final decoded = jsonDecode(legacy.readAsStringSync());
      if (thisInstalls && decoded is Map && await store.read() == null) await store.write(jsonEncode(decoded));
    } catch (_) {
      // Unreadable, or the secret store failing: the worker signs in again.
    }
    try {
      legacy.deleteSync();
    } on FileSystemException {
      // Gone already.
    }
    return thisInstalls;
  }

  /// The data folder's LocalStore. By convention used here only for the [installMarker], never the tokens; the code
  /// doesn't enforce that, `test/local_store_guard_test.dart` does.
  static LocalStore _localOf(Directory dir) => LocalStore.forDir(dir);

  static void _markThisInstall(LocalStore local) {
    local.write(installMarker, 'opened by this install; holds no secret');
  }
}
