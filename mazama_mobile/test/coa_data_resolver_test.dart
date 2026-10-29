import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/coa_data_resolver.dart';
import 'package:mazama_mobile/coa_uploader.dart';
import 'package:mazama_mobile/configured_coa_submit.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/state_client.dart' show stateReadsSpec;

import 'fake_timers.dart';

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
/// resolveAdhocInventory and the uploader make (fetchPackagesFromState, fetchCoaDataBatch, fetchStateJson,
/// downloadStateDocument, uploadCoaParse) - same approach cart_page_test_support.dart's own fixtures use for a page with several
/// network deps. The first route whose key the path contains answers, so a more specific key goes first.
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
  // The uploads' GetPackagedProductInfo call runs through fetchStateJson (state_client.dart), which loads
  // assets/flows/state_reads.yaml via rootBundle - that needs a binding, which plain test() (unlike
  // testWidgets()) never initializes on its own. Without this, every test below that reaches the upload path
  // fails with "Binding has not yet been initialized" - see licenses_client_test.dart's own comment.
  TestWidgetsFlutterBinding.ensureInitialized();
  // Read once up front, so an upload's chain doesn't wait on the asset load while [drain] pumps the event queue.
  setUpAll(() async => await stateReadsSpec());

  late Directory dir;
  late FakeTimers timers;
  late ServerHealth health;
  late CatchUpWork catchUp;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mazama_coa_resolver_test_');
    timers = FakeTimers();
    health = ServerHealth(probe: () async => false, startTimer: timers.start);
    catchUp = CatchUpWork(
        health: health,
        store: CatchUpStore(dataDir: () => dir),
        submitCoa: (l, a) async => true,
        uploadSnapshot: (s) async {},
        auth: () async => null);
  });
  tearDown(() {
    catchUp.dispose();
    health.dispose();
    dir.deleteSync(recursive: true);
  });

  /// The app's uploader (coa_uploader.dart) over [client], its timers fired by the test ([drain]): the real chain
  /// (configured_coa_submit.dart) against the same fake state system and server as the load.
  CoaUploader uploaderOver(http.Client client) {
    final u = CoaUploader(
      health: health,
      catchUp: catchUp,
      auth: () async => const CatchUpAuth(accessToken: 'T', workerEmail: 'w@example.com', deviceId: 'D-1'),
      sent: CoaSentMemory(store: CoaSentStore(dataDir: () => dir)),
      startTimer: timers.start,
      isDemo: () => false,
      send: (lot, auth) => submitCoaForLot(
          lotGuid: lot.lotGuid,
          representativePackageId: lot.packageId,
          accessToken: auth.accessToken,
          workerEmail: auth.workerEmail,
          deviceId: auth.deviceId,
          statePsilocybin: lot.statePsilocybin,
          client: client),
    );
    addTearDown(u.dispose);
    return u;
  }

  /// Runs the uploader until nothing waits or is under way.
  Future<void> drain(CoaUploader u) async {
    for (var i = 0; i < 200 && !(u.idle && timers.active.isEmpty); i++) {
      timers.fireAll();
      await pumpEventQueue();
    }
  }

  test('every guid resolved by the batch lookup: nothing is queued for upload at all', () async {
    final loaded = <Package>[];
    final resolvedCalls = <String>[];
    final queued = <CoaUploadLot>[];
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001'), _stateRow('PKPR-b', 2, 'HB-a0002')]),
      'coa-data/batch': (req) async => _json({'HB-a0001': _coaDataJson(strain: 'Golden Teacher'), 'HB-a0002': _coaDataJson(strain: 'Enigma')}),
      'GetPackagedProductInfo': (req) async => throw Exception('should never be reached - every guid was a batch hit'),
    });

    final result = await resolveAdhocInventory(
      stateId: 225, accessToken: 'T', workerEmail: 'w@example.com', deviceId: 'D-1',
      onInventoryLoaded: loaded.addAll,
      onResolved: (guid, pkg) => resolvedCalls.add(guid),
      queueUploads: (lots, {onResolved}) => queued.addAll(lots),
      client: client,
    );

    expect(loaded, hasLength(2)); // onInventoryLoaded fires with the raw, pre-enrichment inventory
    expect(result.guidsTotal, 2);
    expect(result.guidsResolved, 2);
    expect(resolvedCalls, unorderedEquals(['HB-a0001', 'HB-a0002']));
    expect(queued, isEmpty);
    final byGuid = {for (final p in result.packages) p.lotGuid: p};
    expect(byGuid['HB-a0001']!.strain, 'Golden Teacher');
    expect(byGuid['HB-a0002']!.strain, 'Enigma');
  });

  test('SM-22: the server answers with lower-cased lot ids; every lot it knows is still a hit, none queued', () async {
    // 30 lots: before SM-22 every one was a "miss" and was re-downloaded and re-uploaded
    final lots = [for (var i = 0; i < 30; i++) 'HB-${(0xaaa00 + i).toRadixString(16)}'];
    final queued = <CoaUploadLot>[];
    final client = _router({
      'GetPackagedProducts': (req) async => _json([for (var i = 0; i < lots.length; i++) _stateRow('PKPR-$i', i + 1, lots[i])]),
      'coa-data/batch': (req) async {
        final asked = (jsonDecode((req as http.Request).body) as Map)['guids'] as List;
        return _json({for (final g in asked) (g as String).toLowerCase(): _coaDataJson(strain: 'Golden Teacher')});
      },
    });

    final result = await resolveAdhocInventory(
        stateId: 225, accessToken: 'T', workerEmail: 'w@example.com', deviceId: 'D-1',
        queueUploads: (l, {onResolved}) => queued.addAll(l), client: client);

    expect(result.guidsTotal, 30);
    expect(result.guidsResolved, 30);
    expect(queued, isEmpty);
    expect(result.packages.every((p) => p.strain == 'Golden Teacher'), isTrue);
  });

  test('CU-R1: every miss is queued, with no cap of 20, keyed by one package of the lot and the state psilocybin',
      () async {
    final rows = [for (var i = 0; i < 25; i++) _stateRow('PKPR-$i', 700 + i, 'HB-b${i.toString().padLeft(4, '0')}')]
      ..add(_stateRow('PKPR-dup', 799, 'HB-b0000')); // a second package of the first lot: still one upload
    final queued = <CoaUploadLot>[];
    final client = _router({
      'GetPackagedProducts': (req) async => _json(rows),
      'coa-data/batch': (req) async => _json(<String, Object?>{}),
    });

    final result = await resolveAdhocInventory(
        stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd',
        queueUploads: (l, {onResolved}) => queued.addAll(l), client: client);

    expect(result.guidsTotal, 25);
    expect(result.guidsResolved, 0);
    expect(queued, hasLength(25));
    final first = queued.firstWhere((l) => l.lotGuid == 'HB-b0000');
    expect([first.packageId, first.stateId, first.statePsilocybin], [700, 225, 4.5]); // the package's id, never the center's
  });

  test('CU-R2: the load returns before any upload; a lot resolved later is patched in through onResolved', () async {
    final resolved = <String, Package>{};
    var parses = 0;
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 777, 'HB-a0001'), _stateRow('PKPR-b', 2, 'HB-a0002')]),
      'coa-data/batch': (req) async => _json({'HB-a0002': _coaDataJson(strain: 'Enigma')}), // a clean miss for HB-a0001
      'GetPackagedProductInfo/777': (req) async => _json(_productInfoWithPdf(42)), // the PACKAGE's id, not the center's 225
      'DownloadDocument': (req) async => http.StreamedResponse(Stream.value([0x25, 0x50, 0x44, 0x46]), 200),
      'coa-data/parse': (req) async {
        parses++;
        expect(req, isA<http.MultipartRequest>());
        final mp = req as http.MultipartRequest;
        expect(mp.fields['guid'], 'HB-a0001');
        // Snake_case, matching mazama_sales' own Form() parameter names (worker_email/device_id) exactly - see
        // coa_data_client.dart's own uploadCoaParse comment on why.
        expect(mp.fields['worker_email'], 'w@example.com');
        expect(mp.fields['device_id'], 'D-1');
        expect(mp.fields['doc_id'], '42');
        expect(mp.fields['state_psilocybin'], '4.5');
        return _json(_coaDataJson(strain: 'Blue Meanie', tpe: 2.0));
      },
    });
    final u = uploaderOver(client);

    final result = await resolveAdhocInventory(
        stateId: 225, accessToken: 'T', workerEmail: 'w@example.com', deviceId: 'D-1',
        onResolved: (guid, pkg) => resolved[guid] = pkg, queueUploads: u.enqueue, client: client);

    expect(parses, 0); // returned with the upload only queued
    expect(result.guidsResolved, 1);
    expect(u.waiting, 1);
    expect({for (final p in result.packages) p.lotGuid: p.strain}, {'HB-a0001': '', 'HB-a0002': 'Enigma'});

    await drain(u);
    expect(parses, 1);
    expect(resolved['HB-a0001']!.strain, 'Blue Meanie');
    expect(resolved['HB-a0001']!.tpeMg, 10); // weightPerUnit 5.0 * tpe 2.0 = 10, ceil -> 10
    expect(resolved['HB-a0001']!.id, 777);
  });

  test('SM-D15: a lab result with no TPE keeps the state figure\'s mg; no mg is worked out from the lab report', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001')]),
      'coa-data/batch': (req) async => _json({'HB-a0001': _coaDataJson(strain: 'Golden Teacher', tpe: null)}),
    });
    final result = await resolveAdhocInventory(
        stateId: 225, accessToken: 'T', workerEmail: 'w@example.com', deviceId: 'D-1',
        queueUploads: (l, {onResolved}) {}, client: client);
    expect(result.packages.single.strain, 'Golden Teacher');
    expect(result.packages.single.tpeMg, 23); // the state's 4.5 mg/g x 5.0 g = 22.5, rounded up, as before the lookup
  });

  test('a miss with no PDF on file at all stays degraded rather than failing the whole load', () async {
    final resolved = <String>[];
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001')]),
      'coa-data/batch': (req) async => _json(<String, Object?>{}),
      'GetPackagedProductInfo': (req) async => _json({'testResults': <Object?>[]}), // no Potency result at all
      'coa-data/parse': (req) async => throw Exception('nothing to upload without a PDF'),
    });
    final u = uploaderOver(client);

    final result = await resolveAdhocInventory(
        stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd',
        onResolved: (g, p) => resolved.add(g), queueUploads: u.enqueue, client: client);
    await drain(u);

    expect(result.guidsTotal, 1);
    expect(result.guidsResolved, 0);
    expect(result.packages.single.strain, ''); // unchanged from the raw state row's own blank strain
    expect(resolved, isEmpty);
  });

  test('one lot\'s upload failing never fails the others - each guid is independent', () async {
    final resolved = <String>[];
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001'), _stateRow('PKPR-b', 2, 'HB-a0002')]),
      'coa-data/batch': (req) async => _json(<String, Object?>{}),
      'GetPackagedProductInfo/1': (req) async => _json(_productInfoWithPdf(41)),
      'GetPackagedProductInfo/2': (req) async => _json(_productInfoWithPdf(42)),
      'DownloadDocument/41': (req) async => http.StreamedResponse(const Stream.empty(), 404), // the state refuses this one
      'DownloadDocument/42': (req) async => http.StreamedResponse(Stream.value([0x25, 0x50, 0x44, 0x46]), 200),
      'coa-data/parse': (req) async => _json(_coaDataJson(strain: 'Recovered')),
    });
    final u = uploaderOver(client);

    final result = await resolveAdhocInventory(
        stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd',
        onResolved: (g, p) => resolved.add(g), queueUploads: u.enqueue, client: client);
    await drain(u);

    expect(result.packages, hasLength(2));
    expect(resolved, ['HB-a0002']);
  });

  test('a batch-lookup failure is not fatal; nothing is queued, since which lots are missing is not known', () async {
    final queued = <CoaUploadLot>[];
    final client = _router({
      'GetPackagedProducts': (req) async => _json([_stateRow('PKPR-a', 1, 'HB-a0001')]),
      'coa-data/batch': (req) async => http.StreamedResponse(const Stream.empty(), 500),
    });

    final result = await resolveAdhocInventory(
        stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd',
        queueUploads: (l, {onResolved}) => queued.addAll(l), client: client);

    expect(result.guidsTotal, 1);
    expect(result.guidsResolved, 0);
    expect(result.packages.single.strain, '');
    expect(queued, isEmpty);
  });

  test('a fetchPackagesFromState failure surfaces as AdhocCoaError, not a raw StatePackagesError', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => http.StreamedResponse(const Stream.empty(), 401),
    });
    await expectLater(
      resolveAdhocInventory(
          stateId: 225, accessToken: 'STALE', workerEmail: 'w', deviceId: 'd', queueUploads: (l, {onResolved}) {}, client: client),
      throwsA(isA<AdhocCoaError>()),
    );
  });

  test('an inventory with no lot guids at all resolves immediately with nothing to look up', () async {
    final client = _router({
      'GetPackagedProducts': (req) async => _json([
            {'productGuid': 'PKPR-a', 'productType': 'Extract', 'id': 1, 'weightPerUnit': 5.0, 'analyteWeight': 4.5, 'quantity': 10},
          ]),
    });
    final result = await resolveAdhocInventory(
        stateId: 225, accessToken: 'T', workerEmail: 'w', deviceId: 'd', queueUploads: (l, {onResolved}) {}, client: client);
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
