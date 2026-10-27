// Mirrors sale_log_client_test.dart's own structure - the two clients are deliberately parallel (see
// sale_failure_client.dart's own file comment).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/sale_failure_client.dart';

void main() {
  test('posts workerEmail/deviceId/reason/request as JSON to the right path on a clean 201', () async {
    final client = http_testing.MockClient((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/p/sale-failure/225');
      expect(req.headers['content-type'], 'application/json');
      final body = jsonDecode(req.body) as Map<String, Object?>;
      expect(body['workerEmail'], 'worker@example.com');
      expect(body['deviceId'], 'DEVICE-1');
      expect(body['reason'], 'the session has expired and cannot be renewed automatically - please sign in again.');
      expect(body['request'], [
        {'productGuid': 'PKPR-ab12c', 'qty': 2},
      ]);
      return http.Response('', 201);
    });
    await postSaleFailure(
      225,
      workerEmail: 'worker@example.com',
      deviceId: 'DEVICE-1',
      reason: 'the session has expired and cannot be renewed automatically - please sign in again.',
      request: [
        {'productGuid': 'PKPR-ab12c', 'qty': 2},
      ],
      client: client,
    );
  });

  test('a plain 200 is also treated as success - this call never depends on a specific 2xx code', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 200));
    await postSaleFailure(225, workerEmail: 'worker@example.com', deviceId: 'DEVICE-1', reason: 'expired', request: const [], client: client);
  });

  test('a non-2xx response is reported as a SaleFailureError naming the status code', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 500));
    await expectLater(
      postSaleFailure(225, workerEmail: 'worker@example.com', deviceId: 'DEVICE-1', reason: 'expired', request: const [], client: client),
      throwsA(isA<SaleFailureError>().having((e) => e.message, 'message', contains('500'))),
    );
  });

  test('a network failure is reported clearly, not as an opaque exception', () async {
    final client = http_testing.MockClient((req) async => throw Exception('boom'));
    await expectLater(
      postSaleFailure(225, workerEmail: 'worker@example.com', deviceId: 'DEVICE-1', reason: 'expired', request: const [], client: client),
      throwsA(isA<SaleFailureError>()),
    );
  });
}
