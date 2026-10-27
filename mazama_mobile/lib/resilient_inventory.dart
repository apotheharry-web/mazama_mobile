// The three-tier fallback behind "stock is still usable even when something's down": CartPage and StockPage
// both just call a plain Future<List<Package>> Function(int) - see packages_client.dart's own fetchPackages -
// and this is what CartPage actually hands them in production (cart_page.dart's own _resilient field), wrapped
// around whatever `base` it was given.
//
// On every call:
//   1. Try `base` (normally packages_client.fetchPackages - Mazama's own /p/packages/{state_id}, no login). On
//      success, save it to [cache] and return it. This is the ONLY tier that returns Mazama's own enrichment
//      (real strain names, real tpeMg from the best known potency, including a COA override) - the other two
//      exist purely to keep the app usable while Mazama's own server (not just the network) is unreachable.
//   2. If that fails, [enableStateFallback] is true (the ResilienceOptions build-time knob - see that file's
//      own comment), and a [session] is available, try state_packages_client.dart's fetchPackagesFromState -
//      the real Oregon state system's own GetPackagedProducts, direct, using the SAME access token the worker
//      is already signed in with for selling (session.dart). On success, save it to [cache] too (so a LATER
//      failure of both tiers 1 and 2 can still fall back to this, not just to whatever tier 1 last produced)
//      and return it - but see state_packages_client.dart's own file comment for exactly what's missing from
//      this tier (blank strain, an estimated tpeMg).
//   3. If THAT fails too (or there's no session to try it with), fall back to whatever [cache] has on file for
//      this center, but only if it's no older than [maxAge] (3 days by default - see cart_page.dart). Past
//      that, showing it would risk a worker selling against a count that's not just approximate but actually
//      likely wrong by now, which is worse than a plain "could not load" screen telling them something's
//      actually broken and needs attention.
//
// Mazama's last word, reused offline (enrichment_store.dart): every time Mazama's server answers, its own rows'
// strain, tpeMg and expires are remembered per package in [ResilientInventory.enrichment], with the weightPerUnit and
// analyteWeight they were worked out from. Whenever stock comes from the state system alone instead (tier 2, or a
// [ResilientInventory.merged] read the server didn't answer), those are filled back in for each package whose weight
// and state potency are exactly what they were then (applyEnrichment); every other package stays the state's estimate
// and is marked Package.stateEstimate, so the screens can say which figures are which (stateSourceNotice). Since SM-D31
// the figures kept also include the phone's own coa_core reading of a lab report (phone_label.dart), and a package with
// neither shows only the state's psilocybin, called mg psilocybin on every screen (Package.mgFigure).
//
//   4. If nothing above produced anything, the error thrown is always the ORIGINAL failure from `base` (tier
//      1) - that's the one that actually describes what's wrong (Mazama's server down, a bad network, etc.);
//      whatever tier 2/3 failed with along the way is strictly less informative and never surfaces on its own.
import 'dart:async';

import 'enrichment_store.dart';
import 'inventory_cache_store.dart';
import 'merged_inventory.dart' show MergedInventoryResult;
import 'packages_client.dart';
import 'session.dart';

/// Which tier actually produced the result a call to [ResilientInventory.fetch] returned - CartPage reads this
/// right after the call completes (see its own _inventorySource field) to decide whether to show a banner
/// telling the worker this isn't live data from Mazama's own server.
/// [adhoc] is CartPage's own addition, not something ResilientInventory.fetch itself ever returns: a center
/// center_status (coa_data_client.dart) says Mazama has never been configured for at all, so CartPage runs
/// coa_data_resolver.dart's resolveAdhocInventory instead of this class entirely (see cart_page.dart's own
/// _loadInventory) and tags the result with this value for the same banner/StockPage plumbing [state]/[cache]
/// already use.
enum InventorySource { live, state, cache, adhoc }

/// The result of one [ResilientInventory.fetch] call: the packages themselves, which tier produced them, and -
/// for [InventorySource.cache] only - how old that cached snapshot was. live/state are always "just now" (both
/// are a real network call that only returns on success), so [asOf] is null for those; a worker only ever needs
/// to see an age for the one tier that can be genuinely stale.
class InventoryFetch {
  final List<Package> packages;
  final InventorySource source;
  final DateTime? asOf;
  InventoryFetch({required this.packages, required this.source, this.asOf});
}

class ResilientInventory {
  /// Tier 1 as a plain list: Mazama's server's own rows, exactly as /p/packages sent them (remembered as they are in
  /// [enrichment]). Used only when [merged] is null.
  final Future<List<Package>> Function(int stateId)? base;

  /// Tier 1 as CartPage runs it for a configured center (merged_inventory.dart): the server's rows joined with the
  /// state's live ones. When the server answered, its own rows (MergedInventoryResult.mazamaPackages - never the
  /// merged ones, whose weights are the state's) are remembered in [enrichment] and the result is [InventorySource.live].
  /// When only the state answered, the result is the state's alone, filled in from [enrichment] where safe, and is
  /// reported as [InventorySource.state] - the same honest label as tier 2, since it is the same data.
  final Future<MergedInventoryResult> Function(int stateId)? merged;

  /// What Mazama's server last sent per package (enrichment_store.dart). Null: nothing is remembered or filled in, and
  /// a state-only result is left exactly as the state read gave it (unmarked), as before this existed.
  final EnrichmentStore? enrichment;
  final Future<List<Package>> Function(int stateId, {required String accessToken}) fetchFromState;
  final InventoryCacheStore cache;

  /// The worker's current session, read fresh on every call (never captured once) - CartPage passes `() =>
  /// _session`, its own State field that _maybeRenewSession keeps up to date, so tier 2 always uses whatever
  /// access token is actually current right now, not whatever it was when this ResilientInventory was built.
  /// Null (rather than a Session that can't actually authenticate) skips tier 2 outright, going straight from
  /// a failed tier 1 to tier 3.
  final Session? Function() session;

  final Duration maxAge;
  final DateTime Function() now;

  /// Build-time knob (ResilienceOptions.enableStateFallback, threaded in by cart_page.dart) - false skips tier
  /// 2 outright, the same as having no session at all, without needing a fake always-null [session] getter
  /// just to turn it off. True by default, same as before this was configurable.
  final bool enableStateFallback;

  ResilientInventory({
    this.base,
    this.merged,
    this.enrichment,
    required this.fetchFromState,
    required this.cache,
    required this.session,
    this.maxAge = const Duration(days: 3),
    this.now = DateTime.now,
    this.enableStateFallback = true,
  }) : assert(base != null || merged != null, 'ResilientInventory needs a base or a merged tier 1');

  /// Remembers the server's own rows; never lets a failed write (a full disk) get in the way of showing the stock.
  void _remember(List<Package> serverRows) {
    final store = enrichment;
    if (store == null) return;
    try {
      unawaited(store.remember(serverRows, now()).catchError((_) {}));
    } catch (_) {
      // nothing remembered this time; what was kept before stays
    }
  }

  /// [statePackages] (the state system's alone) with the server's last figures filled in where safe
  /// (applyEnrichment), or as they are when there is no [enrichment] store.
  Future<List<Package>> _fill(List<Package> statePackages) async {
    final store = enrichment;
    if (store == null) return statePackages;
    Map<String, PackageEnrichment> known;
    try {
      known = await store.load(now());
    } catch (_) {
      known = const {};
    }
    return applyEnrichment(statePackages, known);
  }

  Future<InventoryFetch> fetch(int stateId) async {
    Object liveError;
    try {
      final m = merged;
      if (m != null) {
        final result = await m(stateId);
        final serverRows = result.mazamaPackages;
        if (result.mazamaOk && serverRows != null) {
          _remember(serverRows);
          unawaited(cache.save(stateId, result.packages, now()));
          return InventoryFetch(packages: result.packages, source: InventorySource.live);
        }
        final filled = await _fill(result.packages);
        unawaited(cache.save(stateId, filled, now()));
        return InventoryFetch(packages: filled, source: InventorySource.state);
      }
      final pkgs = await base!(stateId);
      _remember(pkgs);
      unawaited(cache.save(stateId, pkgs, now()));
      return InventoryFetch(packages: pkgs, source: InventorySource.live);
    } catch (e) {
      liveError = e;
    }

    final session = enableStateFallback ? this.session() : null;
    if (session != null) {
      try {
        final pkgs = await _fill(await fetchFromState(stateId, accessToken: session.accessToken));
        unawaited(cache.save(stateId, pkgs, now()));
        return InventoryFetch(packages: pkgs, source: InventorySource.state);
      } catch (_) {
        // Tier 2 failing says nothing worth surfacing on its own - tier 3 (or, failing that, liveError) is
        // still the right next step either way.
      }
    }

    final cached = await cache.load(stateId);
    if (cached != null && now().difference(cached.fetchedAt) <= maxAge) {
      return InventoryFetch(packages: cached.packages, source: InventorySource.cache, asOf: cached.fetchedAt);
    }

    throw liveError;
  }

  /// A plain `Future<List<Package>> Function(int)` tear-off - the exact shape CartPage.fetchPackages (and, by
  /// extension, StockPage's and SelectCenterPage's own same-shaped fields, once CartPage hands this down to
  /// them) already expects, so cart_page.dart needs no change to either of those widgets just to make their
  /// fetch resilient too. Drops which tier answered - CartPage reads that straight off [fetch] itself, right
  /// where it has an _inventorySource field to put it in; nothing downstream of StockPage/SelectCenterPage
  /// needs to know.
  Future<List<Package>> fetchPackages(int stateId) async => (await fetch(stateId)).packages;
}

/// The banner for stock read from the state system alone ([InventorySource.state]), from what its packages say about
/// themselves (applyEnrichment's marks), counted by PKPR as the screens show them (SM-D31):
///   - nothing filled in from figures kept on the phone (or no marks at all): only the state's psilocybin is known, and
///     the amounts are shown as mg psilocybin, not TPE.
///   - every PKPR filled in: says where the strain and TPE are from - Mazama's last update, this phone's reading of the
///     lab reports, or both - on the oldest date involved, and that the counts are the state's (a banner is still shown:
///     the counts and the COA/label flags are not Mazama's live word).
///   - some filled, some not: the same, for how many, and says that for the rest only the state's psilocybin is known,
///     shown as mg psilocybin and marked in the stock list.
String stateSourceNotice(List<Package> packages) {
  const degraded = "Mazama's own server could not be reached - showing stock read directly from the state system. "
      "No TPE is known for these products: amounts are the state's psilocybin only, shown as mg psilocybin, and "
      'strain names are only what the product names say.';
  final groups = groupByPkpr(packages);
  final filled = [for (final g in groups) if (!groupIsEstimate(g) && groupEnrichedAt(g) != null) g];
  if (filled.isEmpty) return degraded;
  var oldest = groupEnrichedAt(filled.first)!;
  for (final g in filled) {
    final at = groupEnrichedAt(g)!;
    if (at.isBefore(oldest)) oldest = at;
  }
  final date = formatEnrichmentDate(oldest);
  final byPhone = filled.where((g) => groupEnrichedBy(g) == EnrichmentSource.phone).length;
  final from = byPhone == 0
      ? "Mazama's last update on $date"
      : byPhone == filled.length
          ? "this phone's reading of the lab reports, from $date on"
          : "Mazama's last update or this phone's reading of the lab reports, from $date on";
  const lead = "Mazama's own server could not be reached - counts are read directly from the state system.";
  final rest = groups.length - filled.length;
  if (rest == 0) {
    return '$lead Strain and TPE are from $from; the state\'s figures for them have not changed since.';
  }
  final others = rest == 1 ? 'the other product' : 'the other $rest products';
  return '$lead Strain and TPE for ${filled.length} of ${groups.length} products are from $from. '
      'For $others only the state\'s psilocybin is known: shown as mg psilocybin (marked in the stock list), strain '
      'only from the product name.';
}

/// Added to the cached-stock banner ([InventorySource.cache]) when the copy kept was itself a state-only read with
/// products whose only figure is the state's psilocybin: '' otherwise.
String cachedEstimatesNote(List<Package> packages) => packages.any((p) => p.stateEstimate)
    ? " For some products in it only the state's psilocybin is known, shown as mg psilocybin."
    : '';
