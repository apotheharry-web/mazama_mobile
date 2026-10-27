// server_link_client.dart: the http.Client every /p/ call goes through (README R56) - records how each call ended with
// the tracker, and while it counts the server offline fails at once without a request.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/par_client.dart';
import 'package:mazama_mobile/server_error.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_link_client.dart';

import 'fake_timers.dart';

void main() {
  late ServerHealth health;
  late int requests;

  setUp(() {
    health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
    requests = 0;
  });
  tearDown(() => health.dispose());

  ServerLinkClient client(Future<http.Response> Function(http.Request) answer,
          {Duration read = const Duration(seconds: 5), Duration write = const Duration(seconds: 5)}) =>
      ServerLinkClient(http_testing.MockClient((req) {
        requests++;
        return answer(req);
      }), health: health, readTimeout: read, writeTimeout: write);

  final uri = Uri.parse('https://sales.example/p/par/231');

  test('no connection marks the server offline and the error still reaches the caller', () async {
    final c = client((_) async => throw const SocketException('no route'));
    await expectLater(c.get(uri), throwsA(isA<SocketException>()));
    expect(health.offline, isTrue);
  });

  test('no answer in time marks it offline (a timeout, which server_error.dart counts as unreachable)', () async {
    final c = client((_) => Completer<http.Response>().future, read: const Duration(milliseconds: 20));
    Object? error;
    try {
      await c.get(uri);
    } catch (e) {
      error = e;
    }
    expect(error, isA<TimeoutException>());
    expect(isServerUnreachable(error), isTrue);
    expect(health.offline, isTrue);
  });

  test("a 5xx from the proxy marks it offline; one in the server's own words doesn't", () async {
    await client((_) async => http.Response('<html>Bad gateway</html>', 502)).get(uri);
    expect(health.offline, isTrue);
    health.markReachable();
    final own = await client((_) async => http.Response(jsonEncode({'detail': "Reading lab reports isn't available"}), 503)).get(uri);
    expect(own.statusCode, 503);
    expect(jsonDecode(own.body), {'detail': "Reading lab reports isn't available"}); // the body still reaches the client
    expect(health.online, isTrue);
  });

  test('a 4xx (the server refusing) is an answer: it never marks the server offline', () async {
    await client((_) async => http.Response('{"detail": "No such service center."}', 404)).get(uri);
    expect(health.online, isTrue);
  });

  test('a 200 after an outage marks it online', () async {
    // simulate an answer arriving through a request already out when the tracker went offline
    final gate = Completer<http.Response>();
    final c = client((_) => gate.future);
    final pending = c.get(uri);
    health.markUnreachable();
    gate.complete(http.Response('{}', 200));
    await pending;
    expect(health.online, isTrue);
  });

  test('while offline a request fails at once and nothing is sent', () async {
    health.markUnreachable();
    final c = client((_) async => http.Response('{}', 200));
    Object? error;
    try {
      await c.post(uri, body: '{}');
    } catch (e) {
      error = e;
    }
    expect(error, isA<ServerOfflineException>());
    expect(error, isA<http.ClientException>());
    expect(isServerUnreachable(error), isTrue);
    expect(requests, 0);
  });

  test("a client's own error says unreachable for a short-circuited call, so the page's fallback shows", () async {
    health.markUnreachable();
    final c = client((_) async => http.Response('{"levels": []}', 200));
    await expectLater(
      fetchParLevels(231, client: c),
      throwsA(isA<ParError>().having((e) => e.unreachable, 'unreachable', isTrue)),
    );
    expect(requests, 0);
  });

  test('writes wait longer than reads', () async {
    final c = client((_) => Completer<http.Response>().future,
        read: const Duration(milliseconds: 10), write: const Duration(milliseconds: 300));
    final sw = Stopwatch()..start();
    await expectLater(c.get(uri), throwsA(isA<TimeoutException>()));
    final readTook = sw.elapsedMilliseconds;
    health.markReachable();
    sw.reset();
    await expectLater(c.post(uri, body: '{}'), throwsA(isA<TimeoutException>()));
    expect(sw.elapsedMilliseconds, greaterThan(readTook));
    expect(serverWriteTimeout, greaterThan(serverReadTimeout));
  });

  test("isServerOwnErrorBody: only the server's {\"detail\": ...} envelope", () {
    expect(isServerOwnErrorBody(utf8.encode('{"detail": "x"}')), isTrue);
    expect(isServerOwnErrorBody(utf8.encode('<html></html>')), isFalse);
    expect(isServerOwnErrorBody(utf8.encode('{"error": "x"}')), isFalse);
    expect(isServerOwnErrorBody(const []), isFalse);
  });
}
