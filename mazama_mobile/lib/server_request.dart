// The one request skeleton every /p/ client uses (sheets_client.dart, par_client.dart, sale_log_client.dart and the
// rest): a client of its own through the server link (server_link_client.dart's serverClient) unless the caller gave
// one, closed afterwards; the app key on every request (app_api_key.dart); and the same words for each way a request
// fails, each made by the client's own error factory so it keeps its own error type:
//   - no connection or no answer in time: "cannot reach <host>: <exception type>", unreachable;
//   - a reply that isn't a success: the server's own words (server_error.dart's describeServerError), its status, and
//     unreachable when it is a 5xx (isUnreachableStatus);
//   - a body that isn't JSON: "the server did not answer with JSON".
// [serverRequest] is the whole of it for a plain GET or JSON POST; a client with a request of another shape (a
// multipart upload, a streamed reply) uses the pieces: [withServerClient], [sendToServer], [serverReplyError],
// [serverJson].
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

/// Makes a client's own error: [message] to show, the server's [status] when it answered, [unreachable] when it
/// couldn't be reached (server_error.dart's rule). A [ServerFailure] subclass's constructor is one (`SheetsError.new`);
/// a client whose error keeps less passes a function that drops the rest.
typedef ServerErrorFactory = Exception Function(String message, {int? status, bool unreachable});

/// A reply with exactly 200.
bool isOkStatus(int status) => status == 200;

/// Any 2xx reply.
bool isSuccessStatus(int status) => status >= 200 && status < 300;

/// What [use] returns, run with [client], or with a client of its own from [open] (the server link's by default) that
/// is closed afterwards, whatever [use] does.
Future<T> withServerClient<T>(http.Client? client, Future<T> Function(http.Client c) use,
    {http.Client Function() open = serverClient}) async {
  final c = client ?? open();
  try {
    return await use(c);
  } finally {
    if (client == null) c.close();
  }
}

/// What [send] answers; when it throws (no connection, no answer in time, the link counting the server offline),
/// [error] "cannot reach <[uri]'s host>: <the exception's type>", unreachable.
Future<R> sendToServer<R>(Uri uri, Future<R> Function() send, ServerErrorFactory error) async {
  try {
    return await send();
  } catch (ex) {
    throw error('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
  }
}

/// [error] for [resp], a reply that isn't a success: describeServerError's words, its status, and unreachable when it
/// is a 5xx (or as [unreachable] says, when given).
Exception serverReplyError(http.Response resp, ServerErrorFactory error, {bool? unreachable}) =>
    error(describeServerError(resp.statusCode, resp.body),
        status: resp.statusCode, unreachable: unreachable ?? isUnreachableStatus(resp.statusCode));

/// [reply] decoded as JSON: an [http.Response] (its body as package:http decodes it), a [String], or bytes (read as
/// UTF-8). When it isn't JSON, [error] "the server did not answer with JSON" with [status] and [unreachable].
Object? serverJson(Object reply, ServerErrorFactory error, {int? status, bool unreachable = false}) {
  try {
    final text = switch (reply) {
      http.Response r => r.body,
      String s => s,
      List<int> bytes => utf8.decode(bytes),
      _ => throw ArgumentError.value(reply, 'reply', 'not a response, a string or bytes'),
    };
    return jsonDecode(text);
  } on FormatException {
    throw error('the server did not answer with JSON', status: status, unreachable: unreachable);
  }
}

/// Sends one /p/ request to [url] and returns what [read] makes of the reply.
///
/// A GET, or a POST when [method] is 'POST' with [json] encoded as its body (and `Content-Type: application/json`),
/// always with the app key and [headers]; held to [timeout] when given (the server link holds every request to its
/// own). [client] when given (left open), else one from [open] (the server link's), closed afterwards. A send that
/// fails is [sendToServer]'s error; a reply whose status [ok] refuses (only 200 by default) is [serverReplyError]'s,
/// unreachable as [unreachableReply] says when given; [read] gets every other reply.
Future<T> serverRequest<T>(
  String url, {
  required ServerErrorFactory error,
  required FutureOr<T> Function(http.Response resp) read,
  String method = 'GET',
  Object? json,
  Map<String, String> headers = const {},
  Duration? timeout,
  bool Function(int status) ok = isOkStatus,
  bool Function(http.Response resp)? unreachableReply,
  http.Client? client,
  http.Client Function() open = serverClient,
}) {
  if (method != 'GET' && method != 'POST') throw ArgumentError.value(method, 'method', 'GET or POST');
  return withServerClient(client, (c) async {
    final uri = Uri.parse(url);
    final resp = await sendToServer(uri, () {
      final Future<http.Response> sent = method == 'GET'
          ? c.get(uri, headers: {...appApiKeyHeaders, ...headers})
          : c.post(uri,
              headers: {...appApiKeyHeaders, 'Content-Type': 'application/json', ...headers}, body: jsonEncode(json));
      return timeout == null ? sent : sent.timeout(timeout);
    }, error);
    if (!ok(resp.statusCode)) {
      throw serverReplyError(resp, error, unreachable: unreachableReply?.call(resp));
    }
    return await read(resp);
  }, open: open);
}
