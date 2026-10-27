// DeviceIdStore itself has no Flutter dependency (plain dart:io, like SessionStore/CartStore), but lives under
// test/ alongside everything else in this app - same reasoning as cart_store_test.dart/session_store_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/device_id.dart';

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_device_id_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  // Nested one level down from tempDir, so idOrCreate is also proving it creates the directory itself
  // (`create(recursive: true)`) rather than assuming it already exists - same reasoning as the other stores.
  DeviceIdStore store() => DeviceIdStore(dataDir: () => Directory('${tempDir.path}/nested'));

  test('generates an id when nothing has been saved yet, and it is not empty', () async {
    final id = await store().idOrCreate();
    expect(id, isNotEmpty);
  });

  test('a second call on the same store returns the exact same id it already generated', () async {
    final s = store();
    final first = await s.idOrCreate();
    final second = await s.idOrCreate();
    expect(second, first);
  });

  test('a fresh store pointed at a directory that already has one picks up the saved id, not a new one', () async {
    final first = await store().idOrCreate();
    final again = await store().idOrCreate(); // a distinct DeviceIdStore instance, same directory
    expect(again, first);
  });

  test('two independent stores pointed at different directories never generate the same id', () async {
    final a = DeviceIdStore(dataDir: () => Directory('${tempDir.path}/a'));
    final b = DeviceIdStore(dataDir: () => Directory('${tempDir.path}/b'));
    final idA = await a.idOrCreate();
    final idB = await b.idOrCreate();
    expect(idA, isNot(idB));
  });

  test('an empty file on disk is treated as nothing saved yet, not an error, and a fresh id is written', () async {
    final s = store();
    await Directory('${tempDir.path}/nested').create(recursive: true);
    await File('${tempDir.path}/nested/device_id.txt').writeAsString('');
    final id = await s.idOrCreate();
    expect(id, isNotEmpty);
    // The fresh id was actually persisted - a later store reading the same directory sees it too.
    expect(await store().idOrCreate(), id);
  });

  test('whitespace-only content on disk is also treated as nothing saved yet', () async {
    final s = store();
    await Directory('${tempDir.path}/nested').create(recursive: true);
    await File('${tempDir.path}/nested/device_id.txt').writeAsString('   \n');
    final id = await s.idOrCreate();
    expect(id, isNotEmpty);
  });
}
