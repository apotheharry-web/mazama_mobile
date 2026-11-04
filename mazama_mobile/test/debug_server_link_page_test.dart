// debug_server_link_page.dart: the server link as it stands - status, the sale reports waiting, the dead letters, the
// sale logs dropped for room, the catch-up work, and the sync engine's datasets.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/debug_server_link_page.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/sale_failure_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_link.dart';
import 'package:mazama_mobile/server_outbox.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/sync_engine.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';

import 'fake_timers.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mazama_debug_link_test_'));
  tearDown(() {
    LocalStore.debugCloseAll();
    dir.deleteSync(recursive: true);
  });

  // A link over an engine on the test's folder; [send] answers each sale report.
  ServerLink makeLink(ServerHealth health, {FakeTimers? timers, Future<void> Function(OutboxEntry)? send}) {
    final l = ServerLink(
      health: health,
      engine: SyncEngine(
        store: LocalStore.forDir(dir),
        health: health,
        startTimer: timers?.start,
        senders: {
          QueueKind.saleLog: outboxQueueSender(send ?? (e) async {}),
          QueueKind.saleFailure: outboxQueueSender(send ?? (e) async {}),
        },
      ),
    );
    addTearDown(l.dispose);
    return l;
  }

  testWidgets('shows offline, what waits, the dead letters and the dropped logs', (tester) async {
    final timers = FakeTimers();
    final health = ServerHealth(probe: () async => false, startTimer: timers.start);
    var refuse = true;
    final link = makeLink(health, timers: timers, send: (e) async {
      if (refuse) throw SaleFailureError('reason is required.', status: 400);
    });
    await tester.runAsync(() async {
      link.queue.addSaleFailure(231, workerEmail: 'w', deviceId: 'd', reason: 'r', request: const [{'n': 1}]);
      await pumpEventQueue();
      refuse = false;
      health.markUnreachable();
      link.queue.addSaleLog(231, workerEmail: 'w', deviceId: 'd', request: const [{'n': 2}], response: null);
      // a sale log dropped for room, as the queue counts it
      LocalStore.forDir(dir).write('sync_dropped_sale_logs', '1');
      link.queue.addCoaLot(lotGuid: 'HB-aaaa0001', packageId: 101, stateId: 231);
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
    final link = makeLink(health);
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

  testWidgets('a dataset stored with no time recorded says so, not 1969', (tester) async {
    final health = ServerHealth(probe: () async => true, startTimer: FakeTimers().start);
    final link = makeLink(health);
    final datasets = Datasets.forDir(() => dir);
    datasets.put(Dataset.mazamaLicenses, '231', '[]',
        source: sourceServer, at: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));

    await tester.pumpWidget(MaterialApp(home: DebugServerLinkPage(link: link)));
    expect(find.text('  mazama_licenses/231 from the server, no time'), findsOneWidget);
    expect(find.textContaining('1969'), findsNothing);
    expect(find.textContaining('1970'), findsNothing);
  });
}
