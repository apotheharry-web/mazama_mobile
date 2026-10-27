// SP-R9: the phone's par client (lib/par_client.dart) against the vendored API examples
// (assets/shared/api/examples/par*.json, from ../mazama_modules/api/): it reads the example replies and builds the
// example request at the paths routes.yaml gives.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/par_client.dart';
import 'package:mazama_mobile/stock_summary.dart';

Object? _example(String name) => jsonDecode(File('assets/shared/api/examples/$name.json').readAsStringSync());

(http.Client, List<http.Request>) _serve(Object? reply, {int status = 200}) {
  final seen = <http.Request>[];
  final client = http_testing.MockClient((req) async {
    seen.add(req);
    return http.Response(reply is String ? reply : jsonEncode(reply), status);
  });
  return (client, seen);
}

String _level(ParLevel l) => '${l.strain}|${l.size}|${l.par}';

void main() {
  final stateId = (_example('par.params') as Map)['state_id'] as int;

  test('fetchParLevels reads the example reply from /p/par/{state_id}', () async {
    final (client, seen) = _serve(_example('par.response'));
    final levels = await fetchParLevels(stateId, client: client);
    final req = seen.single;
    expect(req.method, apiRoutes['par']!['method']);
    expect(req.url.toString(), '$apiBaseUrl${parPath(stateId)}');
    if (appApiKey.isNotEmpty) expect(req.headers[appApiKeyHeader], appApiKey);
    expect(levels.map(_level), ['Bluey|0|3', 'Chocolate|-1|20', 'Golden Teacher|25|4', 'Golden Teacher|5|12']); // -1: Booster (specs/edibles)
  });

  test('saveParLevels sends the example request and reads the stored levels back', () async {
    final request = _example('par_save.request') as Map;
    final (client, seen) = _serve(_example('par_save.response'));
    final stored = await saveParLevels(
      (_example('par_save.params') as Map)['state_id'] as int,
      workerEmail: request['workerEmail'] as String,
      deviceId: request['deviceId'] as String,
      levels: [for (final l in request['levels'] as List) ParLevel.fromJson(Map<String, Object?>.from(l as Map))],
      client: client,
    );
    final req = seen.single;
    expect(req.method, apiRoutes['par_save']!['method']);
    expect(req.url.toString(), '$apiBaseUrl${parSavePath(stateId)}');
    expect(req.headers['Content-Type'], startsWith('application/json'));
    if (appApiKey.isNotEmpty) expect(req.headers[appApiKeyHeader], appApiKey);
    expect(jsonDecode(req.body), request); // a null par is sent as null: it removes the level
    expect(stored.map(_level), ['Bluey|0|3', 'Chocolate|-1|20', 'Golden Teacher|25|4', 'Golden Teacher|5|12']);
  });

  test("a refused save is a ParError with the server's own message", () async {
    const detail = 'These values are not whole numbers from 0 to 99999, or the strain name is empty: Bluey other';
    final (client, _) = _serve({'detail': detail}, status: 400);
    await expectLater(
      saveParLevels(stateId, workerEmail: 'w@example.com', deviceId: 'd', levels: const [ParLevel(strain: 'Bluey', size: 0, par: 100000)], client: client),
      throwsA(isA<ParError>().having((e) => e.toString(), 'toString', detail)),
    );
  });

  test('an unknown center, a rate limit and an odd reply are ParErrors', () async {
    final (c404, _) = _serve({'detail': 'No such service center.'}, status: 404);
    await expectLater(fetchParLevels(1, client: c404), throwsA(isA<ParError>().having((e) => e.message, 'message', 'No such service center.')));
    final (c429, _) = _serve({'detail': 'slow down'}, status: 429);
    await expectLater(fetchParLevels(1, client: c429), throwsA(isA<ParError>().having((e) => e.message, 'message', contains('wait a minute'))));
    final (odd, _) = _serve({'levels': 'none'});
    await expectLater(fetchParLevels(1, client: odd), throwsA(isA<ParError>()));
    final (html, _) = _serve('<html>proxy</html>');
    await expectLater(fetchParLevels(1, client: html), throwsA(isA<ParError>()));
  });

  test('no network is a ParError', () async {
    final client = http_testing.MockClient((req) async => throw const SocketException('offline'));
    await expectLater(fetchParLevels(1, client: client), throwsA(isA<ParError>().having((e) => e.message, 'message', contains('cannot reach'))));
  });

  test('no network or a 5xx is unreachable, on a read and a save; a 4xx is not', () async {
    final down = http_testing.MockClient((req) async => throw const SocketException('offline'));
    await expectLater(fetchParLevels(1, client: down), throwsA(isA<ParError>().having((e) => e.unreachable, 'unreachable', isTrue)));
    await expectLater(saveParLevels(1, workerEmail: 'w', deviceId: 'd', levels: const [], client: down),
        throwsA(isA<ParError>().having((e) => e.unreachable, 'unreachable', isTrue)));
    final (c503, _) = _serve('<html>Service unavailable</html>', status: 503);
    await expectLater(fetchParLevels(1, client: c503), throwsA(isA<ParError>().having((e) => e.unreachable, 'unreachable', isTrue)));
    final (c502, _) = _serve('<html>Bad gateway</html>', status: 502);
    await expectLater(saveParLevels(1, workerEmail: 'w', deviceId: 'd', levels: const [], client: c502),
        throwsA(isA<ParError>().having((e) => e.unreachable, 'unreachable', isTrue)));
    for (final status in [400, 401, 404, 429]) {
      final (c, _) = _serve({'detail': 'no'}, status: status);
      await expectLater(fetchParLevels(1, client: c), throwsA(isA<ParError>().having((e) => e.unreachable, 'unreachable', isFalse)));
      await expectLater(saveParLevels(1, workerEmail: 'w', deviceId: 'd', levels: const [], client: c),
          throwsA(isA<ParError>().having((e) => e.unreachable, 'unreachable', isFalse)));
    }
  });
}
