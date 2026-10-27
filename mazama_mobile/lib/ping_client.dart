// GET /p/ping (C15, routes.yaml): whether Mazama's server answers. The server link's tracker (server_health.dart) sends
// it while it counts the server as unreachable, through a plain client of its own: the link's own client
// (server_link_client.dart) would refuse it, the tracker being offline. Contract: ../mazama_modules/api/routes.yaml,
// schema ping.response, example assets/shared/api/examples/ping.response.json.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show isServerOwnErrorBody;

/// How long a probe waits for an answer.
const pingTimeout = Duration(seconds: 10);

class PingError implements ServerRequestError {
  @override
  final String message;
  @override
  final bool unreachable;
  PingError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}

/// The server's answer to C15. Throws [PingError] on anything but a 200 {"ok": true} ([PingError.unreachable]: no
/// connection, no answer in [timeout], or a 5xx that isn't the server's own reply).
Future<void> ping({String baseUrl = apiBaseUrl, http.Client? client, Duration timeout = pingTimeout}) async {
  final c = client ?? http.Client();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${pingPath()}');
    http.Response resp;
    try {
      resp = await c.get(uri, headers: appApiKeyHeaders).timeout(timeout);
    } catch (ex) {
      throw PingError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode != 200) {
      throw PingError(describeServerError(resp.statusCode, resp.body),
          unreachable: isUnreachableStatus(resp.statusCode) && !isServerOwnErrorBody(resp.bodyBytes));
    }
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      // a captive portal's page, say: something answered, but not Mazama's server
      throw PingError('the server did not answer with JSON', unreachable: true);
    }
    if (body is! Map || body['ok'] != true) throw PingError('unexpected response shape', unreachable: true);
  } finally {
    if (shouldClose) c.close();
  }
}

/// The tracker's probe: true when the server answers at all, the way server_link_client.dart counts it (any reply of
/// its own, 4xx included: a refused app key is still a server that answers; a 200 that isn't its {"ok": true}, such as
/// a Wi-Fi sign-in page, is not). Never throws.
Future<bool> serverAnswers({String baseUrl = apiBaseUrl, http.Client? client, Duration timeout = pingTimeout}) async {
  try {
    await ping(baseUrl: baseUrl, client: client, timeout: timeout);
    return true;
  } on PingError catch (e) {
    return !e.unreachable;
  } catch (_) {
    return false;
  }
}
