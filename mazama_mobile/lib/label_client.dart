// A plain, unauthenticated GET against Mazama's own public label endpoint (see
// src/mazama_sales/web/stock_pages.py's public_label route, server-side: the same compact-label picture a
// signed-in user sees at /c/{slug}/labels/{name}, but reached directly by productGuid and gated only by a
// valid service-center state_id - no login, same reasoning as packages_client.dart). Used right after a worker
// adds a package to the cart, so they can compare the server's own picture of the label against the physical
// one they're holding.
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'server_request.dart';

class LabelError implements Exception {
  final String message;
  LabelError(this.message);
  @override
  String toString() => message;
}

/// GETs [apiBaseUrl]/p/label/{stateId}/{guid} (routes.yaml) and returns the raw image bytes. Throws
/// LabelError on anything but a clean 200 image - including a 404, which just as often means "this package has
/// no label on file yet" as "no such service center," not a network problem either way.
Future<Uint8List> fetchLabel(int stateId, String guid,
    {String baseUrl = apiBaseUrl, http.Client? client}) =>
    serverRequest('$baseUrl${labelPath(stateId, guid)}',
        error: _labelError, ok: (status) => status == 200 || status == 404, client: client, read: (resp) {
      if (resp.statusCode == 404) throw LabelError('no label on file for $guid');
      return resp.bodyBytes;
    });

// A LabelError keeps only its words.
LabelError _labelError(String message, {int? status, bool unreachable = false}) => LabelError(message);
