// debug_server_link_page.dart: the server link as it stands (README R56) - status, the outbox, the dead letters, the
// sale logs dropped for room, the catch-up work, and the sync engine's datasets.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/debug_server_link_page.dart';
import 'package:mazama_mobile/sale_failure_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_link.dart';
import 'package:mazama_mobile/server_outbox.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';

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

  testWidgets('lists the datasets kept, with where from, when and a failed refresh', (tester) async {
    final health = ServerHealth(probe: () async => true, startTimer: FakeTimers().start);
    final link = ServerLink(
      health: health,
      outbox: ServerOutbox(health: health, store: OutboxStore(dataDir: () => dir), send: (e) async {}),
      catchUp: CatchUpWork(
          health: health,
          store: CatchUpStore(dataDir: () => dir),
          submitCoa: (l, a) async => true,
          uploadSnapshot: (s) async {},
          auth: () async => null),
    );
    addTearDown(link.dispose);
    final at = DateTime.utc(2026, 10, 21, 9, 30);
    final datasets = Datasets.forDir(() => dir);
    datasets.put(Dataset.par, '231', '[]', source: sourceServer, at: at);
    datasets.put(Dataset.mazamaInventory, '', '{}', source: sourceServer, at: at);
    datasets.failed(Dataset.mazamaInventory, '', 'cannot reach x', at: at.add(const Duration(hours: 1)));

    await tester.pumpWidget(MaterialApp(home: DebugServerLinkPage(link: link)));
    expect(find.byKey(const ValueKey('dataset-par/231')), findsOneWidget);
    expect(find.textContaining('par/231 from the server'), findsOneWidget);
    expect(find.textContaining('mazama_inventory from the server'), findsOneWidget);
    expect(find.textContaining('the last refresh failed: cannot reach x'), findsOneWidget);
  });

  // Task 10 review, minor 3: a copy an older build kept with no time is moved in at the epoch; it reads as no time.
  testWidgets('a dataset moved in with no time recorded says so, not 1969', (tester) async {
    final health = ServerHealth(probe: () async => true, startTimer: FakeTimers().start);
    final link = ServerLink(
      health: health,
      outbox: ServerOutbox(health: health, store: OutboxStore(dataDir: () => dir), send: (e) async {}),
      catchUp: CatchUpWork(
          health: health,
          store: CatchUpStore(dataDir: () => dir),
          submitCoa: (l, a) async => true,
          uploadSnapshot: (s) async {},
          auth: () async => null),
    );
    addTearDown(link.dispose);
    final datasets = Datasets.forDir(() => dir);
    datasets.put(Dataset.mazamaLicenses, '231', '[]',
        source: sourceServer, at: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));

    await tester.pumpWidget(MaterialApp(home: DebugServerLinkPage(link: link)));
    expect(find.text('  mazama_licenses/231 from the server, no time'), findsOneWidget);
    expect(find.textContaining('1969'), findsNothing);
    expect(find.textContaining('1970'), findsNothing);
  });
}
