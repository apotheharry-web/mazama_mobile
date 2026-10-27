import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/coa_data_resolver.dart';
import 'package:mazama_mobile/packages_client.dart';

/// A row shaped like the real state system's GetPackagedProducts response (state_packages_client_test.dart's
/// own fixtures), with a lotGuid so coa_data_resolver.dart's byGuid grouping has something to key off of.
Map<String, Object?> _stateRow(String productGuid, int id, String lotGuid) => {
      'productGuid': productGuid, 'productType': 'Extract', 'id': id, 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
      'quantity': 10, 'harvestBatchGuid': lotGuid,
    };

Map<String, Object?> _coaDataJson({String strain = 'Golden Teacher', double? tpe = 1.75}) =>
    {'strain': strain, 'psilocybin': 1.0, 'psilocin': 0.5, 'baeocystin': 0, 'norbaeocystin': 0, 'norpsilocin': 0, 'tpe': tpe};

/// GetPackagedProductInfo's own shape (labpdfs.py's _pdf_docs mirrors this server-side) - one accepted Potency
/// test result with a single non-deprecated PDF document.
Map<String, Object?> _productInfoWithPdf(int docId, {String dateCompleted = '01/02/2026'}) => {
      'testResults': [
        {
          'test': 'Potency', 'status': 'Accepted', 'dateCompleted': dateCompleted,
          'testingManifest': {
            'documents': [
              {'id': docId, 'extension': '.pdf', 'deprecated': false},
            ],
          },
        },
      ],
    };

/// Dispatches by URL path/host so one MockClient can stand in for every state/Mazama call
/// resolveAdhocInventory makes (fetchPackagesFromState, fetchCoaDataBatch, fetchStateJson, downloadStateDocument,
/// uploadCoaParse) - same approach cart_page_test.dart's own fixtures use for a page with several network deps.
http.Client _router(Map<String, Future<http.StreamedResponse> Function(http.BaseRequest)> routes) =>
    http_testing.MockClient.streaming((req, bodyStream) async {
      for (final entry in routes.entries) {
        if (req.url.path.contains(entry.key)) return entry.value(req);
      }
      throw Exception('no route stubbed for ${req.method} ${req.url}');
    });

Future<http.StreamedResponse> _json(Object body, [int status = 200]) async =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status);

void main() {
  // The miss path's GetPackagedProductInfo call runs through fetchStateJson (state_client.dart), which loads
  // assets/flows/state_reads.yaml via rootBundle - that needs a binding, which plain test() (unlike
  // testWidgets()) never initializes on its own. Without this, every test below that reaches the miss path
  // fails with "Binding has not yet been initialized" - see licenses_client_test.dart's own comment.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every guid resolved by the batch lookup: no miss-path calls made at all', () async {
    final loaded = <Package>[];
    final resolvedCalls = <String>[];
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001'), _stateRow('PKPR-b', 2, 'HB-a0002')]),
      'coa-data/batch': (req) async => _json({'HB-a0001': _coaDataJson(strain: 'Golden Teacher'), 'HB-a0002': _coaDataJson(strain: 'Enigma')}),
      'GetPackagedProductInfo': (req) async => throw Exception('should never be reached - every guid was a batch hit'),
    });

    final result = await resolveAdhocInventory(
      stateId: 225, accessToken: 'T', workerEmail: 'w@example.com', deviceId: 'D-1',
      onInventoryLoaded: loaded.addAll,
      onResolved: (guid, pkg) => resolvedCalls.add(guid),
      client: client,
    );

    expect(loaded, hasLength(2)); // onInventoryLoaded fires with the raw, pre-enrichment inventory
    expect(result.guidsTotal, 2);
    expect(result.guidsResolved, 2);
    expect(resolvedCalls, unorderedEquals(['HB-a0001', 'HB-a0002']));
    final byGuid = {for (final p in result.packages) p.lotGuid: p};
    expect(byGuid['HB-a0001']!.strain, 'Golden Teacher');
    expect(byGuid['HB-a0002']!.strain, 'Enigma');
  });

  test('SM-22: the server answers with lower-cased lot ids; every lot it knows is still a hit, none re-downloaded', () async {
    // 30 lots, more than maxMisses (25 then; defaultMaxMisses, 20, since SM-23): before the fix every one was a "miss", 25 were re-downloaded and
    // re-uploaded and the last 5 never resolved
    final lots = [for (var i = 0; i < 30; i++) 'HB-${(0xaaa00 + i).toRadixString(16)}'];
    final client = _router({
      'GetPackagedProducts': (req) async => _json([for (var i = 0; i < lots.length; i++) _stateRow('PKPR-$i', i + 1, lots[i])]),
      'coa-data/batch': (req) async {
        final asked = (jsonDecode((req as http.Request).body) as Map)['guids'] as List;
        return _json({for (final g in asked) (g as String).toLowerCase(): _coaDataJson(strain: 'Golden Teacher')});
      },
      'GetPackagedProductInfo': (req) async => throw Exception('a lot the server already knows was re-downloaded'),
      'coa-data/parse': (req) async => throw Exception('a lot the server already knows was re-uploaded'),
    });

    final result = await resolveAdhocInventory(stateId: 225, accessToken: 'T', workerEmail: 'w@example.com', deviceId: 'D-1', client: client);

    expect(result.guidsTotal, 30);
    expect(result.guidsResolved, 30);
    expect(result.packages.every((p) => p.strain == 'Golden Teacher'), isTrue);
  });

  test('a batch miss runs the full GetPackagedProductInfo -> download -> parse path and applies the result', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001')]),
      'coa-data/batch': (req) async => _json(<String, Object?>{}), // a clean miss for G-1
      'GetPackagedProductInfo': (req) async => _json(_productInfoWithPdf(42)),
      'DownloadDocument': (req) async => http.StreamedResponse(Stream.value([0x25, 0x50, 0x44, 0x46]), 200),
      'coa-data/parse': (req) async {
        expect(req, isA<http.MultipartRequest>());
        final mp = req as http.MultipartRequest;
        expect(mp.fields['guid'], 'HB-a0001');
        // Snake_case, matching mazama_sales' own Form() parameter names (worker_email/device_id) exactly - see
        // coa_data_client.dart's own uploadCoaParse comment on why. This test previously asserted camelCase,
        // which the real field never was - the mismatch meant mp.fields['workerEmail'] was always null, this
        // expect() always threw, and that thrown TestFailure was then silently swallowed by
        // coa_data_resolver.dart's own worker() catch-all (every miss is treated as non-fatal by design), so
        // the test failed much further down instead, as "guidsResolved: 0" rather than at the real mismatch.
        expect(mp.fields['worker_email'], 'w@example.com');
        expect(mp.fields['device_id'], 'D-1');
        expect(mp.fields['doc_id'], '42');
        return _json(_coaDataJson(strain: 'Blue Meanie', tpe: 2.0));
      },
    });

    final result = await resolveAdhocInventory(stateId: 225, accessToken: 'T', workerEmail: 'w@example.com', deviceId: 'D-1', client: client);

    expect(result.guidsResolved, 1);
    expect(result.packages.single.strain, 'Blue Meanie');
    expect(result.packages.single.tpeMg, 10); // weightPerUnit 5.0 * tpe 2.0 = 10, ceil -> 10
  });

  test('SM-D15: a lab result with no TPE keeps the state figure\'s mg; no mg is worked out from the lab report', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001')]),
      'coa-data/batch': (req) async => _json({'HB-a0001': _coaDataJson(strain: 'Golden Teacher', tpe: null)}),
    });
    final result = await resolveAdhocInventory(stateId: 225, accessToken: 'T', workerEmail: 'w@example.com', deviceId: 'D-1', client: client);
    expect(result.packages.single.strain, 'Golden Teacher');
    expect(result.packages.single.tpeMg, 23); // the state's 4.5 mg/g x 5.0 g = 22.5, rounded up, as before the lookup
  });

  test('the miss-path GetPackagedProductInfo call uses the lot\'s own representative PACKAGE id, never the '
      'service center\'s stateId - mazama_sales\' labpdfs.py calls session.packaged_product_info(cand["state_id"]) '
      'with exactly a packaged_product row\'s own state_id, never a center\'s', () async {
    String? infoPath;
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 777, 'HB-a0001')]), // package id 777, center is 225
      'coa-data/batch': (req) async => _json(<String, Object?>{}),
      'GetPackagedProductInfo': (req) async {
        infoPath = req.url.path;
        return _json(_productInfoWithPdf(42));
      },
      'DownloadDocument': (req) async => http.StreamedResponse(Stream.value([0x25, 0x50, 0x44, 0x46]), 200),
      'coa-data/parse': (req) async => _json(_coaDataJson()),
    });

    await resolveAdhocInventory(stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd', client: client);

    expect(infoPath, endsWith('/GetPackagedProductInfo/777')); // the PACKAGE's own id, not the center's 225
  });

  test('a miss with no PDF on file at all stays degraded rather than failing the whole load', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001')]),
      'coa-data/batch': (req) async => _json(<String, Object?>{}),
      'GetPackagedProductInfo': (req) async => _json({'testResults': <Object?>[]}), // no Potency result at all
    });

    final result = await resolveAdhocInventory(stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd', client: client);

    expect(result.guidsTotal, 1);
    expect(result.guidsResolved, 0);
    expect(result.packages.single.strain, ''); // unchanged from the raw state row's own blank strain
  });

  test('one lot\'s miss-path failure never fails the others - each guid is independent', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001'), _stateRow('PKPR-b', 2, 'HB-a0002')]),
      'coa-data/batch': (req) async => _json(<String, Object?>{}),
      'GetPackagedProductInfo': (req) async => _json(_productInfoWithPdf(42)),
      'DownloadDocument': (req) async => throw Exception('network hiccup - should not take down the other guid'),
    });

    final result = await resolveAdhocInventory(
      stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd', maxConcurrent: 2, client: client);

    expect(result.guidsTotal, 2);
    expect(result.guidsResolved, 0); // both failed the same way here, but neither threw out of resolveAdhocInventory
    expect(result.packages, hasLength(2));
  });

  test('misses are capped at maxMisses - the rest simply stay degraded, never queued', () async {
    var infoCalls = 0;
    final client = _router({
      'GetPackagedProducts': (req) async =>
          _json([_stateRow('PKPR-a', 1, 'HB-a0001'), _stateRow('PKPR-b', 2, 'HB-a0002'), _stateRow('PKPR-c', 3, 'HB-a0003')]),
      'coa-data/batch': (req) async => _json(<String, Object?>{}),
      'GetPackagedProductInfo': (req) async {
        infoCalls++;
        return _json({'testResults': <Object?>[]});
      },
    });

    final result = await resolveAdhocInventory(
      stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd', maxMisses: 1, client: client);

    expect(result.guidsTotal, 3);
    expect(infoCalls, 1); // only the one allowed-through miss ever reaches the state system again
  });

  test('a batch-lookup failure is not fatal - every guid simply falls through to the miss path', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001')]),
      'coa-data/batch': (req) async => http.StreamedResponse(const Stream.empty(), 500),
      'GetPackagedProductInfo': (req) async => _json(_productInfoWithPdf(7)),
      'DownloadDocument': (req) async => http.StreamedResponse(Stream.value([0x25, 0x50, 0x44, 0x46]), 200),
      'coa-data/parse': (req) async => _json(_coaDataJson(strain: 'Recovered')),
    });

    final result = await resolveAdhocInventory(stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd', client: client);

    expect(result.guidsResolved, 1);
    expect(result.packages.single.strain, 'Recovered');
  });

  test('a fetchPackagesFromState failure surfaces as AdhocCoaError, not a raw StatePackagesError', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => http.StreamedResponse(const Stream.empty(), 401),
    });
    await expectLater(
      resolveAdhocInventory(stateId: 225, accessToken: 'STALE', workerEmail: 'w', deviceId: 'd', client: client),
      throwsA(isA<AdhocCoaError>()),
    );
  });

  test('an inventory with no lot guids at all resolves immediately with nothing to look up', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => _json([
            {'productGuid': 'PKPR-a', 'productType': 'Extract', 'id': 1, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10},
          ]),
    });
    final result = await resolveAdhocInventory(stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd', client: client);
    expect(result.guidsTotal, 0);
    expect(result.guidsResolved, 0);
    expect(result.packages, hasLength(1));
  });

  group('newestPotencyPdfDocId', () {
    test('picks the newest non-deprecated accepted-Potency PDF, ignoring other tests/statuses/extensions', () {
      final info = {
        'testResults': [
          {
            'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '01/01/2026',
            'testingManifest': {'documents': [
              {'id': 1, 'extension': '.pdf', 'deprecated': false},
            ]},
          },
          {
            'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '06/15/2026',
            'testingManifest': {'documents': [
              {'id': 2, 'extension': '.pdf', 'deprecated': false},
              {'id': 3, 'extension': '.pdf', 'deprecated': true}, // deprecated - skipped
              {'id': 4, 'extension': '.docx', 'deprecated': false}, // wrong extension - skipped
            ]},
          },
          {
            'test': 'Pesticide', 'status': 'Accepted', 'dateCompleted': '09/01/2026',
            'testingManifest': {'documents': [
              {'id': 5, 'extension': '.pdf', 'deprecated': false}, // wrong test - skipped
            ]},
          },
          {
            'test': 'Potency', 'status': 'Pending', 'dateCompleted': '09/02/2026',
            'testingManifest': {'documents': [
              {'id': 6, 'extension': '.pdf', 'deprecated': false}, // not accepted - skipped
            ]},
          },
        ],
      };
      expect(newestPotencyPdfDocId(info), 2); // the 06/15/2026 result beats the 01/01/2026 one
    });

    test('returns null when there is no candidate at all', () {
      expect(newestPotencyPdfDocId({'testResults': <Object?>[]}), isNull);
      expect(newestPotencyPdfDocId(null), isNull);
      expect(newestPotencyPdfDocId('not a map'), isNull);
    });

    test('an undated candidate sorts after every dated one', () {
      final info = {
        'testResults': [
          {
            'test': 'Potency', 'status': 'Accepted', 'dateCompleted': null,
            'testingManifest': {'documents': [
              {'id': 1, 'extension': '.pdf', 'deprecated': false},
            ]},
          },
          {
            'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '01/01/2020',
            'testingManifest': {'documents': [
              {'id': 2, 'extension': '.pdf', 'deprecated': false},
            ]},
          },
        ],
      };
      expect(newestPotencyPdfDocId(info), 2);
    });
  });
}
