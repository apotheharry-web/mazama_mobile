// configured_coa_submit.dart: a configured center's cart-add COA submission (GetPackagedProductInfo -> newest
// accepted Potency PDF -> DownloadDocument -> /p/coa-data/parse). Had no test of its own until SM-22, which found
// it didn't send state_psilocybin while the adhoc path (coa_data_resolver.dart) did.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/configured_coa_submit.dart';

Map<String, Object?> _info(int docId) => {
      'testResults': [
        {
          'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '01/02/2026',
          'testingManifest': {
            'documents': [
              {'id': docId, 'extension': '.pdf', 'deprecated': false},
            ],
          },
        },
      ],
    };

const _coa = {'strain': 'Golden Teacher', 'psilocybin': 10.4, 'psilocin': 0.6, 'baeocystin': 0, 'norbaeocystin': 0,
    'norpsilocin': 0, 'tpe': 11.2, 'guid': 'hb-9bc7d118', 'sample_date': null, 'doc_id': 42};

void main() {
  // fetchStateFlow loads assets/flows/state_reads.yaml through rootBundle, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  (http.Client, List<http.BaseRequest>) router({Object? info}) {
    final seen = <http.BaseRequest>[];
    final client = http_testing.MockClient.streaming((req, body) async {
      await body.drain<void>();
      seen.add(req);
      final p = req.url.path;
      Object? reply;
      if (p.endsWith('/GetPackagedProductInfo/777')) {
        reply = info ?? _info(42);
      } else if (p.endsWith('/DownloadDocument/42')) {
        return http.StreamedResponse(Stream.value(utf8.encode('%PDF-1.4 report')), 200);
      } else if (p == '/p/coa-data/parse') {
        reply = _coa;
      } else {
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404);
      }
      return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(reply))), 200);
    });
    return (client, seen);
  }

  test("uploads the lot's newest report with the state's psilocybin figure, from the representative package", () async {
    final (client, seen) = router();
    final data = await submitCoaForLot(
      lotGuid: 'HB-9bc7d118',
      representativePackageId: 777,
      statePsilocybin: 10.4,
      accessToken: 'TEST-TOKEN',
      workerEmail: 'worker@example.com',
      deviceId: 'D-1',
      client: client,
    );
    expect(data!.strain, 'Golden Teacher');
    final parse = seen.whereType<http.MultipartRequest>().single;
    expect(parse.fields, {
      'guid': 'HB-9bc7d118',
      'doc_id': '42',
      'worker_email': 'worker@example.com',
      'device_id': 'D-1',
      'state_psilocybin': '10.4',
    });
  });

  test('without a state psilocybin figure the field is left out, as on the adhoc path', () async {
    final (client, seen) = router();
    await submitCoaForLot(
        lotGuid: 'HB-9bc7d118', representativePackageId: 777, accessToken: 'TEST-TOKEN', workerEmail: 'w', deviceId: 'D-1', client: client);
    expect(seen.whereType<http.MultipartRequest>().single.fields.containsKey('state_psilocybin'), isFalse);
  });

  test('no accepted Potency PDF on file: nothing is uploaded and the answer is null', () async {
    final (client, seen) = router(info: {'testResults': <Object?>[]});
    final data = await submitCoaForLot(
        lotGuid: 'HB-9bc7d118', representativePackageId: 777, accessToken: 'TEST-TOKEN', workerEmail: 'w', deviceId: 'D-1', client: client);
    expect(data, isNull);
    expect(seen.whereType<http.MultipartRequest>(), isEmpty);
  });
}
