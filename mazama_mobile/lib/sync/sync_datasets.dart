// The sync engine's datasets (specs/phone-sync PS-R3): what the phone knows, one row per page's worth (a center's par
// levels, its product information sheets, Mazama's stock), each with where it came from and when it was read
// (sync_tables.dart's sync_dataset). Pages read them, and watch them for changes ([Datasets.watch]); the engine
// refreshes them (sync_engine.dart's register/refresh) and writes each refresh here; a failed refresh records only the
// try and its error, leaving the body as it was (PS-R1: nothing is thrown into a page).
//
// [Datasets] is the stored side, over one folder's database: the engine's own (its tables), or a page's handle on a
// folder ([Datasets.forDir]: the app's, or the demo's own). Writes through any handle on the same database reach every
// watcher of it. The first handle on a database moves the reply store's kept par levels, sheets and Mazama stock in
// (sync_migration.dart's migrateReplies), so nothing an older build kept is lost.
//
// The server's reads (phase 2): [parDataset], [sheetsDataset] and [mazamaInventoryDataset] are the keep/kept pairs the
// pages read with (server_read.dart's readWithCache: the server's reply when it answers, else the kept copy with
// its time; README R87, no notice of the page's own), replacing the reply store's for those reads; a copy an older
// build kept (the reply store, stock_cache_<id>.json, mazama_inventory_cache.json; their classes removed in Task 10) is
// moved here on the database's first open (sync_migration.dart).
// [serverReadRefreshers] are the engine's refreshers for them and for center_status and coa_data, each body in the
// same JSON the keepers read.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../center_status_client.dart' show CenterStatus;
import '../coa_data_client.dart' show CoaData;
import '../local_store.dart';
import '../mazama_inventory_client.dart' show MazamaInventory;
import 'server_read.dart';
import '../sheets_client.dart' show ProductSheet;
import '../stock_summary.dart' show ParLevel;
import 'sync_migration.dart' show migrateReplies, migrateStockCaches;
import 'sync_tables.dart';

/// PS-R3's datasets, by their stored names.
enum Dataset {
  licenses('licenses'),
  centerStatus('center_status'),
  centerStock('center_stock'),
  enrichment('enrichment'),
  par('par'),
  sheets('sheets'),
  mazamaInventory('mazama_inventory'),
  coaData('coa_data'),
  recentSales('recent_sales'),
  stockRows('stock_rows'),

  /// A center's Mazama manufacturer licenses (/p/center-status's list, SP-R8), kept for drawing state-only stock
  /// (stock_rows.dart; Task 10: before, stock_cache_store.dart's).
  mazamaLicenses('mazama_licenses');

  const Dataset(this.stored);

  /// The name in sync_dataset.
  final String stored;
}

/// Where a dataset's body came from (sync_dataset.source).
const sourceState = 'state', sourceServer = 'server', sourceMerged = 'merged', sourceDemo = 'demo';

/// Reads [key]'s copy of a dataset afresh: its body (the JSON its page reads) and where it came from. Throws when it
/// can't (the engine records the failure and keeps the old body).
typedef Refresher = Future<({String body, String source})> Function(String key);

class Datasets {
  /// Over the engine's own [tables].
  Datasets(SyncTables tables, {DateTime Function()? now})
      : _tables = (() => tables),
        now = now ?? DateTime.now;

  /// Over the database of the folder [dataDir] gives, opened at each use (as the other stores), so a handle never
  /// holds a database that was closed under it.
  Datasets.forDir(Directory Function() dataDir, {DateTime Function()? now})
      : _tables = (() => SyncTables(LocalStore.forDir(dataDir()))),
        now = now ?? DateTime.now;

  final SyncTables Function() _tables;

  /// The clock, for when a refresh or a failure happened.
  final DateTime Function() now;

  /// The watchers of each database, by dataset and key; any handle's write tells them.
  static final _watchers = Expando<Map<String, Set<void Function()>>>('dataset watchers');

  /// How many times each database's older copies have been moved in this run ([moveTriesMax] once every move worked):
  /// a move that failed (logged by sync_migration.dart, the document kept) is tried again at the next open, so what an
  /// older build kept isn't missing for the rest of the run, up to [moveTriesMax] times, not at every read.
  static final _moveTries = Expando<int>('older copies moved');

  /// The most tries of the moves per database and run (Task 10 review, minor 1).
  static const moveTriesMax = 3;

  static String _id(Dataset d, String key) => '${d.stored}\u0000$key';

  /// Watchers that started while the database couldn't be opened: attached on this handle's next good open.
  final List<void Function(LocalStore store)> _unattached = [];

  SyncTables? _open() {
    final SyncTables t;
    try {
      t = _tables();
      final tries = _moveTries[t.store] ?? 0;
      if (tries < moveTriesMax) {
        _moveTries[t.store] = tries + 1; // counted first: a move that throws counts too
        final replies = migrateReplies(t.store, t);
        final stock = migrateStockCaches(t.store, t);
        if (replies && stock) _moveTries[t.store] = moveTriesMax;
      }
    } catch (e) {
      debugPrint('the datasets could not be opened: $e');
      return null;
    }
    if (_unattached.isNotEmpty) {
      final waiting = List.of(_unattached);
      _unattached.clear();
      for (final attach in waiting) {
        attach(t.store);
      }
    }
    return t;
  }

  /// Opens the database, which on its first open moves in what an older build kept (sync_migration.dart), and nothing
  /// else: for a store beside the datasets that reads a document the move writes (par_columns.dart).
  void moveOlderCopies() => _open();

  /// [d]'s copy for [key]; null when none is stored, or the database can't be read.
  DatasetRow? read(Dataset d, String key) {
    try {
      return _open()?.dataset(d.stored, key);
    } catch (e) {
      debugPrint('${d.stored}/$key could not be read: $e');
      return null;
    }
  }

  /// Stores [body] as [d]'s copy for [key], read from [source] at [at] (now by default), and tells its watchers.
  /// False when it couldn't be stored (never throws: keeping a copy is best effort), and when the copy stored was read
  /// later than [at] (an older read finishing last never replaces a newer one; a stored time in the future, a clock
  /// moved back, doesn't count as later).
  bool put(Dataset d, String key, String body, {required String source, DateTime? at}) {
    final t = _open();
    if (t == null) return false;
    final current = now().toUtc();
    final fetchedAt = (at ?? current).toUtc();
    final bool changed;
    try {
      final had = t.dataset(d.stored, key);
      if (had != null && had.fetchedAt.isAfter(fetchedAt) && !had.fetchedAt.isAfter(current)) return false;
      changed = had == null ||
          had.body != body ||
          had.source != source ||
          had.fetchedAt != fetchedAt ||
          had.lastError != null;
      t.putDataset(d.stored, key, body, source: source, fetchedAt: fetchedAt);
    } catch (e) {
      debugPrint('${d.stored}/$key could not be stored: $e');
      return false;
    }
    if (changed) _notify(t.store, d, key); // the same copy again tells nobody
    return true;
  }

  /// A refresh of [d]'s copy for [key] failed with [error]: only the try is recorded; the body stays as it was.
  void failed(Dataset d, String key, String error, {DateTime? at}) {
    final t = _open();
    if (t == null) return;
    try {
      if (t.dataset(d.stored, key) == null) return; // nothing stored: nothing recorded, nobody told
      t.datasetFailed(d.stored, key, error, (at ?? now()).toUtc());
    } catch (e) {
      debugPrint('${d.stored}/$key: the failed refresh could not be recorded: $e');
      return;
    }
    _notify(t.store, d, key);
  }

  /// Forgets [d]'s copy for [key], or every copy of [d] when [key] is null (a store's clear), telling the watchers of
  /// [key]. Never throws.
  void remove(Dataset d, {String? key}) {
    final t = _open();
    if (t == null) return;
    try {
      t.deleteDataset(d.stored, key: key);
    } catch (e) {
      debugPrint('${d.stored} could not be removed: $e');
      return;
    }
    if (key != null) _notify(t.store, d, key);
  }

  /// Every dataset stored, by name and key (the debug page).
  List<DatasetRow> list() {
    try {
      return _open()?.allDatasets() ?? const [];
    } catch (e) {
      debugPrint('the datasets could not be listed: $e');
      return const [];
    }
  }

  /// [d]'s copy for [key] as it is stored now (null when none), then again after every write or failed refresh of it.
  /// [onListen] and [onCancel] tell the engine what is watched.
  Stream<DatasetRow?> watch(Dataset d, String key, {void Function()? onListen, void Function()? onCancel}) {
    late final StreamController<DatasetRow?> controller;
    LocalStore? store;
    void emit() {
      if (!controller.isClosed) controller.add(read(d, key));
    }

    var listening = false;
    void attach(LocalStore s) {
      if (!listening || store != null) return;
      store = s;
      final all = _watchers[s] ??= {};
      (all[_id(d, key)] ??= {}).add(emit);
      emit(); // what is stored, now that it can be read
    }

    controller = StreamController<DatasetRow?>(
      onListen: () {
        listening = true;
        final s = _open()?.store;
        if (s != null) {
          attach(s);
        } else {
          // the database can't be opened now: null for the moment, and attached on this handle's next good open
          _unattached.add(attach);
          emit();
        }
        onListen?.call();
      },
      onCancel: () {
        listening = false;
        _unattached.remove(attach);
        final s = store;
        if (s != null) _watchers[s]?[_id(d, key)]?.remove(emit);
        onCancel?.call();
      },
    );
    return controller.stream;
  }

  static void _notify(LocalStore store, Dataset d, String key) {
    final watchers = _watchers[store]?[_id(d, key)];
    if (watchers == null) return;
    for (final w in watchers.toList()) {
      try {
        w();
      } catch (e) {
        debugPrint('a watcher of ${d.stored}/$key failed: $e');
      }
    }
  }

  /// [d]'s copy for [key] as a page's keep/kept pair (readWithCache's save and load), its value encoded with [encode]
  /// and read back with [decode].
  DatasetKeeper<T> keeper<T>(Dataset d, String key,
          {required Object? Function(T value) encode, required T Function(Object? json) decode}) =>
      DatasetKeeper<T>._(this, d, key, encode, decode);
}

/// One dataset's copy, encoded and decoded, as a page's keep/kept pair ([Datasets.keeper]).
class DatasetKeeper<T> {
  DatasetKeeper._(this.datasets, this.dataset, this.key, this._encode, this._decode);

  final Datasets datasets;
  final Dataset dataset;
  final String key;
  final Object? Function(T value) _encode;
  final T Function(Object? json) _decode;

  /// Keeps [value] as the server sent it [at].
  Future<void> save(T value, DateTime at) async {
    datasets.put(dataset, key, jsonEncode(_encode(value)), source: sourceServer, at: at);
  }

  /// The stored copy with when it was read; null when none is stored. A stored copy that can't be decoded counts as
  /// none.
  Future<ServerRead<T>?> load() async {
    final row = datasets.read(dataset, key);
    if (row != null) {
      try {
        // a copy moved in without a recorded time is stored at the epoch: no time known, as before (Task 8b)
        final at = row.fetchedAt.millisecondsSinceEpoch == 0 ? null : row.fetchedAt;
        return ServerRead.cached(_decode(jsonDecode(row.body)), at);
      } catch (_) {
        // an older or damaged copy: as if none were kept
      }
    }
    return null;
  }
}

// --- the server's reads (phase 2) ------------------------------------------------------------------------------------

Object? _encodePar(List<ParLevel> levels) => [for (final l in levels) l.toJson()];
List<ParLevel> _decodePar(Object? json) =>
    [for (final l in json as List) ParLevel.fromJson(Map<String, Object?>.from(l as Map))];

Object? _encodeSheets(List<ProductSheet> sheets) => [for (final s in sheets) s.toJson()];
List<ProductSheet> _decodeSheets(Object? json) =>
    [for (final s in json as List) ProductSheet.fromJson(Map<String, Object?>.from(s as Map))];

Object? _encodeInventory(MazamaInventory inventory) => inventory.toJson();
MazamaInventory _decodeInventory(Object? json) => MazamaInventory.fromJson(Map<String, Object?>.from(json as Map));

/// A center's par levels (route C10), kept as the `par` dataset.
DatasetKeeper<List<ParLevel>> parDataset(Datasets datasets, int stateId) =>
    datasets.keeper<List<ParLevel>>(Dataset.par, '$stateId', encode: _encodePar, decode: _decodePar);

/// A center's product information sheets (route C13), kept as the `sheets` dataset.
DatasetKeeper<List<ProductSheet>> sheetsDataset(Datasets datasets, int stateId) =>
    datasets.keeper<List<ProductSheet>>(Dataset.sheets, '$stateId', encode: _encodeSheets, decode: _decodeSheets);

/// Mazama's stock (route C12), kept as the `mazama_inventory` dataset (one copy, key '').
DatasetKeeper<MazamaInventory> mazamaInventoryDataset(Datasets datasets) =>
    datasets.keeper<MazamaInventory>(Dataset.mazamaInventory, '', encode: _encodeInventory, decode: _decodeInventory);

/// A `center_status` body read back (null when it isn't one).
CenterStatus? centerStatusFromBody(String body) {
  try {
    final j = jsonDecode(body);
    return j is Map && j['configured'] is bool ? CenterStatus.fromJson(Map<String, Object?>.from(j)) : null;
  } catch (_) {
    return null;
  }
}

/// A `coa_data` body read back for [lotGuid]: the server's figures, or null when it has none for the lot (or the body
/// isn't one).
CoaData? coaDataFromBody(String lotGuid, String body) {
  try {
    final j = jsonDecode(body);
    return j is Map ? CoaData.fromJson(lotGuid, Map<String, Object?>.from(j)) : null;
  } catch (_) {
    return null;
  }
}

/// The engine's refreshers for the server's reads (phase 2): `par`, `sheets` and `center_status` by center (the key
/// is the state id), `mazama_inventory` (key ''), `coa_data` by lot (the key is the lot id, lower-case; the body is
/// `null` when the server has no figures for it). Each fetch is today's client, through the server link.
Map<Dataset, Refresher> serverReadRefreshers({
  required Future<List<ParLevel>> Function(int stateId) fetchPar,
  required Future<List<ProductSheet>> Function(int stateId) fetchSheets,
  required Future<MazamaInventory> Function() fetchMazamaInventory,
  required Future<CenterStatus> Function(int stateId) fetchCenterStatus,
  required Future<Map<String, CoaData>> Function(List<String> lotGuids) fetchCoaData,
}) {
  int center(String key) {
    final id = int.tryParse(key);
    if (id == null) throw ArgumentError.value(key, 'key', 'not a center id');
    return id;
  }

  return {
    Dataset.par: (key) async => (body: jsonEncode(_encodePar(await fetchPar(center(key)))), source: sourceServer),
    Dataset.sheets: (key) async =>
        (body: jsonEncode(_encodeSheets(await fetchSheets(center(key)))), source: sourceServer),
    Dataset.mazamaInventory: (key) async =>
        (body: jsonEncode(_encodeInventory(await fetchMazamaInventory())), source: sourceServer),
    Dataset.centerStatus: (key) async =>
        (body: jsonEncode((await fetchCenterStatus(center(key))).toJson()), source: sourceServer),
    Dataset.coaData: (key) async {
      final lot = key.toLowerCase();
      final found = await fetchCoaData([lot]);
      CoaData? data;
      for (final e in found.entries) {
        if (e.key.toLowerCase() == lot) data = e.value;
      }
      return (body: jsonEncode(data?.toJson()), source: sourceServer);
    },
  };
}
