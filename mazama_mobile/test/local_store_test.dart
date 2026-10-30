// LocalStore (foundations LS-R1, LS-R2): one SQLite database of documents per data folder. Each test has its own
// folder, so the registry never hands one test another's database.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_store.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_local_store_test_'));
  tearDown(() {
    LocalStore.debugCloseAll();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('write then read gives the body and the time, across a second forDir of the same folder', () {
    final dir = Directory('${tempDir.path}/nested');
    final store = LocalStore.forDir(dir);
    final at = DateTime.utc(2026, 10, 1, 12, 30, 15, 250);
    store.write('cart.json', '{"lines":[]}', at: at);

    expect(LocalStore.forDir(dir), same(store));
    expect(File('${dir.path}/$localStoreFileName').existsSync(), isTrue);

    LocalStore.debugCloseAll(); // a restart
    final read = LocalStore.forDir(dir).read('cart.json');
    expect(read, isNotNull);
    expect(read!.body, '{"lines":[]}');
    expect(read.savedAt.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
    expect(read.savedAt.isUtc, isTrue);
  });

  test('a write without a time is stamped now', () {
    final before = DateTime.now().millisecondsSinceEpoch;
    final store = LocalStore.forDir(tempDir)..write('a', 'x');
    final after = DateTime.now().millisecondsSinceEpoch;
    final ms = store.read('a')!.savedAt.millisecondsSinceEpoch;
    expect(ms, inInclusiveRange(before, after));
  });

  test('two folders never see each other\'s documents', () {
    final a = LocalStore.forDir(Directory('${tempDir.path}/a'));
    final b = LocalStore.forDir(Directory('${tempDir.path}/b'));
    a.write('cart.json', 'from a');
    expect(b.read('cart.json'), isNull);
    b.write('cart.json', 'from b');
    expect(a.read('cart.json')!.body, 'from a');
    expect(b.read('cart.json')!.body, 'from b');
  });

  test('a throw inside transaction leaves the previous body', () {
    final store = LocalStore.forDir(tempDir)..write('x', 'a');
    expect(
      () => store.transaction(() {
        store.write('x', 'b');
        store.write('y', 'new');
        throw StateError('');
      }),
      throwsStateError,
    );
    expect(store.read('x')!.body, 'a');
    expect(store.read('y'), isNull);
  });

  test('a transaction commits everything inside it and returns its value; nested ones run inline', () {
    final store = LocalStore.forDir(tempDir);
    final result = store.transaction(() {
      store.write('x', '1');
      return store.transaction(() {
        store.write('y', '2');
        return 42;
      });
    });
    expect(result, 42);
    LocalStore.debugCloseAll();
    final again = LocalStore.forDir(tempDir);
    expect(again.read('x')!.body, '1');
    expect(again.read('y')!.body, '2');
  });

  test('names lists one prefix, sorted; delete removes one', () {
    final store = LocalStore.forDir(tempDir)
      ..write('server_replies/par%2F231.json', 'p')
      ..write('server_replies/packages%2F231.json', 'k')
      ..write('server_repliesX.json', 'not in the prefix')
      ..write('cart.json', 'c');
    expect(store.names('server_replies/'), ['server_replies/packages%2F231.json', 'server_replies/par%2F231.json']);
    // A prefix is matched as text, never as a LIKE pattern: '%' and '_' are ordinary characters.
    expect(store.names('server_replies/par%'), ['server_replies/par%2F231.json']);
    expect(store.names('server%'), isEmpty);

    store.delete('server_replies/par%2F231.json');
    expect(store.read('server_replies/par%2F231.json'), isNull);
    expect(store.names('server_replies/'), ['server_replies/packages%2F231.json']);
    store.delete('never-written'); // deleting nothing is fine
    expect(store.read('cart.json')!.body, 'c');
  });

  test('a deleted folder gets a new empty database on the next call', () {
    final dir = Directory('${tempDir.path}/data');
    LocalStore.forDir(dir).write('cart.json', 'old');
    dir.deleteSync(recursive: true);

    final store = LocalStore.forDir(dir);
    expect(store.read('cart.json'), isNull);
    store.write('cart.json', 'new');
    expect(File('${dir.path}/$localStoreFileName').existsSync(), isTrue);

    LocalStore.debugCloseAll();
    expect(LocalStore.forDir(dir).read('cart.json')!.body, 'new');
  });

  test('a database file that is not a database is set aside as mazama.db.corrupt and a new one opened', () {
    File('${tempDir.path}/$localStoreFileName').writeAsStringSync('this was never a SQLite file, invented ' * 200);
    File('${tempDir.path}/cart.json').writeAsStringSync('{"invented":1}'); // a legacy file still to import

    final store = LocalStore.forDir(tempDir);
    expect(store.read('cart.json')!.body, '{"invented":1}');
    store.write('x', 'y');
    expect(File('${tempDir.path}/$localStoreFileName.corrupt').readAsStringSync(), startsWith('this was never'));
    LocalStore.debugCloseAll();
    expect(LocalStore.forDir(tempDir).read('x')!.body, 'y');
  });

  // Final review I-3: a page damaged after the open (the header still whole) made every later call throw
  // SqliteException(11), on every launch; a damaged store file only ever cost that store ("nothing saved").
  test('a page damaged after the open reads as nothing saved, and the next write lands in a fresh database', () async {
    final store = LocalStore.forDir(tempDir);
    for (var i = 0; i < 50; i++) {
      store.write('doc_$i.json', 'invented ' * 100);
    }
    await CartStore(dataDir: () => tempDir).save(231, const []);
    LocalStore.debugCloseAll(); // checkpoints the WAL into mazama.db
    final file = File('${tempDir.path}/$localStoreFileName');
    final bytes = file.readAsBytesSync();
    for (var i = 4096; i < bytes.length; i++) {
      bytes[i] = 0x5a;
    }
    file.writeAsBytesSync(bytes);

    final cart = CartStore(dataDir: () => tempDir);
    expect(await cart.load(231), isNull);
    expect(File('${tempDir.path}/$localStoreFileName.corrupt').existsSync(), isTrue);
    await cart.save(231, const []);
    expect(await cart.load(231), isEmpty);
    expect(LocalStore.forDir(tempDir).read('doc_1.json'), isNull, reason: 'a fresh database');
    LocalStore.debugCloseAll();
    expect(await cart.load(231), isEmpty, reason: 'and it stays');
  });

  test('a damaged page inside a transaction is set aside too, and the transaction runs on the fresh database', () {
    final store = LocalStore.forDir(tempDir);
    for (var i = 0; i < 50; i++) {
      store.write('doc_$i.json', 'invented ' * 100);
    }
    LocalStore.debugCloseAll();
    final file = File('${tempDir.path}/$localStoreFileName');
    final bytes = file.readAsBytesSync();
    for (var i = 4096; i < bytes.length; i++) {
      bytes[i] = 0x5a;
    }
    file.writeAsBytesSync(bytes);

    final again = LocalStore.forDir(tempDir);
    final result = again.transaction(() {
      again.write('a', '1');
      return again.read('doc_3.json');
    });
    expect(result, isNull);
    expect(again.read('a')!.body, '1');
  });

  // Re-review N-3: when setting a damaged file aside failed half-way, the instance stayed registered on its closed
  // connection, and every later call threw until a restart.
  test('a set-aside that fails leaves no closed connection behind: the next call opens the database again', () {
    final store = LocalStore.forDir(tempDir);
    for (var i = 0; i < 50; i++) {
      store.write('doc_$i.json', 'invented ' * 100);
    }
    LocalStore.debugCloseAll();
    final file = File('${tempDir.path}/$localStoreFileName');
    final bytes = file.readAsBytesSync();
    for (var i = 4096; i < bytes.length; i++) {
      bytes[i] = 0x5a;
    }
    file.writeAsBytesSync(bytes);
    final blocker = Directory('${tempDir.path}/$localStoreFileName.corrupt')..createSync();
    File('${blocker.path}/keep').writeAsStringSync('x'); // the rename onto it fails

    final again = LocalStore.forDir(tempDir);
    expect(() => again.read('doc_3.json'), throwsA(isA<FileSystemException>()));
    blocker.deleteSync(recursive: true);

    expect(again.read('doc_3.json'), isNull, reason: 'the same instance reopens, sets the file aside and reads');
    again.write('a', '1');
    expect(LocalStore.forDir(tempDir).read('a')!.body, '1');
    expect(File('${tempDir.path}/$localStoreFileName.corrupt').existsSync(), isTrue);
  });

  // Re-review m-1: the set-aside renamed mazama.db first, then its -wal and -shm. When a journal file's rename failed,
  // mazama.db was gone and its -wal left behind, and the next open put a fresh database beside that WAL, which SQLite
  // may replay into it. The journal files now go first: a failed rename leaves the damaged files together.
  test('a set-aside that fails on the -wal leaves mazama.db and its -wal together, then moves them as one', () {
    final store = LocalStore.forDir(tempDir);
    for (var i = 0; i < 50; i++) {
      store.write('doc_$i.json', 'invented ' * 100);
    }
    LocalStore.debugCloseAll();
    final file = File('${tempDir.path}/$localStoreFileName');
    final bytes = file.readAsBytesSync();
    for (var i = 4096; i < bytes.length; i++) {
      bytes[i] = 0x5a;
    }
    file.writeAsBytesSync(bytes);
    final other = sqlite3.open(file.path); // another connection keeps the -wal there when the store closes its own
    other.select('PRAGMA user_version');
    final wal = File('${file.path}-wal');
    expect(wal.existsSync(), isTrue);
    final blocker = Directory('${file.path}.corrupt-wal')..createSync();
    File('${blocker.path}/keep').writeAsStringSync('x'); // the -wal's rename onto it fails

    final again = LocalStore.forDir(tempDir);
    expect(() => again.read('doc_3.json'), throwsA(isA<FileSystemException>()));
    expect(file.existsSync(), isTrue, reason: 'mazama.db is not moved without its -wal');
    expect(wal.existsSync(), isTrue);
    expect(File('${file.path}.corrupt').existsSync(), isFalse);
    other.close();
    blocker.deleteSync(recursive: true);

    expect(again.read('doc_3.json'), isNull, reason: 'the next call sets the damaged files aside together');
    expect(File('${file.path}.corrupt').existsSync(), isTrue);
    again.write('a', '1');
    LocalStore.debugCloseAll();
    final fresh = LocalStore.forDir(tempDir);
    expect(fresh.read('a')!.body, '1');
    expect(fresh.read('doc_3.json'), isNull, reason: 'a fresh database, with no old journal replayed into it');
  });

  // Review of m-1: with the journal files moved first, a failure renaming mazama.db itself left the database without
  // its -wal, and the retry could open it "fine" without the pages only that WAL held. What moved is put back.
  test('a set-aside that fails on mazama.db puts its moved -wal and -shm back', () {
    final store = LocalStore.forDir(tempDir);
    for (var i = 0; i < 50; i++) {
      store.write('doc_$i.json', 'invented ' * 100);
    }
    LocalStore.debugCloseAll();
    final file = File('${tempDir.path}/$localStoreFileName');
    final bytes = file.readAsBytesSync();
    for (var i = 4096; i < bytes.length; i++) {
      bytes[i] = 0x5a;
    }
    file.writeAsBytesSync(bytes);
    final other = sqlite3.open(file.path); // keeps the -wal and -shm there when the store closes its own connection
    other.select('PRAGMA user_version');
    final wal = File('${file.path}-wal');
    final shm = File('${file.path}-shm');
    expect(wal.existsSync() && shm.existsSync(), isTrue);
    final blocker = Directory('${file.path}.corrupt')..createSync();
    File('${blocker.path}/keep').writeAsStringSync('x'); // mazama.db's own rename fails

    final again = LocalStore.forDir(tempDir);
    expect(() => again.read('doc_3.json'), throwsA(isA<FileSystemException>()));
    expect(file.existsSync() && wal.existsSync() && shm.existsSync(), isTrue,
        reason: 'mazama.db keeps its journal files when it could not be moved');
    expect(File('${file.path}.corrupt-wal').existsSync(), isFalse);
    expect(File('${file.path}.corrupt-shm').existsSync(), isFalse);
    other.close();
    blocker.deleteSync(recursive: true);

    expect(again.read('doc_3.json'), isNull, reason: 'the next call sets the damaged files aside together');
    expect(File('${file.path}.corrupt').existsSync(), isTrue);
    again.write('a', '1');
    expect(LocalStore.forDir(tempDir).read('a')!.body, '1');
  });

  test('the schema version is 2 (the sync tables) and the journal is WAL', () {
    final store = LocalStore.forDir(tempDir);
    expect(localStoreSchemaVersion, 2);
    expect(store.debugQuery('PRAGMA user_version').single.values.single, localStoreSchemaVersion);
    expect(store.debugQuery('PRAGMA journal_mode').single.values.single, 'wal');
    final columns = store.debugQuery('PRAGMA table_info(documents)').map((r) => r['name']).toList();
    expect(columns, ['name', 'body', 'saved_at_ms']);
  });
}
