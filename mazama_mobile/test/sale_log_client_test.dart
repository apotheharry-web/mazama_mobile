import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/sale_log_client.dart';

void main() {
  test('posts workerEmail/request/response as JSON to the right path on a clean 201', () async {
    final client = http_testing.MockClient((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/p/sale-log/225');
      expect(req.headers['content-type'], 'application/json');
      final body = jsonDecode(req.body) as Map<String, Object?>;
      expect(body['workerEmail'], 'worker@example.com');
      expect(body['deviceId'], 'DEVICE-1');
      expect(body['request'], [
        {'productGuid': 'PKPR-ab12c', 'qty': 2},
      ]);
      expect(body['response'], {'saleNumber': 'S-1'});
      return http.Response('', 201);
    });
    await postSaleLog(
      225,
      workerEmail: 'worker@example.com',
      deviceId: 'DEVICE-1',
      request: [
        {'productGuid': 'PKPR-ab12c', 'qty': 2},
      ],
      response: {'saleNumber': 'S-1'},
      client: client,
    );
  });

  test('a plain 200 is also treated as success - this call never depends on a specific 2xx code', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 200));
    await postSaleLog(225, workerEmail: 'worker@example.com', deviceId: 'DEVICE-1', request: const [], response: null, client: client);
  });

  test('a non-2xx response is reported as a SaleLogError naming the status code', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 500));
    await expectLater(
      postSaleLog(225, workerEmail: 'worker@example.com', deviceId: 'DEVICE-1', request: const [], response: null, client: client),
      throwsA(isA<SaleLogError>().having((e) => e.message, 'message', contains('500'))),
    );
  });

  test('a network failure is reported clearly, not as an opaque exception', () async {
    final client = http_testing.MockClient((req) async => throw Exception('boom'));
    await expectLater(
      postSaleLog(225, workerEmail: 'worker@example.com', deviceId: 'DEVICE-1', request: const [], response: null, client: client),
      throwsA(isA<SaleLogError>()),
    );
  });
}
