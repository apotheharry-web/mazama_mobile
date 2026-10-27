// How the phone words a failed /p/ request, the same way for every route (SM-23). Every /p/ error reply from
// mazama_sales is {"detail": "..."} (../mazama_modules/api/schemas/error.schema.json, web/__init__.py show_error);
// two statuses get their own words because what the worker should do about them is different:
//   401 - the server refused this build's app key: retrying never helps, the app has to be updated.
//   429 - this phone sent more requests than the route allows per minute (routes.yaml rate_limit): wait.
//
// And whether a failure means Mazama's server couldn't be reached at all, one rule for every client (the pages then
// show the copy kept on the phone, server_offline.dart, or ask the worker to try again later): no connection, no
// answer in time, or a 5xx (the server, or the proxy in front of it, is down or broken). A 4xx is the server's own
// answer (a bad app key, an unknown center, a refused value, a rate limit) and is shown as an error, as before.
import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

/// How long a /p/ read waits for Mazama's server before counting it as unreachable.
const serverReadTimeout = Duration(seconds: 20);

/// The message to show for a /p/ reply with [status] and [body] that wasn't a success.
String describeServerError(int status, String body) {
  if (status == 401) {
    return "The server didn't accept this app's key (HTTP 401) - this copy of the app needs updating.";
  }
  if (status == 429) {
    return 'Too many requests to the server from this phone just now - wait a minute and try again.';
  }
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['detail'] is String && (decoded['detail'] as String).trim().isNotEmpty) {
      return decoded['detail'] as String;
    }
  } on FormatException {
    // not the envelope (a proxy's error page, say): fall through
  }
  return 'the server answered HTTP $status';
}

/// Whether a reply with [status] means the server couldn't serve the request at all (5xx), not that it refused it.
bool isUnreachableStatus(int status) => status >= 500 && status <= 599;

/// A failed /p/ request, as the clients for Mazama's own pages report it (par_client.dart, sheets_client.dart,
/// mazama_inventory_client.dart, order_client.dart).
abstract interface class ServerRequestError implements Exception {
  /// What to show the worker: the server's own `detail` when it sent one.
  String get message;

  /// True when Mazama's server couldn't be reached: no connection, no answer in time, or a 5xx.
  bool get unreachable;
}

/// Whether [error] means Mazama's server couldn't be reached (see this file's comment). A client's own error says so
/// itself; a bare connection error or timeout (from a loader that doesn't wrap them) counts too.
bool isServerUnreachable(Object? error) =>
    (error is ServerRequestError && error.unreachable) ||
    error is SocketException ||
    error is TimeoutException ||
    error is http.ClientException;
