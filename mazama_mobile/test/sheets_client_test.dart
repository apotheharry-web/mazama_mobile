// SP-R16: the phone's client for GET /p/sheets/{state_id} (lib/sheets_client.dart) against the vendored API example
// (assets/shared/api/examples/sheets.*.json, from ../mazama_modules/api/), how it reports what can go wrong, and how a
// sheet matches the strain picked on the stock page. api_contract_test.dart checks the route, key and 401 / 429.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/sheets_client.dart';

Object? _example(String part) => jsonDecode(File('assets/shared/api/examples/sheets.$part.json').readAsStringSync());

http.Client _serve(Object? reply, {int status = 200}) =>
    http_testing.MockClient((req) async => http.Response(reply is String ? reply : jsonEncode(reply), status));

Future<String> _error(http.Client client) async {
  try {
    await fetchProductSheets(225, client: client);
  } on SheetsError catch (e) {
    return e.message;
  }
  fail('expected a SheetsError');
}

void main() {
  final stateId = (_example('params') as Map)['state_id'] as int;

  test('reads the example reply, and each sheet opens its page on the server', () async {
    Uri? asked;
    final sheets = await fetchProductSheets(stateId, client: http_testing.MockClient((req) async {
      asked = req.url;
      return http.Response(jsonEncode(_example('response')), 200);
    }));
    expect(asked.toString(), '$apiBaseUrl${sheetsPath(stateId)}');
    expect([for (final s in sheets) s.toJson()], (_example('response') as Map)['sheets']);
    expect(sheets.single.url().toString(), '$apiBaseUrl/p/lots/mazama/HB-aaaa0001');
  });

  test('a sheet is for a strain ignoring case, and an unknown one is "Unknown"', () {
    const s = ProductSheet(guid: 'HB-1', name: '', product: '', tested: '', path: null, strains: ['Golden Teacher', '']);
    expect(s.isFor('golden teacher'), isTrue);
    expect(s.isFor('Unknown'), isTrue);
    expect(s.isFor('Penis Envy'), isFalse);
    expect(s.url(), isNull); // nothing to open (demo mode)
  });

  test('SP-D18: lab figures and types are read; a server from before them gives none; another shape is refused', () async {
    final sheets = await fetchProductSheets(stateId, client: _serve(_example('response')));
    expect([sheets.single.tpe, sheets.single.psilocybin, sheets.single.psilocin], [8.64, 7.25, 1.0]);
    expect(sheets.single.types, ['DH']);
    final old = await fetchProductSheets(stateId,
        client: _serve({'sheets': [{'guid': 'HB-1', 'name': '', 'product': '', 'tested': '', 'path': null, 'strains': []}]}));
    expect([old.single.tpe, old.single.detected, old.single.types], [null, isEmpty, isEmpty]);
    expect(await _error(_serve({'sheets': [{'guid': 'HB-1', 'strains': [], 'tpe': 'high'}]})), 'unexpected response shape');
    expect(await _error(_serve({'sheets': [{'guid': 'HB-1', 'strains': [], 'types': 'DH'}]})), 'unexpected response shape');
  });

  test('SP-D18: sheetLotRows puts a lot under each strain, an edible lot under its product, sorted by name then id', () {
    const sheets = [
      ProductSheet(guid: 'PL-choc', name: '', product: '', tested: '', path: null, strains: ['Blue Lantern'], types: ['CH'], tpe: 6),
      ProductSheet(guid: 'PL-mix', name: '', product: '', tested: '', path: '/p/x', strains: ['Bluey', 'avery'], types: ['FD', 'GM']),
      ProductSheet(guid: 'HB-un', name: '', product: '', tested: '', path: null, strains: []),
    ];
    final rows = sheetLotRows(sheets);
    expect([for (final r in rows) '${r.strain}|${r.lot}'], ['avery|PL-mix', 'Bluey|PL-mix', 'Chocolate|PL-choc', 'Gummy|PL-mix', '|HB-un']);
    final choc = rows.firstWhere((r) => r.lot == 'PL-choc');
    expect([choc.tpe, choc.types, choc.path], [6, ['CH'], null]);
    expect(rows.firstWhere((r) => r.lot == 'PL-mix').path, '/p/x');
  });

  test("the server's 404 detail is shown as it is", () async {
    expect(await _error(_serve({'detail': 'No such service center.'}, status: 404)), 'No such service center.');
  });

  test('a reply that is not JSON, or not the shape, says so', () async {
    expect(await _error(_serve('<html>proxy</html>')), 'the server did not answer with JSON');
    expect(await _error(_serve(['not', 'a', 'map'])), 'unexpected response shape');
    expect(await _error(_serve({'sheets': [1]})), 'unexpected response shape');
    expect(await _error(_serve({'sheets': [{'guid': 'HB-1', 'strains': 'Bluey'}]})), 'unexpected response shape');
  });

  test('no connection says which server could not be reached', () async {
    final down = http_testing.MockClient((req) async => throw const SocketException('down'));
    expect(await _error(down), startsWith('cannot reach '));
  });

  test('no network or a 5xx is unreachable; a 4xx or an odd reply is not', () async {
    Future<bool> unreachable(http.Client c) async {
      try {
        await fetchProductSheets(225, client: c);
      } on SheetsError catch (e) {
        return e.unreachable;
      }
      fail('expected a SheetsError');
    }

    expect(await unreachable(http_testing.MockClient((r) async => throw const SocketException('down'))), isTrue);
    expect(await unreachable(_serve('<html>Bad gateway</html>', status: 502)), isTrue);
    expect(await unreachable(_serve({'detail': 'No such service center.'}, status: 404)), isFalse);
    expect(await unreachable(_serve({'detail': 'bad key'}, status: 401)), isFalse);
    expect(await unreachable(_serve('<html>proxy</html>')), isFalse);
  });
}
