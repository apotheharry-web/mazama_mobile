import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/debug_adhoc_coa_diagnostics_page.dart';
import 'package:mazama_mobile/device_id.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/session.dart';

Session _session() => Session(
    accessToken: 'TOKEN', refreshToken: 'REFRESH', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

/// GetPackagedProductInfo's own shape, mirroring coa_data_resolver_test.dart's own fixture - one accepted
/// Potency test result with a single non-deprecated PDF document.
Object _productInfoWithPdf(int docId) => {
      'testResults': [
        {
          'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '01/02/2026',
          'testingManifest': {'documents': [
            {'id': docId, 'extension': '.pdf', 'deprecated': false},
          ]},
        },
      ],
    };

Widget _page({
  int? initialStateId,
  Future<List<Package>> Function(int, {required String accessToken})? fetchPackagesFromState,
  Future<Object?> Function(int, {required String accessToken})? fetchProductInfo,
  Future<Uint8List> Function(int, {required String accessToken})? downloadDocument,
  Future<CoaData> Function({required String guid, required Uint8List pdfBytes, int? docId, required String workerEmail, required String deviceId, double? statePsilocybin})?
      uploadCoaParse,
  DeviceIdStore? deviceIdStore,
  Future<void> Function(Uint8List bytes, String fileName)? sharePdf,
}) =>
    MaterialApp(
      home: DebugAdhocCoaDiagnosticsPage(
        session: _session(),
        initialStateId: initialStateId,
        fetchPackagesFromState: fetchPackagesFromState ?? (stateId, {required accessToken}) async => throw Exception('no fixture'),
        fetchProductInfo: fetchProductInfo ?? (packageId, {required accessToken}) async => throw Exception('no fixture'),
        downloadDocument: downloadDocument ?? (docId, {required accessToken}) async => throw Exception('no fixture'),
        uploadCoaParse: uploadCoaParse ??
            ({required guid, required pdfBytes, docId, required workerEmail, required deviceId, statePsilocybin}) async => throw Exception('no fixture'),
        deviceIdStore: deviceIdStore ?? DeviceIdStore(dataDir: () => Directory.systemTemp.createTempSync()),
        sharePdf: sharePdf ?? (bytes, fileName) async => throw Exception('no fixture'),
      ),
    );

void main() {
  testWidgets('the state-id field is pre-filled from initialStateId and the button runs every step in order on success', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchPackagesFromState: (stateId, {required accessToken}) async {
        calls.add('inventory:$stateId:$accessToken');
        return [
          // A package id (999) deliberately different from the center's own state id (225) below, so this
          // test actually catches a regression back to the bug where fetchProductInfo was called with the
          // CENTER's id instead of this package's own one (see coa_data_resolver.dart's own comment on it).
          Package(productGuid: 'PKPR-a', productType: 'Extract', id: 999, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 10, lotGuid: 'G-1'),
        ];
      },
      fetchProductInfo: (packageId, {required accessToken}) async {
        calls.add('productInfo:$packageId');
        return _productInfoWithPdf(42);
      },
      downloadDocument: (docId, {required accessToken}) async {
        calls.add('download:$docId');
        return Uint8List.fromList([0x25, 0x50, 0x44, 0x46]);
      },
      uploadCoaParse: ({required guid, required pdfBytes, docId, required workerEmail, required deviceId, statePsilocybin}) async {
        calls.add('upload:$guid:$docId:$workerEmail');
        return CoaData(guid: guid, strain: 'Golden Teacher', psilocybin: 1.0, psilocin: 0.5, baeocystin: 0, norbaeocystin: 0, norpsilocin: 0, tpe: 1.75);
      },
    ));

    expect(find.widgetWithText(TextField, 'Service center state id'), findsOneWidget);
    expect((tester.widget(find.byType(TextField)) as TextField).controller!.text, '225');

    await tester.tap(find.text('Run diagnostic'));
    await tester.pumpAndSettle();

    expect(calls, [
      'inventory:225:TOKEN',
      'productInfo:999', // the package's own id, not the center's 225
      'download:42',
      'upload:G-1:42:worker@example.com',
    ]);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(4));
    expect(find.byIcon(Icons.error), findsNothing);
    expect(find.textContaining('Golden Teacher'), findsOneWidget);
  });

  testWidgets('a lot with no PDF on file stops at step 2 and never reaches download/upload', (tester) async {
    var downloadCalled = false;
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchPackagesFromState: (stateId, {required accessToken}) async => [
        Package(productGuid: 'PKPR-a', productType: 'Extract', id: 1, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 10, lotGuid: 'G-1'),
      ],
      fetchProductInfo: (packageId, {required accessToken}) async => {'testResults': <Object?>[]},
      downloadDocument: (docId, {required accessToken}) async {
        downloadCalled = true;
        return Uint8List(0);
      },
    ));

    await tester.tap(find.text('Run diagnostic'));
    await tester.pumpAndSettle();

    expect(downloadCalled, isFalse);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(1)); // only step 1 (pull inventory) succeeded
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.textContaining('no accepted, non-deprecated Potency-test PDF'), findsOneWidget);
  });

  testWidgets('an inventory with no lot guids at all fails step 1 immediately', (tester) async {
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchPackagesFromState: (stateId, {required accessToken}) async => [
        Package(productGuid: 'PKPR-a', productType: 'Extract', id: 1, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 10),
      ],
    ));

    await tester.tap(find.text('Run diagnostic'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.textContaining('none carry a lotGuid'), findsOneWidget);
  });

  testWidgets('a non-numeric state id refuses to run rather than crashing', (tester) async {
    await tester.pumpWidget(_page());
    await tester.enterText(find.byType(TextField), 'not-a-number');
    await tester.tap(find.text('Run diagnostic'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Enter a numeric state id'), findsOneWidget);
  });

  testWidgets('after a failed upload the downloaded PDF can be shared', (tester) async {
    Uint8List? shared;
    String? sharedName;
    await tester.pumpWidget(_page(
      initialStateId: 229,
      fetchPackagesFromState: (stateId, {required accessToken}) async => [
        Package(productGuid: 'PKPR-71c5e6ad', productType: 'Extract', id: 6667, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 10, lotGuid: 'PL-de20657a'),
      ],
      fetchProductInfo: (packageId, {required accessToken}) async => _productInfoWithPdf(3092),
      downloadDocument: (docId, {required accessToken}) async => Uint8List.fromList([37, 80, 68, 70]),
      uploadCoaParse: ({required guid, required pdfBytes, docId, required workerEmail, required deviceId, statePsilocybin}) async =>
          throw Exception("could not find this id's own test result in the document"),
      sharePdf: (bytes, fileName) async {
        shared = bytes;
        sharedName = fileName;
      },
    ));

    expect(find.text('Share the lab report PDF'), findsNothing);
    await tester.tap(find.text('Run diagnostic'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.error), findsOneWidget);
    await tester.ensureVisible(find.text('Share the lab report PDF'));
    await tester.tap(find.text('Share the lab report PDF'));
    await tester.pumpAndSettle();
    expect(shared, [37, 80, 68, 70]);
    expect(sharedName, 'PL-de20657a_document_3092.pdf');
  });

  testWidgets("the upload carries the package's state psilocybin figure", (tester) async {
    double? sent;
    await tester.pumpWidget(_page(
      initialStateId: 229,
      fetchPackagesFromState: (stateId, {required accessToken}) async => [
        Package(productGuid: 'PKPR-71c5e6ad', productType: 'Extract', id: 6667, weightPerUnit: 5.0, analyteWeight: 5.25, quantity: 10, lotGuid: 'PL-de20657a'),
      ],
      fetchProductInfo: (packageId, {required accessToken}) async => _productInfoWithPdf(3092),
      downloadDocument: (docId, {required accessToken}) async => Uint8List.fromList([37, 80, 68, 70]),
      uploadCoaParse: ({required guid, required pdfBytes, docId, required workerEmail, required deviceId, statePsilocybin}) async {
        sent = statePsilocybin;
        throw Exception('stop here');
      },
    ));
    await tester.tap(find.text('Run diagnostic'));
    await tester.pumpAndSettle();
    expect(sent, 5.25);
  });

  testWidgets('lists every test result and document the state returned, and which one was picked', (tester) async {
    final info = {
      'testResults': [
        {
          'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '07/23/2026', 'productId': 'HB-597a95ef',
          'labTestBatchNumber': '2607166',
          'testingManifest': {'documents': [
            {'id': 3092, 'name': '2607166_1 PRM_LabAnalysis.pdf', 'extension': '.pdf', 'deprecated': false},
            {'id': 3093, 'name': 'CoC.pdf', 'extension': '.pdf', 'deprecated': true},
          ]},
        },
        {
          'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '06/01/2026', 'productId': 'PL-de20657a',
          'testingManifest': {'documents': [
            {'id': 2900, 'name': 'older.pdf', 'extension': '.pdf', 'deprecated': false},
          ]},
        },
        {
          'test': 'Microbial', 'status': 'Accepted', 'dateCompleted': '07/23/2026',
          'testingManifest': {'documents': [{'id': 2800, 'name': 'micro.pdf', 'extension': '.pdf'}]},
        },
      ],
    };
    String? sharedName;
    List<int>? shared;
    await tester.pumpWidget(_page(
      initialStateId: 229,
      fetchPackagesFromState: (stateId, {required accessToken}) async => [
        Package(productGuid: 'PKPR-71c5e6ad', productType: 'Extract', id: 6667, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 10, lotGuid: 'PL-de20657a'),
      ],
      fetchProductInfo: (packageId, {required accessToken}) async => info,
      downloadDocument: (docId, {required accessToken}) async => Uint8List.fromList([37, 80, 68, 70]),
      uploadCoaParse: ({required guid, required pdfBytes, docId, required workerEmail, required deviceId, statePsilocybin}) async =>
          throw Exception('not found'),
      sharePdf: (bytes, fileName) async {
        shared = bytes;
        sharedName = fileName;
      },
    ));
    await tester.tap(find.text('Run diagnostic'));
    await tester.pumpAndSettle();

    final detail = find.textContaining('3 test result(s)');
    expect(detail, findsOneWidget);
    final text = (tester.widget(detail) as Text).data!;
    expect(text, contains('Newest accepted Potency-test PDF is document 3092'));
    expect(text, contains('Potency / Accepted / completed 07/23/2026'));
    expect(text, contains('productId: HB-597a95ef'));
    expect(text, contains('labTestBatchNumber: 2607166'));
    expect(text, contains("doc 3092 '2607166_1 PRM_LabAnalysis.pdf' <- picked"));
    expect(text, contains("doc 3093 'CoC.pdf' (deprecated)"));
    expect(text, contains('productId: PL-de20657a'));
    expect(text, contains("doc 2900 'older.pdf'"));
    expect(text, contains('Microbial / Accepted'));

    await tester.ensureVisible(find.text("Share the state's product info (JSON)"));
    await tester.tap(find.text("Share the state's product info (JSON)"));
    await tester.pumpAndSettle();
    expect(sharedName, 'PKPR-71c5e6ad_product_info_6667.json');
    expect(jsonDecode(utf8.decode(shared!)), info);
  });
}
