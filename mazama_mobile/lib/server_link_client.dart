// The http.Client every call to Mazama's server (/p/ routes) goes through (README R56). It keeps each client's own
// shape - packages_client.dart, par_client.dart, sale_log_client.dart and the rest still build their requests and read
// their replies as before - and adds the one shared rule about the server being down (server_health.dart):
//   - while the tracker says offline, a request fails at once with [ServerOfflineException] (an http.ClientException,
//     which every client already reports as "cannot reach ..." and server_error.dart counts as unreachable): no
//     network call, so a page's fallback shows at once instead of after a timeout;
//   - otherwise the request is sent; no connection, no answer within [serverReadTimeout] (a GET) or
//     [serverWriteTimeout] (anything else), or a 5xx that isn't the server's own {"detail": ...} reply marks the
//     tracker offline; any other reply marks it online.
// Only /p/ traffic goes through this. The state system's calls (the sale, stock reads, lab report downloads) use their
// own plain clients and never look at the tracker.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_error.dart';
import 'server_health.dart';
import 'server_link.dart' show serverLink;

/// How long a /p/ write (a POST: a sale report, an inventory upload, a lab report to read) waits for the server's
/// reply before counting it as unreachable. Longer than a read: the server reads a lab report before answering.
const serverWriteTimeout = Duration(seconds: 120);

/// A /p/ request not sent because Mazama's server is counted as unreachable (server_health.dart).
class ServerOfflineException extends http.ClientException {
  ServerOfflineException(Uri? uri) : super("Mazama's server can't be reached (waiting for it to answer again)", uri);
}

/// Whether a 5xx reply's [body] is the server's own error envelope ({"detail": "..."}, every /p/ error reply): the
/// app itself answered (a route's own 500/503), as opposed to the proxy in front of it or nothing at all.
bool isServerOwnErrorBody(List<int> body) {
  try {
    final decoded = jsonDecode(utf8.decode(body));
    return decoded is Map && decoded['detail'] is String;
  } catch (_) {
    return false;
  }
}

class ServerLinkClient extends http.BaseClient {
  ServerLinkClient(this._inner,
      {required this.health, this.readTimeout = serverReadTimeout, this.writeTimeout = serverWriteTimeout});

  final http.Client _inner;
  final ServerHealth health;
  final Duration readTimeout;
  final Duration writeTimeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (health.offline) throw ServerOfflineException(request.url);
    final read = request.method == 'GET' || request.method == 'HEAD';
    final http.StreamedResponse resp;
    try {
      resp = await _inner.send(request).timeout(read ? readTimeout : writeTimeout);
    } catch (_) {
      health.markUnreachable();
      rethrow;
    }
    if (!isUnreachableStatus(resp.statusCode)) {
      health.markReachable();
      return resp;
    }
    final List<int> bytes;
    try {
      bytes = await resp.stream.toBytes();
    } catch (_) {
      health.markUnreachable();
      rethrow;
    }
    if (isServerOwnErrorBody(bytes)) {
      health.markReachable();
    } else {
      health.markUnreachable();
    }
    return http.StreamedResponse(Stream<List<int>>.value(bytes), resp.statusCode,
        contentLength: bytes.length,
        request: resp.request,
        headers: resp.headers,
        isRedirect: resp.isRedirect,
        persistentConnection: resp.persistentConnection,
        reasonPhrase: resp.reasonPhrase);
  }

  @override
  void close() => _inner.close();
}

/// The client a /p/ client function uses when its caller passes none: a fresh plain client wrapped with the app's own
/// tracker (server_link.dart's [serverLink]). Closed by the function that made it, as before.
http.Client serverClient() => ServerLinkClient(http.Client(), health: serverLink.health);
