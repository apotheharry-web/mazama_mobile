// ping_client.dart: C15 GET /p/ping, the server tracker's probe (README R56).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/ping_client.dart';

void main() {
  http.Client answering(int status, String body, {List<http.Request>? seen}) => http_testing.MockClient((req) async {
        seen?.add(req);
        return http.Response(body, status);
      });

  test('reads the example reply from the routes.yaml path, with the app key', () async {
    final seen = <http.Request>[];
    final example = File('assets/shared/api/examples/ping.response.json').readAsStringSync();
    await ping(client: answering(200, example, seen: seen));
    expect(seen.single.method, 'GET');
    expect(seen.single.url.toString(), '$apiBaseUrl${pingPath()}');
    if (appApiKey.isNotEmpty) expect(seen.single.headers[appApiKeyHeader], appApiKey);
    expect(await serverAnswers(client: answering(200, example)), isTrue);
  });

  test('no connection, a proxy 5xx, or no answer in time: the server does not answer', () async {
    expect(await serverAnswers(client: http_testing.MockClient((_) async => throw const SocketException('down'))), isFalse);
    expect(await serverAnswers(client: answering(502, '<html>Bad gateway</html>')), isFalse);
    expect(
        await serverAnswers(
            client: http_testing.MockClient((_) => Future<http.Response>.delayed(const Duration(seconds: 1), () => http.Response('', 200))),
            timeout: const Duration(milliseconds: 20)),
        isFalse);
  });

  test("any reply of the server's own is an answer: a 401 (an old app key), a 503 in its own words", () async {
    expect(await serverAnswers(client: answering(401, jsonEncode({'detail': 'Missing or wrong X-App-Key header.'}))), isTrue);
    expect(await serverAnswers(client: answering(503, jsonEncode({'detail': 'busy'}))), isTrue);
  });

  test("a captive portal's page is not the server", () async {
    await expectLater(ping(client: answering(200, '<html>Sign in to Wi-Fi</html>')), throwsA(isA<PingError>()));
    expect(await serverAnswers(client: answering(200, '<html>Sign in to Wi-Fi</html>')), isFalse);
  });
}
