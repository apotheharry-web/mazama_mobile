// SM-23: every /p/ error reply is {"detail": "..."} (../mazama_modules/api/schemas/error.schema.json); the phone turns
// one into a message with describeServerError, the same way for every route. The 401 and 429 examples are vendored
// at assets/shared/api/examples/.
import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/order_client.dart';
import 'package:mazama_mobile/par_client.dart';
import 'package:mazama_mobile/server_error.dart';
import 'package:mazama_mobile/sheets_client.dart';

String _example(String name) => File('assets/shared/api/examples/$name.json').readAsStringSync();

void main() {
  test('401: the server refused the app key - says the app needs updating, not "try again"', () {
    final m = describeServerError(401, _example('error.401'));
    expect(m, contains('key'));
    expect(m, contains('updat'));
  });

  test('429: too many requests - says to wait, not that something is broken', () {
    final m = describeServerError(429, _example('error.429'));
    expect(m, contains('wait'));
    expect(m, isNot(contains('HTTP')));
  });

  test("any other status shows the server's own detail", () {
    expect(describeServerError(422, jsonEncode({'detail': 'PL-1234567 is not in this report.'})), 'PL-1234567 is not in this report.');
    expect(describeServerError(404, jsonEncode({'detail': 'No such service center.'})), 'No such service center.');
  });

  test('a reply that is not the envelope falls back to the status', () {
    expect(describeServerError(502, '<html>Bad gateway</html>'), 'the server answered HTTP 502');
    expect(describeServerError(500, jsonEncode({'detail': '   '})), 'the server answered HTTP 500');
    expect(describeServerError(500, jsonEncode({'error': 'x'})), 'the server answered HTTP 500');
    expect(describeServerError(500, ''), 'the server answered HTTP 500');
  });

  test('unreachable: no connection, no answer in time, or a 5xx; never a 4xx', () {
    for (final s in [500, 502, 503, 504, 599]) {
      expect(isUnreachableStatus(s), isTrue, reason: '$s');
    }
    for (final s in [200, 400, 401, 404, 422, 429, 600]) {
      expect(isUnreachableStatus(s), isFalse, reason: '$s');
    }
    expect(isServerUnreachable(const SocketException('down')), isTrue);
    expect(isServerUnreachable(TimeoutException('slow')), isTrue);
    expect(isServerUnreachable(http.ClientException('reset')), isTrue);
    expect(isServerUnreachable(Exception('something else')), isFalse);
    expect(isServerUnreachable(null), isFalse);
  });

  test("every client's error says itself whether the server was unreachable", () {
    final errors = <ServerRequestError Function(bool)>[
      (u) => ParError('x', unreachable: u),
      (u) => SheetsError('x', unreachable: u),
      (u) => MazamaInventoryError('x', unreachable: u),
      (u) => OrderError('x', unreachable: u),
    ];
    for (final make in errors) {
      expect(isServerUnreachable(make(true)), isTrue);
      expect(isServerUnreachable(make(false)), isFalse);
    }
    expect(ParError('x').unreachable, isFalse); // the default: the server's own answer
  });
}
