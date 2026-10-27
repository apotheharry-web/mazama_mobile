// MI-R2: the phone's client for GET /p/mazama-inventory (lib/mazama_inventory_client.dart) against the vendored API
// example (assets/shared/api/examples/mazama_inventory.response.json, from ../mazama_modules/api/), and how it
// reports what can go wrong. api_contract_test.dart checks the route, the app key and the 401 / 429 wording.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/stock_mix.dart';

Object? _example() => jsonDecode(File('assets/shared/api/examples/mazama_inventory.response.json').readAsStringSync());

http.Client _serve(Object? reply, {int status = 200}) =>
    http_testing.MockClient((req) async => http.Response(reply is String ? reply : jsonEncode(reply), status));

Future<String> _error(http.Client client) async {
  try {
    await fetchMazamaInventory(client: client);
  } on MazamaInventoryError catch (e) {
    return e.message;
  }
  fail('expected a MazamaInventoryError');
}

void main() {
  test('reads the example reply, and its cells give the shared mix', () async {
    final inv = await fetchMazamaInventory(client: _serve(_example()));
    expect(inv.name, 'Mazama Mushrooms LLC');
    expect([for (final c in inv.cells) '${c.strain}|${c.type}|${c.mg}'], ['Golden Teacher|DH|3888.0', 'Maztapec|WF|500.0']);
    final mix = stockMix(inv.cells);
    expect(formatMixMg(mix['total'] as num), '4,388');
    expect([for (final l in inv.lots) '${l.strain}|${l.lot}|${l.tpe}|${l.psilocybin}|${l.psilocin}|${l.detected}'],
        ['Golden Teacher|HB-aaaa0001|8.64|7.25|1.0|[]', 'Maztapec|HB-bbbb0002|5.0|5.0|null|[]']);
  });

  test('MI-R7: a server without lots gives none; lots in another shape are refused', () async {
    final inv = await fetchMazamaInventory(client: _serve({'name': 'Mazama', 'cells': []}));
    expect(inv.lots, isEmpty);
    expect(await _error(_serve({'name': 'Mazama', 'cells': [], 'lots': [1]})), 'unexpected response shape');
    expect(await _error(_serve({'name': 'Mazama', 'cells': [], 'lots': [{'strain': 'GT', 'lot': 'HB-1', 'tpe': '8'}]})),
        'unexpected response shape');
    final lot = (await fetchMazamaInventory(client: _serve({'name': 'Mazama', 'cells': [], 'lots': [
      {'strain': 'GT', 'lot': 'HB-1', 'tpe': 8, 'psilocybin': null, 'psilocin': 1.5, 'detected': ['norpsilocin']}
    ]}))).lots.single;
    expect(lot.toJson(), {
      'strain': 'GT',
      'lot': 'HB-1',
      'tpe': 8,
      'psilocybin': null,
      'psilocin': 1.5,
      'detected': ['norpsilocin'],
      'types': [],
      'path': null
    });
    expect(lot.url(), isNull);
  });

  test('MI-D18: a lot with a sheet has its address on the server; a path that is not text is refused', () async {
    final inv = await fetchMazamaInventory(client: _serve(_example()));
    expect(inv.lots.first.url().toString(), '$apiBaseUrl/p/lots/mazama/HB-aaaa0001');
    expect(inv.lots.last.url(), isNull);
    expect([for (final l in inv.lots) l.types], [['DH'], ['WF']]); // MI-D20
    expect(await _error(_serve({'name': 'Mazama', 'cells': [], 'lots': [{'strain': 'GT', 'lot': 'HB-1', 'types': 'DH'}]})),
        'unexpected response shape');
    expect(await _error(_serve({'name': 'Mazama', 'cells': [], 'lots': [{'strain': 'GT', 'lot': 'HB-1', 'path': 5}]})),
        'unexpected response shape');
  });

  test('asks the generated path on the default server', () async {
    Uri? asked;
    await fetchMazamaInventory(client: http_testing.MockClient((req) async {
      asked = req.url;
      return http.Response(jsonEncode(_example()), 200);
    }));
    expect(asked.toString(), '$apiBaseUrl${mazamaInventoryPath()}');
  });

  test("the server's 404 detail is shown as it is", () async {
    expect(await _error(_serve({'detail': 'No manufacturer.'}, status: 404)), 'No manufacturer.');
  });

  test('a reply that is not JSON, or not the shape, says so', () async {
    expect(await _error(_serve('<html>proxy</html>')), 'the server did not answer with JSON');
    expect(await _error(_serve(['not', 'a', 'map'])), 'unexpected response shape');
    expect(await _error(_serve({'name': 'Mazama'})), 'unexpected response shape');
    expect(await _error(_serve({'name': 'Mazama', 'cells': [1]})), 'unexpected response shape');
  });

  test('no connection says which server could not be reached', () async {
    final down = http_testing.MockClient((req) async => throw const SocketException('down'));
    expect(await _error(down), startsWith('cannot reach '));
  });

  test('no network or a 5xx is unreachable; a 4xx is not', () async {
    Future<bool> unreachable(http.Client c) async {
      try {
        await fetchMazamaInventory(client: c);
      } on MazamaInventoryError catch (e) {
        return e.unreachable;
      }
      fail('expected a MazamaInventoryError');
    }

    expect(await unreachable(http_testing.MockClient((r) async => throw const SocketException('down'))), isTrue);
    expect(await unreachable(_serve('', status: 503)), isTrue);
    expect(await unreachable(_serve({'detail': 'No manufacturer.'}, status: 404)), isFalse);
  });

  test('toJson reads back through fromJson as the same mix (the copy kept on the phone)', () async {
    final inv = await fetchMazamaInventory(client: _serve(_example()));
    final back = MazamaInventory.fromJson(jsonDecode(jsonEncode(inv.toJson())) as Map<String, Object?>);
    expect(back.name, inv.name);
    expect([for (final c in back.cells) c.toJson()], [for (final c in inv.cells) c.toJson()]);
    expect([for (final l in back.lots) l.toJson()], [for (final l in inv.lots) l.toJson()]);
  });
}
