// Item 2 of "mazama_sales no longer auto-syncs every 12 hours": for a CONFIGURED center, CartPage now pulls
// inventory from BOTH mazama_sales (packages_client.dart's fetchPackages - the enriched view: real strain,
// real tpeMg, and the coaAvailable/labelAvailable flags items 3b/4 need) AND the state system directly
// (state_packages_client.dart's fetchPackagesFromState - the freshest quantity, now that mazama_sales' own
// mirror can go stale for up to settings.auto_sync_interval_hours, or indefinitely with auto-sync turned
// off entirely) - merged every time this is called, not as a failure fallback. The cart no longer calls this: it reads
// through lib/sync/center_stock.dart (the same join, in sync/stock_merge.dart's mergeStock, with its fallbacks); this
// is still the stock page's (stock_rows.dart's loadCenterStock) and a debug page's, for when both sides answer but may
// disagree about what's actually in stock right now.
//
// Merge key: productGuid + id (one lot - see packages_client.dart's own PkprGroup comment on why a PKPR can
// have more than one). The state's own row wins for quantity/weightPerUnit/analyteWeight - those are the
// numbers that go stale without mazama_sales' own sync. Mazama's own row wins for strain/tpeMg/coaAvailable/
// labelAvailable - things only mazama_sales' own certificate-folder matching and label folder can answer at
// all; the state system has no idea whether a COA or label exists - and for the stock page's mazama, expired,
// unitMgTpe and description (SP-D10).
//
// A lot the state system has but mazama_sales' own /p/packages/{stateId} doesn't (made or transferred in
// since mazama_sales' mirror last refreshed) keeps the state's own degraded strain/tpeMg AND is marked
// coaAvailable/labelAvailable = false rather than silently assuming either is fine - see _unknownCoaLabel.
// CartPage would rather double-check a lot it has no server-side word on than skip a COA/label submission
// that's actually needed.
import 'dart:async';

import 'package:http/http.dart' as http;

import 'packages_client.dart' as packages_client;
import 'state_packages_client.dart' as state_packages_client;

/// -> [fetchMergedInventory]'s result: the merged packages, plus which of the two sources actually answered
/// (the stock page uses these to decide what to say about the figures it shows, in the same spirit as
/// center_stock.dart's InventorySource - but both sources missing is the only case that's fatal here, surfaced by
/// [fetchMergedInventory] throwing rather than returning an empty, misleading result).
class MergedInventoryResult {
  final List<packages_client.Package> packages;
  final bool mazamaOk;
  final bool stateOk;

  /// The state system's own RAW records (unmapped), present only when [stateOk] - this is exactly what a
  /// caller should hand to inventory_upload_client.dart's uploadInventorySnapshot for item 3a ("push after
  /// every state read"), since it is, by definition, a fresh state read that just happened.
  final List<Object?>? rawStateRecords;

  /// mazama_sales' own rows, present only when [mazamaOk]: the stock page counts only the lots the server returned
  /// (SP-D9: it leaves out what it won't sell), with the merged quantities.
  final List<packages_client.Package>? mazamaPackages;

  MergedInventoryResult(
      {required this.packages, required this.mazamaOk, required this.stateOk, this.rawStateRecords, this.mazamaPackages});
}

class MergedInventoryError implements Exception {
  final String message;
  MergedInventoryError(this.message);
  @override
  String toString() => message;
}

/// A lot only the state system knows about this call: strain/tpeMg stay whatever the state-only read already
/// degraded them to (state_packages_client.dart's own file comment), and coaAvailable/labelAvailable are
/// forced to false - not because either is actually known to be missing, but because mazama_sales (the only
/// source that could say "yes, on file") was never asked about this specific lot at all.
packages_client.Package _unknownCoaLabel(packages_client.Package p) => packages_client.Package(
      productGuid: p.productGuid,
      productType: p.productType,
      id: p.id,
      weightPerUnit: p.weightPerUnit,
      analyteWeight: p.analyteWeight,
      quantity: p.quantity,
      exactQuantity: p.exactQuantity,
      lotGuid: p.lotGuid,
      strain: p.strain,
      tpeMg: p.tpeMg,
      coaAvailable: false,
      labelAvailable: false,
      expires: p.expires,
      mazama: p.mazama,
      expired: p.expired,
      unitMgTpe: p.unitMgTpe,
      description: p.description,
      type: p.type,
    );

/// Runs mazama_sales' fetchPackages and the state system's own fetchPackagesFromState concurrently and merges
/// them (see this file's own header comment for the exact rule). Throws [MergedInventoryError] only when
/// BOTH sources fail - either one succeeding is enough to return something a page can show, in the same spirit as
/// center_stock.dart's "the original failure is what's worth surfacing" rule, except here there is no kept copy to
/// fall further back to (the caller's job: stock_rows.dart falls back to the rows last drawn on the phone).
Future<MergedInventoryResult> fetchMergedInventory(
  int stateId, {
  required String accessToken,
  Future<List<packages_client.Package>> Function(int stateId) fetchMazama = packages_client.fetchPackages,
  Future<List<Object?>> Function(int stateId, {required String accessToken}) fetchRawState =
      state_packages_client.fetchRawPackagesFromState,
  http.Client? client,
}) async {
  List<packages_client.Package>? mazama;
  List<Object?>? rawState;
  Object? mazamaError;
  Object? stateError;

  await Future.wait<void>([
    Future(() async {
      try {
        mazama = await fetchMazama(stateId);
      } catch (e) {
        mazamaError = e;
      }
    }),
    Future(() async {
      try {
        rawState = await fetchRawState(stateId, accessToken: accessToken);
      } catch (e) {
        stateError = e;
      }
    }),
  ]);

  if (mazama == null && rawState == null) {
    throw MergedInventoryError('both inventory sources failed: ${mazamaError ?? ''} ${stateError ?? ''}'.trim());
  }
  if (rawState == null) {
    return MergedInventoryResult(packages: mazama!, mazamaOk: true, stateOk: false, mazamaPackages: mazama);
  }
  final state = state_packages_client.mapRawPackagesFromState(rawState!);
  if (mazama == null) {
    return MergedInventoryResult(
        packages: [for (final p in state) _unknownCoaLabel(p)], mazamaOk: false, stateOk: true, rawStateRecords: rawState);
  }

  final byKey = <String, packages_client.Package>{for (final p in mazama!) '${p.productGuid}#${p.id}': p};
  final merged = <packages_client.Package>[];
  for (final sp in state) {
    final mp = byKey['${sp.productGuid}#${sp.id}'];
    if (mp == null) {
      merged.add(_unknownCoaLabel(sp));
      continue;
    }
    merged.add(packages_client.Package(
      productGuid: sp.productGuid,
      productType: sp.productType,
      id: sp.id,
      weightPerUnit: sp.weightPerUnit,
      analyteWeight: sp.analyteWeight,
      quantity: sp.quantity,
      exactQuantity: sp.exactQuantity,
      lotGuid: sp.lotGuid ?? mp.lotGuid,
      strain: mp.strain,
      tpeMg: mp.tpeMg,
      coaAvailable: mp.coaAvailable,
      labelAvailable: mp.labelAvailable,
      expires: mp.expires, // SM-17: only the server knows a record's expiry; the sale draws the earliest first
      // SP-D10: the server's own word on these; only the quantity (above) is the state's.
      mazama: mp.mazama,
      expired: mp.expired,
      unitMgTpe: mp.unitMgTpe,
      description: mp.description,
      type: mp.type, // specs/edibles ED-R2: the server's kind code
      labelInput: mp.labelInput, // README R64: the server's, for a label drawn without the lab report
    ));
  }
  // A lot mazama_sales' own mirror still lists that the state system no longer does (sold out, transferred
  // away, or otherwise dropped) is NOT carried forward - the state's own live list is authoritative for which
  // lots still exist at all, the same "drop what's no longer really there" rule public_packages itself
  // already applies server-side.
  return MergedInventoryResult(
      packages: merged, mazamaOk: true, stateOk: true, rawStateRecords: rawState, mazamaPackages: mazama);
}
