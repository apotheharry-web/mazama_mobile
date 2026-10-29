// The last good reply of each read from Mazama's server, kept on the phone (README R56, server_link.dart), for the pages
// to show while the server can't be reached (server_offline.dart's readWithCache; the app-wide banner says the server
// can't be reached, README R87). One store for every read, keyed by route and parameters ([replyKey]), each reply kept with when
// the server sent it, so a new read gets offline support by one call:
//
//   final read = await replies.read(replyKey('sheets', stateId), fetch: ..., encode: ..., decode: ...);
//
// One small JSON document per key in the data folder's LocalStore ({"atMs": ..., "value": ...}), named as the file an
// older build kept under server_replies/ (`server_replies/<the key, URI-encoded>.json`), written with synchronous
// calls as the other stores, each write in a transaction (a crash mid-write leaves the old copy whole); anything
// unreadable counts as nothing kept. No age limit, as before: the notice always says when the copy is
// from, and nothing is sold from these pages.
//
// Par levels, the stock page's product information sheets and Mazama's stock moved here from stock_cache_store.dart and
// mazama_inventory_cache_store.dart. Copies those kept are read once, when this store has none for the key yet, and
// moved here ([ReplyStore.read]'s legacy), so a phone updated while the server is down still has them.
import 'dart:convert';
import 'dart:io';

import 'local_store.dart';
import 'mazama_inventory_cache_store.dart';
import 'mazama_inventory_client.dart' show MazamaInventory;
import 'server_offline.dart';
import 'session_store.dart' show defaultSessionDataDir;
import 'sheets_client.dart' show ProductSheet;
import 'stock_cache_store.dart';
import 'stock_summary.dart' show ParLevel;

/// The key for [route]'s reply (routes.yaml's name: 'par', 'sheets', 'mazama_inventory', ...) with [params] (path
/// parameters, in order).
String replyKey(String route, [List<Object> params = const []]) => [route, ...params].join('/');

/// A kept reply: the JSON the server sent (as the caller encoded it) and when.
class KeptReply {
  const KeptReply(this.value, this.at);
  final Object? value;
  final DateTime at;
}

class ReplyStore {
  const ReplyStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  /// Overridable for tests, as the other stores.
  final Directory Function() dataDir;

  static const _prefix = 'server_replies/';

  static String _name(String key) => '$_prefix${Uri.encodeComponent(key)}.json';

  /// Keeps [value] (JSON-encodable) as [key]'s reply, sent at [at].
  void save(String key, Object? value, DateTime at) {
    final body = jsonEncode({'atMs': at.toUtc().millisecondsSinceEpoch, 'value': value});
    LocalStore.forDir(dataDir()).write(_name(key), body);
  }

  /// [key]'s kept reply; null when none (or none readable) is kept.
  KeptReply? load(String key) {
    try {
      final text = LocalStore.forDir(dataDir()).read(_name(key))?.body;
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded['atMs'] is! int || !decoded.containsKey('value')) return null;
      return KeptReply(decoded['value'], DateTime.fromMillisecondsSinceEpoch(decoded['atMs'] as int, isUtc: true));
    } catch (_) {
      return null;
    }
  }

  /// Every key with a reply kept (for the debug page).
  List<String> keys() {
    final keys = <String>[];
    for (final n in LocalStore.forDir(dataDir()).names(_prefix)) {
      if (!n.endsWith('.json')) continue;
      try {
        keys.add(Uri.decodeComponent(n.substring(_prefix.length, n.length - '.json'.length)));
      } on ArgumentError {
        continue; // not a name this store wrote
      }
    }
    return keys..sort();
  }

  /// [key]'s kept reply as a page's own keep/kept pair (CenterStockPage's keepSheets/keptSheets, MazamaInventoryPage's
  /// keep/kept): what [read] does, for a page that runs readWithCache itself.
  ReplyKeeper<T> keeper<T>(String key,
          {required Object? Function(T value) encode,
          required T Function(Object? json) decode,
          Future<ServerRead<T>?> Function()? legacy}) =>
      ReplyKeeper<T>._(this, key, encode, decode, legacy);

  /// Reads with [fetch]; a reply is kept as [key]'s (encoded with [encode], stamped [now]) and returned. When the
  /// server can't be reached (server_error.dart's rule), the reply kept for [key] instead (decoded with [decode]), or,
  /// with none, what [legacy] gives (a copy an older build kept elsewhere; moved here when found); with neither, or for
  /// any other failure, the fetch's own error.
  Future<ServerRead<T>> read<T>(
    String key, {
    required Future<T> Function() fetch,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
    Future<ServerRead<T>?> Function()? legacy,
    DateTime Function() now = DateTime.now,
  }) =>
      readWithCache<T>(
        fetch: fetch,
        save: keeper<T>(key, encode: encode, decode: decode, legacy: legacy).save,
        load: keeper<T>(key, encode: encode, decode: decode, legacy: legacy).load,
        now: now,
      );
}

/// One key's kept reply, encoded and decoded (ReplyStore.keeper).
class ReplyKeeper<T> {
  ReplyKeeper._(this._store, this.key, this._encode, this._decode, this._legacy);

  final ReplyStore _store;
  final String key;
  final Object? Function(T value) _encode;
  final T Function(Object? json) _decode;
  final Future<ServerRead<T>?> Function()? _legacy;

  /// Keeps [value] as the server sent it [at].
  Future<void> save(T value, DateTime at) async => _store.save(key, _encode(value), at);

  /// The kept reply, or (none kept here yet) the copy an older build kept elsewhere, moved here when it has a time;
  /// null when neither. A kept reply that can't be decoded counts as none.
  Future<ServerRead<T>?> load() async {
    final kept = _store.load(key);
    if (kept != null) {
      try {
        return ServerRead.cached(_decode(kept.value), kept.at);
      } catch (_) {
        // an older or damaged copy: as if none were kept
      }
    }
    final legacy = _legacy;
    final old = legacy == null ? null : await legacy();
    if (old == null) return null;
    final at = old.cachedAt;
    if (at != null) {
      try {
        _store.save(key, _encode(old.value), at);
      } catch (_) {
        // moving it is best effort; it is shown either way
      }
    }
    return ServerRead.cached(old.value, at);
  }
}

// --- the reads moved here (README R56) ------------------------------------------------------------------------------

/// A center's par levels (route C10): kept here, read once from stock_cache_store.dart where older builds kept them.
ReplyKeeper<List<ParLevel>> parReplies(ReplyStore replies, int stateId, {StockCacheStore? legacy}) =>
    replies.keeper<List<ParLevel>>(replyKey('par', [stateId]),
        encode: (levels) => [for (final l in levels) l.toJson()],
        decode: (json) => [for (final l in json as List) ParLevel.fromJson(Map<String, Object?>.from(l as Map))],
        legacy: legacy == null
            ? null
            : () async {
                final saved = await legacy.load(stateId);
                final par = saved.par;
                return par == null ? null : ServerRead.cached(par, saved.parAt);
              });

/// A center's product information sheets (route C13): kept here, read once from stock_cache_store.dart as [parReplies].
ReplyKeeper<List<ProductSheet>> sheetsReplies(ReplyStore replies, int stateId, {StockCacheStore? legacy}) =>
    replies.keeper<List<ProductSheet>>(replyKey('sheets', [stateId]),
        encode: (sheets) => [for (final s in sheets) s.toJson()],
        decode: (json) => [for (final s in json as List) ProductSheet.fromJson(Map<String, Object?>.from(s as Map))],
        legacy: legacy == null
            ? null
            : () async {
                final saved = await legacy.load(stateId);
                final sheets = saved.sheets;
                return sheets == null ? null : ServerRead.cached(sheets, saved.sheetsAt);
              });

/// Mazama's stock (route C12): kept here, read once from mazama_inventory_cache_store.dart where older builds kept it.
ReplyKeeper<MazamaInventory> mazamaInventoryReplies(ReplyStore replies, {MazamaInventoryCacheStore? legacy}) =>
    replies.keeper<MazamaInventory>(replyKey('mazama_inventory'),
        encode: (inventory) => inventory.toJson(),
        decode: (json) => MazamaInventory.fromJson(Map<String, Object?>.from(json as Map)),
        legacy: legacy?.load);
