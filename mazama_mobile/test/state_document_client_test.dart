import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/state_document_client.dart';

late final FlowSpec readsSpec = FlowSpec.fromYaml(File('assets/flows/state_reads.yaml').readAsStringSync());

void main() {
  // downloadStateDocument reads its site, API base and User-Agent from assets/flows/state_reads.yaml (SM-20) via
  // rootBundle when no spec is passed, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  // SM-20: the same values the shared read flows send, taken from the spec rather than written out here.
  test('takes the API base, Referer, Origin and User-Agent from the state_reads spec', () async {
    final custom = FlowSpec({
      ...readsSpec.vars,
      'api': 'https://example.test/api/',
      'site': 'https://example.test/',
      'site_origin': 'https://example.test',
      'user_agent': 'UA-TEST',
    }, readsSpec.flows);
    final client = http_testing.MockClient.streaming((req, bodyStream) async {
      expect(req.url.toString(), 'https://example.test/api/DownloadDocument/9');
      expect(req.headers['Referer'], 'https://example.test/');
      expect(req.headers['Origin'], 'https://example.test');
      expect(req.headers['User-Agent'], 'UA-TEST');
      return http.StreamedResponse(Stream.value([1]), 200);
    });
    expect(await downloadStateDocument(9, accessToken: 'T', client: client, spec: custom, allowedHosts: const ['example.test']),
        [1]);
  });

  group('the token stays on the state host', () {
    const api = 'https://psilocybin.oregon.gov/api/private/ProductTracking/DownloadDocument/42';

    test('a redirect to another host is followed without the Authorization header', () async {
      final seen = <String, String?>{};
      final client = http_testing.MockClient.streaming((req, bodyStream) async {
        seen[req.url.toString()] = req.headers['Authorization'];
        if (req.url.toString() == api) {
          return http.StreamedResponse(const Stream.empty(), 302,
              headers: {'location': 'https://storage.example.net/docs/42.pdf?sig=abc'});
        }
        return http.StreamedResponse(Stream.value([7]), 200);
      });
      expect(await downloadStateDocument(42, accessToken: 'TOKEN', client: client), [7]);
      expect(seen, {api: 'Bearer TOKEN', 'https://storage.example.net/docs/42.pdf?sig=abc': null});
    });

    test('a redirect on the same host keeps the Authorization header', () async {
      final seen = <String?>[];
      final client = http_testing.MockClient.streaming((req, bodyStream) async {
        seen.add(req.headers['Authorization']);
        if (req.url.path.endsWith('/42')) {
          return http.StreamedResponse(const Stream.empty(), 307, headers: {'location': '/files/42.pdf'});
        }
        return http.StreamedResponse(Stream.value([8]), 200);
      });
      expect(await downloadStateDocument(42, accessToken: 'TOKEN', client: client), [8]);
      expect(seen, ['Bearer TOKEN', 'Bearer TOKEN']);
    });

    test('a redirect to the same host on another port is followed without the Authorization header', () async {
      final seen = <String, String?>{};
      final client = http_testing.MockClient.streaming((req, bodyStream) async {
        seen[req.url.toString()] = req.headers['Authorization'];
        if (req.url.toString() == api) {
          return http.StreamedResponse(const Stream.empty(), 302,
              headers: {'location': 'https://psilocybin.oregon.gov:8443/files/42.pdf'});
        }
        return http.StreamedResponse(Stream.value([9]), 200);
      });
      expect(await downloadStateDocument(42, accessToken: 'TOKEN', client: client), [9]);
      expect(seen, {api: 'Bearer TOKEN', 'https://psilocybin.oregon.gov:8443/files/42.pdf': null});
    });

    test('a redirect naming the default port 443 is still the same origin and keeps the header', () async {
      final seen = <String?>[];
      final client = http_testing.MockClient.streaming((req, bodyStream) async {
        seen.add(req.headers['Authorization']);
        if (req.url.path.endsWith('/42')) {
          return http.StreamedResponse(const Stream.empty(), 302,
              headers: {'location': 'https://PSILOCYBIN.oregon.gov:443/files/42.pdf'});
        }
        return http.StreamedResponse(Stream.value([5]), 200);
      });
      expect(await downloadStateDocument(42, accessToken: 'TOKEN', client: client), [5]);
      expect(seen, ['Bearer TOKEN', 'Bearer TOKEN']);
    });

    test('a redirect to a non-https address is refused', () async {
      final client = http_testing.MockClient.streaming((req, bodyStream) async =>
          http.StreamedResponse(const Stream.empty(), 302, headers: {'location': 'http://psilocybin.oregon.gov/x.pdf'}));
      await expectLater(downloadStateDocument(42, accessToken: 'TOKEN', client: client),
          throwsA(isA<StateDocumentError>().having((e) => e.message, 'message', contains('non-https'))));
    });

    test('more than five redirects is an error', () async {
      var n = 0;
      final client = http_testing.MockClient.streaming((req, bodyStream) async {
        n += 1;
        return http.StreamedResponse(const Stream.empty(), 302, headers: {'location': '/again/$n'});
      });
      await expectLater(downloadStateDocument(42, accessToken: 'TOKEN', client: client),
          throwsA(isA<StateDocumentError>().having((e) => e.message, 'message', contains('more than 5'))));
      expect(n, 6);
    });

    test('nothing is sent when the API host is not an allowed host', () async {
      var sent = false;
      final custom = FlowSpec({...readsSpec.vars, 'api': 'https://evil.example.com/api/'}, readsSpec.flows);
      final client = http_testing.MockClient.streaming((req, bodyStream) async {
        sent = true;
        return http.StreamedResponse(Stream.value([1]), 200);
      });
      await expectLater(downloadStateDocument(42, accessToken: 'TOKEN', client: client, spec: custom),
          throwsA(isA<StateDocumentError>().having((e) => e.message, 'message', contains('not an allowed state host'))));
      expect(sent, isFalse);
    });
  });

  test('GETs DownloadDocument/{docId} with the same bearer/Referer/Origin header shape as every other state call', () async {
    final bytes = [0x25, 0x50, 0x44, 0x46]; // %PDF
    final client = http_testing.MockClient.streaming((req, bodyStream) async {
      expect(req.method, 'GET');
      expect(req.url.toString(), 'https://psilocybin.oregon.gov/api/private/ProductTracking/DownloadDocument/42');
      expect(req.headers['Authorization'], 'Bearer TOKEN');
      expect(req.headers['Referer'], 'https://psilocybin.oregon.gov/');
      expect(req.headers['Origin'], 'https://psilocybin.oregon.gov');
      expect(req.headers['User-Agent'], readsSpec.vars['user_agent']);
      return http.StreamedResponse(Stream.value(bytes), 200);
    });
    final result = await downloadStateDocument(42, accessToken: 'TOKEN', client: client);
    expect(result, bytes);
  });

  test('a 401 is reported as a session problem, same wording every other state call uses', () async {
    final client = http_testing.MockClient.streaming((req, bodyStream) async => http.StreamedResponse(const Stream.empty(), 401));
    await expectLater(
      downloadStateDocument(42, accessToken: 'STALE', client: client),
      throwsA(isA<StateDocumentError>().having((e) => e.message, 'message', contains('sign in again'))),
    );
  });

  test('a non-200 that is not 401 is reported with its status code', () async {
    final client = http_testing.MockClient.streaming((req, bodyStream) async => http.StreamedResponse(const Stream.empty(), 500));
    await expectLater(
      downloadStateDocument(42, accessToken: 'T', client: client),
      throwsA(isA<StateDocumentError>().having((e) => e.message, 'message', contains('500'))),
    );
  });

  test('a response over the byte limit aborts the stream rather than buffering it all', () async {
    final client = http_testing.MockClient.streaming((req, bodyStream) async => http.StreamedResponse(
          Stream.fromIterable([Uint8List(5), Uint8List(5)]),
          200,
        ));
    await expectLater(
      downloadStateDocument(42, accessToken: 'T', limit: 6, client: client),
      throwsA(isA<StateDocumentError>().having((e) => e.message, 'message', contains('larger than'))),
    );
  });

  test('a network failure is reported with the host name, not a raw exception', () async {
    final client = http_testing.MockClient.streaming((req, bodyStream) async => throw Exception('boom'));
    await expectLater(
      downloadStateDocument(42, accessToken: 'T', client: client),
      throwsA(isA<StateDocumentError>().having((e) => e.message, 'message', contains('psilocybin.oregon.gov'))),
    );
  });

  // SM-12: this hand-written state read had no timeout either.
  test('no answer within the timeout is an error, not a wait forever', () async {
    final client = http_testing.MockClient.streaming((req, bodyStream) => Completer<http.StreamedResponse>().future);
    await expectLater(
      downloadStateDocument(42, accessToken: 'T', client: client, timeout: const Duration(milliseconds: 50)),
      throwsA(isA<StateDocumentError>().having((e) => e.message, 'message', contains('no answer from psilocybin.oregon.gov'))),
    );
  });

  test('a download that stops part way is an error after the timeout', () async {
    final stalled = StreamController<List<int>>()..add([0x25]);
    final client = http_testing.MockClient.streaming((req, bodyStream) async => http.StreamedResponse(stalled.stream, 200));
    await expectLater(
      downloadStateDocument(42, accessToken: 'T', client: client, timeout: const Duration(milliseconds: 50)),
      throwsA(isA<StateDocumentError>().having((e) => e.message, 'message', contains('stopped arriving'))),
    );
  });
}
