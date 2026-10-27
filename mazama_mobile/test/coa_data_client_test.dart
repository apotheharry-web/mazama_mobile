import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/coa_data_client.dart';

void main() {
  group('centerIsConfigured', () {
    test('true/false pass straight through from the {"configured": ...} body', () async {
      final client = http_testing.MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/p/center-status/225');
        return http.Response(jsonEncode({'configured': true}), 200);
      });
      expect(await centerIsConfigured(225, client: client), isTrue);

      final client2 = http_testing.MockClient((req) async => http.Response(jsonEncode({'configured': false}), 200));
      expect(await centerIsConfigured(225, client: client2), isFalse);
    });

    test('a non-200 is reported as CoaDataError with the status code', () async {
      final client = http_testing.MockClient((req) async => http.Response('', 500));
      await expectLater(
        centerIsConfigured(225, client: client),
        throwsA(isA<CoaDataError>().having((e) => e.message, 'message', contains('500'))),
      );
    });

    test('a non-JSON body is reported clearly', () async {
      final client = http_testing.MockClient((req) async => http.Response('<html>nope</html>', 200));
      await expectLater(centerIsConfigured(225, client: client), throwsA(isA<CoaDataError>()));
    });

    test('an unexpected response shape (missing/non-bool "configured") is reported clearly', () async {
      final client = http_testing.MockClient((req) async => http.Response(jsonEncode({'nope': true}), 200));
      await expectLater(centerIsConfigured(225, client: client), throwsA(isA<CoaDataError>()));
    });

    test('a network failure is reported with the host name', () async {
      final client = http_testing.MockClient((req) async => throw Exception('boom'));
      await expectLater(
        centerIsConfigured(225, client: client),
        throwsA(isA<CoaDataError>().having((e) => e.message, 'message', contains('sales.mazamamushrooms.com'))),
      );
    });
  });

  group('fetchCoaDataBatch', () {
    test('an empty guid list never makes a request at all', () async {
      var called = false;
      final client = http_testing.MockClient((req) async {
        called = true;
        return http.Response('{}', 200);
      });
      final result = await fetchCoaDataBatch([], client: client);
      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('posts the guid list as JSON and parses every returned entry into a CoaData', () async {
      final client = http_testing.MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/p/coa-data/batch');
        expect(jsonDecode(req.body), {'guids': ['G-1', 'G-2']});
        return http.Response(
          jsonEncode({
            'G-1': {
              'strain': 'Golden Teacher', 'psilocybin': 1.0, 'psilocin': 0.5, 'baeocystin': 0.1,
              'norbaeocystin': 0.05, 'norpsilocin': 0.02, 'aeruginascin': 0.03, 'tpe': 1.75,
            },
          }),
          200,
        );
      });
      final result = await fetchCoaDataBatch(['G-1', 'G-2'], client: client);
      expect(result.keys, ['G-1']); // G-2 is a miss - simply absent, not an error
      expect(result['G-1']!.strain, 'Golden Teacher');
      expect(result['G-1']!.tpe, 1.75);
      // SM-08: the rules file's analyte names
      expect(result['G-1']!.baeocystin, 0.1);
      expect(result['G-1']!.norbaeocystin, 0.05);
      expect(result['G-1']!.aeruginascin, 0.03);
    });

    test('SM-08: an aeruginascin the server didn\'t send is unknown, not 0', () async {
      final client = http_testing.MockClient((req) async => http.Response(jsonEncode({
            'G-1': {'strain': 'GT', 'psilocybin': 1.0, 'psilocin': 0.5, 'aeruginascin': null},
          }), 200));
      expect((await fetchCoaDataBatch(['G-1'], client: client))['G-1']!.aeruginascin, isNull);
    });

    test('SM-22: keys come back as the guid the app asked for, whatever case the server answers in', () async {
      final client = http_testing.MockClient((req) async => http.Response(jsonEncode({
            'hb-9c564cf': {'strain': 'Huaulta', 'psilocybin': 9.54, 'psilocin': 0.0},
            'pl-de20657a': {'strain': 'Tat', 'psilocybin': 5.25, 'psilocin': 0.658},
          }), 200));
      final got = await fetchCoaDataBatch(['HB-9c564cf', 'PL-de20657a'], client: client);
      expect(got.keys, unorderedEquals(['HB-9c564cf', 'PL-de20657a']));
      expect(got['HB-9c564cf']!.guid, 'HB-9c564cf');
      expect(got['PL-de20657a']!.strain, 'Tat');
    });

    test('a non-200 is reported as CoaDataError', () async {
      final client = http_testing.MockClient((req) async => http.Response('', 500));
      await expectLater(fetchCoaDataBatch(['G-1'], client: client), throwsA(isA<CoaDataError>()));
    });
  });

  group('CoaData.tpe (SM-03, SM-D15: the server works TPE out; null is unknown)', () {
    CoaData parse(Map<String, Object?> j) => CoaData.fromJson('PL-de20657a', j);

    test("is the server's TPE when it sent one", () {
      expect(parse({'strain': 'Tat', 'psilocybin': 13.1, 'psilocin': 0.497, 'tpe': 6.16}).tpe, 6.16);
    });

    test('is unknown when the server sent none, even with psilocybin and psilocin known: no formula on the phone', () {
      expect(parse({'strain': 'Tat', 'psilocybin': 13.1, 'psilocin': 0.497, 'tpe': null}).tpe, isNull);
    });

    test('a missing psilocybin or psilocin is unknown, not 0', () {
      final d = parse({'strain': 'Tat', 'psilocybin': null, 'tpe': null});
      expect(d.psilocybin, isNull);
      expect(d.psilocin, isNull);
      expect(parse({'strain': 'Tat', 'psilocybin': 0, 'psilocin': 0, 'tpe': 0}).psilocin, 0); // ND stays 0
    });
  });

  group('uploadCoaParse', () {
    test('sends a multipart POST with the guid/worker_email/device_id fields (snake_case, matching the server\'s '
        'own Form() parameter names exactly) and the PDF bytes, parses the result', () async {
      final pdfBytes = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]); // %PDF
      final client = http_testing.MockClient.streaming((req, bodyStream) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/p/coa-data/parse');
        expect(req, isA<http.MultipartRequest>());
        final mp = req as http.MultipartRequest;
        expect(mp.fields['guid'], 'G-1');
        expect(mp.fields['worker_email'], 'worker@example.com');
        expect(mp.fields['device_id'], 'DEVICE-1');
        expect(mp.fields['doc_id'], '42');
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({
            'strain': 'Enigma', 'psilocybin': 2.0, 'psilocin': 1.0, 'baeocystin': 0, 'norbaeocystin': 0, 'norpsilocin': 0,
          }))),
          200,
        );
      });
      final result = await uploadCoaParse(
        guid: 'G-1', pdfBytes: pdfBytes, docId: 42, workerEmail: 'worker@example.com', deviceId: 'DEVICE-1', client: client);
      expect(result.strain, 'Enigma');
      expect(result.guid, 'G-1');
    });

    test('sends the state psilocybin figure when there is one, so the server can match a report printed under '
        'another id', () async {
      final sent = <String?>[];
      final client = http_testing.MockClient.streaming((req, bodyStream) async {
        sent.add((req as http.MultipartRequest).fields['state_psilocybin']);
        return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'strain': 'Tat', 'psilocybin': 5.25, 'psilocin': 0.658}))), 200);
      });
      final pdf = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]);
      await uploadCoaParse(guid: 'PL-de20657a', pdfBytes: pdf, workerEmail: 'w', deviceId: 'd', statePsilocybin: 5.25, client: client);
      await uploadCoaParse(guid: 'PL-de20657a', pdfBytes: pdf, workerEmail: 'w', deviceId: 'd', statePsilocybin: 0, client: client);
      await uploadCoaParse(guid: 'PL-de20657a', pdfBytes: pdf, workerEmail: 'w', deviceId: 'd', client: client);
      expect(sent, ['5.25', null, null]);
    });

    test('a non-200 surfaces the server\'s own "detail" message rather than a generic one', () async {
      final client = http_testing.MockClient.streaming((req, bodyStream) async => http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({'detail': "this guid's own test result isn't in the PDF"}))),
            422,
          ));
      await expectLater(
        uploadCoaParse(guid: 'G-1', pdfBytes: Uint8List(0), workerEmail: 'w', deviceId: 'd', client: client),
        throwsA(isA<CoaDataError>().having((e) => e.message, 'message', contains("isn't in the PDF"))),
      );
    });

    test('a non-200 with no parseable "detail" falls back to the generic status-code message', () async {
      final client = http_testing.MockClient.streaming((req, bodyStream) async => http.StreamedResponse(Stream.value(utf8.encode('')), 503));
      await expectLater(
        uploadCoaParse(guid: 'G-1', pdfBytes: Uint8List(0), workerEmail: 'w', deviceId: 'd', client: client),
        throwsA(isA<CoaDataError>().having((e) => e.message, 'message', contains('503'))),
      );
    });
  });

  group('CoaDataSessionCache', () {
    test('put/get/has/putAll round-trip by guid, no staleness concept', () {
      final cache = CoaDataSessionCache();
      expect(cache.has('G-1'), isFalse);
      final data = CoaData(guid: 'G-1', strain: 'X', psilocybin: 1, psilocin: 1, baeocystin: 0, norbaeocystin: 0, norpsilocin: 0);
      cache.put(data);
      expect(cache.has('G-1'), isTrue);
      expect(cache.get('G-1'), same(data));
      cache.putAll({'G-2': data});
      expect(cache.has('G-2'), isTrue);
    });
  });
}
