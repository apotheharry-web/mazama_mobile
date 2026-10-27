// MI-R5, MI-R6: the phone's order client (lib/order_client.dart) against the vendored API examples
// (assets/shared/api/examples/order.*.json, from ../mazama_modules/api/), and how it reports what can go wrong.
// api_contract_test.dart checks the route, the app key and the 401 / 429 wording.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/order_client.dart';

Object? _example(String part) => jsonDecode(File('assets/shared/api/examples/order.$part.json').readAsStringSync());

List<OrderLine> _lines() =>
    [for (final l in (_example('request') as Map)['lines'] as List) OrderLine.fromJson(Map<String, Object?>.from(l as Map))];

Future<String> _error(http.Client client) async {
  try {
    await submitOrder(225, workerEmail: 'w@example.com', deviceId: 'D-1', lines: _lines(), client: client);
  } on OrderError catch (e) {
    return e.message;
  }
  fail('expected an OrderError');
}

void main() {
  final stateId = (_example('params') as Map)['state_id'] as int;

  test('sends the example request to /p/orders/{state_id} and reads the example reply', () async {
    final req = _example('request') as Map<String, Object?>;
    http.Request? seen;
    final receipt = await submitOrder(stateId,
        workerEmail: req['workerEmail'] as String,
        deviceId: req['deviceId'] as String,
        lines: _lines(),
        note: req['note'] as String,
        client: http_testing.MockClient((r) async {
          seen = r;
          return http.Response(jsonEncode(_example('response')), 201);
        }));
    expect(seen!.method, 'POST');
    expect(seen!.url.toString(), '$apiBaseUrl${orderPath(stateId)}');
    expect(jsonDecode(seen!.body), req);
    final reply = _example('response') as Map;
    expect(receipt.id, reply['id']);
    expect(receipt.center, reply['center']);
    expect([for (final l in receipt.lines) l.toJson()], reply['lines']);
    expect(receipt.note, reply['note']); // MI-D10: the notes go along and come back
  });

  test('an order without notes sends an empty note', () async {
    http.Request? seen;
    await submitOrder(225, workerEmail: 'w', deviceId: 'd', lines: _lines(), client: http_testing.MockClient((r) async {
      seen = r;
      return http.Response(jsonEncode({..._example('response') as Map, 'note': ''}), 201);
    }));
    expect((jsonDecode(seen!.body) as Map)['note'], '');
  });

  test('the kinds are freeze dried, dehydrated and homogenized, as the server takes them', () {
    expect(orderKinds, {'FD': 'Freeze dried', 'DH': 'Dehydrated', 'HG': 'Homogenized'});
    expect(_lines().length, lessThanOrEqualTo(orderMaxLines));
    expect(orderMaxNoteChars, 1000);
  });

  test("a refusal is the server's own message", () async {
    final refuse = http_testing.MockClient((r) async => http.Response(jsonEncode({'detail': 'The order has no lines.'}), 400));
    expect(await _error(refuse), 'The order has no lines.');
  });

  test('no connection says which server could not be reached', () async {
    final down = http_testing.MockClient((r) async => throw const SocketException('down'));
    expect(await _error(down), startsWith('cannot reach '));
  });

  test('no connection or a 5xx is unreachable (try later); a refusal is not', () async {
    Future<bool> unreachable(http.Client c) async {
      try {
        await submitOrder(225, workerEmail: 'w', deviceId: 'd', lines: _lines(), client: c);
      } on OrderError catch (e) {
        return e.unreachable;
      }
      fail('expected an OrderError');
    }

    expect(await unreachable(http_testing.MockClient((r) async => throw const SocketException('down'))), isTrue);
    expect(await unreachable(http_testing.MockClient((r) async => http.Response('<html>Bad gateway</html>', 502))), isTrue);
    expect(await unreachable(http_testing.MockClient((r) async => http.Response(jsonEncode({'detail': 'No lines.'}), 400))), isFalse);
  });

  test('a stored order whose answer cannot be read says it was sent, not that it failed', () async {
    final odd = http_testing.MockClient((r) async => http.Response('{"id": "x"}', 201));
    expect(await _error(odd), contains('the order was sent'));
  });
}
