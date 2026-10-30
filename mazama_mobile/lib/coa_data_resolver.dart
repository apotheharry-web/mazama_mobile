// Orchestrates the whole adhoc-COA flow (see coa_data_client.dart's own file comment for the three HTTP calls
// this builds on) for a service center mazama_sales has never heard of - the thing CartPage actually calls
// once centerIsConfigured (coa_data_client.dart) has said "no" for this center's stateId, in place of its
// normal load (lib/sync/center_stock.dart's CenterStock.fetch).
//
//   1. fetchPackagesFromState (state_packages_client.dart) - the center's raw inventory, direct from the state
//      system. This IS center_stock.dart's own step 2, reused here as the only source there is: step 1
//      (Mazama's own server) has nothing for a center it was never configured for, by definition.
//   2. Every distinct lotGuid across that inventory, looked up in one batch (fetchCoaDataBatch) - always tried
//      first, before anything else below, so a lot any other worker anywhere has ever resolved costs nothing
//      here.
//   3. Every guid the batch lookup didn't return, with no cap (CU-R1), is handed to the app's one background
//      uploader (coa_uploader.dart), keyed by one representative PACKAGE's own state-system id for its lot, never
//      the service center's id (GetPackagedProductInfo/{center id} isn't a package at all: every lot silently came
//      back with no PDF on file when this once used the center's id). The uploader runs the chain
//      (GetPackagedProductInfo -> the newest accepted potency PDF -> downloadStateDocument -> uploadCoaParse,
//      configured_coa_submit.dart) paced to the server's budget, in the background (CU-R2): this returns as soon as
//      the batch lookup has been applied, never waiting for an upload.
//
// Every guid that resolves - by the batch lookup or, later, by an upload the server answered with its numbers - is
// applied to its packages as it lands (via [onResolved]), so a caller can repaint progressively instead of blocking
// the whole screen on the slowest lot; an upload's answer can come after this function has returned. A guid that
// never resolves (no PDF found, a parse failure, the server queuing it for later) simply keeps today's degraded
// blank-strain/estimated-TPE values - exactly center_stock.dart's own step-2 behavior - never a reason to fail
// the whole load.
import 'package:http/http.dart' as http;

import 'coa_data_client.dart';
import 'coa_uploader.dart';
import 'dose.dart';
import 'packages_client.dart';
import 'select_documents.dart';
import 'server_link.dart' as server_link;
import 'server_link_client.dart' show serverClient;
import 'state_packages_client.dart';

/// One load's worth of adhoc-COA results: the enriched packages (whatever fetchCoaDataBatch/uploadCoaParse
/// resolved already folded in - see _applyCoaData), how many distinct lot guids this inventory had, and how
/// many of those had resolved when it returned (by the batch lookup; an upload's answer comes later, through
/// onResolved). [guidsResolved] < [guidsTotal] means at least one lot was still at today's degraded
/// blank-strain/estimated-TPE values (being uploaded in the background, no PDF on file, a parse failure) - the caller
/// (CartPage) uses the gap to word its banner, not to retry anything automatically.
class AdhocInventoryResult {
  final List<Package> packages;
  final int guidsTotal;
  final int guidsResolved;
  AdhocInventoryResult({required this.packages, required this.guidsTotal, required this.guidsResolved});
}

class AdhocCoaError implements Exception {
  final String message;
  AdhocCoaError(this.message);
  @override
  String toString() => message;
}

/// The first document to read for a lot from a GetPackagedProductInfo reply, or null if there is none: the head of
/// the shared selection (select_documents.dart, SM-06). This app has no local doc-id ledger the way the server's
/// lab_pdf table is one; every miss here is, by definition, a guid the server has never resolved at all.
int? newestPotencyPdfDocId(Object? info) {
  final docs = selectPotencyDocuments(info);
  return docs.isEmpty ? null : docs.first.docId;
}

/// A new Package with [data]'s strain/tpe folded in - the app-side mirror of mazama_sales' stockdata.Stock.mg_of
/// (weightPerUnit x the TPE), rounded up the same way packages_client.dart's own fromJson/tpeMg already is. The TPE
/// is the server's (it already applies the state's psilocybin figure, SM-03); when the server has none, the package
/// keeps the mg it came with (the state's figure): no mg is worked out from the lab report on the phone (SM-D15).
Package _applyCoaData(Package p, CoaData data) {
  final tpePerG = data.tpe;
  return Package(
    productGuid: p.productGuid,
    productType: p.productType,
    id: p.id,
    weightPerUnit: p.weightPerUnit,
    analyteWeight: p.analyteWeight,
    strain: data.strain.isNotEmpty ? data.strain : p.strain,
    tpeMg: tpePerG == null ? p.tpeMg : ceilMg(p.weightPerUnit * tpePerG), // SM-04 (dose.dart)
    quantity: p.quantity,
    lotGuid: p.lotGuid,
  );
}

/// Runs the whole flow described in this file's own header comment for one center. [onInventoryLoaded] fires
/// once, as soon as the raw state-system inventory itself is in (before any enrichment at all) - a caller that
/// wants to show something on screen immediately, before any guid resolves, sets its own list from this rather
/// than waiting for the return value. [onResolved] is then called once per package of each guid as it resolves -
/// from the batch lookup before this returns, then whenever an upload the server answered with its numbers lands
/// (possibly after this has returned) - so that same caller can patch each one in as it lands.
///
/// [workerEmail] and [deviceId] are kept for callers; the uploader sends the session's own at send time.
/// [queueUploads] is the app's uploader (server_link.dart's queueCoaUploads) unless a test gives its own. When the
/// batch lookup itself fails nothing is queued: which lots the server is missing isn't known, and the next load asks
/// again.
Future<AdhocInventoryResult> resolveAdhocInventory({
  required int stateId,
  required String accessToken,
  required String workerEmail,
  required String deviceId,
  void Function(List<Package> packages)? onInventoryLoaded,
  void Function(String guid, Package updated)? onResolved,
  QueueCoaUploads? queueUploads,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  // Mazama's server's own call (the batch lookup) goes through the server link (README R56) unless a client was
  // given; the state system's never do. The uploads are the uploader's (coa_uploader.dart).
  final server = client ?? serverClient();
  final shouldClose = client == null;
  try {
    List<Package> packages;
    try {
      packages = await fetchPackagesFromState(stateId, accessToken: accessToken, client: c);
    } on StatePackagesError catch (ex) {
      throw AdhocCoaError(ex.message);
    }
    onInventoryLoaded?.call(packages);
    final byGuid = <String, Package>{};
    for (final p in packages) {
      final g = p.lotGuid;
      if (g != null && g.isNotEmpty) byGuid.putIfAbsent(g, () => p);
    }
    final guids = byGuid.keys.toList();
    if (guids.isEmpty) {
      return AdhocInventoryResult(packages: packages, guidsTotal: 0, guidsResolved: 0);
    }

    final current = <String, Package>{for (final p in packages) '${p.productGuid}#${p.id}': p};
    void apply(String guid, CoaData data) {
      for (final entry in current.entries.toList()) {
        if (entry.value.lotGuid == guid) {
          final updated = _applyCoaData(entry.value, data);
          current[entry.key] = updated;
          onResolved?.call(guid, updated);
        }
      }
    }

    Map<String, CoaData>? hits;
    try {
      hits = await fetchCoaDataBatch(guids, client: server);
    } on CoaDataError {
      hits = null; // not fatal: the load shows the state's figures, and nothing is uploaded on a guess (see above)
    }
    for (final entry in (hits ?? const <String, CoaData>{}).entries) {
      apply(entry.key, entry.value);
    }

    if (hits != null) {
      final found = hits;
      final misses = guids.where((g) => !found.containsKey(g)).toList();
      if (misses.isNotEmpty) {
        // The uploader may name a lot in another case than this inventory does (another load enqueued it first).
        final ours = {for (final g in misses) g.toLowerCase(): g};
        (queueUploads ?? server_link.queueCoaUploads)(
          [
            for (final g in misses)
              CoaUploadLot(lotGuid: g, packageId: byGuid[g]!.id, stateId: stateId, statePsilocybin: byGuid[g]!.analyteWeight),
          ],
          onResolved: (guid, data) {
            final own = ours[guid.toLowerCase()];
            if (own != null) apply(own, data);
          },
        );
      }
    }

    return AdhocInventoryResult(packages: current.values.toList(), guidsTotal: guids.length, guidsResolved: hits?.length ?? 0);
  } finally {
    if (shouldClose) {
      c.close();
      server.close();
    }
  }
}
