// The label the phone draws when the server has none (phone_label.dart): every state call, pdfium and the shared
// reader faked, the same pattern as debug_coa_label_page_test.dart.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/coa_core_ffi.dart';
import 'package:mazama_mobile/enrichment_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/phone_label.dart';

Map<String, Object?> _record(
        {String pkpr = 'PKPR-71c5e6ad', String? lot = 'PL-de20657a', double analyteWeight = 0, int id = 6667, double weightPerUnit = 2.62}) =>
    {
      'id': id,
      'productGuid': pkpr,
      'description': 'Huautla 25 mg TPE DH (2027-08-31)',
      'weightPerUnit': weightPerUnit,
      'productType': 'Whole Fungi',
      'analyteWeight': analyteWeight,
      if (lot != null) 'processLotGuid': lot,
      'quantity': 10,
    };

Object _productInfo({List<Object?>? results}) => {
      'testResults': results ??
          [
            {
              'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '05/27/2025',
              'testingManifest': {'documents': [
                {'id': 3092, 'name': 'report.pdf', 'extension': '.pdf', 'deprecated': false},
              ]},
            },
          ],
    };

final Map<String, Object?> _section = {'uid': 'PL-de20657a', 'sample': 'Huautla'};
final Map<String, Object?> _spec = {'pkpr': 'PKPR-71c5e6ad', 'strain': 'Huautla', 'dose_mg_tpe': 25};

class _FakeCore implements CoaCore {
  final Map<String, Object?>? found;
  final Map<String, Object?> outcome;

  /// When set, the label answer for each input instead of [outcome] (as coa_core answers per record).
  final Map<String, Object?> Function(Map<String, Object?> input)? answer;
  final labelInputs = <Map<String, Object?>>[];
  final findLotCalls = <(String, double?)>[];
  _FakeCore({this.found = const {'section': 0, 'uid': 'PL-de20657a', 'via': 'own'}, Map<String, Object?>? outcome, this.answer})
      : outcome = outcome ?? {'spec': _spec, 'warnings': <Object?>[]};

  @override
  Map<String, Object?> findLot(Map<String, Object?> coaText, String lot, {double? statePsilocybin}) {
    findLotCalls.add((lot, statePsilocybin));
    return {'result': {'sections': [_section]}, 'found': found};
  }

  @override
  Map<String, Object?> labelSpec(Map<String, Object?> input) {
    labelInputs.add(input);
    return answer?.call(input) ?? outcome;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Map<String, Object?>> _draw(
  List<String> calls, {
  _FakeCore? core,
  bool noCore = false,
  List<Object?>? records,
  Object? info,
  String strain = '',
  EnrichmentStore? enrichment,
  Map<String, Object?>? labelInput,
}) =>
    drawPhoneLabelSpec(
      229,
      'pkpr-71C5E6AD',
      accessToken: 'TOKEN',
      strain: strain,
      now: () => DateTime(2026, 10, 21, 9, 30),
      loadCore: () => noCore ? null : (core ?? _FakeCore()),
      fetchRawPackages: (stateId, {required accessToken}) async {
        calls.add('inventory:$stateId:$accessToken');
        return records ?? [_record(pkpr: 'PKPR-00000001'), _record()];
      },
      fetchProductInfo: (packageId, {required accessToken}) async {
        calls.add('productInfo:$packageId');
        return info ?? _productInfo();
      },
      downloadDocument: (docId, {required accessToken}) async {
        calls.add('download:$docId');
        return Uint8List.fromList('%PDF-1.7'.codeUnits);
      },
      extractText: (pdf) async {
        calls.add('text:${pdf.length}');
        return {'pages': <Object?>[]};
      },
      enrichment: enrichment,
      labelInput: labelInput,
    );

/// /p/packages' labelInput for the package (README R64): coa_core's LabelInput as the server builds it, without today.
final Map<String, Object?> _serverInput = {
  'package': {
    'pkpr': 'PKPR-71c5e6ad', 'description': 'Huautla 25 mg TPE DH (2027-08-31)', 'weight_per_unit': 2.62,
    'product_type': 'Whole Fungi', 'analyte_weight': 9.1, 'lot': 'PL-de20657a', 'strain': 'Huautla', 'subtype': 'Dehydrated',
  },
  'section': _section,
  'settings': {'shelf_months': 18, 'fd_months': 30, 'shelf_days': null, 'fd_days': null},
  'test_date': '2025-05-27',
};

void main() {
  group("the server's label input (README R64)", () {
    test('draws the label from it with no call to the state system at all', () async {
      final calls = <String>[];
      final core = _FakeCore();
      final spec = await _draw(calls, core: core, labelInput: _serverInput);
      expect(spec, _spec);
      expect(calls, isEmpty); // no inventory read, no product info, no download
      expect(core.findLotCalls, isEmpty);
      // exactly the server's input (its own shelf-life settings, not the phone's), with the phone's today
      expect(core.labelInputs.single, {..._serverInput, 'today': '2026-10-21'});
    });

    test("a label coa_core blocks says why, still without calling the state system", () async {
      final calls = <String>[];
      final core = _FakeCore(outcome: {'blocked': ['no psilocybin result', 'no weight']});
      await expectLater(_draw(calls, core: core, labelInput: _serverInput),
          throwsA(isA<PhoneLabelError>().having((e) => e.message, 'message', 'no psilocybin result; no weight')));
      expect(calls, isEmpty);
    });

    test('a build without coa_core says so, still without calling the state system', () async {
      final calls = <String>[];
      await expectLater(_draw(calls, noCore: true, labelInput: _serverInput),
          throwsA(isA<PhoneLabelError>().having((e) => e.message, 'message', coaCoreMissingMessage)));
      expect(calls, isEmpty);
    });

    test('keeps nothing in the enrichment store: the figures are already the server\'s', () async {
      final dir = Directory.systemTemp.createTempSync('phone_label_r64_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = EnrichmentStore(dataDir: () => dir);
      await _draw([], labelInput: _serverInput, enrichment: store);
      expect(await store.load(DateTime(2026, 10, 21)), isEmpty);
    });
  });

  test("runs the whole chain and returns coa_core's spec", () async {
    final calls = <String>[];
    final core = _FakeCore();
    final spec = await _draw(calls, core: core, strain: ' Huautla ');
    expect(spec, _spec);
    expect(calls, ['inventory:229:TOKEN', 'productInfo:6667', 'download:3092', 'text:8']);
    expect(core.findLotCalls, [('PL-de20657a', null)]);
    expect(core.labelInputs.single, {
      'package': {
        'pkpr': 'PKPR-71c5e6ad', 'description': 'Huautla 25 mg TPE DH (2027-08-31)', 'weight_per_unit': 2.62,
        'product_type': 'Whole Fungi', 'analyte_weight': 0.0, 'lot': 'PL-de20657a', 'strain': 'Huautla',
      },
      'section': _section,
      'settings': phoneLabelSettings,
      'today': '2026-10-21',
      'test_date': '2025-05-27', // SM-D18: best-by counts from the state's test-completed date, as on the server
    });
  });

  test("passes the state's psilocybin to the lot finder, and no strain when the server knows none", () async {
    final core = _FakeCore();
    await _draw([], core: core, records: [_record(analyteWeight: 5.25)]);
    expect(core.findLotCalls, [('PL-de20657a', 5.25)]);
    expect((core.labelInputs.single['package'] as Map).containsKey('strain'), isFalse);
    expect((core.labelInputs.single['package'] as Map)['analyte_weight'], 5.25);
  });

  test('a build without coa_core says so without fetching anything', () async {
    final calls = <String>[];
    await expectLater(_draw(calls, noCore: true), throwsA(isA<PhoneLabelError>().having((e) => e.message, 'message', coaCoreMissingMessage)));
    expect(calls, isEmpty);
  });

  test('a package missing from the inventory, or with no lot, says so', () async {
    await expectLater(_draw([], records: [_record(pkpr: 'PKPR-00000001')]),
        throwsA(isA<PhoneLabelError>().having((e) => e.message, 'message', contains("isn't in this center's inventory"))));
    await expectLater(_draw([], records: [_record(lot: null)]),
        throwsA(isA<PhoneLabelError>().having((e) => e.message, 'message', contains('names no batch or lot'))));
  });

  test('a lot with no accepted lab report says so without downloading', () async {
    final calls = <String>[];
    await expectLater(_draw(calls, info: _productInfo(results: [])),
        throwsA(isA<PhoneLabelError>().having((e) => e.message, 'message', contains('has no accepted lab report'))));
    expect(calls.where((c) => c.startsWith('download')), isEmpty);
  });

  test("a report that doesn't name the lot says so", () async {
    await expectLater(_draw([], core: _FakeCore(found: null)),
        throwsA(isA<PhoneLabelError>().having((e) => e.message, 'message', contains("doesn't name it"))));
  });

  test("a blocked label gives every one of coa_core's reasons", () async {
    final core = _FakeCore(outcome: {'blocked': ['the package has no unit weight', 'there is no strain name'], 'warnings': <Object?>[]});
    await expectLater(_draw([], core: core),
        throwsA(isA<PhoneLabelError>().having((e) => e.message, 'message', 'the package has no unit weight; there is no strain name')));
  });

  // SM-D31: what the phone keeps from coa_core's reading, for a later read from the state system alone.
  group("keeping the phone's reading", () {
    late Directory tempDir;
    setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_phone_label_test_'));
    tearDown(() => tempDir.deleteSync(recursive: true));
    EnrichmentStore store() => EnrichmentStore(dataDir: () => tempDir);
    final readAt = DateTime(2026, 10, 21, 9, 30);

    // coa_core's answer for each record: its TPE for the record's own state figure (state + factor x psilocin, to 2
    // places; the fake just echoes a figure per state psilocybin) and the record's psilocin per unit.
    Map<String, Object?> perRecord(Map<String, Object?> input) {
      final pkg = input['package'] as Map;
      final aw = pkg['analyte_weight'] as double;
      final wpu = pkg['weight_per_unit'] as double;
      return {
        'spec': {
          ..._spec,
          'tpe_mg_per_g': aw == 5.25 ? 9.54 : 8.11,
          'per_unit_mg': {'psilocybin': wpu * aw, 'psilocin': wpu * 3.08},
          'best_by': '2027-08-31',
          'best_by_from': 'name',
        },
        'warnings': <Object?>[],
      };
    }

    test("a drawn label keeps coa_core's TPE, psilocin and the unit's mg TPE for every record of the product on the lot",
        () async {
      final es = store();
      final core = _FakeCore(answer: perRecord);
      await _draw([], core: core, enrichment: es, records: [
        _record(analyteWeight: 5.25),
        _record(analyteWeight: 4.8, id: 6668, weightPerUnit: 1.31), // the same product and lot, another record
        _record(analyteWeight: 5.25, id: 6669, lot: 'PL-0000beef'), // another lot: its report wasn't read
        _record(pkpr: 'PKPR-00000001', id: 7000), // another product
      ]);
      final known = await es.load(readAt);
      expect(known.keys.toSet(), {enrichmentKey('PKPR-71c5e6ad', 6667), enrichmentKey('PKPR-71c5e6ad', 6668)});
      final a = known[enrichmentKey('PKPR-71c5e6ad', 6667)]!;
      // 2.62 g x 9.54 mg/g = 24.99 -> 25 mg TPE per unit, rounded up as /p/packages' tpeMg (SM-D16, SM-D17)
      expect([a.source, a.tpeMgPerG, a.tpeMg, a.psilocinMg, a.weightPerUnit, a.analyteWeight, a.strain],
          [EnrichmentSource.phone, 9.54, 25, closeTo(2.62 * 3.08, 1e-9), 2.62, 5.25, 'Huautla']);
      expect(a.expires, DateTime(2027, 8, 31));
      expect(a.seenAt, readAt.toUtc());
      // the other record: coa_core asked again for its own weight and state figure; 1.31 x 8.11 = 10.62 -> 11
      final b = known[enrichmentKey('PKPR-71c5e6ad', 6668)]!;
      expect([b.tpeMgPerG, b.tpeMg, b.weightPerUnit, b.analyteWeight], [8.11, 11, 1.31, 4.8]);
      expect([for (final i in core.labelInputs) (i['package'] as Map)['analyte_weight']], [5.25, 4.8]);
    });

    test('a best-by worked out from the phone\'s own shelf life is not kept as the expiry', () async {
      final es = store();
      await _draw([], enrichment: es, records: [_record(analyteWeight: 5.25)], core: _FakeCore(answer: (input) {
        final out = perRecord(input);
        return {...out, 'spec': {...out['spec'] as Map, 'best_by_from': 'test_date'}};
      }));
      expect((await es.load(readAt)).values.single.expires, isNull);
    });

    test('nothing is kept when no label can be drawn', () async {
      final es = store();
      final blocked = _FakeCore(outcome: {'blocked': ['the linked certificate has no psilocybin/psilocin values'], 'warnings': <Object?>[]});
      await expectLater(_draw([], core: blocked, enrichment: es), throwsA(isA<PhoneLabelError>()));
      await expectLater(_draw([], core: _FakeCore(found: null), enrichment: es), throwsA(isA<PhoneLabelError>()));
      expect(await es.load(readAt), isEmpty);
    });

    test('a spec with no TPE keeps nothing, and the label is still returned', () async {
      final es = store();
      final spec = await _draw([], enrichment: es); // _spec carries no tpe_mg_per_g
      expect(spec, _spec);
      expect(await es.load(readAt), isEmpty);
    });

    test("never replaces the server's figures for the same inputs", () async {
      final es = store();
      await es.remember([
        Package(productGuid: 'PKPR-71c5e6ad', productType: 'Whole Fungi', id: 6667, weightPerUnit: 2.62, analyteWeight: 5.25,
            strain: 'Huautla', tpeMg: 26),
      ], readAt);
      await _draw([], core: _FakeCore(answer: perRecord), enrichment: es, records: [_record(analyteWeight: 5.25)]);
      final e = (await es.load(readAt)).values.single;
      expect([e.source, e.tpeMg], [EnrichmentSource.server, 26]);
    });

    test('phoneReading: the per-unit mg TPE is the weight x coa_core\'s TPE rounded up, never the label\'s dose', () {
      final r = phoneReading(_record(analyteWeight: 5.25), 6667,
          {'strain': 'Huautla', 'dose_mg_tpe': 25, 'tpe_mg_per_g': 10.0, 'per_unit_mg': {'psilocin': 1.2}}, readAt)!;
      expect([r.tpeMg, r.tpeMgPerG, r.psilocinMg], [27, 10.0, 1.2]); // 2.62 x 10.0 = 26.2 -> 27, not the name's 25
      expect(phoneReading(_record(), 6667, {'strain': 'Huautla'}, readAt), isNull); // no TPE from coa_core
      expect(phoneReading(_record(weightPerUnit: 0), 6667, {'tpe_mg_per_g': 10.0}, readAt), isNull);
    });
  });
}
