// SessionStore itself has no Flutter dependency (it's plain dart:io), but it lives under test/ alongside
// everything else in this app rather than a separate package, and flutter_test's `test` function works fine
// for a widget-free unit test like this one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/session_store.dart';

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_session_store_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  // Nested one level down from tempDir, so `save` is also proving it creates the directory itself
  // (`create(recursive: true)`) rather than assuming it already exists.
  SessionStore store() => SessionStore(dataDir: () => Directory('${tempDir.path}/nested'));

  test('load returns null when nothing has been saved yet', () async {
    expect(await store().load(), isNull);
  });

  test('save then load round-trips the exact map given, including a null value', () async {
    final s = store();
    await s.save({'access_token': 'A', 'refresh_token': null, 'expires_at_ms': 123});
    expect(await s.load(), {'access_token': 'A', 'refresh_token': null, 'expires_at_ms': 123});
  });

  test('a second save overwrites the first, not appends', () async {
    final s = store();
    await s.save({'access_token': 'OLD', 'expires_at_ms': 1});
    await s.save({'access_token': 'NEW', 'expires_at_ms': 2});
    expect(await s.load(), {'access_token': 'NEW', 'expires_at_ms': 2});
  });

  test('clear removes a saved session, and is a no-op if nothing was ever saved', () async {
    final s = store();
    await s.save({'access_token': 'A', 'expires_at_ms': 1});
    await s.clear();
    expect(await s.load(), isNull);
    await s.clear(); // must not throw even though there is nothing left to delete
  });

  // session.json is only ever an older build's file now (its tokens move to the secret store on the first load), so it
  // is written before the store first opens the folder (plan P-D5).
  test('a corrupted file on disk reads back as null, not a crash', () async {
    await Directory('${tempDir.path}/nested').create(recursive: true);
    await File('${tempDir.path}/nested/session.json').writeAsString('not json{{{');
    expect(await store().load(), isNull);
    expect(File('${tempDir.path}/nested/session.json').existsSync(), isFalse);
  });

  test('two independent stores pointed at different directories do not see each other\'s data', () async {
    final a = SessionStore(dataDir: () => Directory('${tempDir.path}/a'));
    final b = SessionStore(dataDir: () => Directory('${tempDir.path}/b'));
    await a.save({'access_token': 'ONLY-A', 'expires_at_ms': 1});
    expect(await b.load(), isNull);
  });
}
