// The phone's "COA → label" debug page (plan 08 Task 8, specs/coa/08-phone-label-debug.md): every step faked
// (state calls, pdfium, the shared reader), the same pattern as the Adhoc-COA page's tests.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/debug_coa_label_page.dart';
import 'package:mazama_mobile/pdf_text.dart';
import 'package:mazama_mobile/session.dart';

Session _session() => Session(
    accessToken: 'TOKEN', refreshToken: 'REFRESH', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

/// A GetPackagedProducts record as the state sends it.
Map<String, Object?> _record({
  String pkpr = 'PKPR-71c5e6ad',
  int id = 6667,
  String description = 'Huautla 25 mg TPE DH (2027-08-31)',
  String lot = 'PL-de20657a',
  double weightPerUnit = 2.62,
  double analyteWeight = 0,
}) =>
    {
      'id': id,
      'productGuid': pkpr,
      'description': description,
      'weightPerUnit': weightPerUnit,
      'productType': 'Whole Fungi',
      'analyteWeight': analyteWeight,
      'processLotGuid': lot,
      'quantity': 10,
    };

Object _productInfo(int docId) => {
      'testResults': [
        {
          'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '05/27/2025',
          'testingManifest': {'documents': [
            {'id': docId, 'name': '2505144 PRM_LabAnalysis.pdf', 'extension': '.pdf', 'deprecated': false},
          ]},
        },
      ],
    };

final _pdfBytes = Uint8List.fromList('%PDF-1.7 test'.codeUnits);

Map<String, Object?> _page(int index, {bool text = true}) => {
      'index': index, 'width': 612.0, 'height': 792.0, 'source': text ? 'text_layer' : 'none', 'engine': 'pdfium',
      'words': [
        if (text) {'text': 'UID:', 'x0': 72.0, 'y0': 44.1, 'x1': 94.6, 'y1': 54.3, 'conf': null},
      ],
    };

Map<String, Object?> _coaText(List<Map<String, Object?>> pages) =>
    {'version': 1, 'source_sha256': '0' * 64, 'extractor': pdfTextExtractor, 'pages': pages};

/// The canonical_dated golden case's section (assets/shared/coa/corpus/labels/cases.json).
Map<String, Object?> _section({String uid = 'PL-de20657a'}) => {
      'uid': uid, 'uid_folded': false, 'page': 1, 'is_fd': false, 'sample': 'Huautla', 'unit_found': 'mg/g',
      'lab_totals': <String, Object?>{}, 'tpe': null, 'analyzed_date': '05/23/2025', 'status': 'ok', 'reasons': <Object?>[],
      'analytes': {
        'psilocybin': {'kind': 'number', 'value': 9.54},
        'psilocin': {'kind': 'nd'},
        'baeocystin': {'kind': 'number', 'value': 1.07},
        'norbaeocystin': {'kind': 'nd'},
        'norpsilocin': {'kind': 'nd'},
        'aeruginascin': {'kind': 'nd'},
      },
    };

Map<String, Object?> _parsed(List<Map<String, Object?>> sections, Map<String, int> ofRecord) => {
      'version': 1,
      'parser_version': 'mazama_core 0.1.0 / rules test',
      'source_sha256': '0' * 64,
      'report': {'lab': 'Rose City Laboratories', 'licensee': 'Uptown Fungus', 'reported_date': '2025-05-27'},
      'sections': sections,
      'of_record': ofRecord,
    };

/// The canonical_dated golden case's outcome (assets/shared/coa/corpus/labels/expected.json).
final Map<String, Object?> _canonicalOutcome = {
  'spec': {
    'spec_version': 2, 'pkpr': 'PKPR-71c5e6ad', 'strain': 'Huautla', 'dose_mg_tpe': 25, 'net_wt_g': 2.62,
    'tpe_mg_per_g': 9.54,
    'per_unit_mg': {'psilocybin': 24.9948, 'psilocin': 0.0, 'baeocystin': 2.8034, 'norbaeocystin': 0.0, 'norpsilocin': 0.0, 'aeruginascin': 0.0},
    'psilocybin_from': 'coa', 'best_by': '2027-08-31', 'best_by_from': 'name', 'type_code': 'DH',
    'source': 'PL-de20657a', 'description': 'Huautla 25 mg TPE DH (2027-08-31)',
  },
  'warnings': <Object?>[],
};

/// Stands in for the shared reader, so the page's tests need neither the library nor its answers.
class _FakeCore implements CoreFunctions {
  final Map<String, Object?> parsed;
  final Map<String, Object?> outcome;

  /// What findLot answers; by default the lot's own of_record section (via "own"), else null.
  final Map<String, Object?>? found;
  final bool fixedFound;
  final labelInputs = <Map<String, Object?>>[];
  final findLotCalls = <(String, double?)>[];
  _FakeCore({Map<String, Object?>? parsed, Map<String, Object?>? outcome, Map<String, Object?>? found, this.fixedFound = false})
      : parsed = parsed ?? _parsed([_section()], {'pl-de20657a': 0}),
        outcome = outcome ?? _canonicalOutcome,
        found = found;

  @override
  Map<String, Object?> coaParse(Map<String, Object?> coaText) => parsed;

  @override
  Map<String, Object?> coaFindLot(Map<String, Object?> input) {
    final lot = input['lot'] as String;
    findLotCalls.add((lot, (input['state_psilocybin'] as num?)?.toDouble()));
    Map<String, Object?>? hit = found;
    if (!fixedFound) {
      final at = (parsed['of_record'] as Map)[lot.toLowerCase()];
      final sections = parsed['sections'] as List;
      hit = at is int ? {'section': at, 'uid': (sections[at] as Map)['uid'], 'via': 'own'} : null;
    }
    return {'result': parsed, 'found': hit};
  }

  @override
  Map<String, Object?> labelSpec(Map<String, Object?> input) {
    labelInputs.add(input);
    return outcome;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  final calls = <String>[];
  String? copied;
  Uint8List? shared;
  String? sharedName;
}

Widget _pageWidget(
  _Harness h, {
  List<Map<String, Object?>>? records,
  Object? productInfo,
  Uint8List? pdf,
  Map<String, Object?>? coaText,
  CoreFunctions? core,
}) =>
    MaterialApp(
      home: DebugCoaLabelPage(
        session: _session(),
        initialStateId: 229,
        now: () => DateTime(2026, 10, 21, 9, 30),
        fetchRawPackages: (stateId, {required accessToken}) async {
          h.calls.add('inventory:$stateId:$accessToken');
          return records ?? [_record()];
        },
        fetchProductInfo: (packageId, {required accessToken}) async {
          h.calls.add('productInfo:$packageId');
          return productInfo ?? _productInfo(3092);
        },
        downloadDocument: (docId, {required accessToken}) async {
          h.calls.add('download:$docId');
          return pdf ?? _pdfBytes;
        },
        extractText: (bytes) async {
          h.calls.add('text:${bytes.length}');
          return coaText ?? _coaText([_page(0), _page(1)]);
        },
        core: core ?? _FakeCore(),
        sharePdf: (bytes, name) async {
          h.shared = bytes;
          h.sharedName = name;
        },
        copyText: (text) async => h.copied = text,
      ),
    );

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _testPkpr(WidgetTester tester, String pkpr) async {
  await tester.enterText(find.widgetWithText(TextField, 'PKPR to test'), pkpr);
  await _tap(tester, 'Test this PKPR');
}

void main() {
  testWidgets('runs every step and draws the preview', (tester) async {
    final h = _Harness();
    final core = _FakeCore();
    await tester.pumpWidget(_pageWidget(h, core: core));

    expect((tester.widget(find.widgetWithText(TextField, 'Service center state id')) as TextField).controller!.text, '229');
    await _testPkpr(tester, 'PKPR-71c5e6ad');

    expect(h.calls, ['inventory:229:TOKEN', 'productInfo:6667', 'download:3092', 'text:${_pdfBytes.length}']);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(7));
    expect(find.byIcon(Icons.error), findsNothing);
    expect(find.text('Lot: 71c5e6ad'), findsOneWidget);
    expect(find.text('25 mg Equiv'), findsOneWidget);

    // what the shared reader was asked: the package as the state sent it, the lot's section, the page's settings
    final input = core.labelInputs.single;
    expect(input['package'], {
      'pkpr': 'PKPR-71c5e6ad', 'description': 'Huautla 25 mg TPE DH (2027-08-31)', 'weight_per_unit': 2.62,
      'product_type': 'Whole Fungi', 'analyte_weight': 0.0, 'lot': 'PL-de20657a',
    });
    expect(input['section'], _section());
    expect(input['settings'], {'shelf_months': 12, 'fd_months': 24, 'shelf_days': null, 'fd_days': null});
    expect(input['today'], '2026-10-21');

    // each step says what it saw
    expect(find.textContaining('document 3092, completed 05/27/2025'), findsOneWidget);
    expect(find.textContaining('${_pdfBytes.length} bytes'), findsOneWidget);
    expect(find.textContaining('2 page(s)'), findsOneWidget);
    expect(find.textContaining('Rose City Laboratories'), findsOneWidget);
    expect(find.textContaining('PL-de20657a is of record: section 1'), findsOneWidget);
    expect(find.textContaining('best-by 2027-08-31 (from the name)'), findsOneWidget);
  });

  testWidgets('an upper-case lot finds its lower-case of_record entry', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_pageWidget(h, records: [_record(lot: 'PL-DE20657A')]));
    await _testPkpr(tester, 'PKPR-71c5e6ad');
    expect(find.byIcon(Icons.check_circle), findsNWidgets(7));
  });

  testWidgets("a lot that isn't in the report names the UIDs that are", (tester) async {
    final h = _Harness();
    final core = _FakeCore(parsed: _parsed([_section(uid: 'HB-11112222'), _section(uid: 'HB-33334444')], {'hb-11112222': 0, 'hb-33334444': 1}));
    await tester.pumpWidget(_pageWidget(h, records: [_record(lot: 'PL-DE20657A')], core: core));
    await _testPkpr(tester, 'PKPR-71c5e6ad');

    expect(find.byIcon(Icons.check_circle), findsNWidgets(4));
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.textContaining('PL-DE20657A is not in this report; it has: HB-11112222, HB-33334444'), findsOneWidget);
    expect(core.labelInputs, isEmpty);
    expect(find.text('PREVIEW, not a printable label'), findsNothing);
  });

  testWidgets("a process lot reported under its parent batch's UID is found by the report's request (AD-19)", (tester) async {
    final h = _Harness();
    final core = _FakeCore(
      parsed: _parsed([_section(uid: 'HB-597a95ef')], {'hb-597a95ef': 0}),
      found: {'section': 0, 'uid': 'HB-597a95ef', 'via': 'request'},
      fixedFound: true,
    );
    await tester.pumpWidget(_pageWidget(h, core: core));
    await _testPkpr(tester, 'PKPR-71c5e6ad');

    expect(find.byIcon(Icons.check_circle), findsNWidgets(7));
    expect(find.textContaining("PL-de20657a is reported as HB-597a95ef (found by the report's request / chain of custody): section 1"),
        findsOneWidget);
    expect(core.findLotCalls, [('PL-de20657a', null)]); // analyteWeight 0: no state figure
    final input = core.labelInputs.single;
    expect((input['section'] as Map)['uid'], 'HB-597a95ef');
    expect((input['package'] as Map)['lot'], 'PL-de20657a'); // the label still names the package's own lot
    expect(find.text('Lot: 71c5e6ad'), findsOneWidget);
  });

  testWidgets("the state's psilocybin goes to findLot when the package has one", (tester) async {
    final h = _Harness();
    final core = _FakeCore();
    await tester.pumpWidget(_pageWidget(h, records: [_record(analyteWeight: 5.25)], core: core));
    await _testPkpr(tester, 'PKPR-71c5e6ad');
    expect(core.findLotCalls, [('PL-de20657a', 5.25)]);
    expect(find.textContaining('PL-de20657a is of record: section 1'), findsOneWidget);
  });

  testWidgets('no text layer pages are listed and parsing still runs', (tester) async {
    final h = _Harness();
    final core = _FakeCore(parsed: _parsed([], {}));
    await tester.pumpWidget(_pageWidget(h, coaText: _coaText([_page(0), _page(1, text: false), _page(2, text: false)]), core: core));
    await _testPkpr(tester, 'PKPR-71c5e6ad');

    expect(find.textContaining('no text layer: pages 2, 3'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(4)); // the text step passes: a page without text is reported, not read
    expect(find.textContaining('PL-de20657a is not in this report; it has: no UID lines'), findsOneWidget);
  });

  testWidgets('blocked spec lists every reason', (tester) async {
    final h = _Harness();
    final core = _FakeCore(outcome: {
      'blocked': ['the package has no unit weight', 'there is no strain name'],
      'warnings': ['no certificate date: best-by counted from today'],
    });
    await tester.pumpWidget(_pageWidget(h, core: core));
    await _testPkpr(tester, 'PKPR-71c5e6ad');

    expect(find.byIcon(Icons.check_circle), findsNWidgets(5));
    expect(find.textContaining('the package has no unit weight'), findsOneWidget);
    expect(find.textContaining('there is no strain name'), findsOneWidget);
    expect(find.textContaining('no certificate date: best-by counted from today'), findsOneWidget);
    expect(find.text('PREVIEW, not a printable label'), findsNothing);
  });

  testWidgets('a download that is not a PDF stops at step 3', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_pageWidget(h, pdf: Uint8List.fromList('<html>sign in</html>'.codeUnits)));
    await _testPkpr(tester, 'PKPR-71c5e6ad');

    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.textContaining('not a PDF'), findsOneWidget);
    expect(h.calls.where((c) => c.startsWith('text:')), isEmpty);
  });

  testWidgets('copy results puts every step on the clipboard', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_pageWidget(h));
    await _testPkpr(tester, 'PKPR-71c5e6ad');
    await _tap(tester, 'Copy results');

    final text = h.copied!;
    for (final title in ['1. Inventory', '2. Lab report', '3. Download', '4. Text', '5. Parse', '6. Label spec', '7. Preview']) {
      expect(text, contains(title));
    }
    expect(text, contains('PKPR-71c5e6ad'));
    expect(text, contains('document 3092'));
    expect(text, contains('2027-08-31'));
    expect('✓'.allMatches(text).length, 7);
  });

  testWidgets('picking a package from the list tests that package', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_pageWidget(h, records: [
      _record(),
      _record(pkpr: 'PKPR-0a0b0c0d', id: 7001, description: 'Shakti 3 mg TPE DH', lot: 'PL-7c737a92'),
    ]));
    await _tap(tester, 'Load packages');
    expect(find.textContaining('2 package(s)'), findsOneWidget);
    expect(h.calls, ['inventory:229:TOKEN']);

    await _tap(tester, 'PKPR-0a0b0c0d');
    expect(h.calls, ['inventory:229:TOKEN', 'productInfo:7001', 'download:3092', 'text:${_pdfBytes.length}']);
    expect(find.textContaining('Shakti 3 mg TPE DH'), findsWidgets);
  });

  testWidgets('a typed PKPR tests that package', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_pageWidget(h, records: [
      _record(pkpr: 'PKPR-0a0b0c0d', id: 7001),
      _record(),
    ]));
    await _testPkpr(tester, '71C5E6AD'); // without the prefix, other case
    expect(h.calls, contains('productInfo:6667'));

    h.calls.clear();
    await _testPkpr(tester, 'PKPR-ffff0000');
    expect(find.textContaining("PKPR-ffff0000 is not in this center's inventory (2 package(s))"), findsOneWidget);
    expect(h.calls, ['inventory:229:TOKEN']);
  });

  testWidgets('share sends the downloaded PDF', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_pageWidget(h));
    expect(find.text('Share the lab report PDF'), findsNothing);
    await _testPkpr(tester, 'PKPR-71c5e6ad');
    await _tap(tester, 'Share the lab report PDF');

    expect(h.shared, _pdfBytes);
    expect(h.sharedName, 'PL-de20657a_document_3092.pdf');
  });
}
