// The move from the stores' old files into LocalStore (foundations LS-R5): every legacy file is imported, each in its
// own transaction, before LocalStore.forDir returns, and renamed *.migrated only once its import committed. All
// content here is invented.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/local_store_import.dart';

/// One sample file per pattern in legacyDocumentPatterns.
const _samples = <String>[
  'cart.json',
  'cart_c2.json',
  'carts.json',
  'session_timer.json',
  'session_timer_c2.json',
  'session_dose.json',
  'session_dose_c2.json',
  'device_id.txt',
  'inventory_cache.json',
  'enrichment.json',
  'stock_cache_231.json',
  'mazama_inventory_cache.json',
  'server_outbox.json',
  'server_catch_up.json',
  'coa_sent.json',
  'server_health.json',
  'server_replies/par%2F231.json',
];

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_local_store_import_test_'));
  tearDown(() {
    debugBeforeLegacyImportWrite = null;
    debugRenameLegacyFile = null;
    LocalStore.debugCloseAll();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File legacy(String name) => File('${tempDir.path}/$name')..parent.createSync(recursive: true);

  test('every pattern has a sample here, and each sample matches its pattern', () {
    expect(_samples, hasLength(legacyDocumentPatterns.length));
    for (final name in _samples) {
      expect(isLegacyDocumentName(name), isTrue, reason: name);
    }
  });

  test('an open imports every legacy file before the first read', () {
    final modified = DateTime.utc(2026, 9, 3, 8, 15);
    for (final name in _samples) {
      legacy(name)
        ..writeAsStringSync('{"invented":"$name"}')
        ..setLastModifiedSync(modified);
    }

    final store = LocalStore.forDir(tempDir);
    for (final name in _samples) {
      final read = store.read(name);
      expect(read?.body, '{"invented":"$name"}', reason: name);
      expect(read!.savedAt.millisecondsSinceEpoch ~/ 1000, modified.millisecondsSinceEpoch ~/ 1000, reason: name);
      expect(File('${tempDir.path}/$name').existsSync(), isFalse, reason: name);
      expect(File('${tempDir.path}/$name.migrated').existsSync(), isTrue, reason: name);
    }
  });

  test('corrupt text is imported as it is', () {
    legacy('cart.json').writeAsStringSync('not json{{{');
    expect(LocalStore.forDir(tempDir).read('cart.json')!.body, 'not json{{{');
  });

  test('an empty file is imported as an empty document', () {
    legacy('device_id.txt').writeAsStringSync('');
    expect(LocalStore.forDir(tempDir).read('device_id.txt')!.body, '');
    expect(File('${tempDir.path}/device_id.txt.migrated').existsSync(), isTrue);
  });

  test('bytes that are not UTF-8 import nothing and the file is renamed', () {
    legacy('server_outbox.json').writeAsBytesSync([0x7b, 0xff, 0xfe, 0x7d]);
    final store = LocalStore.forDir(tempDir);
    expect(store.read('server_outbox.json'), isNull);
    expect(File('${tempDir.path}/server_outbox.json').existsSync(), isFalse);
    expect(File('${tempDir.path}/server_outbox.json.migrated').existsSync(), isTrue);
  });

  test('an existing document wins over a legacy file of the same name', () {
    LocalStore.forDir(tempDir).write('carts.json', 'kept in the database');
    LocalStore.debugCloseAll();
    legacy('carts.json').writeAsStringSync('left behind');

    final store = LocalStore.forDir(tempDir);
    expect(store.read('carts.json')!.body, 'kept in the database');
    expect(File('${tempDir.path}/carts.json').existsSync(), isFalse);
    expect(File('${tempDir.path}/carts.json.migrated').readAsStringSync(), 'left behind');
  });

  test('a failed import keeps the file and the next open imports it', () {
    legacy('server_catch_up.json').writeAsStringSync('{"invented":1}');
    legacy('coa_sent.json').writeAsStringSync('{"invented":2}');
    debugBeforeLegacyImportWrite = (name) {
      if (name == 'server_catch_up.json') throw const FileSystemException('disk full');
    };

    final first = LocalStore.forDir(tempDir);
    expect(first.read('server_catch_up.json'), isNull);
    expect(File('${tempDir.path}/server_catch_up.json').existsSync(), isTrue);
    expect(first.read('coa_sent.json')!.body, '{"invented":2}', reason: 'one failure does not stop the next file');

    debugBeforeLegacyImportWrite = null;
    LocalStore.debugCloseAll();
    final second = LocalStore.forDir(tempDir);
    expect(second.read('server_catch_up.json')!.body, '{"invented":1}');
    expect(File('${tempDir.path}/server_catch_up.json').existsSync(), isFalse);
    expect(File('${tempDir.path}/server_catch_up.json.migrated').existsSync(), isTrue);
  });

  // Final review M-1: "an existing document wins" covers an overwrite, not a deletion. A sold or discarded cart must not
  // come back from a cart.json whose rename failed after its import committed.
  test('a file whose rename failed after its import is never imported again, even after its document is deleted', () {
    legacy('cart.json').writeAsStringSync('{"invented":"old draft"}');
    debugRenameLegacyFile = (file, to) => throw const FileSystemException('rename refused');
    final first = LocalStore.forDir(tempDir);
    expect(first.read('cart.json')!.body, '{"invented":"old draft"}');
    expect(File('${tempDir.path}/cart.json').existsSync(), isTrue, reason: 'the rename failed');

    first.delete('cart.json'); // the cart was sold
    LocalStore.debugCloseAll();
    debugRenameLegacyFile = null;
    final second = LocalStore.forDir(tempDir);
    expect(second.read('cart.json'), isNull);
    expect(File('${tempDir.path}/cart.json').existsSync(), isFalse, reason: 'renamed this time');
    expect(File('${tempDir.path}/cart.json.migrated').existsSync(), isTrue);
  });

  test('files outside the list are left alone', () {
    final others = ['login_spec.yaml', 'login_hosts.json', 'session.json', 'x.json', 'cart_NOT-AN-ID.json',
        'stock_cache_abc.json', 'server_outbox.json.tmp', 'server_replies/par.json.tmp'];
    for (final name in others) {
      legacy(name).writeAsStringSync('invented');
    }
    final store = LocalStore.forDir(tempDir);
    for (final name in others) {
      expect(isLegacyDocumentName(name), isFalse, reason: name);
      expect(store.read(name), isNull, reason: name);
      expect(File('${tempDir.path}/$name').readAsStringSync(), 'invented', reason: name);
    }
  });
}
