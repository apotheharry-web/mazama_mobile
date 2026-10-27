// Orchestrates the whole adhoc-COA flow (see coa_data_client.dart's own file comment for the three HTTP calls
// this builds on) for a service center mazama_sales has never heard of - the thing CartPage actually calls
// once centerIsConfigured (coa_data_client.dart) has said "no" for this center's stateId, in place of its
// normal ResilientInventory.fetch.
//
//   1. fetchPackagesFromState (state_packages_client.dart) - the center's raw inventory, direct from the state
//      system. This IS resilient_inventory.dart's own tier 2, reused here as the only source there is: tier 1
//      (Mazama's own server) has nothing for a center it was never configured for, by definition.
//   2. Every distinct lotGuid across that inventory, looked up in one batch (fetchCoaDataBatch) - always tried
//      first, before anything else below, so a lot any other worker anywhere has ever resolved costs nothing
//      here.
//   3. For guids the batch lookup didn't return (capped at [maxMisses], so a center with dozens of brand-new
//      lots can't hang a single load): GetPackagedProductInfo(packageId) - keyed by one representative
//      PACKAGE's own state-system id for this lot, never the service center's id (see labpdfs.py's own
//      _package_candidates/session.packaged_product_info for the server-side precedent this mirrors; an
//      ordinary JSON read, fetchStateJson already covers it) -> the newest non-deprecated accepted-Potency-test
//      PDF document id (newestPotencyPdfDocId, ported from labpdfs.py's own _pdf_docs) -> downloadStateDocument
//      -> uploadCoaParse.
//      Run through a small fixed-size worker pool ([maxConcurrent] in flight at once) rather than all at once,
//      so a center with a lot of misses doesn't fire dozens of simultaneous PDF-rendering requests at the
//      server (see mazama_sales' ratelimit.py's own coa_parse budget).
//
// Every guid that resolves - by the batch lookup or by a fresh parse - is applied to its packages immediately
// (via [onResolved], called as each one lands) rather than waiting for every miss to finish, so a caller can
// repaint progressively instead of blocking the whole screen on the slowest lot. A guid that never resolves
// (no PDF found, a parse failure, or past [maxMisses]) simply keeps today's degraded blank-strain/estimated-TPE
// values - exactly resilient_inventory.dart's own tier-2 behavior - never a retry storm and never a reason to
// fail the whole load.
import 'dart:async';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'coa_data_client.dart';
import 'dose.dart';
import 'packages_client.dart';
import 'select_documents.dart';
import 'server_link_client.dart' show serverClient;
import 'state_client.dart';
import 'state_document_client.dart';
import 'state_packages_client.dart';

/// One load's worth of adhoc-COA results: the enriched packages (whatever fetchCoaDataBatch/uploadCoaParse
/// resolved already folded in - see _applyCoaData), how many distinct lot guids this inventory had, and how
/// many of those actually resolved (by cache hit or by a fresh parse). [guidsResolved] < [guidsTotal] means at
/// least one lot stayed at today's degraded blank-strain/estimated-TPE values (no PDF on file, a parse failure,
/// or it fell past [maxMisses]) - the caller (CartPage) uses the gap to word its banner, not to retry anything
/// automatically.
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

/// How many lab reports one load may upload for parsing at most (SM-23): the server's per-minute budget for
/// /p/coa-data/parse (routes.yaml), so a load never plans uploads that are bound to be refused with a 429.
const defaultMaxMisses = coaDataParseRateLimitPerMinute;

/// Runs the whole flow described in this file's own header comment for one center. [onInventoryLoaded] fires
/// once, as soon as the raw state-system inventory itself is in (before any enrichment at all) - a caller that
/// wants to show something on screen immediately, before any guid resolves, sets its own list from this rather
/// than waiting for the return value. [onResolved] is then called once per guid as it resolves - from the batch
/// lookup as soon as it returns, then once per successful miss resolution - so that same caller can patch each
/// one in as it lands instead of waiting for the slowest lot in the whole queue.
Future<AdhocInventoryResult> resolveAdhocInventory({
  required int stateId,
  required String accessToken,
  required String workerEmail,
  required String deviceId,
  void Function(List<Package> packages)? onInventoryLoaded,
  void Function(String guid, Package updated)? onResolved,
  int maxConcurrent = 4,
  int maxMisses = defaultMaxMisses,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  // Mazama's server's own calls (the batch lookup, the uploads) go through the server link (README R56) unless a
  // client was given; the state system's never do.
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

    Map<String, Package> current = {for (final p in packages) '${p.productGuid}#${p.id}': p};
    void apply(String guid, CoaData data) {
      for (final entry in current.entries.toList()) {
        if (entry.value.lotGuid == guid) {
          final updated = _applyCoaData(entry.value, data);
          current[entry.key] = updated;
          onResolved?.call(guid, updated);
        }
      }
    }

    Map<String, CoaData> hits;
    try {
      hits = await fetchCoaDataBatch(guids, client: server);
    } on CoaDataError {
      hits = const {}; // the batch lookup failing is not fatal - every guid just falls through to the miss path
    }
    for (final entry in hits.entries) {
      apply(entry.key, entry.value);
    }

    final misses = guids.where((g) => !hits.containsKey(g)).toList();
    final toResolve = misses.take(maxMisses).toList();
    var resolved = hits.length;

    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= toResolve.length) return;
        final guid = toResolve[i];
        try {
          // GetPackagedProductInfo is keyed by a PACKAGE's own state-system id (packaged_product.state_id in
          // mazama_sales' own schema - see labpdfs.py's _package_candidates/Runner.run, which calls
          // session.packaged_product_info(cand["state_id"]) with exactly that, never the service center's own
          // id). byGuid[guid] is this lot's one representative package (any package carrying this guid works -
          // the test history belongs to the lot, not the specific package, same comment _package_candidates
          // makes) - using [stateId] (the CENTER's id) here instead was a real bug: GetPackagedProductInfo/
          // {center id} isn't a package at all, so every lot silently came back with no PDF on file.
          final info =
              await fetchStateFlow('packaged_product_info', {'package_id': byGuid[guid]!.id}, accessToken: accessToken, client: c);
          final docId = newestPotencyPdfDocId(info);
          if (docId == null) continue; // no lab report on file at all for this lot yet - stays degraded
          final bytes = await downloadStateDocument(docId, accessToken: accessToken, client: c);
          final data = await uploadCoaParse(
            guid: guid,
            pdfBytes: bytes,
            docId: docId,
            workerEmail: workerEmail,
            deviceId: deviceId,
            statePsilocybin: byGuid[guid]!.analyteWeight,
            client: server,
          );
          apply(guid, data);
          resolved++;
        } catch (_) {
          // This one lot's miss failing (unreadable report, network hiccup, this guid's own UID not actually in
          // the document) is never fatal to the rest of the queue or the load as a whole - see this file's own
          // header comment: it just stays at today's degraded blank-strain/estimated-TPE values.
        }
      }
    }

    await Future.wait(List.generate(maxConcurrent.clamp(1, toResolve.length == 0 ? 1 : toResolve.length), (_) => worker()));

    return AdhocInventoryResult(packages: current.values.toList(), guidsTotal: guids.length, guidsResolved: resolved);
  } finally {
    if (shouldClose) {
      c.close();
      server.close();
    }
  }
}
