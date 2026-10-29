// specs/center-web CW-R10 (phone half), CW-D16: a center's sales records, as the phone read them from the state system
// (GetSalesRecords, the Sales page), go to Mazama's server through the ingest route's `sales` dataset
// (POST /p/ingest/sales/{stateId}, routes.yaml C20, specs/ingest IN-R7), so they feed invoicing. The twin of
// inventory_upload_client.dart's uploadInventorySnapshot: same body, same headers, same error rules. The server inserts
// or updates rows and never deletes one (the `sales` dataset's policy, IN-R4). Never in the sale path: selling never
// waits on it (the Sales page starts it and doesn't wait).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'select_documents.dart' show stateDateIso;
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

/// The ingest dataset this client sends (routes.yaml C20's `{dataset}`).
const salesDataset = 'sales';

class SalesUploadError implements ServerRequestError {
  @override
  final String message;

  /// Mazama's server couldn't be reached (server_error.dart's rule): the snapshot waits (catch_up_store.dart).
  @override
  final bool unreachable;

  /// The status the server answered with; null when it didn't answer (or nothing was sent).
  final int? status;
  SalesUploadError(this.message, {this.unreachable = false, this.status});
  @override
  String toString() => message;
}

/// [records] as one upload takes them: all of them while there are at most [limit] (the same list), else the [limit]
/// newest by `dateOfSale` (records without a usable date counted oldest), in their original order. The `sales` dataset
/// only inserts or updates from a phone (IN-R4), so leaving the oldest out removes nothing; the sync has them.
List<Object?> newestSalesForUpload(List<Object?> records, {int limit = ingestMaxRecords}) {
  if (records.length <= limit) return records;
  // Each record's date worked out once, not on every comparison.
  final dates = [
    for (final r in records)
      (r is Map && r['dateOfSale'] is String ? stateDateIso(r['dateOfSale'] as String) : null) ?? '',
  ];
  final order = [for (var i = 0; i < records.length; i++) i]
    ..sort((a, b) {
      final byDate = dates[b].compareTo(dates[a]);
      return byDate != 0 ? byDate : b.compareTo(a);
    });
  final keep = order.take(limit).toList()..sort();
  return [for (final i in keep) records[i]];
}

/// POSTs `records` (the state system's own sales records for this center, as GetSalesRecords returned them) to
/// /p/ingest/sales/{stateId}, wrapped with `workerEmail`/`deviceId` so the rows are attributed to a real worker and
/// device. -> the server's summary, `{'rows': n, 'skipped': n}`, or `{'rows': 0, 'skipped': 0, 'held': true}` from a
/// phone not yet approved (nothing applied; done, nothing to retry). Throws [SalesUploadError] on anything but a clean
/// 200 JSON object, including a 404 (an older server without the `sales` dataset, or not a configured center) and
/// more records than the route takes ([ingestMaxRecords]), refused before sending.
Future<Map<String, Object?>> uploadSalesSnapshot(
  int stateId,
  List<Object?> records, {
  required String workerEmail,
  required String deviceId,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) async {
  // The server refuses more than ingestMaxRecords records outright (413, routes.yaml): say so here rather than send it.
  if (records.length > ingestMaxRecords) {
    throw SalesUploadError('${records.length} records is more than the server takes in one upload ($ingestMaxRecords)');
  }
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${ingestPath(salesDataset, stateId)}');
    http.Response resp;
    try {
      resp = await c.post(
        uri,
        headers: {...appApiKeyHeaders, 'content-type': 'application/json'},
        body: jsonEncode({'workerEmail': workerEmail, 'deviceId': deviceId, 'records': records}),
      );
    } catch (ex) {
      throw SalesUploadError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode != 200) {
      throw SalesUploadError(describeServerError(resp.statusCode, resp.body),
          unreachable: isUnreachableStatus(resp.statusCode), status: resp.statusCode);
    }
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw SalesUploadError('the server did not answer with JSON', status: 200);
    }
    if (body is! Map) {
      throw SalesUploadError('unexpected response shape', status: 200);
    }
    return Map<String, Object?>.from(body);
  } finally {
    if (shouldClose) c.close();
  }
}
