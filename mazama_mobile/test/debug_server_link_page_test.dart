// debug_server_link_page.dart: the server link as it stands (README R56) - status, the outbox, the dead letters, the
// sale logs dropped for room, the catch-up work.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/debug_server_link_page.dart';
import 'package:mazama_mobile/reply_store.dart';
import 'package:mazama_mobile/sale_failure_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_link.dart';
import 'package:mazama_mobile/server_outbox.dart';

import 'fake_timers.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mazama_debug_link_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('shows offline, what waits, the dead letters and the dropped logs', (tester) async {
    final timers = FakeTimers();
    final health = ServerHealth(probe: () async => false, startTimer: timers.start);
    var refuse = true;
    final link = ServerLink(
      health: health,
      outbox: ServerOutbox(
          health: health,
          store: OutboxStore(dataDir: () => dir),
          startTimer: timers.start,
          cap: 1,
          send: (e) async {
            if (refuse) throw SaleFailureError('reason is required.', status: 400);
          }),
      catchUp: CatchUpWork(
          health: health,
          store: CatchUpStore(dataDir: () => dir),
          submitCoa: (l, a) async => true,
          uploadSnapshot: (s) async {},
          auth: () async => null),
      replies: ReplyStore(dataDir: () => dir),
    );
    addTearDown(link.dispose);
    await tester.runAsync(() async {
      await link.outbox.addSaleFailure(231, workerEmail: 'w', deviceId: 'd', reason: 'r', request: const [{'n': 1}]);
      await pumpEventQueue();
      refuse = false;
      health.markUnreachable();
      await link.outbox.addSaleLog(231, workerEmail: 'w', deviceId: 'd', request: const [{'n': 2}], response: null);
      await link.outbox.addSaleLog(231, workerEmail: 'w', deviceId: 'd', request: const [{'n': 3}], response: null);
      link.catchUp.addCoaLot(lotGuid: 'HB-aaaa0001', packageId: 101, stateId: 231);
    });

    await tester.pumpWidget(MaterialApp(home: DebugServerLinkPage(link: link)));
    expect(find.textContaining('Offline since'), findsOneWidget);
    expect(find.text('Outbox: 1 waiting'), findsOneWidget);
    expect(find.byKey(const ValueKey('outbox-dropped')), findsOneWidget);
    expect(find.text('Dead letters: 1'), findsOneWidget);
    expect(find.textContaining('HTTP 400'), findsOneWidget);
    expect(find.text('Lab reports to submit: 1'), findsOneWidget);
  });
}
