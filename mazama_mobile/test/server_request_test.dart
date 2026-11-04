// server_request.dart: the one /p/ request skeleton every client uses - its client and closing, the app key, and the
// words and flags of each way a request fails, made by the client's own error factory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart' show appApiKeyHeader;
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/server_error.dart';
import 'package:mazama_mobile/server_request.dart';

class TestError extends ServerFailure {
  TestError(super.message, {super.status, super.unreachable});
}

/// A client that counts how often it is closed.
class CountingClient extends http.BaseClient {
  CountingClient(this._inner);
  final http.Client _inner;
  int closed = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);

  @override
  void close() {
    closed++;
    _inner.close();
  }
}

http.Client answering(Future<http.Response> Function(http.Request) answer) => http_testing.MockClient(answer);

const url = 'https://sales.example/p/thing/7';

void main() {
  group('serverRequest', () {
    test('a GET sends the app key and gives read the reply', () async {
      final seen = <http.Request>[];
      final got = await serverRequest('$url?x=1',
          error: TestError.new,
          client: answering((req) async {
            seen.add(req);
            return http.Response('{"a": 1}', 200);
          }),
          read: (resp) => serverJson(resp, TestError.new));
      expect(got, {'a': 1});
      expect(seen.single.method, 'GET');
      expect(seen.single.url.toString(), '$url?x=1');
      if (appApiKey.isNotEmpty) expect(seen.single.headers[appApiKeyHeader], appApiKey);
      expect(seen.single.headers.containsKey('content-type'), isFalse);
    });

    test('a POST sends json as its body, as application/json, with the app key and extra headers', () async {
      final seen = <http.Request>[];
      await serverRequest(url,
          method: 'POST',
          json: {'k': 'v', 'n': [1, 2]},
          headers: {'X-Extra': 'yes'},
          error: TestError.new,
          client: answering((req) async {
            seen.add(req);
            return http.Response('', 200);
          }),
          read: (_) {});
      final req = seen.single;
      expect(req.method, 'POST');
      expect(jsonDecode(req.body), {'k': 'v', 'n': [1, 2]});
      expect(req.headers['content-type'], startsWith('application/json'));
      expect(req.headers['x-extra'], 'yes');
      if (appApiKey.isNotEmpty) expect(req.headers[appApiKeyHeader], appApiKey);
    });

    test('only GET and POST', () {
      expect(() => serverRequest(url, method: 'PUT', error: TestError.new, read: (_) {}), throwsArgumentError);
    });

    test('no connection: "cannot reach <host>: <type>", unreachable, no status', () async {
      await expectLater(
          serverRequest(url,
              error: TestError.new,
              client: answering((_) async => throw const SocketException('no route')),
              read: (_) => fail('no reply to read')),
          throwsA(isA<TestError>()
              .having((e) => e.message, 'message', 'cannot reach sales.example: SocketException')
              .having((e) => e.unreachable, 'unreachable', isTrue)
              .having((e) => e.status, 'status', isNull)));
    });

    test('no answer within the timeout is unreachable too', () async {
      final never = Completer<http.Response>();
      await expectLater(
          serverRequest(url,
              error: TestError.new,
              timeout: const Duration(milliseconds: 10),
              client: answering((_) => never.future),
              read: (_) => fail('no reply to read')),
          throwsA(isA<TestError>()
              .having((e) => e.message, 'message', 'cannot reach sales.example: TimeoutException')
              .having((e) => e.unreachable, 'unreachable', isTrue)));
    });

    test("a refused reply: the server's own detail, its status, not unreachable", () async {
      await expectLater(
          serverRequest(url,
              error: TestError.new,
              client: answering((_) async => http.Response('{"detail": "no such center"}', 404)),
              read: (_) => fail('a 404 is not read')),
          throwsA(isA<TestError>()
              .having((e) => e.message, 'message', 'no such center')
              .having((e) => e.status, 'status', 404)
              .having((e) => e.unreachable, 'unreachable', isFalse)));
    });

    test("a 401 and a 429 get describeServerError's own words", () async {
      for (final status in [401, 429]) {
        await expectLater(
            serverRequest(url,
                error: TestError.new, client: answering((_) async => http.Response('', status)), read: (_) {}),
            throwsA(isA<TestError>().having((e) => e.message, 'message', describeServerError(status, ''))));
      }
    });

    test('a 5xx is unreachable, with its status', () async {
      await expectLater(
          serverRequest(url,
              error: TestError.new, client: answering((_) async => http.Response('bad gateway', 502)), read: (_) {}),
          throwsA(isA<TestError>()
              .having((e) => e.message, 'message', 'the server answered HTTP 502')
              .having((e) => e.status, 'status', 502)
              .having((e) => e.unreachable, 'unreachable', isTrue)));
    });

    test('unreachableReply decides unreachable for a refused reply when given', () async {
      await expectLater(
          serverRequest(url,
              error: TestError.new,
              unreachableReply: (_) => false,
              client: answering((_) async => http.Response('bad gateway', 502)),
              read: (_) {}),
          throwsA(isA<TestError>().having((e) => e.unreachable, 'unreachable', isFalse)));
    });

    test('ok chooses which statuses are read', () async {
      final got = await serverRequest(url,
          error: TestError.new,
          ok: (s) => s == 201 || s == 404,
          client: answering((_) async => http.Response('', 404)),
          read: (resp) => resp.statusCode);
      expect(got, 404);
      await expectLater(
          serverRequest(url,
              error: TestError.new,
              ok: (s) => s == 201,
              client: answering((_) async => http.Response('', 200)),
              read: (_) {}),
          throwsA(isA<TestError>().having((e) => e.status, 'status', 200)));
      for (final status in [200, 201, 204, 299]) {
        await serverRequest(url,
            error: TestError.new,
            ok: isSuccessStatus,
            client: answering((_) async => http.Response('', status)),
            read: (_) {});
      }
      expect(isSuccessStatus(300), isFalse);
      expect(isSuccessStatus(199), isFalse);
      expect(isOkStatus(200), isTrue);
      expect(isOkStatus(201), isFalse);
    });

    test("read's own error reaches the caller as it is", () async {
      await expectLater(
          serverRequest(url,
              error: TestError.new,
              client: answering((_) async => http.Response('{}', 200)),
              read: (_) => throw TestError('unexpected response shape')),
          throwsA(isA<TestError>().having((e) => e.message, 'message', 'unexpected response shape')));
    });

    test("the error factory keeps the client's own type", () async {
      await expectLater(
          serverRequest(url,
              error: (m, {status, unreachable = false}) => FormatException(m),
              client: answering((_) async => throw const SocketException('down')),
              read: (_) {}),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('cannot reach'))));
    });

    test("a client of its own (from open) is closed afterwards, whatever happens; the caller's never", () async {
      for (final answer in <Future<http.Response> Function(http.Request)>[
        (_) async => http.Response('', 200),
        (_) async => http.Response('', 500),
        (_) async => throw const SocketException('down'),
      ]) {
        final own = CountingClient(answering(answer));
        try {
          await serverRequest(url, error: TestError.new, open: () => own, read: (_) {});
        } on TestError {
          // the failures are the other tests'
        }
        expect(own.closed, 1);

        final given = CountingClient(answering(answer));
        var opened = 0;
        try {
          await serverRequest(url, error: TestError.new, client: given, open: () {
            opened++;
            return given;
          }, read: (_) {});
        } on TestError {
          // as above
        }
        expect(given.closed, 0);
        expect(opened, 0);
      }
    });
  });

  group('serverJson', () {
    test('reads a response, a string or UTF-8 bytes', () {
      expect(serverJson(http.Response('[1]', 200), TestError.new), [1]);
      expect(serverJson('{"a": "b"}', TestError.new), {'a': 'b'});
      expect(serverJson(utf8.encode('{"name": "Café"}'), TestError.new), {'name': 'Café'});
    });

    test('not JSON: "the server did not answer with JSON", with the status and unreachable asked for', () {
      expect(
          () => serverJson('<html>', TestError.new),
          throwsA(isA<TestError>()
              .having((e) => e.message, 'message', 'the server did not answer with JSON')
              .having((e) => e.status, 'status', isNull)
              .having((e) => e.unreachable, 'unreachable', isFalse)));
      expect(
          () => serverJson(http.Response('', 200), TestError.new, status: 200, unreachable: true),
          throwsA(isA<TestError>()
              .having((e) => e.status, 'status', 200)
              .having((e) => e.unreachable, 'unreachable', isTrue)));
    });

    test('bytes that are not UTF-8 are not JSON either', () {
      expect(() => serverJson(const [0xff, 0xfe], TestError.new),
          throwsA(isA<TestError>().having((e) => e.message, 'message', 'the server did not answer with JSON')));
    });
  });

  group('the pieces', () {
    test('sendToServer passes the answer through, and words a failure', () async {
      final uri = Uri.parse(url);
      expect(await sendToServer(uri, () async => 5, TestError.new), 5);
      await expectLater(
          sendToServer(uri, () async => throw http.ClientException('reset'), TestError.new),
          throwsA(isA<TestError>()
              .having((e) => e.message, 'message', 'cannot reach sales.example: ClientException')
              .having((e) => e.unreachable, 'unreachable', isTrue)));
    });

    test('serverReplyError: the words, the status, unreachable for a 5xx unless told otherwise', () {
      final e = serverReplyError(http.Response('{"detail": "busy"}', 503), TestError.new) as TestError;
      expect(e.message, 'busy');
      expect(e.status, 503);
      expect(e.unreachable, isTrue);
      final told = serverReplyError(http.Response('', 503), TestError.new, unreachable: false) as TestError;
      expect(told.unreachable, isFalse);
      final refused = serverReplyError(http.Response('', 400), TestError.new) as TestError;
      expect(refused.message, 'the server answered HTTP 400');
      expect(refused.unreachable, isFalse);
    });

    test('withServerClient closes only a client of its own, also when use throws', () async {
      final own = CountingClient(answering((_) async => http.Response('', 200)));
      await expectLater(withServerClient(null, (_) async => throw StateError('x'), open: () => own), throwsStateError);
      expect(own.closed, 1);
      final given = CountingClient(answering((_) async => http.Response('', 200)));
      expect(await withServerClient(given, (c) async => identical(c, given)), isTrue);
      expect(given.closed, 0);
    });
  });

  group('ServerFailure', () {
    test('is a ServerRequestError whose toString is its message', () {
      final e = TestError('the words', status: 500, unreachable: true);
      expect(e, isA<ServerRequestError>());
      expect(e.toString(), 'the words');
      expect(isServerUnreachable(e), isTrue);
      expect(TestError('x').unreachable, isFalse);
      expect(TestError('x').status, isNull);
    });
  });
}
