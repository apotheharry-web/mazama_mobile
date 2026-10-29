// Where the worker's session (access token, refresh token, expiry) is kept (specs/foundations LS-R4): on Android and
// iOS in the platform's own secure storage (Keystore / Keychain, through flutter_secure_storage), never in mazama.db
// or any file. Elsewhere - flutter test on a Linux or macOS host, the checked-in desktop builds - there is no such
// storage, and the session is the `session` document of the data folder's LocalStore (plan P-D6).
//
// Asynchronous, unlike LocalStore: flutter_secure_storage is, and SessionStore's methods were Futures already.
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_store.dart';

/// One secret: the session's JSON text.
abstract class SecretStore {
  /// The kept text, or null when nothing is kept.
  Future<String?> read();

  /// Replaces what is kept with [value].
  Future<void> write(String value);

  /// Forgets what is kept; nothing kept is fine.
  Future<void> delete();
}

/// The phones' store: Keychain (iOS) / Keystore (Android). Never touches the database or a file.
class PlatformSecretStore implements SecretStore {
  const PlatformSecretStore([this._storage = defaultStorage]);

  /// The key the session is kept under.
  static const key = 'mazama.session';

  /// On iOS readable from the first unlock after a restart until the next restart, as session.json was under iOS's
  /// default file protection (so the app's work after a server outage still finds it), and kept on this device only:
  /// never synced to iCloud Keychain or restored onto another phone.
  static const defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: key);

  @override
  Future<void> write(String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: key);
}

/// Off the phones: the [documentName] document of [dir]'s LocalStore (P-D6).
class DocumentSecretStore implements SecretStore {
  const DocumentSecretStore(this.dir);

  static const documentName = 'session';

  final Directory dir;

  @override
  Future<String?> read() async => LocalStore.forDir(dir).read(documentName)?.body;

  @override
  Future<void> write(String value) async => LocalStore.forDir(dir).write(documentName, value);

  @override
  Future<void> delete() async => LocalStore.forDir(dir).delete(documentName);
}

/// The session's store for the data folder [dir]: secure storage on Android and iOS, the folder's `session` document
/// anywhere else.
SecretStore secretStoreFor(Directory dir) =>
    Platform.isAndroid || Platform.isIOS ? const PlatformSecretStore() : DocumentSecretStore(dir);
