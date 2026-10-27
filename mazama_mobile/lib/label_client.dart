// A plain, unauthenticated GET against Mazama's own public label endpoint (see
// src/mazama_sales/web/stock_pages.py's public_label route, server-side: the same compact-label picture a
// signed-in user sees at /c/{slug}/labels/{name}, but reached directly by productGuid and gated only by a
// valid service-center state_id - no login, same reasoning as packages_client.dart). Used right after a worker
// adds a package to the cart, so they can compare the server's own picture of the label against the physical
// one they're holding.
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

class LabelError implements Exception {
  final String message;
  LabelError(this.message);
  @override
  String toString() => message;
}

/// GETs [apiBaseUrl]/p/label/{stateId}/{guid} (C2, routes.yaml) and returns the raw image bytes. Throws
/// LabelError on anything but a clean 200 image - including a 404, which just as often means "this package has
/// no label on file yet" as "no such service center," not a network problem either way.
Future<Uint8List> fetchLabel(int stateId, String guid,
    {String baseUrl = apiBaseUrl, http.Client? client}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${labelPath(stateId, guid)}');
    http.Response resp;
    try {
      resp = await c.get(uri, headers: appApiKeyHeaders);
    } catch (ex) {
      throw LabelError('cannot reach ${uri.host}: ${ex.runtimeType}');
    }
    if (resp.statusCode == 404) {
      throw LabelError('no label on file for $guid');
    }
    if (resp.statusCode != 200) {
      throw LabelError(describeServerError(resp.statusCode, resp.body));
    }
    return resp.bodyBytes;
  } finally {
    if (shouldClose) c.close();
  }
}
