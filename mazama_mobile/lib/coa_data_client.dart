// The app-side half of the adhoc-COA flow: for a service center mazama_sales has never heard of (see
// center_status below), the app reads a center's inventory straight from the state system
// (state_packages_client.dart's fetchPackagesFromState, already used as resilient_inventory.dart's tier 2) and
// then resolves each package's strain/potency itself, directly from its own lab report PDF, instead of relying
// on Mazama's own sync + certificate-folder matching (which never ran for a center that was never configured).
//
// Three calls, all PUBLIC and unauthenticated on the server (see mazama_sales' web/stock_pages.py -
// center_status/coa_data_batch/coa_data_parse - for the server-side half and why):
//   1. centerIsConfigured(stateId) - checked once, up front, before even trying the normal tier-1 fetch, so the
//      app knows to switch into this flow instead of discovering "unconfigured" from a 404 partway through.
//   2. fetchCoaDataBatch(guids) - ALWAYS tried first, for every distinct lot guid in a center's inventory, before
//      touching the state system again or spending any device time... actually this reads a server-side cache,
//      so "spending CPU" means the SERVER's CPU (pdftoppm + Tesseract), not the phone's - a guid this returns
//      means no further work for anyone, ever, for that lot.
//   3. uploadCoaParse(...) - the miss path: only for a guid fetchCoaDataBatch didn't return. The caller is
//      responsible for finding and downloading that lot's own lab report PDF first (GetPackagedProductInfo ->
//      pick the newest non-deprecated accepted-Potency-test document -> DownloadDocument - the same state-system
//      calls labpdfs.py's own _package_candidates path already makes server-side, just run here on-device
//      instead) and hands the raw bytes to this call.
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

class CoaDataError implements ServerRequestError {
  @override
  final String message;

  /// Mazama's server couldn't be reached (server_error.dart's rule).
  @override
  final bool unreachable;

  /// The server's HTTP status when it answered, null when it couldn't be reached. The background uploader
  /// (coa_uploader.dart) tells a reply below 500 (the server has the report: queued, held or refused) from a 429 (busy)
  /// and from no answer at all (CU-R3, CU-R4).
  final int? status;
  CoaDataError(this.message, {this.unreachable = false, this.status});
  @override
  String toString() => message;
}

/// One lot's lab result, resolved either from the server's adhoc_coa cache (fetchCoaDataBatch) or from a fresh
/// upload this device just parsed (uploadCoaParse) - same shape either way (mazama_modules/api/schemas/coa_data_*).
/// [tpe] is the server's, worked out by mazama_sales' coa.tpe (SM-03: the state's psilocybin + 284.25 / 204.27 x
/// psilocin when the state has a figure, else the lab's printed total, else the report's formula). The phone works
/// out no TPE of its own (SM-D15): null is unknown, and so is a missing psilocybin or psilocin - never 0.
class CoaData {
  final String guid;
  final String strain;

  /// Null when the report's value isn't known (ND / below LOQ come as 0).
  final double? psilocybin;
  final double? psilocin;
  // SM-08: analyte names as the shared rules file (mazama_modules/coa/rules/coa_rules.yaml) and coa_core spell them,
  // the same keys /p/coa-data sends.
  final double baeocystin;
  final double norbaeocystin;
  final double norpsilocin;

  /// Null when the report's value isn't known (it doesn't print it, or the server read the lot before it kept it).
  final double? aeruginascin;
  final double? tpe;

  CoaData({
    required this.guid,
    required this.strain,
    this.psilocybin,
    this.psilocin,
    required this.baeocystin,
    required this.norbaeocystin,
    required this.norpsilocin,
    this.aeruginascin,
    this.tpe,
  });

  factory CoaData.fromJson(String guid, Map<String, Object?> j) => CoaData(
        guid: guid,
        strain: j['strain'] as String? ?? '',
        psilocybin: (j['psilocybin'] as num?)?.toDouble(),
        psilocin: (j['psilocin'] as num?)?.toDouble(),
        baeocystin: (j['baeocystin'] as num?)?.toDouble() ?? 0,
        norbaeocystin: (j['norbaeocystin'] as num?)?.toDouble() ?? 0,
        norpsilocin: (j['norpsilocin'] as num?)?.toDouble() ?? 0,
        aeruginascin: (j['aeruginascin'] as num?)?.toDouble(),
        tpe: (j['tpe'] as num?)?.toDouble(),
      );
}


/// GETs /p/center-status/{stateId}. True when Mazama's own server already tracks this service center (the
/// normal tier-1 fetch, packages_client.fetchPackages, will work); false when it's never been configured there
/// at all - the signal that should switch the app into this whole file's flow instead. Throws [CoaDataError] on
/// anything but a clean 200 JSON object (there is no "unknown stateId" case here, unlike fetchPackages -
/// center_status answers {"configured": false} for that instead of 404ing, since "not configured" is exactly
/// the question being asked, not an error).
Future<bool> centerIsConfigured(int stateId, {String baseUrl = apiBaseUrl, http.Client? client}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${centerStatusPath(stateId)}');
    http.Response resp;
    try {
      resp = await c.get(uri, headers: appApiKeyHeaders);
    } catch (ex) {
      throw CoaDataError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode != 200) {
      throw CoaDataError(describeServerError(resp.statusCode, resp.body),
          status: resp.statusCode, unreachable: isUnreachableStatus(resp.statusCode));
    }
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw CoaDataError('the server did not answer with JSON');
    }
    if (body is! Map || body['configured'] is! bool) {
      throw CoaDataError('unexpected response shape');
    }
    return body['configured'] as bool;
  } finally {
    if (shouldClose) c.close();
  }
}

/// POSTs the distinct lot guids from a center's whole inventory to /p/coa-data/batch in one call - always the
/// first thing tried for every guid, before anything else in this file. The result only has entries for guids
/// the server already has on file; a guid with no entry needs the miss path (uploadCoaParse) instead. Throws
/// [CoaDataError] on anything but a clean 200 JSON object.
Future<Map<String, CoaData>> fetchCoaDataBatch(List<String> guids, {String baseUrl = apiBaseUrl, http.Client? client}) async {
  if (guids.isEmpty) return {};
  // The server answers for the first coaDataBatchMaxGuids ids of a request only (routes.yaml): ask in pieces.
  if (guids.length > coaDataBatchMaxGuids) {
    final c = client ?? serverClient();
    try {
      final out = <String, CoaData>{};
      for (var i = 0; i < guids.length; i += coaDataBatchMaxGuids) {
        final end = i + coaDataBatchMaxGuids < guids.length ? i + coaDataBatchMaxGuids : guids.length;
        out.addAll(await fetchCoaDataBatch(guids.sublist(i, end), baseUrl: baseUrl, client: c));
      }
      return out;
    } finally {
      if (client == null) c.close();
    }
  }
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${coaDataBatchPath()}');
    http.Response resp;
    try {
      resp = await c.post(uri, headers: {...appApiKeyHeaders, 'content-type': 'application/json'},
                         body: jsonEncode({'guids': guids}));
    } catch (ex) {
      throw CoaDataError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode != 200) {
      throw CoaDataError(describeServerError(resp.statusCode, resp.body),
          status: resp.statusCode, unreachable: isUnreachableStatus(resp.statusCode));
    }
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw CoaDataError('the server did not answer with JSON');
    }
    if (body is! Map) {
      throw CoaDataError('unexpected response shape');
    }
    // SM-22: the server answers with lower-cased ids ('hb-...'); callers look results up by the id as the state
    // system spells it ('HB-...'). Key every result by the guid this call was asked about, compared ignoring
    // case, so a lot the server already knows is never taken for a miss (re-downloaded, re-uploaded).
    final asked = {for (final g in guids) g.toLowerCase(): g};
    return {
      for (final entry in body.entries)
        if (entry.value is Map && entry.key is String)
          (asked[(entry.key as String).toLowerCase()] ?? entry.key as String):
              CoaData.fromJson(asked[(entry.key as String).toLowerCase()] ?? entry.key as String,
                  Map<String, Object?>.from(entry.value as Map))
    };
  } finally {
    if (shouldClose) c.close();
  }
}

/// POSTs a lot's own lab report PDF (already downloaded from the state system by the caller - see this file's
/// own header comment) to /p/coa-data/parse for the server to read (coagen.py's own PDF pipeline, reused) and
/// cache in adhoc_coa, so no other worker at any center ever has to re-resolve this same lot again.
/// workerEmail/deviceId ride along purely for accountability (see mazama_sales' coa_data_parse docstring) -
/// never a credential, same as sale_log_client.dart/sale_failure_client.dart already send.
///
/// Throws [CoaDataError] on a network problem or an unexpected response shape; a 422 ("this guid's own test
/// result isn't in the PDF") or 413 ("too large") or 503 ("OCR unavailable right now") all surface as
/// [CoaDataError] with the server's own message, which the caller should show as "couldn't read this lot's
/// report" rather than retry automatically - see this file's own header comment on the miss queue's hard cap.
Future<CoaData> uploadCoaParse({
  required String guid,
  required Uint8List pdfBytes,
  int? docId,
  required String workerEmail,
  required String deviceId,
  /// The state's psilocybin figure for this lot (a package's analyteWeight, mg/g), sent when above 0: the server
  /// uses it to pick the lot's section when the lab printed another id as the UID (AD-19, coa_core's find_lot).
  double? statePsilocybin,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${coaDataParsePath()}');
    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll(appApiKeyHeaders)
      ..fields['guid'] = guid
      // Snake_case to match mazama_sales' own Form() parameter names exactly (web/stock_pages.py's
      // coa_data_parse: worker_email, device_id) - both have "" defaults server-side, so sending the wrong
      // names here never raised an error, it just silently discarded accountability data on every real
      // upload (see this file's own header comment on why worker_email/device_id exist at all). Caught by
      // reading the route's own parameter names while chasing an unrelated 422.
      ..fields['worker_email'] = workerEmail
      ..fields['device_id'] = deviceId
      ..files.add(http.MultipartFile.fromBytes('pdf', pdfBytes, filename: '$guid.pdf'));
    if (docId != null) req.fields['doc_id'] = docId.toString();
    if (statePsilocybin != null && statePsilocybin > 0) req.fields['state_psilocybin'] = statePsilocybin.toString();
    http.StreamedResponse streamed;
    try {
      streamed = await c.send(req);
    } catch (ex) {
      throw CoaDataError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode != 200) {
      throw CoaDataError(describeServerError(resp.statusCode, resp.body),
          status: resp.statusCode, unreachable: isUnreachableStatus(resp.statusCode));
    }
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw CoaDataError('the server did not answer with JSON', status: resp.statusCode);
    }
    if (body is! Map) {
      throw CoaDataError('unexpected response shape', status: resp.statusCode);
    }
    return CoaData.fromJson(guid, Map<String, Object?>.from(body));
  } finally {
    if (shouldClose) c.close();
  }
}

/// A tiny per-session, in-memory cache keyed by guid, so a worker re-opening the same unconfigured center
/// doesn't redo the batch-lookup round trip for guids already resolved this session. Deliberately has no
/// staleness/maxAge concept (unlike InventoryCacheStore) - a lot's lab numbers don't change once resolved, so
/// unlike the inventory cache this is never shown as "possibly stale" and never expires on its own. Lives for
/// as long as whatever holds it (a page's State object, typically) - this is a convenience, not durable
/// storage; the durable, shared cache is the server's own adhoc_coa table.
class CoaDataSessionCache {
  final Map<String, CoaData> _byGuid = {};

  CoaData? get(String guid) => _byGuid[guid];

  void put(CoaData data) => _byGuid[data.guid] = data;

  void putAll(Map<String, CoaData> data) => _byGuid.addAll(data);

  bool has(String guid) => _byGuid.containsKey(guid);
}
