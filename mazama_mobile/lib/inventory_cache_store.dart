// Persists the last successfully fetched inventory for a service center, so a worker who opens the app with
// no signal at all - not even enough to reach the state system directly (state_packages_client.dart), let
// alone Mazama's own server (packages_client.dart) - still sees SOMETHING rather than a blank "Stock did not
// load" screen. Since specs/phone-sync phase 3 it is the sync engine's center_stock dataset (lib/sync/sync_datasets.dart),
// one per center ({"packages": [...], "source": ...}, with when it was read), in the data folder's database; the
// document an older build kept (inventory_cache.json, one center) is moved there (sync_migration.dart's
// migrateStockCaches). It has no staleness rule of its own: it hands back what's kept, with its time, and the caller
// decides (lib/sync/center_stock.dart shows it at any age; the cart refuses to sell from stock older than 3 days, Q3).
import 'dart:convert';
import 'dart:io';

import 'local_store.dart';
import 'packages_client.dart';
import 'session_store.dart' show defaultSessionDataDir;
import 'sync/sync_datasets.dart' show Dataset, Datasets, sourceMerged;

/// What InventoryCacheStore.load hands back: the packages as last successfully saved (whichever source -
/// lib/sync/center_stock.dart keeps a result from Mazama's own server or a direct state fetch the same way), and
/// when that happened.
class CachedInventory {
  final List<Package> packages;
  final DateTime fetchedAt;
  CachedInventory({required this.packages, required this.fetchedAt});
}

class InventoryCacheStore {
  /// Overridable for tests, so a test never reads or writes the real app-data directory - same pattern as
  /// CartStore.dataDir/SessionStore.dataDir.
  final Directory Function() dataDir;

  const InventoryCacheStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  Datasets get _datasets => Datasets.forDir(dataDir);

  /// Replaces what was kept for [centerId]; [source] is where the packages came from (sync_datasets.dart's sources).
  Future<void> save(int centerId, List<Package> packages, DateTime fetchedAt, {String source = sourceMerged}) async {
    _datasets.put(Dataset.centerStock, '$centerId',
        jsonEncode({'packages': packages.map((p) => p.toJson()).toList(), 'source': source}),
        source: source, at: fetchedAt);
  }

  /// Null if nothing is kept for [centerId], or what is kept can't be read back. No staleness rule: what is kept and
  /// when it was read (UTC, so it equals the time it was saved with).
  Future<CachedInventory?> load(int centerId) async {
    final row = _datasets.read(Dataset.centerStock, '$centerId');
    if (row == null) return null;
    final packages = packagesFromBody(row.body);
    return packages == null ? null : CachedInventory(packages: packages, fetchedAt: row.fetchedAt.toUtc());
  }

  /// The packages of a center_stock body ({"packages": [...], "source": ...}); null when it isn't one (an older or
  /// damaged copy: as if none were kept).
  static List<Package>? packagesFromBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final rawPackages = decoded['packages'];
      if (rawPackages is! List) return null;
      final packages = <Package>[];
      for (final rp in rawPackages) {
        if (rp is! Map) return null;
        packages.add(Package.fromJson(Map<String, Object?>.from(rp)));
      }
      return packages;
    } catch (_) {
      return null;
    }
  }

  /// Forgets every center's kept stock (the debug page's reset), and an older build's document.
  Future<void> clear() async {
    _datasets.remove(Dataset.centerStock);
    try {
      LocalStore.forDir(dataDir()).delete('inventory_cache.json');
    } catch (_) {
      // nothing there, or the database can't be opened: nothing kept either way
    }
  }
}
