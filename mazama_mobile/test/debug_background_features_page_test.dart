import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/debug_background_features_page.dart';
import 'package:mazama_mobile/device_id.dart';
import 'package:mazama_mobile/merged_inventory.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/session.dart';

Session _session() => Session(
    accessToken: 'TOKEN', refreshToken: 'REFRESH', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

Widget _page({
  int? initialStateId,
  Future<MergedInventoryResult> Function(int, {required String accessToken})? fetchMergedInventory,
  Future<Map<String, Object?>> Function(int, List<Object?>, {required String workerEmail, required String deviceId})? uploadInventorySnapshot,
  Future<CoaData?> Function(
          {required String lotGuid, required int representativePackageId, required String accessToken, required String workerEmail, required String deviceId, double? statePsilocybin})?
      submitCoaForLot,
  Future<Uint8List> Function(int, String)? fetchLabel,
  Future<void> Function(int, {required String workerEmail, required String deviceId, required List<Map<String, Object?>> request, required Object? response})?
      postSaleLog,
  Future<void> Function(int, {required String workerEmail, required String deviceId, required String reason, required List<Map<String, Object?>> request})?
      postSaleFailure,
}) =>
    MaterialApp(
      home: DebugBackgroundFeaturesPage(
        session: _session(),
        initialStateId: initialStateId,
        fetchMergedInventory: fetchMergedInventory ?? (stateId, {required accessToken}) async => throw Exception('no fixture'),
        uploadInventorySnapshot: uploadInventorySnapshot ?? (stateId, records, {required workerEmail, required deviceId}) async => throw Exception('no fixture'),
        submitCoaForLot: submitCoaForLot ??
            ({required lotGuid, required representativePackageId, required accessToken, required workerEmail, required deviceId, statePsilocybin}) async =>
                throw Exception('no fixture'),
        fetchLabel: fetchLabel ?? (stateId, guid) async => throw Exception('no fixture'),
        postSaleLog: postSaleLog ?? (stateId, {required workerEmail, required deviceId, required request, required response}) async => throw Exception('no fixture'),
        postSaleFailure: postSaleFailure ?? (stateId, {required workerEmail, required deviceId, required reason, required request}) async => throw Exception('no fixture'),
        deviceIdStore: DeviceIdStore(dataDir: () => Directory.systemTemp.createTempSync()),
      ),
    );

/// The page's own ListView is taller than the default 800x600 test surface, so anything past the first
/// section or two is either laid out below the visible viewport (a real tap there misses - flutter_test warns
/// and the test still fails) or, further down still, not even built yet (a plain ListView only materializes
/// children within its viewport + cache extent, same as a ListView.builder would). Scrolling it into view
/// first - not just taller test surface, since a worker's real phone is no taller either - fixes both.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  // A positive delta moves forward through a top-to-bottom list (the same convention flutter_test's own
  // scrollUntilVisible doc example uses to reach a later item) - what every section below the first needs,
  // since this page's ListView is taller than the default 800x600 test surface.
  //
  // find.byType(Scrollable).first, not the bare finder: this page has several TextFields on screen at once,
  // and each one's own EditableText carries an internal Scrollable for cursor-follow scrolling (not just the
  // page's own ListView) - scrollUntilVisible needs exactly one match for the scrollable it drags, and the
  // ListView's is always the first one built.
  await tester.scrollUntilVisible(finder, 400, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the device id once it loads, and the session email', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.textContaining('Device id:'), findsOneWidget);
    expect(find.textContaining('(loading...)'), findsNothing); // idOrCreate resolved by the time pumpAndSettle returns
    expect(find.textContaining('worker@example.com'), findsWidgets);
  });

  testWidgets('fetch & merge shows mazamaOk/stateOk and enables the push button only on success with raw records',
      (tester) async {
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchMergedInventory: (stateId, {required accessToken}) async => MergedInventoryResult(
        packages: [
          Package(productGuid: 'PKPR-a', productType: 'Extract', id: 1, weightPerUnit: 5, analyteWeight: 4.5, quantity: 10, coaAvailable: false, labelAvailable: false),
        ],
        mazamaOk: true,
        stateOk: true,
        rawStateRecords: [
          {'id': 1}
        ],
      ),
    ));

    expect((tester.widget(find.byType(TextField).first) as TextField).controller!.text, '225');

    await tester.tap(find.text('Fetch & merge'));
    await tester.pumpAndSettle();

    expect(find.textContaining('mazamaOk=true, stateOk=true'), findsOneWidget);
    expect(find.textContaining('1 missing a COA/label'), findsOneWidget);

    final pushButton = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Push this snapshot to mazama_sales now'));
    expect(pushButton.onPressed, isNotNull);
  });

  testWidgets('push is disabled until a merge has actually run, and sends exactly the records that merge produced',
      (tester) async {
    Map<String, Object?>? captured;
    List<Object?>? sentRecords;
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchMergedInventory: (stateId, {required accessToken}) async => MergedInventoryResult(
        packages: const [],
        mazamaOk: true,
        stateOk: true,
        rawStateRecords: [
          {'id': 7}
        ],
      ),
      uploadInventorySnapshot: (stateId, records, {required workerEmail, required deviceId}) async {
        sentRecords = records;
        captured = {'rows': 1, 'skipped': 0};
        return captured!;
      },
    ));

    // Before any merge, the push button exists but does nothing useful - disabled.
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Push this snapshot to mazama_sales now')).onPressed, isNull);

    await tester.tap(find.text('Fetch & merge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Push this snapshot to mazama_sales now'));
    await tester.pumpAndSettle();

    expect(sentRecords, [{'id': 7}]);
    expect(find.textContaining('rows'), findsOneWidget);
  });

  testWidgets('submitCoaForLot: a null result (no PDF yet) is shown as a success, not an error', (tester) async {
    await tester.pumpWidget(_page(
      submitCoaForLot: ({required lotGuid, required representativePackageId, required accessToken, required workerEmail, required deviceId, statePsilocybin}) async => null,
    ));

    await tester.enterText(find.widgetWithText(TextField, 'Lot guid (harvestBatchGuid or processLotGuid)'), 'G-1');
    await tester.enterText(find.widgetWithText(TextField, 'Representative package id (any package in that lot)'), '42');
    await _scrollTo(tester, find.text('Submit via submitCoaForLot'));
    await tester.tap(find.text('Submit via submitCoaForLot'));
    await tester.pumpAndSettle();

    expect(find.textContaining('no accepted Potency-test PDF'), findsOneWidget);
  });

  testWidgets('submitCoaForLot: a real result shows the parsed strain/potency', (tester) async {
    await tester.pumpWidget(_page(
      submitCoaForLot: ({required lotGuid, required representativePackageId, required accessToken, required workerEmail, required deviceId, statePsilocybin}) async => CoaData(
        guid: lotGuid, strain: 'Golden Teacher', psilocybin: 1.0, psilocin: 0.5, baeocystin: 0, norbaeocystin: 0, norpsilocin: 0, tpe: 1.75,
      ),
    ));

    await tester.enterText(find.widgetWithText(TextField, 'Lot guid (harvestBatchGuid or processLotGuid)'), 'G-1');
    await tester.enterText(find.widgetWithText(TextField, 'Representative package id (any package in that lot)'), '42');
    await _scrollTo(tester, find.text('Submit via submitCoaForLot'));
    await tester.tap(find.text('Submit via submitCoaForLot'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Golden Teacher'), findsOneWidget);
  });

  testWidgets('check label shows a byte count on success and the error message on failure', (tester) async {
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchLabel: (stateId, guid) async => Uint8List.fromList([1, 2, 3]),
    ));

    await _scrollTo(tester, find.widgetWithText(TextField, 'Product guid'));
    await tester.enterText(find.widgetWithText(TextField, 'Product guid'), 'PKPR-a');
    await _scrollTo(tester, find.text('Check label'));
    await tester.tap(find.text('Check label'));
    await tester.pumpAndSettle();

    expect(find.textContaining('3 bytes'), findsOneWidget);
  });

  testWidgets('sale-log and sale-failure buttons post synthetic records and show the outcome', (tester) async {
    var logCalled = false, failureCalled = false;
    await tester.pumpWidget(_page(
      initialStateId: 225,
      postSaleLog: (stateId, {required workerEmail, required deviceId, required request, required response}) async {
        logCalled = true;
      },
      postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
        failureCalled = true;
      },
    ));

    await _scrollTo(tester, find.text('Send test sale-log'));
    await tester.tap(find.text('Send test sale-log'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('Send test sale-failure'));
    await tester.tap(find.text('Send test sale-failure'));
    await tester.pumpAndSettle();

    expect(logCalled, isTrue);
    expect(failureCalled, isTrue);
    expect(find.textContaining('Posted'), findsNWidgets(2));
  });

  testWidgets('a thrown error from any action is shown in red, not swallowed', (tester) async {
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchMergedInventory: (stateId, {required accessToken}) async => throw Exception('both inventory sources failed'),
    ));

    await tester.tap(find.text('Fetch & merge'));
    await tester.pumpAndSettle();

    expect(find.textContaining('both inventory sources failed'), findsOneWidget);
  });
}
