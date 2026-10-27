// Item 3a of "mazama_sales no longer auto-syncs every 12 hours": for a CONFIGURED service center, CartPage
// posts its own state-system read of this center's inventory (state_packages_client.dart's
// fetchRawPackagesFromState - the raw records, unreshaped) to mazama_sales' own POST /p/inventory/{stateId}
// after every such read, so the mirror stays current from the worker's own device instead of waiting on this
// server's own (now possibly manual-only) sync. PUBLIC and unauthenticated like the app's other /p/ calls -
// see mazama_sales' web/stock_pages.py's own inventory_upload docstring for the server-side half.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

class InventoryUploadError implements ServerRequestError {
  @override
  final String message;

  /// Mazama's server couldn't be reached (server_error.dart's rule): the snapshot waits (catch_up_store.dart).
  @override
  final bool unreachable;
  InventoryUploadError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}


/// POSTs `records` (the state system's own raw packaged-product records for this center, exactly as
/// fetchRawPackagesFromState returned them) to /p/inventory/{stateId}, wrapped with `workerEmail`/`deviceId`
/// so this write - which replaces the whole packaged-product mirror for a center - is attributed to a real
/// worker and device in sync_run/the audit trail instead of landing as SYSTEM (the same convention
/// public_sale_log/public_sale_failure already use). -> {'rows': n, 'skipped': n}, the server's own summary
/// of what it applied. Throws [InventoryUploadError] on anything but a clean 200 JSON object - including a
/// 404 (not a configured center; this should never actually happen for a call CartPage only makes after
/// centerIsConfigured already said yes, but the server still checks) and a 409 (another sync is already
/// running there right now - the caller should simply drop this attempt, not retry immediately; the next
/// state read will post a fresher snapshot anyway).
Future<Map<String, Object?>> uploadInventorySnapshot(
  int stateId,
  List<Object?> records, {
  required String workerEmail,
  required String deviceId,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) async {
  // The server refuses more than inventoryMaxRecords records outright (413, routes.yaml). The upload replaces the
  // center's whole mirror, so it can't be split: say so here rather than send it.
  if (records.length > inventoryMaxRecords) {
    throw InventoryUploadError('${records.length} records is more than the server takes in one upload ($inventoryMaxRecords)');
  }
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${inventoryPath(stateId)}');
    http.Response resp;
    try {
      resp = await c.post(
        uri,
        headers: {...appApiKeyHeaders, 'content-type': 'application/json'},
        body: jsonEncode({'workerEmail': workerEmail, 'deviceId': deviceId, 'records': records}),
      );
    } catch (ex) {
      throw InventoryUploadError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode != 200) {
      throw InventoryUploadError(describeServerError(resp.statusCode, resp.body), unreachable: isUnreachableStatus(resp.statusCode));
    }
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw InventoryUploadError('the server did not answer with JSON');
    }
    if (body is! Map) {
      throw InventoryUploadError('unexpected response shape');
    }
    return Map<String, Object?>.from(body);
  } finally {
    if (shouldClose) c.close();
  }
}
