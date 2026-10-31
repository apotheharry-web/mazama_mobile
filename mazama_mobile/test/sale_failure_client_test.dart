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

  // SALE-15: the report says, as a field of its own, whether the sale was surely not sent. The cart builds every
  // reason with its SaleOutcome as a leading tag ('[notSent] ...', '[bulk 2 of 3] [uncertain] ...'); only a leading
  // notSent tag counts, anything else (no tag, a tag later in the text) is uncertain, as the server reads a report
  // without one.
  group('the outcome field', () {
    Future<Object?> sentOutcome(String reason) async {
      Object? outcome;
      final client = http_testing.MockClient((req) async {
        outcome = (jsonDecode(req.body) as Map<String, Object?>)['outcome'];
        return http.Response('', 201);
      });
      await postSaleFailure(225, workerEmail: 'w@x.com', deviceId: 'D', reason: reason, request: const [{}], client: client);
      return outcome;
    }

    test('a leading notSent tag, alone or after the bulk tag, is sent as not_sent', () async {
      expect(await sentOutcome("[notSent] the state's sign-in could not be renewed"), 'not_sent');
      expect(await sentOutcome('[bulk 2 of 3] [notSent] HTTP 400 from the state'), 'not_sent');
    });

    test('everything else is sent as uncertain', () async {
      for (final reason in [
        '[uncertain] HTTP 504 from the state',
        '[bulk 1 of 2] [uncertain] the state answered 200 but the response did not look like a confirmed sale: x',
        "the state's sign-in session expired",
        '[uncertain] the reply said [notSent] somewhere',
        ' [notSent] a space first',
        '[notSent]no space after',
        '[bulk x of 2] [notSent] not a bulk tag',
      ]) {
        expect(await sentOutcome(reason), 'uncertain', reason: reason);
      }
    });

    test('saleFailureOutcome is the rule the report uses', () {
      expect(saleFailureOutcome('[notSent] x'), 'not_sent');
      expect(saleFailureOutcome('[uncertain] x'), 'uncertain');
      expect(saleFailureOutcome(''), 'uncertain');
    });
  });
}
