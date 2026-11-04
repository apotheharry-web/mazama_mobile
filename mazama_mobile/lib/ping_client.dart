// GET /p/ping (routes.yaml): whether Mazama's server answers. The server link's tracker (server_health.dart) sends
// it while it counts the server as unreachable, through a plain client of its own: the link's own client
// (server_link_client.dart) would refuse it, the tracker being offline. Contract: ../mazama_modules/api/routes.yaml,
// schema ping.response, example assets/shared/api/examples/ping.response.json.
import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'server_error.dart';
import 'server_link_client.dart' show isServerOwnErrorBody;
import 'server_request.dart';

/// How long a probe waits for an answer.
const pingTimeout = Duration(seconds: 10);

class PingError extends ServerFailure {
  PingError(super.message, {super.status, super.unreachable});
}

/// The server's answer to GET /p/ping. Throws [PingError] on anything but a 200 {"ok": true} ([PingError.unreachable]: no
/// connection, no answer in [timeout], or a 5xx that isn't the server's own reply).
Future<void> ping({String baseUrl = apiBaseUrl, http.Client? client, Duration timeout = pingTimeout}) =>
    serverRequest('$baseUrl${pingPath()}',
        error: PingError.new,
        timeout: timeout,
        unreachableReply: (resp) => isUnreachableStatus(resp.statusCode) && !isServerOwnErrorBody(resp.bodyBytes),
        client: client,
        // a plain client: the server link's would refuse the probe while the tracker counts the server offline
        open: http.Client.new, read: (resp) {
      // not JSON: a captive portal's page, say: something answered, but not Mazama's server
      final body = serverJson(resp, PingError.new, unreachable: true);
      if (body is! Map || body['ok'] != true) throw PingError('unexpected response shape', unreachable: true);
    });

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
