// Where builds before README R56 kept the last Mazama stock (route C12) the server sent, with when. That copy now lives
// in the app's reply store (reply_store.dart's mazamaInventoryReplies); this file is only read, once, when the reply
// store has none yet, so a phone updated while the server is down still shows it. Nothing writes here any more but this
// class's own save (kept for its tests and for that one read). One small JSON file in the app's data folder; anything
// unreadable counts as nothing kept.
import 'dart:convert';
import 'dart:io';

import 'mazama_inventory_client.dart';
import 'server_offline.dart';
import 'session_store.dart' show defaultSessionDataDir;

class MazamaInventoryCacheStore {
  const MazamaInventoryCacheStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  /// Overridable for tests, as the other stores.
  final Directory Function() dataDir;

  File get _file => File('${dataDir().path}/mazama_inventory_cache.json');

  Future<void> save(MazamaInventory inventory, DateTime at) async {
    dataDir().createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode({'atMs': at.millisecondsSinceEpoch, 'inventory': inventory.toJson()}));
  }

  /// The copy kept, as a cached read with its time; null when none (or none readable) is kept.
  Future<ServerRead<MazamaInventory>?> load() async {
    try {
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return null;
      final at = decoded['atMs'];
      final inventory = decoded['inventory'];
      if (at is! num || inventory is! Map) return null;
      return ServerRead.cached(MazamaInventory.fromJson(Map<String, Object?>.from(inventory)),
          DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true));
    } catch (_) {
      return null; // no file, a partial write, an older format: as if none were kept
    }
  }
}
