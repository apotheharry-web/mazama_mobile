import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/label_client.dart';

void main() {
  test('returns the image bytes on a clean 200', () async {
    final bytes = [0xFF, 0xD8, 0xFF, 0xE0]; // a JPEG's own magic bytes - the body's actual content doesn't
    // matter to this client, just that it comes back untouched.
    final client = http_testing.MockClient((req) async {
      expect(req.url.path, '/p/label/225/PKPR-8a05632f');
      return http.Response.bytes(bytes, 200);
    });
    final result = await fetchLabel(225, 'PKPR-8a05632f', client: client);
    expect(result, bytes);
  });

  test('a guid is percent-encoded in the request path', () async {
    final client = http_testing.MockClient((req) async {
      expect(req.url.path, '/p/label/225/PKPR-ab%2Fcd'); // nothing in a real PKPR needs this, but the client
      // shouldn't build a malformed request if it ever sees an odd guid.
      return http.Response.bytes([1], 200);
    });
    await fetchLabel(225, 'PKPR-ab/cd', client: client);
  });

  test('a 404 (no such center, or no label for this package) is reported, not treated as a network error', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 404));
    await expectLater(
      fetchLabel(225, 'PKPR-0005', client: client),
      throwsA(isA<LabelError>().having((e) => e.message, 'message', contains('PKPR-0005'))),
    );
  });

  test('any other non-200 is reported with the status code', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 500));
    await expectLater(
      fetchLabel(225, 'PKPR-0005', client: client),
      throwsA(isA<LabelError>().having((e) => e.message, 'message', contains('500'))),
    );
  });

  test('a network failure is reported clearly, not as an opaque exception', () async {
    final client = http_testing.MockClient((req) async => throw Exception('boom'));
    await expectLater(fetchLabel(225, 'PKPR-0005', client: client), throwsA(isA<LabelError>()));
  });
}
