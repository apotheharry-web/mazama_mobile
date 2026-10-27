// Persists the last successfully fetched inventory for a service center, so a worker who opens the app with
// no signal at all - not even enough to reach the state system directly (state_packages_client.dart), let
// alone Mazama's own server (packages_client.dart) - still sees SOMETHING rather than a blank "Stock did not
// load" screen. Same hand-written-JSON-file approach as cart_store.dart/session_store.dart, reusing
// session_store.dart's own defaultSessionDataDir.
//
// Deliberately scoped to exactly one center at a time, the same way cart_store.dart is: a worker who switches
// centers overwrites whatever was cached for the one before it. A center's inventory refreshes constantly in
// normal use (CartPage/StockPage both fetch on load), so remembering more than the one most recent center adds
// nothing worth the extra bookkeeping. See resilient_inventory.dart for the 3-day staleness rule this file
// itself has no opinion on - it only ever hands back what's on disk, with its own timestamp, and lets the
// caller decide whether that's still good enough to show.
import 'dart:convert';
import 'dart:io';

import 'packages_client.dart';
import 'session_store.dart' show defaultSessionDataDir;

/// What InventoryCacheStore.load hands back: the packages as last successfully saved (whichever source -
/// resilient_inventory.dart saves a result from Mazama's own server or a direct state fetch the same way), and
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

  File get _file => File('${dataDir().path}/inventory_cache.json');

  /// Overwrites whatever was cached before (for any center) - see this file's own comment for why remembering
  /// only the one most recent center is enough.
  Future<void> save(int centerId, List<Package> packages, DateTime fetchedAt) async {
    dataDir().createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode({
      'centerId': centerId,
      'fetchedAtMs': fetchedAt.millisecondsSinceEpoch,
      'packages': packages.map((p) => p.toJson()).toList(),
    }));
  }

  /// Null if nothing is stored, what's there can't be read back (no file, a partial write from a crash mid-
  /// save, a future/older format), or - same rule as cart_store.dart's own load - what's stored belongs to a
  /// different center than [centerId]: a stale center's cache has no business reappearing at another one, even
  /// on the same device. This method has no staleness rule of its own - it hands back exactly what's on disk
  /// plus its timestamp, and the caller (resilient_inventory.dart's own 3-day window) decides whether that's
  /// still worth showing.
  Future<CachedInventory?> load(int centerId) async {
    try {
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return null;
      if ((decoded['centerId'] as num?)?.toInt() != centerId) return null;
      final fetchedAtMs = decoded['fetchedAtMs'];
      final rawPackages = decoded['packages'];
      if (fetchedAtMs is! num || rawPackages is! List) return null;
      final packages = <Package>[];
      for (final rp in rawPackages) {
        if (rp is! Map) return null;
        packages.add(Package.fromJson(Map<String, Object?>.from(rp)));
      }
      // isUtc: true matters here, not just for display: DateTime's own == checks it alongside the instant, so
      // a caller comparing this against the UTC DateTime it originally saved (every call site in this app uses
      // DateTime.now()/DateTime.utc(...), never a local one, for fetchedAt) would otherwise see two unequal
      // objects for the exact same moment - exactly what inventory_cache_store_test.dart's own round-trip test
      // caught.
      return CachedInventory(
        packages: packages,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(fetchedAtMs.toInt(), isUtc: true),
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      _file.deleteSync();
    } on FileSystemException {
      // Already gone (or never existed) - exactly the state this call is meant to produce, so that's fine.
    }
  }
}
