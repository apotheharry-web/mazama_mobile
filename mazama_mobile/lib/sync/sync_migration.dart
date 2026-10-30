// Moving today's stores into the sync engine's tables (specs/phone-sync PS-R9), on every start until nothing is left:
//   - server_outbox.json (OutboxStore): its reports and dead letters become sale_log / sale_failure items with the same
//     clientIds, order, tries, errors and reasons; its count of dropped sale logs is added to the queue's.
//   - server_catch_up.json (CatchUpStore): its lots become lab_report items kept for later, its snapshots
//     inventory_snapshot and sales_snapshot items (specs/center-web's sales kind).
//   - coa_sent.json (the old CoaSentStore document): the sent lots go to sync_sent.
// Each document is moved in one transaction that also deletes it, so a crash or a failure leaves the document and none
// of its items, and the next start tries again; a second run finds nothing. A report or lab report already in the
// queue under the same kind and key is the same item (its clientId or lot) and is kept. A snapshot already queued is
// kept only when it is the newer: after a downgrade and a re-upgrade the older build may have kept a newer read than
// the one this build left queued, and the newer read wins (final review M2). A document this build can't read is left
// where it is, counted as nothing (as the stores always did), for a person to look at.
//
// Phase 2 ([migrateReplies]): the reply store's kept par levels, sheets and Mazama stock (the
// `server_replies/<key>.json` documents of reply_store.dart, removed in Task 10: they are read here by name) become
// the par, sheets and mazama_inventory datasets, with the time the server sent them, each in its own transaction that
// also deletes it; a dataset already stored is kept when it is as new or newer. Phase 4 adds the Sales tab's state
// read (recent_sales, source state). A reply of any other route is left.
//
// Phase 3 ([migrateStockCaches]): the last inventory kept (inventory_cache.json, one center) becomes that center's
// center_stock dataset with its time (source merged: an older build didn't say where it came from), unless a newer
// copy is stored; the figures kept per package (enrichment.json) become the enrichment dataset, unless this build
// already keeps one. Task 8b Step 6b and Task 10 add the rest of what the removed stores kept: Mazama's stock
// (mazama_inventory_cache.json) becomes the mazama_inventory dataset, and each center's stock-page copy
// (stock_cache_<id>.json) its par, sheets, stock_rows and mazama_licenses datasets and its par_columns_<id>.json
// document (par_columns.dart), as [_moveStockCache] says. Each in its own transaction that also deletes the document;
// one this build can't read is left.
//
// These run at the engine's start (openSyncTables) and on a database's first open through Datasets
// (sync_datasets.dart), which tries a move that failed again at its next opens, a few times per run.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../catch_up_store.dart';
import '../coa_uploader.dart' show CoaSentStore;
import '../local_store.dart';
import '../par_columns.dart' show parColumnsDocument;
import '../server_outbox.dart';
import 'sync_datasets.dart' show Dataset, sourceMerged, sourceServer, sourceState;
import 'sync_tables.dart';

final _atOnce = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// [store]'s tables, with today's queues moved in ([migrateQueues]).
SyncTables openSyncTables(LocalStore store) {
  final tables = SyncTables(store);
  migrateQueues(store, tables);
  migrateReplies(store, tables);
  migrateStockCaches(store, tables);
  return tables;
}

/// Moves the outbox, the catch-up list and the sent lab reports into [tables] (the file comment).
void migrateQueues(LocalStore store, SyncTables tables) {
  _move(store, OutboxStore.documentName, (text) {
    final state = OutboxStore.parse(text);
    // dead letters first: storing one never replaces a live item, and a live one never replaces a dead letter
    for (final e in state.dead) {
      _put(tables, e.kind == OutboxKind.saleLog ? 'sale_log' : 'sale_failure', e.clientId, jsonEncode(e.toJson()),
          e.createdAt, attempts: e.attempts, dead: e.lastError ?? 'refused');
    }
    DateTime? last;
    for (final e in state.pending) {
      // the order they were in, even where the phone's clock went backwards between two
      final at = last != null && e.createdAt.isBefore(last) ? last : e.createdAt;
      last = at;
      _put(tables, e.kind == OutboxKind.saleLog ? 'sale_log' : 'sale_failure', e.clientId, jsonEncode(e.toJson()), at,
          attempts: e.attempts);
    }
    if (state.droppedLogs > 0) {
      const name = 'sync_dropped_sale_logs';
      final had = store.read(name)?.body;
      final before = had == null ? 0 : (int.tryParse(had) ?? 0);
      store.write(name, jsonEncode(before + state.droppedLogs));
    }
  });
  _move(store, CatchUpStore.documentName, (text) {
    final state = CatchUpStore.parse(text);
    DateTime? last;
    for (final lot in state.lots) {
      final at = last != null && lot.addedAt.isBefore(last) ? last : lot.addedAt;
      last = at;
      _put(tables, 'lab_report', lot.lotGuid.toLowerCase(), jsonEncode(lot.toJson()), at);
    }
    for (final s in state.snapshots.values) {
      _put(tables, s.kind == snapshotKindSales ? 'sales_snapshot' : 'inventory_snapshot', '${s.stateId}',
          jsonEncode(s.toJson()), s.readAt, newerWins: true);
    }
  });
  _move(store, CoaSentStore.documentName, (text) {
    final d = jsonDecode(text);
    final lots = d is Map ? d['lots'] : null;
    if (lots is! List) return;
    for (final l in lots) {
      if (l is! Map) continue;
      final guid = l['lotGuid'], at = l['sentAtMs'];
      if (guid is! String || guid.isEmpty || at is! int) continue;
      final key = guid.toLowerCase();
      final when = DateTime.fromMillisecondsSinceEpoch(at, isUtc: true);
      final kept = tables.store.select('SELECT sent_at_ms FROM sync_sent WHERE kind = ? AND key = ?', ['lab_report', key]);
      if (kept.isEmpty || (kept.first['sent_at_ms'] as int) < at) tables.sent('lab_report', key, when);
    }
  });
}

/// Runs [moveIn] over the document [name] and deletes it, in one transaction; a document this build can't read is
/// left, and any other failure leaves it (and none of its items) for the next start.
void _move(LocalStore store, String name, void Function(String text) moveIn) {
  try {
    final text = store.read(name)?.body;
    if (text == null) return;
    try {
      jsonDecode(text);
    } on FormatException {
      return; // unreadable: left where it is
    }
    store.transaction(() {
      moveIn(text);
      store.delete(name);
    });
  } catch (e) {
    debugPrint('$name could not be moved into the sync queue (kept for the next start): $e');
  }
}

/// Queues one moved item, unless the same kind and key is already there; with [newerWins] (snapshots), the one there is
/// replaced when it was queued before [at].
void _put(SyncTables tables, String kind, String key, String body, DateTime at,
    {int attempts = 0, String? dead, bool newerWins = false}) {
  final exists = tables.store.select(
      'SELECT queued_at_ms FROM sync_queue WHERE kind = ? AND key = ? AND ${dead == null ? "state <> 'dead'" : "state = 'dead'"}',
      [kind, key]);
  if (exists.isNotEmpty && !(newerWins && (exists.first['queued_at_ms'] as int) < at.millisecondsSinceEpoch)) return;
  tables.enqueue(QueueItem(
    kind: kind,
    key: key,
    body: body,
    queuedAt: at,
    nextAt: _atOnce,
    attempts: attempts,
    state: dead == null ? queueWaiting : queueDead,
    reason: dead,
  ));
}

// ---- phase 2: the reply store's reads

const _repliesPrefix = 'server_replies/';

/// The reply store's routes whose replies are datasets now, and the dataset each became.
const replyRoutesMoved = {
  'par': Dataset.par,
  'sheets': Dataset.sheets,
  'mazama_inventory': Dataset.mazamaInventory,
  'state_sales': Dataset.recentSales, // phase 4: the Sales tab's read from the state system (sales_page.dart)
};

/// Moves the reply store's kept replies of [replyRoutesMoved] into [tables] as datasets (the file comment). A dataset
/// read after [now] (the phone's clock moved back since) counts as older than the reply, so the reply isn't lost.
/// False when a move failed (logged; the reply is kept to be tried again), not for a reply this build can't read.
bool migrateReplies(LocalStore store, SyncTables tables, {DateTime Function()? now}) {
  final current = (now ?? DateTime.now)().toUtc();
  final List<String> names;
  try {
    names = store.names(_repliesPrefix);
  } catch (e) {
    debugPrint('the kept replies could not be listed (kept for the next start): $e');
    return false;
  }
  var allMoved = true;
  for (final name in names) {
    if (!name.endsWith('.json')) continue;
    final String replyKey;
    try {
      replyKey = Uri.decodeComponent(name.substring(_repliesPrefix.length, name.length - '.json'.length));
    } catch (_) {
      continue; // not a name the reply store wrote
    }
    final parts = replyKey.split('/');
    final moved = replyRoutesMoved[parts.first];
    if (moved == null) continue;
    final Dataset d = moved;
    final perCenter = d != Dataset.mazamaInventory;
    if (parts.length != (perCenter ? 2 : 1) || (perCenter && int.tryParse(parts[1]) == null)) continue;
    final key = perCenter ? parts[1] : '';
    try {
      final text = store.read(name)?.body;
      if (text == null) continue;
      final Object? kept;
      try {
        kept = jsonDecode(text);
      } on FormatException {
        continue; // unreadable: left where it is
      }
      if (kept is! Map || kept['atMs'] is! int || !kept.containsKey('value')) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(kept['atMs'] as int, isUtc: true);
      final body = jsonEncode(kept['value']);
      store.transaction(() {
        final had = tables.dataset(d.stored, key);
        if (had == null || had.fetchedAt.isBefore(at) || had.fetchedAt.isAfter(current)) {
          tables.putDataset(d.stored, key, body,
              source: d == Dataset.recentSales ? sourceState : sourceServer, fetchedAt: at);
        }
        store.delete(name);
      });
    } catch (e) {
      debugPrint('$name could not be moved into the datasets (kept for the next start): $e');
      allMoved = false;
    }
  }
  return allMoved;
}

// ---- phase 3: the stock caches

/// The document names of the caches moved by [migrateStockCaches].
const inventoryCacheDocument = 'inventory_cache.json', enrichmentDocument = 'enrichment.json';

/// Moves inventory_cache.json and enrichment.json into [tables] as the center_stock and enrichment datasets, then
/// Mazama's stock and each center's stock-page copy (the file comment). False when a move failed (logged; the document
/// is kept to be tried again), not for a document this build can't read (left for a person to look at).
bool migrateStockCaches(LocalStore store, SyncTables tables, {DateTime Function()? now}) {
  final current = (now ?? DateTime.now)().toUtc();
  var allMoved = _moveDocument(store, inventoryCacheDocument, (j) {
    final center = j['centerId'], at = j['fetchedAtMs'], packages = j['packages'];
    if (center is! num || at is! num || packages is! List || packages.any((p) => p is! Map)) return false;
    final key = '${center.toInt()}';
    final fetchedAt = DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true);
    final had = tables.dataset(Dataset.centerStock.stored, key);
    if (had == null || had.fetchedAt.isBefore(fetchedAt) || had.fetchedAt.isAfter(current)) {
      tables.putDataset(Dataset.centerStock.stored, key, jsonEncode({'packages': packages, 'source': sourceMerged}),
          source: sourceMerged, fetchedAt: fetchedAt);
    }
    return true;
  });
  allMoved &= _moveDocument(store, enrichmentDocument, (j) {
    if (j['version'] != 1 || j['entries'] is! List) return false;
    if (tables.dataset(Dataset.enrichment.stored, '') == null) {
      tables.putDataset(Dataset.enrichment.stored, '', jsonEncode(j), source: sourceServer, fetchedAt: current);
    }
    return true;
  });
  // Task 8b Step 6b: Mazama's stock as an older build kept it, and each center's stock-page copy.
  allMoved &= _moveDocument(store, mazamaInventoryCacheDocument, (j) {
    final at = j['atMs'], inventory = j['inventory'];
    if (at is! num || inventory is! Map) return false;
    _putIfNewer(tables, Dataset.mazamaInventory, '', jsonEncode(inventory), sourceServer,
        DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true), current);
    return true;
  });
  final List<String> names;
  try {
    names = store.names(stockCacheDocumentPrefix);
  } catch (e) {
    debugPrint('the stock-page copies could not be listed (kept for the next start): $e');
    return false;
  }
  for (final name in names) {
    final id = int.tryParse(RegExp(r'^stock_cache_(\d+)\.json$').firstMatch(name)?.group(1) ?? '');
    if (id != null) allMoved &= _moveStockCache(store, tables, name, id, current);
  }
  return allMoved;
}

/// The prefix of the stock page's per-center documents an older build kept (stock_cache_store.dart, removed in Task 10:
/// `stock_cache_<state id>.json`).
const stockCacheDocumentPrefix = 'stock_cache_';

/// Mazama's stock as builds before README R56 kept it (mazama_inventory_cache_store.dart, removed in Task 10).
const mazamaInventoryCacheDocument = 'mazama_inventory_cache.json';

final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime _timeOr(Object? ms, DateTime missing) =>
    ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true) : missing;

/// Stores [body] as [d]'s copy for [key] read at [at], unless the copy stored is newer (and not in the future).
void _putIfNewer(SyncTables tables, Dataset d, String key, String body, String source, DateTime at, DateTime current) {
  final had = tables.dataset(d.stored, key);
  if (had == null || had.fetchedAt.isBefore(at) || had.fetchedAt.isAfter(current)) {
    tables.putDataset(d.stored, key, body, source: source, fetchedAt: at);
  }
}

/// Moves one center's stock-page copy [name] (center [stateId]): its par levels, sheets and drawn rows become the par,
/// sheets and stock_rows datasets with their times (a copy with no time recorded is the oldest there is: the epoch);
/// Task 10: Mazama's licenses become the mazama_licenses dataset (no time recorded: the epoch, so any read since wins)
/// and the par columns chosen on this phone the center's par_columns document (par_columns.dart), unless one is there
/// already (a choice made since). Anything else in it (nothing an older build wrote) is written back; the document is
/// deleted when nothing is. One transaction; a document this build can't read is left. False when the move failed.
bool _moveStockCache(LocalStore store, SyncTables tables, String name, int stateId, DateTime current) {
  final id = '$stateId';
  try {
    final text = store.read(name)?.body;
    if (text == null) return true;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return true; // unreadable: left where it is
    }
    if (decoded is! Map) return true;
    final d = Map<String, Object?>.from(decoded);
    final par = d['par'], sheets = d['sheets'], rows = d['rows'], licenses = d['mazamaLicenses'], columns = d['parColumns'];
    if (par is! List && sheets is! List && rows is! List && licenses is! List && columns is! Map) return true; // nothing to move
    store.transaction(() {
      if (par is List) {
        _putIfNewer(tables, Dataset.par, id, jsonEncode(par), sourceServer, _timeOr(d['parAtMs'], _epoch), current);
      }
      if (sheets is List) {
        _putIfNewer(
            tables, Dataset.sheets, id, jsonEncode(sheets), sourceServer, _timeOr(d['sheetsAtMs'], _epoch), current);
      }
      if (rows is List) {
        final mode = d['rowsMgMode'] == 'psilocybin' ? 'psilocybin' : 'tpe';
        // who answered the read isn't recorded in the document: mg psilocybin can only be the state's own read,
        // anything else was the server's (the only two an older build wrote)
        _putIfNewer(tables, Dataset.stockRows, id, jsonEncode({'rows': rows, 'mgMode': mode}),
            mode == 'psilocybin' ? sourceState : sourceMerged, _timeOr(d['rowsAtMs'], _epoch), current);
      }
      if (licenses is List) {
        _putIfNewer(tables, Dataset.mazamaLicenses, id, jsonEncode([for (final l in licenses) if (l is String) l]),
            sourceServer, _epoch, current);
      }
      if (columns is Map) {
        final doc = parColumnsDocument(stateId);
        if (store.read(doc) == null) store.write(doc, jsonEncode(columns));
      }
      final rest = {...d}..removeWhere((k, v) =>
          const {'par', 'parAtMs', 'sheets', 'sheetsAtMs', 'rows', 'rowsMgMode', 'rowsAtMs'}.contains(k) ||
          (k == 'mazamaLicenses' && v is List) ||
          (k == 'parColumns' && v is Map));
      if (rest.isEmpty) {
        store.delete(name);
      } else {
        store.write(name, jsonEncode(rest));
      }
    });
    return true;
  } catch (e) {
    debugPrint('$name could not be moved into the datasets (kept for the next start): $e');
    return false;
  }
}

/// Moves the document [name] with [moveIn] and deletes it, in one transaction; a document that isn't a JSON object, or
/// that [moveIn] can't read (false), is left where it is, as is one whose move failed (then false).
bool _moveDocument(LocalStore store, String name, bool Function(Map<String, Object?> json) moveIn) {
  try {
    final text = store.read(name)?.body;
    if (text == null) return true;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return true; // unreadable: left where it is
    }
    if (decoded is! Map) return true;
    final json = Map<String, Object?>.from(decoded);
    store.transaction(() {
      if (moveIn(json)) store.delete(name);
    });
    return true;
  } catch (e) {
    debugPrint('$name could not be moved into the datasets (kept for the next start): $e');
    return false;
  }
}
