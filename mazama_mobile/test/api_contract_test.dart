// SM-22: every phone client of a /p/ route builds the example request and reads the example reply
// (../mazama_modules/api/examples/<route>.<part>.json, vendored here at assets/shared/api/examples/ by
// tool/sync_flows.sh), at the path routes.yaml gives, through lib/api_contract.g.dart (generated from routes.yaml,
// apiRoutes included). The server's side is mazama_sales/tests/web/test_api_contract.py.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/coa_uploader.dart' show coaUploadStartInterval;
import 'package:mazama_mobile/flow/flow_runner.dart' show FlowStage;
import 'package:mazama_mobile/flow/flow_spec.dart' show supportedFlowFormat;
import 'package:mazama_mobile/inventory_upload_client.dart';
import 'package:mazama_mobile/label_client.dart';
import 'package:mazama_mobile/login_hosts_client.dart';
import 'package:mazama_mobile/login_spec_client.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/order_client.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/par_client.dart';
import 'package:mazama_mobile/ping_client.dart';
import 'package:mazama_mobile/sale_failure_client.dart';
import 'package:mazama_mobile/sale_log_client.dart';
import 'package:mazama_mobile/sales_upload_client.dart';
import 'package:mazama_mobile/scan_match_client.dart';
import 'package:mazama_mobile/server_error.dart';
import 'package:mazama_mobile/server_outbox.dart' show uuidV4;
import 'package:mazama_mobile/sheets_client.dart';
import 'package:mazama_mobile/signin_failure_client.dart';
import 'package:mazama_mobile/stock_summary.dart';

Object? _example(String route, String part) =>
    jsonDecode(File('assets/shared/api/examples/$route.$part.json').readAsStringSync());

/// A client that answers one request with [reply] (or [bytes]) and keeps the request it got, as the client built it
/// (the streaming mock hands over the original, so a multipart request keeps its fields and files).
(http.Client, List<http.BaseRequest>) _serve(Object? reply, {int status = 200, List<int>? bytes}) {
  final seen = <http.BaseRequest>[];
  final client = http_testing.MockClient.streaming((req, body) async {
    await body.drain<void>();
    seen.add(req);
    return http.StreamedResponse(Stream.value(bytes ?? utf8.encode(jsonEncode(reply))), status);
  });
  return (client, seen);
}

void _sameRoute(http.BaseRequest req, String route, String path) {
  final r = apiRoutes[route]!;
  expect(req.method, r['method'], reason: route);
  expect(req.url.toString(), '$apiBaseUrl$path', reason: route);
  if (r['keyRequired'] == true && appApiKey.isNotEmpty) expect(req.headers[appApiKeyHeader], appApiKey, reason: route);
}

Object? _jsonBody(http.BaseRequest req) => jsonDecode((req as http.Request).body);

void main() {
  test('every route in routes.yaml has a path function and the generated paths match it', () {
    final generated = {
      'packages': packagesPath(225),
      'label': labelPath(225, 'PKPR-aaaa0001'),
      'inventory': inventoryPath(225),
      'center_status': centerStatusPath(225),
      'coa_data_batch': coaDataBatchPath(),
      'coa_data_parse': coaDataParsePath(),
      'scan_match': scanMatchPath(225),
      'sale_log': saleLogPath(225),
      'sale_failure': saleFailurePath(225),
      'par': parPath(225),
      'par_save': parSavePath(225),
      'mazama_inventory': mazamaInventoryPath(),
      'sheets': sheetsPath(225),
      'order': orderPath(225),
      'ping': pingPath(),
      'signin_failure': signinFailurePath(),
      'login_spec': loginSpecPath(),
      'login_hosts': loginHostsPath(),
      'login_browser_spec': loginBrowserSpecPath(),
      'ingest': ingestPath('sales', 225),
    };
    expect(generated.keys.toSet(), apiRoutes.keys.toSet());
    for (final e in generated.entries) {
      final path = apiRoutes[e.key]!['path'] as String;
      expect(e.value,
          path.replaceAll('{state_id}', '225').replaceAll('{guid}', 'PKPR-aaaa0001').replaceAll('{dataset}', 'sales'),
          reason: e.key);
    }
    expect(labelPath(225, 'a/b'), '/p/label/225/a%2Fb');
    expect(ingestPath('a/b', 225), '/p/ingest/a%2Fb/225');
    expect(appApiKeyHeaderName, appApiKeyHeader); // app_api_key.dart sends the header routes.yaml names
  });

  test('C1 packages: reads the example reply', () async {
    final (client, seen) = _serve(_example('packages', 'response'));
    final packages = await fetchPackages(225, client: client);
    _sameRoute(seen.single, 'packages', packagesPath(225));
    expect(packages, hasLength(3));
    expect(packages.first.productGuid, 'PKPR-aaaa0001');
    expect(packages.first.tpeMg, 5);
    expect(packages.last.coaAvailable, isFalse);
  });

  test('C2 label: answers the image bytes', () async {
    final (client, seen) = _serve(null, bytes: [0x89, 0x50, 0x4e, 0x47]);
    final png = await fetchLabel(225, 'PKPR-aaaa0001', client: client);
    _sameRoute(seen.single, 'label', labelPath(225, 'PKPR-aaaa0001'));
    expect(png, [0x89, 0x50, 0x4e, 0x47]);
  });

  test('C3 inventory: sends the example request, reads the example reply', () async {
    final req = _example('inventory', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('inventory', 'response'));
    final out = await uploadInventorySnapshot(225, req['records'] as List<Object?>,
        workerEmail: req['workerEmail'] as String, deviceId: req['deviceId'] as String, client: client);
    _sameRoute(seen.single, 'inventory', inventoryPath(225));
    expect(_jsonBody(seen.single), req);
    expect(out, _example('inventory', 'response'));
  });

  test('C3 inventory: more records than the server takes is refused before sending', () async {
    final (client, seen) = _serve({'rows': 0, 'skipped': 0});
    await expectLater(
      uploadInventorySnapshot(225, List.filled(inventoryMaxRecords + 1, <String, Object?>{}),
          workerEmail: 'w@example.com', deviceId: 'd', client: client),
      throwsA(isA<InventoryUploadError>()),
    );
    expect(seen, isEmpty);
  });

  test('C20 ingest (sales): sends the example request, reads the example reply', () async {
    final req = _example('ingest', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('ingest', 'response'));
    final out = await uploadSalesSnapshot(225, req['records'] as List<Object?>,
        workerEmail: req['workerEmail'] as String, deviceId: req['deviceId'] as String, client: client);
    _sameRoute(seen.single, 'ingest', ingestPath('sales', 225));
    expect(_jsonBody(seen.single), req);
    expect(out, _example('ingest', 'response'));
  });

  test('C20 ingest (sales): more records than the server takes is refused before sending', () async {
    final (client, seen) = _serve({'rows': 0, 'skipped': 0});
    await expectLater(
      uploadSalesSnapshot(225, List.filled(ingestMaxRecords + 1, <String, Object?>{}),
          workerEmail: 'w@example.com', deviceId: 'd', client: client),
      throwsA(isA<SalesUploadError>()),
    );
    expect(seen, isEmpty);
  });

  test('C4 center status: reads the example reply', () async {
    final (client, seen) = _serve(_example('center_status', 'response'));
    expect(await centerIsConfigured(225, client: client), isTrue);
    _sameRoute(seen.single, 'center_status', centerStatusPath(225));
  });

  test('C5 coa-data batch: sends the example request, reads the lower-cased keys of the example reply', () async {
    final req = _example('coa_data_batch', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('coa_data_batch', 'response'));
    final out = await fetchCoaDataBatch((req['guids'] as List).cast<String>(), client: client);
    _sameRoute(seen.single, 'coa_data_batch', coaDataBatchPath());
    expect(_jsonBody(seen.single), req);
    expect(out.keys.toSet(), {'HB-9bc7d118', 'PL-DE20657A'}); // as asked, matched case-insensitively
    expect(out['HB-9bc7d118']!.strain, 'Golden Teacher');
    // SM-08: the rules file's analyte names, aeruginascin included (null in the example: not known)
    expect(out['HB-9bc7d118']!.baeocystin, 0.21);
    expect(out['HB-9bc7d118']!.aeruginascin, isNull);
  });

  test('C5 coa-data batch: more lots than the server answers for go in several requests', () async {
    final guids = [for (var i = 0; i < coaDataBatchMaxGuids * 2 + 3; i++) 'HB-${(0x100000 + i).toRadixString(16)}'];
    final sizes = <int>[];
    final client = http_testing.MockClient((req) async {
      final asked = ((jsonDecode(req.body) as Map)['guids'] as List).cast<String>();
      sizes.add(asked.length);
      return http.Response(jsonEncode({for (final g in asked) g.toLowerCase(): _example('coa_data_parse', 'response')}), 200);
    });
    final out = await fetchCoaDataBatch(guids, client: client);
    expect(sizes, [coaDataBatchMaxGuids, coaDataBatchMaxGuids, 3]);
    expect(out.length, guids.length);
  });

  test('C6 coa-data parse: sends the routes.yaml fields and the pdf file, reads the example reply', () async {
    final req = _example('coa_data_parse', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('coa_data_parse', 'response'));
    final data = await uploadCoaParse(
      guid: req['guid'] as String,
      pdfBytes: Uint8List.fromList(utf8.encode('%PDF-1.4')),
      docId: int.parse(req['doc_id'] as String),
      workerEmail: req['worker_email'] as String,
      deviceId: req['device_id'] as String,
      statePsilocybin: double.parse(req['state_psilocybin'] as String),
      client: client,
    );
    final sent = seen.single as http.MultipartRequest;
    _sameRoute(sent, 'coa_data_parse', coaDataParsePath());
    final route = apiRoutes['coa_data_parse']!;
    expect(sent.fields.keys.toSet(), (route['fields'] as List).toSet());
    expect(sent.fields, {for (final e in req.entries) if (e.key != 'pdf') e.key: e.value});
    expect(sent.files.map((f) => f.field).toList(), route['files']);
    expect(data.strain, 'Golden Teacher');
  });

  test('C7 scan match: sends the example request, reads the example reply', () async {
    final req = _example('scan_match', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('scan_match', 'response'));
    final out = await scanMatch(225, (req['lines'] as List).cast<String>(), typed: req['typed'] as bool, client: client);
    _sameRoute(seen.single, 'scan_match', scanMatchPath(225));
    expect(_jsonBody(seen.single), req);
    expect(out.matches.single.guid, 'PKPR-aaaa0001');
  });

  test('C7 scan match: sends no more lines, and no longer lines, than the server reads', () async {
    final (client, seen) = _serve({'matches': [], 'guesses': []});
    await scanMatch(225, List.filled(scanMatchMaxLines + 5, 'x' * (scanMatchMaxLineChars + 9)), client: client);
    final lines = ((_jsonBody(seen.single) as Map)['lines'] as List).cast<String>();
    expect(lines, hasLength(scanMatchMaxLines));
    expect(lines.every((l) => l.length == scanMatchMaxLineChars), isTrue);
  });

  test('C7 scan match: a reply that is not JSON is a ScanMatchError, not a crash', () async {
    final (client, _) = _serve(null, bytes: utf8.encode('<html>proxy error</html>'));
    await expectLater(scanMatch(225, ['x'], client: client), throwsA(isA<ScanMatchError>()));
  });

  test('C8 sale log: sends the example request', () async {
    final req = _example('sale_log', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('sale_log', 'response'), status: 201);
    await postSaleLog(225,
        workerEmail: req['workerEmail'] as String,
        deviceId: req['deviceId'] as String,
        request: (req['request'] as List).cast<Map<String, Object?>>(),
        response: req['response'],
        clientId: req['clientId'] as String, // README R56: the outbox's id, so a repeat is recorded once
        client: client);
    _sameRoute(seen.single, 'sale_log', saleLogPath(225));
    expect(_jsonBody(seen.single), req);
  });

  test('C9 sale failure: sends the example request', () async {
    final req = _example('sale_failure', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('sale_failure', 'response'), status: 201);
    await postSaleFailure(225,
        workerEmail: req['workerEmail'] as String,
        deviceId: req['deviceId'] as String,
        reason: req['reason'] as String,
        request: (req['request'] as List).cast<Map<String, Object?>>(),
        clientId: req['clientId'] as String,
        client: client);
    _sameRoute(seen.single, 'sale_failure', saleFailurePath(225));
    expect(_jsonBody(seen.single), req);
  });

  test('C10 par: reads the example reply', () async {
    final (client, seen) = _serve(_example('par', 'response'));
    final levels = await fetchParLevels(225, client: client);
    _sameRoute(seen.single, 'par', parPath(225));
    expect(levels.map((l) => l.toJson()).toList(), (_example('par', 'response') as Map)['levels']);
  });

  test('C11 par save: sends the example request, reads the example reply', () async {
    final req = _example('par_save', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('par_save', 'response'));
    final stored = await saveParLevels(225,
        workerEmail: req['workerEmail'] as String,
        deviceId: req['deviceId'] as String,
        levels: [for (final l in req['levels'] as List) ParLevel.fromJson(Map<String, Object?>.from(l as Map))],
        client: client);
    _sameRoute(seen.single, 'par_save', parSavePath(225));
    expect(_jsonBody(seen.single), req);
    expect(stored.map((l) => l.toJson()).toList(), (_example('par_save', 'response') as Map)['levels']);
    expect((req['levels'] as List).length, lessThanOrEqualTo(parSaveMaxLevels));
  });

  test('C12 mazama inventory: reads the example reply', () async {
    final example = _example('mazama_inventory', 'response') as Map;
    final (client, seen) = _serve(example);
    final inv = await fetchMazamaInventory(client: client);
    _sameRoute(seen.single, 'mazama_inventory', mazamaInventoryPath());
    expect(inv.name, example['name']);
    expect([for (final c in inv.cells) c.toJson()], example['cells']);
    expect([for (final l in inv.lots) l.toJson()], example['lots']);
  });

  test('C13 sheets: reads the example reply', () async {
    final example = _example('sheets', 'response') as Map;
    final (client, seen) = _serve(example);
    final sheets = await fetchProductSheets(225, client: client);
    _sameRoute(seen.single, 'sheets', sheetsPath(225));
    expect([for (final s in sheets) s.toJson()], example['sheets']);
  });

  test('C14 order: sends the example request, reads the example reply', () async {
    final req = _example('order', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('order', 'response'), status: 201);
    final receipt = await submitOrder(225,
        workerEmail: req['workerEmail'] as String,
        deviceId: req['deviceId'] as String,
        lines: [for (final l in req['lines'] as List) OrderLine.fromJson(Map<String, Object?>.from(l as Map))],
        note: req['note'] as String,
        client: client);
    _sameRoute(seen.single, 'order', orderPath(225));
    expect(_jsonBody(seen.single), req);
    expect([for (final l in receipt.lines) l.toJson()], (_example('order', 'response') as Map)['lines']);
    expect((req['lines'] as List).length, lessThanOrEqualTo(orderMaxLines));
  });

  test('C15 ping: reads the example reply', () async {
    final (client, seen) = _serve(_example('ping', 'response'));
    await ping(client: client);
    _sameRoute(seen.single, 'ping', pingPath());
  });

  test('C8/C9: without a clientId (an older outbox entry, a debug call) none is sent', () async {
    final (client, seen) = _serve({'ok': true}, status: 201);
    await postSaleLog(225, workerEmail: 'w', deviceId: 'd', request: const [{}], response: null, client: client);
    expect((_jsonBody(seen.single) as Map).containsKey('clientId'), isFalse);
  });

  test('the outbox makes clientIds the server takes (routes.yaml: 1-64 letters, digits or dashes)', () {
    for (var i = 0; i < 20; i++) {
      expect(uuidV4(), matches(RegExp(r'^[A-Za-z0-9-]{1,64}$')));
    }
  });

  test('C16 signin failure: sends the example request', () async {
    final req = _example('signin_failure', 'request') as Map<String, Object?>;
    final (client, seen) = _serve(_example('signin_failure', 'response'), status: 201);
    await postSigninFailure(
        deviceId: req['deviceId'] as String,
        step: req['step'] as String?,
        stage: req['stage'] == null ? null : FlowStage.values.byName(req['stage'] as String),
        status: req['status'] as int?,
        reason: req['reason'] as String?,
        specVersion: req['specVersion'] as String?,
        client: client);
    _sameRoute(seen.single, 'signin_failure', signinFailurePath());
    expect(_jsonBody(seen.single), req);
  });

  test('C17 login spec: sends the example params, reads the example reply', () async {
    final params = _example('login_spec', 'params') as Map<String, Object?>;
    final example = _example('login_spec', 'response') as Map<String, Object?>;
    final (client, seen) = _serve(example);
    final got = await requestLoginSpec(client: client);
    expect(params, {'format': supportedFlowFormat}); // the phone asks for the format it reads
    _sameRoute(seen.single, 'login_spec', '${loginSpecPath()}?format=${params['format']}');
    expect(seen.single.url.queryParameters, {for (final e in params.entries) e.key: '${e.value}'});
    expect(got.yaml, example['yaml']);
    expect(got.source, example['source']);
    expect(got.spec.specVersion, example['specVersion']);
  });

  test('C19 browser login spec: sends the example params, reads the example reply', () async {
    final params = _example('login_browser_spec', 'params') as Map<String, Object?>;
    final example = _example('login_browser_spec', 'response') as Map<String, Object?>;
    final (client, seen) = _serve(example);
    final got = await requestBrowserLoginSpec(client: client);
    expect(params, {'format': supportedFlowFormat});
    _sameRoute(seen.single, 'login_browser_spec', '${loginBrowserSpecPath()}?format=${params['format']}');
    expect(seen.single.url.queryParameters, {for (final e in params.entries) e.key: '${e.value}'});
    expect(got.yaml, example['yaml']);
    expect(got.source, example['source']);
    expect(got.spec.specVersion, example['specVersion']);
  });

  test('C18 login hosts: reads the example reply, which verifies under the TEST key it was signed with', () async {
    final example = _example('login_hosts', 'response') as Map<String, Object?>;
    final (client, seen) = _serve(example);
    final got = await requestLoginHosts(client: client);
    _sameRoute(seen.single, 'login_hosts', loginHostsPath());
    expect((got.version, got.list, got.signature), (example['version'], example['list'], example['signature']));
    final vectors =
        jsonDecode(File('assets/shared/flows/contracts/signing_vectors.json').readAsStringSync()) as Map<String, Object?>;
    final testKey = (vectors['test_key'] as Map)['public_key'] as String;
    final (verifying, _) = _serve(example);
    final verified = await fetchLoginHosts(client: verifying, publicKey: testKey);
    expect(verified?.version, example['version']);
    expect(verified?.hosts, ['login.example.gov']);
  });

  test('no client writes out the server address or a /p/ path of its own', () {
    for (final name in [
      'packages_client', 'label_client', 'inventory_upload_client', 'sales_upload_client', 'coa_data_client', 'scan_match_client',
      'sale_log_client', 'sale_failure_client', 'par_client', 'mazama_inventory_client',
      'sheets_client', 'order_client', 'ping_client', 'signin_failure_client', 'login_spec_client',
      'login_hosts_client',
    ]) {
      final src = File('lib/$name.dart').readAsStringSync();
      expect(src.contains('https://sales.mazamamushrooms.com'), isFalse, reason: name);
      expect(RegExp(r"'\$baseUrl/p/").hasMatch(src), isFalse, reason: name);
    }
  });

  // SM-23: every client reports a 401 or a 429 the same way, through describeServerError.
  group('every client reports 401 and 429 the same way', () {
    final calls = <String, Future<Object?> Function(http.Client)>{
      'packages': (c) => fetchPackages(225, client: c),
      'label': (c) => fetchLabel(225, 'PKPR-aaaa0001', client: c),
      'inventory': (c) => uploadInventorySnapshot(225, const [], workerEmail: 'w', deviceId: 'd', client: c),
      'ingest': (c) => uploadSalesSnapshot(225, const [], workerEmail: 'w', deviceId: 'd', client: c),
      'center_status': (c) => centerIsConfigured(225, client: c),
      'coa_data_batch': (c) => fetchCoaDataBatch(['HB-aaaa0001'], client: c),
      'coa_data_parse': (c) => uploadCoaParse(
          guid: 'HB-aaaa0001', pdfBytes: Uint8List.fromList([0x25]), workerEmail: 'w', deviceId: 'd', client: c),
      'scan_match': (c) => scanMatch(225, ['x'], client: c),
      'sale_log': (c) => postSaleLog(225, workerEmail: 'w', deviceId: 'd', request: const [{}], response: null, client: c),
      'sale_failure': (c) => postSaleFailure(225, workerEmail: 'w', deviceId: 'd', reason: 'r', request: const [{}], client: c),
      'par': (c) => fetchParLevels(225, client: c),
      'par_save': (c) => saveParLevels(225, workerEmail: 'w', deviceId: 'd', levels: const [], client: c),
      'mazama_inventory': (c) => fetchMazamaInventory(client: c),
      'sheets': (c) => fetchProductSheets(225, client: c),
      'order': (c) => submitOrder(225, workerEmail: 'w', deviceId: 'd', lines: const [], client: c),
      'ping': (c) => ping(client: c),
      'signin_failure': (c) => postSigninFailure(deviceId: 'd', reason: 'structure', client: c),
      'login_spec': (c) => requestLoginSpec(client: c),
      'login_hosts': (c) => requestLoginHosts(client: c),
      'login_browser_spec': (c) => requestBrowserLoginSpec(client: c),
    };
    test('there is a call for every route', () {
      expect(calls.keys.toSet(), apiRoutes.keys.toSet());
    });
    for (final status in [401, 429]) {
      for (final e in calls.entries) {
        test('${e.key}: $status', () async {
          final body = File('assets/shared/api/examples/error.$status.json').readAsStringSync();
          final (client, _) = _serve(null, status: status, bytes: utf8.encode(body));
          Object? error;
          try {
            await e.value(client);
          } catch (ex) {
            error = ex;
          }
          expect(error?.toString(), describeServerError(status, body));
        });
      }
    }
  });

  test("the uploader never starts uploads faster than the server's per-minute budget for them (CU-R2)", () {
    expect(coaUploadStartInterval * coaDataParseRateLimitPerMinute, const Duration(minutes: 1));
  });
}
