// A center's par levels for the phone's order par step: GET /p/par/{state_id} reads them, POST /p/par/{state_id} sets or removes them with the same
// rules as the server's web form, audited as app:<workerEmail> with this install's device id. Contract:
// ../mazama_modules/api/routes.yaml, schemas par.* and par_save.*, vendored examples at assets/shared/api/examples/
// (test/par_client_test.dart).
import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'server_error.dart';
import 'server_request.dart';
import 'stock_summary.dart';

/// A par request that failed; [message] is the server's own `detail` when it sent one (shown to the worker as is).
/// [unreachable]: the server couldn't be reached (server_error.dart's rule).
class ParError extends ServerFailure {
  ParError(super.message, {super.status, super.unreachable});
}

List<ParLevel> _levels(http.Response resp) {
  final body = serverJson(resp, ParError.new);
  final levels = body is Map ? body['levels'] : null;
  if (levels is! List || levels.any((l) => l is! Map)) throw ParError('unexpected response shape');
  return [for (final l in levels) ParLevel.fromJson(Map<String, Object?>.from(l as Map))];
}

/// The center's stored par levels. Throws [ParError].
Future<List<ParLevel>> fetchParLevels(int stateId, {String baseUrl = apiBaseUrl, http.Client? client}) =>
    serverRequest('$baseUrl${parPath(stateId)}',
        error: ParError.new, timeout: serverReadTimeout, client: client, read: _levels);

/// Sends [levels] (a null par removes that level) as [workerEmail] on [deviceId] and returns the center's
/// par levels as stored. Throws [ParError] with the server's message when it refuses them; nothing is saved then.
Future<List<ParLevel>> saveParLevels(
  int stateId, {
  required String workerEmail,
  required String deviceId,
  required List<ParLevel> levels,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) =>
    serverRequest('$baseUrl${parSavePath(stateId)}',
        method: 'POST',
        json: {'workerEmail': workerEmail, 'deviceId': deviceId, 'levels': [for (final l in levels) l.toJson()]},
        error: ParError.new,
        client: client,
        read: _levels);
