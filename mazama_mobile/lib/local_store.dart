// LocalStore: the one SQLite database (`mazama.db`) the phone keeps everything in between launches (specs/foundations
// Part B, LS-R1, LS-R2). Nothing else in the app opens the database.
//
// Synchronous on purpose. package:sqlite3 calls SQLite through dart:ffi with no isolate in between, so a read or a
// write here is a small blocking call, exactly as the stores' *Sync file calls were. The stores chose those over
// dart:io's async calls because an async write still in flight could deadlock a later delete of the same file under
// flutter_test's fake clock (cart_store.dart's header); keeping every call synchronous keeps that guarantee, and keeps
// every store's public method shape.
//
// Documents, not a table per store (plan P-D1). Each store keeps today's JSON text under today's file name
// (`cart.json`, `stock_cache_231.json`, `server_replies/par%2F231.json`), so its own parsing, caps and corrupt-data
// rules are unchanged, and moving a legacy file in (local_store_import.dart) is a copy.
//
// One database per data folder, found by the folder (P-D2). Every store already takes its folder as `dataDir`, most
// are built `const`, and every test passes its own temporary folder; a registry keyed by the folder keeps all of
// that, opens one connection per file (never two in one process), and gives demo mode, whose stores use their own
// folder, its own database for free (LS-R8).
//
// Every write is in a transaction (a single statement is one on its own; [LocalStore.transaction] groups several):
// a crash leaves the old document or the new one, never half of either.
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart';

import 'local_store_import.dart';

/// The database's file name, in each data folder.
const localStoreFileName = 'mazama.db';

/// `PRAGMA user_version` once every migration in [_migrations] has run.
const localStoreSchemaVersion = 1;

/// Index i moves `user_version` from i to i + 1, in its own transaction. Append only: a phone may be at any version.
final List<void Function(Database)> _migrations = [
  (db) {
    db.execute('CREATE TABLE documents (name TEXT PRIMARY KEY, body TEXT NOT NULL, saved_at_ms INTEGER NOT NULL)');
    // The legacy files already imported (local_store_import.dart), so one whose rename failed is never imported again
    // after its document is deleted (a sold cart coming back).
    db.execute('CREATE TABLE imported_files (name TEXT PRIMARY KEY, saved_at_ms INTEGER NOT NULL)');
  },
];

/// SQLite's result codes for a damaged file: SQLITE_CORRUPT and SQLITE_NOTADB.
const _sqliteCorrupt = 11, _sqliteNotADatabase = 26;

bool _damaged(Object e) =>
    e is SqliteException && (e.resultCode == _sqliteCorrupt || e.resultCode == _sqliteNotADatabase);

class LocalStore {
  /// Open databases, by the folder's canonical path.
  static final Map<String, LocalStore> _open = {};

  Database _db;
  final String _path;
  int _depth = 0;

  /// [_db] was closed by a set-aside that did not finish ([_run]).
  bool _closed = false;

  LocalStore._(this._db, this._path);

  /// The database of [dir] (created if need be, with the folder). The same instance is returned while its file
  /// exists; when `mazama.db` is gone (the folder deleted under it: a test's tear-down, the debug page's fresh
  /// install) a new, empty database is opened instead of writing into the deleted file. Every fresh open imports
  /// the legacy files still in the folder before it returns (LS-R5), so no store reads before the import.
  static LocalStore forDir(Directory dir) {
    dir.createSync(recursive: true);
    final key = dir.resolveSymbolicLinksSync();
    final path = '$key${Platform.pathSeparator}$localStoreFileName';
    final open = _open[key];
    if (open != null) {
      if (File(path).existsSync()) return open;
      _open.remove(key);
      open._close();
    }
    final store = LocalStore._(_openOrSetAside(path), path);
    _open[key] = store;
    importLegacyFiles(store, Directory(key));
    return store;
  }

  /// Opens [path]; a file SQLite says is not a database, or is corrupt, is set aside ([_setAside]) and a new, empty
  /// database opened in its place, so the app still starts (as a corrupt file of a store always counted as nothing
  /// saved). Any other failure (a busy or read-only file) is thrown, the file untouched.
  static Database _openOrSetAside(String path) {
    try {
      return _openDatabase(path);
    } catch (e) {
      if (!_damaged(e)) rethrow;
      _setAside(path);
      return _openDatabase(path);
    }
  }

  /// Renames a damaged database to `mazama.db.corrupt` (with its journal files), for a person to look at: all three
  /// or none. The journal files go first, so a fresh database is never opened beside the damaged one's `-wal` to
  /// replay (re-review m-1); when a later rename fails, what was moved is put back before the error is thrown, so
  /// `mazama.db` keeps its `-wal` (review of m-1) and the next call tries again.
  static void _setAside(String path) {
    final moved = <String>[];
    try {
      for (final suffix in const ['-wal', '-shm', '']) {
        final f = File('$path$suffix');
        if (f.existsSync()) {
          f.renameSync('$path.corrupt$suffix');
          moved.add(suffix);
        }
      }
    } catch (_) {
      for (final suffix in moved.reversed) {
        try {
          File('$path.corrupt$suffix').renameSync('$path$suffix');
        } catch (_) {
          // Best effort: the error below is what the caller sees, and the next call tries the set-aside again.
        }
      }
      rethrow;
    }
  }

  static Database _openDatabase(String path) {
    final db = sqlite3.open(path);
    try {
      db.select('PRAGMA journal_mode=WAL');
      db.select('PRAGMA busy_timeout=2000');
      for (var v = db.userVersion; v < _migrations.length; v++) {
        db.execute('BEGIN IMMEDIATE');
        try {
          _migrations[v](db);
          db.userVersion = v + 1;
          db.execute('COMMIT');
        } catch (_) {
          if (!db.autocommit) db.execute('ROLLBACK');
          rethrow;
        }
      }
      return db;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  /// Runs [op] against the database; when SQLite finds the file damaged (a bad page found after the open), the file is
  /// set aside as `mazama.db.corrupt`, a new, empty database opened in its place, and [op] run once more on it: a
  /// damaged database reads as nothing saved, as a store's damaged file always did, instead of every call throwing on
  /// every launch. Inside a transaction the outermost one does this, for the whole transaction.
  ///
  /// When the set-aside or the fresh open fails half-way, the connection stays marked closed ([_closed]), and the next
  /// call opens the file again (setting it aside then if it is still unreadable) instead of every call throwing on a
  /// closed connection until a restart (re-review N-3).
  T _run<T>(T Function() op) {
    if (_depth > 0) return op();
    if (_closed) {
      _db = _openOrSetAside(_path);
      _closed = false;
    }
    try {
      return op();
    } catch (e) {
      if (!_damaged(e)) rethrow;
      _close();
      _closed = true;
      _setAside(_path);
      _db = _openDatabase(_path);
      _closed = false;
      return op();
    }
  }

  /// The document [name], with the time it was saved (UTC), or null if there is none.
  ({String body, DateTime savedAt})? read(String name) => _run(() {
        final rows = _db.select('SELECT body, saved_at_ms FROM documents WHERE name = ?', [name]);
        if (rows.isEmpty) return null;
        final row = rows.first;
        return (
          body: row['body'] as String,
          savedAt: DateTime.fromMillisecondsSinceEpoch(row['saved_at_ms'] as int, isUtc: true),
        );
      });

  /// Replaces the document [name] with [body], saved at [at] (now by default).
  void write(String name, String body, {DateTime? at}) {
    final ms = (at ?? DateTime.now()).millisecondsSinceEpoch;
    transaction(() => _db.execute(
        'INSERT INTO documents (name, body, saved_at_ms) VALUES (?, ?, ?) '
        'ON CONFLICT (name) DO UPDATE SET body = excluded.body, saved_at_ms = excluded.saved_at_ms',
        [name, body, ms]));
  }

  /// Removes the document [name]; nothing to remove is fine.
  void delete(String name) {
    transaction(() => _db.execute('DELETE FROM documents WHERE name = ?', [name]));
  }

  /// The names of every document starting with [prefix], sorted. The prefix is compared as text (no LIKE
  /// wildcards: reply names hold '%').
  List<String> names(String prefix) => _run(() {
        final rows = _db.select('SELECT name FROM documents WHERE substr(name, 1, length(?1)) = ?1', [prefix]);
        return [for (final r in rows) r['name'] as String]..sort();
      });

  /// For local_store_import.dart: whether the legacy file [name] was imported once already.
  bool legacyFileImported(String name) =>
      _run(() => _db.select('SELECT 1 FROM imported_files WHERE name = ?', [name]).isNotEmpty);

  /// For local_store_import.dart, inside the import's transaction: records the legacy file [name] as imported.
  void recordLegacyFileImported(String name) {
    final ms = DateTime.now().millisecondsSinceEpoch;
    transaction(() => _db.execute(
        'INSERT INTO imported_files (name, saved_at_ms) VALUES (?, ?) ON CONFLICT (name) DO NOTHING', [name, ms]));
  }

  /// Runs [fn] in one transaction (BEGIN IMMEDIATE): everything it writes commits together, or, when it throws,
  /// nothing does and the error is rethrown. A transaction inside another runs inline, as part of the outer one.
  /// [fn] must be synchronous: a Future would let its writes run after the commit, so one is refused. On a damaged
  /// database the whole of [fn] runs once more, on the new one ([_run]).
  T transaction<T>(T Function() fn) => _run(() => _transaction(fn));

  T _transaction<T>(T Function() fn) {
    if (_depth > 0) return fn();
    _db.execute('BEGIN IMMEDIATE');
    _depth++;
    try {
      final result = fn();
      if (result is Future) {
        result.ignore();
        throw StateError('LocalStore.transaction takes a synchronous function');
      }
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      try {
        if (!_db.autocommit) _db.execute('ROLLBACK');
      } catch (_) {
        // A damaged file may refuse the rollback too; the error below is the one that matters.
      }
      rethrow;
    } finally {
      _depth--;
    }
  }

  void _close() {
    try {
      _db.close();
    } catch (_) {
      // Its file is already gone; nothing left to keep.
    }
  }

  /// The rows of [sql], for tests that look at the schema itself.
  @visibleForTesting
  List<Map<String, Object?>> debugQuery(String sql) =>
      [for (final r in _db.select(sql)) Map<String, Object?>.from(r)];

  /// Closes every open database, as an app restart would; the next [forDir] opens (and imports) afresh.
  @visibleForTesting
  static void debugCloseAll() {
    for (final store in _open.values) {
      store._close();
    }
    _open.clear();
  }
}
