// Item 3b: once a product is placed in the cart at a CONFIGURED service center and its own PKPR, HB or PL
// turns out to have no COA (or no label) on file yet - packages_client.dart's Package.coaAvailable/
// labelAvailable, carried through merged_inventory.dart's merge - CartPage submits that lot's own lab report to
// mazama_sales right away, using the exact same three-call pipeline coa_data_resolver.dart already runs for an
// UNCONFIGURED center's misses (GetPackagedProductInfo -> pick the newest non-deprecated accepted-Potency-test
// PDF -> downloadStateDocument -> uploadCoaParse): the "already built function" per the user's own request,
// just reached from a different trigger (a cart add at a configured center, not a whole-inventory load at an
// unconfigured one).
//
// mazama_sales' own web/stock_pages.py (the coa_data_parse route) is what joins the result into the shared
// adhoc_coa table AND the configured pipeline's own coa_dir/CoaFolder (adhoc_coa.py's save_certificate), making
// it visible to every service center, configured or not - and, per item 4, auto-queues a label once the parse
// succeeds (that route's own _queue_labels_for_lot). This file only has to get the PDF there; the server does
// the rest of items 3b/4 on its own, identically whichever trigger reached it.
//
// Never blocks a cart add: CartPage calls submitCoaForLot fire-and-forget (see its own _ensureCoaForCartLine),
// the same spirit as its unawaited(_showLabelDialog(...)) right after _onAddPkpr finishes. A failure here (no
// PDF on file yet at the state system, a parse error, a network hiccup) is never surfaced to the worker - the
// same "stays degraded, no retry storm" rule coa_data_resolver.dart's own per-guid miss handling already
// applies. The gap just means this lot's coaAvailable/labelAvailable stay false until the next successful
// resolution, whether that's another worker's cart add, mazama_sales' own ad hoc flow, or the configured
// pipeline's ordinary sync-worker certificate run finally catching up to it.
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'coa_data_client.dart';
import 'coa_data_resolver.dart' show newestPotencyPdfDocId;
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;
import 'state_client.dart';
import 'state_document_client.dart';

class ConfiguredCoaSubmitError implements ServerRequestError {
  @override
  final String message;

  /// True when the report couldn't reach Mazama's server (server_error.dart's rule): server_link.dart then keeps the
  /// lot and submits it again once the server answers. A state-system failure is never this.
  @override
  final bool unreachable;
  ConfiguredCoaSubmitError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}

/// Submits [lotGuid]'s own lab report to mazama_sales. [representativePackageId] is any ONE package's own
/// state-system id backing this lot - GetPackagedProductInfo is keyed by a package id, never a lot guid or a
/// service center's id (the same caveat coa_data_resolver.dart's own worker() documents, and the same mistake
/// its own comment records having to fix once already - using a center's id there silently returned no PDF for
/// every lot). Returns the parsed [CoaData] on success, or null when there is simply nothing to submit yet (no
/// accepted Potency-test PDF on file for this lot at the state system at all) - a caller should treat a null
/// return and a thrown [ConfiguredCoaSubmitError] the same way: nothing more to do right now, try again next
/// time this lot comes up.
Future<CoaData?> submitCoaForLot({
  required String lotGuid,
  required int representativePackageId,
  required String accessToken,
  required String workerEmail,
  required String deviceId,
  /// The state's psilocybin figure for this lot (the package's analyteWeight, mg/g), sent with the report as the
  /// adhoc path (coa_data_resolver.dart) sends it, so the server can pick the lot's section the same way.
  double? statePsilocybin,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  // The upload to Mazama's server goes through the server link (README R56) unless a client was given; the state
  // system's reads never do.
  final server = client ?? serverClient();
  final shouldClose = client == null;
  try {
    Object? info;
    try {
      info = await fetchStateFlow('packaged_product_info', {'package_id': representativePackageId},
          accessToken: accessToken, client: c);
    } on StateReadError catch (ex) {
      throw ConfiguredCoaSubmitError(ex.message);
    }
    final docId = newestPotencyPdfDocId(info);
    if (docId == null) return null; // no lab report on file at the state system yet - stays degraded for now
    Uint8List bytes;
    try {
      bytes = await downloadStateDocument(docId, accessToken: accessToken, client: c);
    } on StateDocumentError catch (ex) {
      throw ConfiguredCoaSubmitError(ex.message);
    }
    try {
      return await uploadCoaParse(
        guid: lotGuid,
        pdfBytes: bytes,
        docId: docId,
        workerEmail: workerEmail,
        deviceId: deviceId,
        statePsilocybin: statePsilocybin,
        client: server,
      );
    } on CoaDataError catch (ex) {
      throw ConfiguredCoaSubmitError(ex.message, unreachable: ex.unreachable);
    }
  } finally {
    if (shouldClose) {
      c.close();
      server.close();
    }
  }
}
