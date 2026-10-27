import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/scan_match_client.dart';

void main() {
  test('posts lines/typed as JSON to the right path and parses matches back', () async {
    final client = http_testing.MockClient((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/p/scan-match/225');
      expect(req.headers['content-type'], 'application/json');
      final body = jsonDecode(req.body) as Map<String, Object?>;
      expect(body['lines'], ['Lot: 579b4701']);
      expect(body['typed'], false);
      return http.Response(
        jsonEncode({
          'matches': [
            {'guid': 'PKPR-579b4701', 'name': 'Maztapec', 'dist': 0, 'line': 'Lot: 579b4701', 'stock': 6, 'sellable': true},
          ],
          'guesses': [],
        }),
        200,
      );
    });
    final result = await scanMatch(225, ['Lot: 579b4701'], client: client);
    expect(result.matches, hasLength(1));
    expect(result.matches.single.guid, 'PKPR-579b4701');
    expect(result.matches.single.stock, 6);
    expect(result.matches.single.sellable, true);
    expect(result.guesses, isEmpty);
  });

  test('typed defaults to false but is sent through when given', () async {
    final client = http_testing.MockClient((req) async {
      expect(jsonDecode(req.body)['typed'], true);
      return http.Response(jsonEncode({'matches': [], 'guesses': []}), 200);
    });
    await scanMatch(225, ['d0d0d0e1'], typed: true, client: client);
  });

  test('parses guesses when there are no exact matches', () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode({
            'matches': [],
            'guesses': [
              {'guid': 'PKPR-0005', 'name': 'GT', 'score': 6, 'why': ['net weight 0.50 g', 'psilocybin 3.63 mg'], 'stock': 10},
            ],
          }),
          200,
        ));
    final result = await scanMatch(225, ['Net wt: 0.50 g'], client: client);
    expect(result.matches, isEmpty);
    expect(result.guesses, hasLength(1));
    expect(result.guesses.single.why, ['net weight 0.50 g', 'psilocybin 3.63 mg']);
  });

  test('a non-200 response is reported as a ScanMatchError naming the status code', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 500));
    await expectLater(
      scanMatch(225, ['x'], client: client),
      throwsA(isA<ScanMatchError>().having((e) => e.message, 'message', contains('500'))),
    );
  });

  test('a network failure is reported clearly, not as an opaque exception', () async {
    final client = http_testing.MockClient((req) async => throw Exception('boom'));
    await expectLater(scanMatch(225, ['x'], client: client), throwsA(isA<ScanMatchError>()));
  });

  test('malformed entries in matches/guesses are dropped rather than crashing', () async {
    final client = http_testing.MockClient((req) async => http.Response(
          jsonEncode({
            'matches': [
              {'guid': 'PKPR-0005'}, // missing required fields
            ],
            'guesses': [],
          }),
          200,
        ));
    final result = await scanMatch(225, ['x'], client: client);
    expect(result.matches, isEmpty);
  });

  group('ScanMatchError.serverUnavailable: when the cart may match on the phone instead', () {
    test('unreachable, failing, timed out or busy: the server could not answer', () {
      for (final status in [null, 500, 502, 503, 504, 408, 429]) {
        expect(ScanMatchError('x', status: status).serverUnavailable, isTrue, reason: '$status');
      }
    });

    test('any other 4xx is the server refusing the request', () {
      for (final status in [400, 401, 403, 404, 413, 422]) {
        expect(ScanMatchError('x', status: status).serverUnavailable, isFalse, reason: '$status');
      }
    });

    test('scanMatch carries the status when the server answered, none when it could not be reached', () async {
      final refused = http_testing.MockClient((req) async => http.Response(jsonEncode({'detail': 'No such service center.'}), 404));
      await expectLater(scanMatch(225, ['x'], client: refused),
          throwsA(isA<ScanMatchError>().having((e) => e.status, 'status', 404).having((e) => e.serverUnavailable, 'unavailable', isFalse)));
      final failing = http_testing.MockClient((req) async => http.Response('Bad Gateway', 502));
      await expectLater(scanMatch(225, ['x'], client: failing),
          throwsA(isA<ScanMatchError>().having((e) => e.status, 'status', 502).having((e) => e.serverUnavailable, 'unavailable', isTrue)));
      final down = http_testing.MockClient((req) async => throw http.ClientException('connection refused'));
      await expectLater(scanMatch(225, ['x'], client: down),
          throwsA(isA<ScanMatchError>().having((e) => e.status, 'status', isNull).having((e) => e.serverUnavailable, 'unavailable', isTrue)));
    });
  });
}
