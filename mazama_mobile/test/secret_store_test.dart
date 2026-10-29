// secret_store.dart and SessionStore on it (foundations LS-R4, LS-R5): the session's tokens are kept by a SecretStore
// (Keychain/Keystore on the phones, a LocalStore document elsewhere, P-D6), and an older build's session.json is moved
// into it and deleted. The tokens here are invented.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/secret_store.dart';
import 'package:mazama_mobile/session_store.dart';

/// A secret store in memory, as a phone's Keychain/Keystore would be.
class _MemorySecrets implements SecretStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async => value = v;

  @override
  Future<void> delete() async => value = null;
}

/// An in-memory store whose every call takes a few event-loop turns, as a platform channel does.
class _SlowSecrets extends _MemorySecrets {
  Future<void> _turns() async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<String?> read() async {
    await _turns();
    return value;
  }

  @override
  Future<void> write(String v) async {
    await _turns();
    value = v;
  }

  @override
  Future<void> delete() async {
    await _turns();
    value = null;
  }
}

/// A secret store that fails every call, as a locked keychain or a restored Android backup can.
class _ThrowingSecrets implements SecretStore {
  @override
  Future<String?> read() async => throw StateError('keystore unavailable');

  @override
  Future<void> write(String v) async => throw StateError('keystore unavailable');

  @override
  Future<void> delete() async => throw StateError('keystore unavailable');
}

/// An in-memory store whose first [failures] deletes fail, as a keychain still locked after a restart can.
class _DeletesFail extends _MemorySecrets {
  _DeletesFail(this.failures);

  int failures;

  @override
  Future<void> delete() async {
    if (failures > 0) {
      failures--;
      throw StateError('keystore locked');
    }
    await super.delete();
  }
}

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_secret_store_test_'));
  tearDown(() {
    LocalStore.debugCloseAll();
    tempDir.deleteSync(recursive: true);
  });

  const session = {'email': 'worker@example.com', 'access_token': 'INVENTED-A', 'refresh_token': 'INVENTED-R', 'expires_at_ms': 123};

  File legacyFile() => File('${tempDir.path}/session.json');

  test('a session.json from an older build is moved into the secret store and the file deleted', () async {
    legacyFile().writeAsStringSync(jsonEncode(session));
    final secrets = _MemorySecrets();
    final store = SessionStore(dataDir: () => tempDir, secrets: (_) => secrets);

    expect(await store.load(), session);
    expect(jsonDecode(secrets.value!), session);
    expect(legacyFile().existsSync(), isFalse);
    expect(File('${legacyFile().path}.migrated').existsSync(), isFalse, reason: 'deleted, never renamed: it holds a secret');
    expect(LocalStore.forDir(tempDir).read('session'), isNull, reason: 'never a document when a secret store is given');
    expect(await store.load(), session, reason: 'and read from the secret store from then on');
  });

  test('a corrupt session.json is deleted and loads as no session', () async {
    legacyFile().writeAsStringSync('not json{{{');
    final secrets = _MemorySecrets();
    final store = SessionStore(dataDir: () => tempDir, secrets: (_) => secrets);

    expect(await store.load(), isNull);
    expect(legacyFile().existsSync(), isFalse);
    expect(secrets.value, isNull);
  });

  test('a session kept in the secret store wins over a session.json left behind', () async {
    final secrets = _MemorySecrets();
    final store = SessionStore(dataDir: () => tempDir, secrets: (_) => secrets);
    await store.load(); // this install has opened its folder before
    secrets.value = jsonEncode({'access_token': 'NEWER', 'expires_at_ms': 2});
    legacyFile().writeAsStringSync(jsonEncode(session));

    expect(await store.load(), {'access_token': 'NEWER', 'expires_at_ms': 2});
    expect(legacyFile().existsSync(), isFalse);
  });

  // Final review I-2: iOS keeps Keychain items after the app is deleted; session.json went with the app. A reinstalled
  // app (or a phone passed to another worker after a reinstall) must not sign in as the previous worker.
  test('a reinstalled app does not sign in as the previous worker', () async {
    final secrets = _MemorySecrets()..value = jsonEncode(session); // what the deleted install left in the Keychain
    final store = SessionStore(dataDir: () => tempDir, secrets: (_) => secrets); // a fresh, empty data folder

    expect(await store.load(), isNull);
    expect(secrets.value, isNull, reason: 'the previous install\'s session is deleted');
    await store.save({'access_token': 'THIS-INSTALL', 'expires_at_ms': 3});
    expect(await SessionStore(dataDir: () => tempDir, secrets: (_) => secrets).load(),
        {'access_token': 'THIS-INSTALL', 'expires_at_ms': 3}, reason: 'kept once this install has opened its folder');
    expect(LocalStore.forDir(tempDir).read(SessionStore.installMarker)!.body, isNot(contains('THIS-INSTALL')));
  });

  test('the update launch keeps the session.json it moves (the install marker is written first)', () async {
    legacyFile().writeAsStringSync(jsonEncode(session));
    final secrets = _MemorySecrets();
    expect(await SessionStore(dataDir: () => tempDir, secrets: (_) => secrets).load(), session);
  });

  // Final review M-2: a load and a save racing while session.json is still there must not bring the old session back.
  test('a save racing the first launch\'s move of session.json wins', () async {
    legacyFile().writeAsStringSync(jsonEncode(session));
    final secrets = _SlowSecrets();
    final store = SessionStore(dataDir: () => tempDir, secrets: (_) => secrets);
    final loading = store.load();
    final saving = store.save({'access_token': 'RENEWED', 'expires_at_ms': 9});
    await Future.wait([loading, saving]);
    expect(await store.load(), {'access_token': 'RENEWED', 'expires_at_ms': 9});
  });

  test('clear removes a session.json left behind too', () async {
    legacyFile().writeAsStringSync(jsonEncode(session));
    final secrets = _MemorySecrets();
    await SessionStore(dataDir: () => tempDir, secrets: (_) => secrets).clear();
    expect(legacyFile().existsSync(), isFalse);
    expect(secrets.value, isNull);
  });

  test('a failing secret store loads no session and saves nothing elsewhere', () async {
    final store = SessionStore(dataDir: () => tempDir, secrets: (_) => _ThrowingSecrets());

    await store.save(session); // no throw: nothing is kept, the worker signs in again next launch (LS-R4)
    expect(await store.load(), isNull);
    await store.clear();
    expect(legacyFile().existsSync(), isFalse);
    expect(LocalStore.forDir(tempDir).read('session'), isNull);
    expect([for (final e in tempDir.listSync()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)],
        everyElement(startsWith(localStoreFileName)),
        reason: 'no file of its own: only the database, if anything opened it');
  });

  // Re-review N-1: a delete that failed once left the marker unwritten, so the next launch's successful delete wiped the
  // session the worker had signed into in between.
  test('a session saved after a failed delete of the previous one is kept, and the previous one never loads', () async {
    // What a deleted install left in the Keychain; the deletes of the load's and the save's opening both fail.
    final secrets = _DeletesFail(2)..value = jsonEncode(session);
    final store = SessionStore(dataDir: () => tempDir, secrets: (_) => secrets);

    expect(await store.load(), isNull, reason: 'the previous install\'s session could not be deleted: never loaded');
    await store.save({'access_token': 'THIS-INSTALL', 'expires_at_ms': 4}); // the worker signs in
    LocalStore.debugCloseAll(); // a restart; the keychain answers now
    expect(await SessionStore(dataDir: () => tempDir, secrets: (_) => secrets).load(),
        {'access_token': 'THIS-INSTALL', 'expires_at_ms': 4}, reason: 'the session this install saved is not wiped');
  });

  test('after a failed delete the previous install\'s session still never loads, until this install saves one', () async {
    final secrets = _DeletesFail(1)..value = jsonEncode(session);
    expect(await SessionStore(dataDir: () => tempDir, secrets: (_) => secrets).load(), isNull);
    expect(await SessionStore(dataDir: () => tempDir, secrets: (_) => secrets).load(), isNull);
    expect(secrets.value, isNull, reason: 'deleted once the keychain answers');
  });

  // Re-review N-2: a database SQLite can't open (busy, read-only, not openable) made load() throw at start-up.
  test('a database that cannot be opened loads no session, and nothing throws or falls back to a file', () async {
    Directory('${tempDir.path}/$localStoreFileName').createSync(); // SQLite answers CANTOPEN (14), not damage
    legacyFile().writeAsStringSync(jsonEncode(session));
    final secrets = _MemorySecrets()..value = jsonEncode({'access_token': 'BEFORE-THIS-INSTALL', 'expires_at_ms': 1});
    final store = SessionStore(dataDir: () => tempDir, secrets: (_) => secrets);

    expect(await store.load(), isNull, reason: 'whose session it is can\'t be told: the worker signs in again');
    expect(legacyFile().existsSync(), isFalse, reason: 'the tokens never stay in a plain file');
    await store.save({'access_token': 'THIS-INSTALL', 'expires_at_ms': 5});
    await store.clear();
    expect([for (final e in tempDir.listSync()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)], [localStoreFileName],
        reason: 'no file of its own');
  });

  test('a failing secret store still deletes an older build\'s session.json', () async {
    legacyFile().writeAsStringSync(jsonEncode(session));
    final store = SessionStore(dataDir: () => tempDir, secrets: (_) => _ThrowingSecrets());
    expect(await store.load(), isNull);
    expect(legacyFile().existsSync(), isFalse);
  });

  test('on an iPhone the session is readable after the first unlock, as session.json was, and stays on the device', () {
    expect(PlatformSecretStore.defaultStorage.iOptions.accessibility, KeychainAccessibility.first_unlock_this_device);
    expect(PlatformSecretStore.defaultStorage.iOptions.synchronizable, isFalse);
  });

  test('off the phones the session is the session document', () async {
    final secrets = DocumentSecretStore(tempDir);
    expect(await secrets.read(), isNull);
    await secrets.write('INVENTED');
    expect(LocalStore.forDir(tempDir).read(DocumentSecretStore.documentName)!.body, 'INVENTED');
    expect(await DocumentSecretStore(tempDir).read(), 'INVENTED');
    await secrets.delete();
    expect(await secrets.read(), isNull);

    // And it is what this host (flutter test runs on Linux or macOS) gets by default.
    expect(secretStoreFor(tempDir), isA<DocumentSecretStore>());
    final store = SessionStore(dataDir: () => tempDir);
    await store.save(session);
    expect(jsonDecode(LocalStore.forDir(tempDir).read(DocumentSecretStore.documentName)!.body), session);
    expect(legacyFile().existsSync(), isFalse);
  });
}
