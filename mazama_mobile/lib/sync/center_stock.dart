// A center's stock as the cart reads it, through these steps (InventorySource names where a load's stock came
// from), by the same join as the stock page's (stock_merge.dart). Each load, in order:
//   1. Mazama's server (/p/packages) and the state system (GetPackagedProducts, the worker's own token) at once, put
//      together by the one merge rule (stock_merge.dart's mergeStock). The server answered: InventorySource.live, its
//      own rows remembered for later fills (enrichment.dart) and its row keys given for the uploader. Only the
//      state answered: InventorySource.state, filled from the figures kept where they still apply. Whenever the state
//      answered, its raw read is handed to [onStateRead] (the cart uploads it as the center's snapshot, never awaited).
//   2. Both failed, with a session and the state fallback on: the state's own packages, filled the same way
//      (InventorySource.state).
//   3. Still nothing: the stock last kept for the center (the center_stock dataset, [keptCenterStock]), at
//      ANY age, with when it was read (InventorySource.cache). Stock is always shown with its
//      age; it is selling that refuses stock older than [ResilienceOptions.cacheMaxAge] (cart_page.dart, [stockTooOld]).
//   4. Nothing kept either: the first step's error.
// Every stock read in steps 1-2 is kept for step 3, with where it came from. Selling never goes through this: the sale
// reads the state itself when its stock is older than 5 minutes and goes straight to the state.
import 'dart:convert';

import 'enrichment.dart';
import '../packages_client.dart';
import '../session.dart';
import 'stock_merge.dart';
import 'sync_datasets.dart' show Dataset, Datasets, Refresher, sourceMerged, sourceServer, sourceState;

/// Which step produced a load ([CenterStock.fetch]): Mazama's server ([live], with the state's counts when it answered
/// too), the state alone ([state]), or the stock kept for the center ([cache]). [adhoc] is CartPage's own: a center
/// Mazama's server doesn't track (center_status), whose stock the cart reads through coa_data_resolver.dart's
/// resolveAdhocInventory instead, tagged so for the same banner the others use.
enum InventorySource { live, state, cache, adhoc }

/// One load ([CenterStock.fetch]): the packages, which step produced them and, for [InventorySource.cache] only, when
/// the kept copy was read ([asOf]; live and state are a read that just happened).
class InventoryFetch {
  final List<Package> packages;
  final InventorySource source;
  final DateTime? asOf;

  /// For [InventorySource.live] only: the [inventoryRowKey]s of the rows Mazama's server itself sent. A merged row
  /// only the state listed has coaAvailable false because the server was never asked about it, not because its lab
  /// report is missing, so the background uploader queues only these. Null when the server's
  /// rows aren't known.
  final Set<String>? serverKeys;

  /// Whether the state system itself was read for these packages in this load: false for Mazama's server's rows alone
  /// and for a kept copy, whose counts the state hasn't confirmed, so a sale reads the state first.
  final bool stateRead;
  InventoryFetch({required this.packages, required this.source, this.asOf, this.serverKeys, this.stateRead = false});
}

/// One row's key, as the merge matches the server's rows to the state's (stock_merge.dart's stockRowKey): PKPR and
/// package id.
String inventoryRowKey(Package p) => '${p.productGuid}#${p.id}';

/// Added to the kept-stock banner ([InventorySource.cache]) when the copy kept was itself a state-only read with
/// products whose only figure is the state's psilocybin: '' otherwise.
String cachedEstimatesNote(List<Package> packages) => packages.any((p) => p.stateEstimate)
    ? " For some products in it only the state's psilocybin is known, shown as mg psilocybin."
    : '';

/// The engine's center_stock refresher: a load as the cart makes it ([CenterStock.fetch],
/// from [stock], which gives null without a session to read the state with), its body as [keepCenterStock] keeps it
/// ({"packages": [...], "source": ...}) and where it came from: merged when the state answered beside the server, server
/// when only the server did, state when only the state did. A load that fell back to the kept copy, or found nothing,
/// is a failed refresh (the engine keeps the body and its time): a kept copy is never stamped as read again.
Refresher centerStockRefresher(Future<CenterStock?> Function() stock) => (key) async {
      final stateId = int.tryParse(key);
      if (stateId == null) throw ArgumentError.value(key, 'key', 'not a center id');
      final s = await stock();
      if (s == null) throw StateError('no session to read the state system with');
      final r = await s.fetch(stateId);
      if (r.source == InventorySource.cache) throw StateError('neither the state system nor the server answered');
      final source = r.source == InventorySource.live ? (r.stateRead ? sourceMerged : sourceServer) : sourceState;
      return (
        body: jsonEncode({'packages': [for (final p in r.packages) p.toJson()], 'source': source}),
        source: source,
      );
    };

/// Whether stock read at [readAt] is too old to sell from at [now] (older than [maxAge]; exactly [maxAge] is
/// still sellable). A time in the future counts as just read. Whole milliseconds, as stored times are kept
/// (sync_dataset.fetched_at_ms): a kept time has lost its microseconds, and must not read as older for it.
bool stockTooOld(DateTime readAt, DateTime now, Duration maxAge) =>
    now.millisecondsSinceEpoch - readAt.millisecondsSinceEpoch > maxAge.inMilliseconds;

/// What the cart says when it refuses to sell from stock that is too old, [maxAge] in words.
String staleStockRefusal(Duration maxAge) =>
    'The stock on this phone was read more than ${_inWords(maxAge)} ago, so nothing was sent. '
    'Load the stock again (Retry) before selling.';

String _inWords(Duration d) {
  if (d.inDays >= 1 && d.inHours % 24 == 0) return d.inDays == 1 ? '1 day' : '${d.inDays} days';
  if (d.inHours >= 1 && d.inMinutes % 60 == 0) return d.inHours == 1 ? '1 hour' : '${d.inHours} hours';
  return '${d.inMinutes} minutes';
}

/// What the center_stock dataset keeps for a center ([keptCenterStock]): the packages as last read, by whichever step,
/// and when that read started.
class CachedInventory {
  final List<Package> packages;
  final DateTime fetchedAt;
  CachedInventory({required this.packages, required this.fetchedAt});
}

/// Keeps [packages] as [stateId]'s center_stock copy in [datasets], read from [source] (sync_datasets.dart's sources)
/// at [fetchedAt]: the body {"packages": [...], "source": ...}. An older read finishing last never replaces a newer one
/// ([Datasets.put]); never throws.
void keepCenterStock(Datasets datasets, int stateId, List<Package> packages, DateTime fetchedAt,
        {String source = sourceMerged}) =>
    datasets.put(Dataset.centerStock, '$stateId',
        jsonEncode({'packages': [for (final p in packages) p.toJson()], 'source': source}),
        source: source, at: fetchedAt);

/// [stateId]'s center_stock copy in [datasets] with when it was read (UTC); null when none is kept, or what is kept
/// can't be read back. No staleness rule: the caller decides (shown at any age; the cart refuses to sell from stock
/// older than 3 days).
CachedInventory? keptCenterStock(Datasets datasets, int stateId) {
  final row = datasets.read(Dataset.centerStock, '$stateId');
  if (row == null) return null;
  final packages = centerStockPackages(row.body);
  return packages == null ? null : CachedInventory(packages: packages, fetchedAt: row.fetchedAt.toUtc());
}

/// The packages of a center_stock body ({"packages": [...], "source": ...}); null when it isn't one (a damaged copy:
/// as if none were kept).
List<Package>? centerStockPackages(String body) {
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

class CenterStock {
  CenterStock({
    required this.fetchServer,
    required this.fetchRawState,
    required this.fetchFromState,
    required this.datasets,
    required this.session,
    this.onStateRead,
    this.enableStateFallback = true,
    this.now = DateTime.now,
  });

  /// Mazama's server's rows (/p/packages).
  final Future<List<Package>> Function(int stateId) fetchServer;

  /// The state's raw records (GetPackagedProducts).
  final Future<List<Object?>> Function(int stateId, {required String accessToken}) fetchRawState;

  /// The second step: the state's own packages.
  final Future<List<Package>> Function(int stateId, {required String accessToken}) fetchFromState;

  /// Where every read is kept (the center_stock dataset, the third step) and the figures kept for fills (the
  /// enrichment dataset).
  final Datasets datasets;

  /// The worker's session, read fresh at every load (the cart renews it).
  final Session? Function() session;

  /// Given every raw state read of step 1 (the cart uploads it); never awaited, its failures ignored.
  final void Function(int stateId, List<Object?> records)? onStateRead;

  final bool enableStateFallback;
  final DateTime Function() now;

  Map<String, PackageEnrichment> _known() {
    try {
      return keptEnrichment(datasets, now());
    } catch (_) {
      return const {};
    }
  }

  void _remember(List<Package> serverRows) {
    if (serverRows.isEmpty) return;
    try {
      rememberServerFigures(datasets, serverRows, now());
    } catch (_) {
      // nothing remembered this time; what was kept before stays
    }
  }

  void _keep(int stateId, List<Package> packages, String source, DateTime startedAt) {
    try {
      keepCenterStock(datasets, stateId, packages, startedAt, source: source);
    } catch (_) {
      // kept next time; the stock itself is good
    }
  }

  Future<InventoryFetch> fetch(int stateId) async {
    final startedAt = now(); // what this load keeps is as old as its start, per load
    Object firstError;
    final s = session();
    List<Package>? server;
    List<Object?>? raw;
    Object? serverError, stateError;
    await Future.wait<void>([
      Future(() async {
        try {
          server = await fetchServer(stateId);
        } catch (e) {
          serverError = e;
        }
      }),
      Future(() async {
        try {
          if (s == null) throw StateError('no session');
          raw = await fetchRawState(stateId, accessToken: s.accessToken);
        } catch (e) {
          stateError = e;
        }
      }),
    ]);
    final records = raw;
    if (records != null) {
      final report = onStateRead;
      if (report != null) {
        try {
          report(stateId, records);
        } catch (_) {
          // the upload is best effort, never in the way of the stock
        }
      }
    }
    if (server != null || records != null) {
      try {
        final known = server == null ? _known() : const <String, PackageEnrichment>{};
        final merged = mergeStock(stateRecords: records, serverRows: server, enrichment: known, configured: true);
        if (merged.serverKeys != null) {
          _remember(merged.remember);
          _keep(stateId, merged.packages, records == null ? sourceServer : sourceMerged, startedAt);
          return InventoryFetch(
              packages: merged.packages,
              source: InventorySource.live,
              serverKeys: merged.serverKeys,
              stateRead: records != null);
        }
        _keep(stateId, merged.packages, sourceState, startedAt);
        return InventoryFetch(packages: merged.packages, source: InventorySource.state, stateRead: true);
      } catch (e) {
        firstError = e;
      }
    } else {
      firstError = StockMergeError('both inventory sources failed: ${serverError ?? ''} ${stateError ?? ''}'.trim());
    }

    final fallback = enableStateFallback ? session() : null;
    if (fallback != null) {
      try {
        final state = await fetchFromState(stateId, accessToken: fallback.accessToken);
        final filled = applyEnrichment(state, _known());
        _keep(stateId, filled, sourceState, startedAt);
        return InventoryFetch(packages: filled, source: InventorySource.state, stateRead: true);
      } catch (_) {
        // says nothing worth showing on its own: the kept stock, or the first error, comes next
      }
    }

    try {
      final kept = keptCenterStock(datasets, stateId);
      if (kept != null) {
        return InventoryFetch(packages: kept.packages, source: InventorySource.cache, asOf: kept.fetchedAt);
      }
    } catch (_) {
      // nothing readable kept
    }
    throw firstError;
  }

  /// The packages alone, for the pages that take a plain fetch (StockPage, the picker after Switch center).
  Future<List<Package>> fetchPackages(int stateId) async => (await fetch(stateId)).packages;
}
