// A center's par levels for the phone's order par step (specs/stock-page SP-R9, SP-D5, SP-D19; mazama-inventory
// MI-D21): GET /p/par/{state_id} (C10) reads them, POST /p/par/{state_id} (C11) sets or removes them with the same
// rules as the server's web form, audited as app:<workerEmail> with this install's device id. Contract:
// ../mazama_modules/api/routes.yaml, schemas par.* and par_save.*, vendored examples at assets/shared/api/examples/
// (test/par_client_test.dart).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;
import 'stock_summary.dart';

/// A par request that failed; [message] is the server's own `detail` when it sent one (shown to the worker as is).
/// [unreachable]: the server couldn't be reached (server_error.dart's rule).
class ParError implements ServerRequestError {
  @override
  final String message;
  @override
  final bool unreachable;
  ParError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}

List<ParLevel> _levels(http.Response resp) {
  if (resp.statusCode != 200) {
    throw ParError(describeServerError(resp.statusCode, resp.body), unreachable: isUnreachableStatus(resp.statusCode));
  }
  Object? body;
  try {
    body = jsonDecode(resp.body);
  } on FormatException {
    throw ParError('the server did not answer with JSON');
  }
  final levels = body is Map ? body['levels'] : null;
  if (levels is! List || levels.any((l) => l is! Map)) throw ParError('unexpected response shape');
  return [for (final l in levels) ParLevel.fromJson(Map<String, Object?>.from(l as Map))];
}

/// The center's stored par levels (C10). Throws [ParError].
Future<List<ParLevel>> fetchParLevels(int stateId, {String baseUrl = apiBaseUrl, http.Client? client}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${parPath(stateId)}');
    http.Response resp;
    try {
      resp = await c.get(uri, headers: appApiKeyHeaders).timeout(serverReadTimeout);
    } catch (ex) {
      throw ParError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    return _levels(resp);
  } finally {
    if (shouldClose) c.close();
  }
}

/// Sends [levels] (a null par removes that level) as [workerEmail] on [deviceId] (C11) and returns the center's
/// par levels as stored. Throws [ParError] with the server's message when it refuses them; nothing is saved then.
Future<List<ParLevel>> saveParLevels(
  int stateId, {
  required String workerEmail,
  required String deviceId,
  required List<ParLevel> levels,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${parSavePath(stateId)}');
    http.Response resp;
    try {
      resp = await c.post(
        uri,
        headers: {...appApiKeyHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({'workerEmail': workerEmail, 'deviceId': deviceId, 'levels': [for (final l in levels) l.toJson()]}),
      );
    } catch (ex) {
      throw ParError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    return _levels(resp);
  } finally {
    if (shouldClose) c.close();
  }
}
