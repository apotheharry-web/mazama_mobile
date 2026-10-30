// specs/app-updates AU-R12, AU-R14: the phone's update record (app_update_store.dart), in its LocalStore. Release
// files are signed with the TEST key (app_release_signing.dart), injected as the store's key.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/app_update_store.dart';
import 'package:mazama_mobile/local_store.dart';

import 'app_release_signing.dart';

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_app_update_store_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  AppUpdateStore store({String? key}) =>
      AppUpdateStore(dataDir: () => Directory('${tempDir.path}/data'), publicKey: key ?? testPublicKey);

  test('nothing kept: no record, nothing refused', () async {
    expect(await store().seen(), isNull);
    expect(await store().refused(), isEmpty);
  });

  test('the record moves only on a verified APK: only recordVerified writes it, and only upwards', () async {
    final s = store();
    final older = await signedRelease(build: 26102901);
    final newer = await signedRelease(build: 26103001, version: '0.2.5');
    await s.refused(); // reading never writes
    await s.seen();
    expect(LocalStore.forDir(Directory('${tempDir.path}/data')).read('app_release_seen'), isNull);
    await s.recordVerified(newer);
    expect((await s.seen())?.build, 26103001);
    await s.recordVerified(older); // a lower build never replaces it
    expect((await s.seen())?.build, 26103001);
    expect((await s.seen())?.text, newer.text);
  });

  test('a record that no longer verifies counts as none', () async {
    await store().recordVerified(await signedRelease(build: 26103001));
    expect(await store(key: otherPublicKey).seen(), isNull);
    expect((await store().seen())?.build, 26103001);
  });

  test('a corrupt document counts as none', () async {
    final local = LocalStore.forDir(Directory('${tempDir.path}/data'));
    for (final body in ['not json', '[]', '{"text": 1, "signature": "x"}', '{"text": "{}", "signature": "x"}']) {
      local.write('app_release_seen', body);
      expect(await store().seen(), isNull, reason: body);
    }
    local.write('app_release_refused', 'not json');
    expect(await store().refused(), isEmpty);
  });

  test('refused builds are kept', () async {
    await store().refuse(26103001);
    await store().refuse(26102901);
    await store().refuse(26103001);
    expect(await store().refused(), {26102901, 26103001});
  });
}
