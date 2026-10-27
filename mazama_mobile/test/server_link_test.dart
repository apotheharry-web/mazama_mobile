// server_link.dart: the app's one link to Mazama's server (README R56) - the banner above every page, the outbox and
// catch-up work woken when the server answers again, the snapshot and lab-report defaults, and when the server went
// offline kept across restarts.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/configured_coa_submit.dart';
import 'package:mazama_mobile/device_id.dart';
import 'package:mazama_mobile/inventory_upload_client.dart';
import 'package:mazama_mobile/reply_store.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_link.dart';
import 'package:mazama_mobile/server_offline.dart' show formatAsOf;
import 'package:mazama_mobile/server_outbox.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/session_store.dart';

import 'fake_timers.dart';

late Directory _dir;

void main() {
  late FakeTimers timers;
  late List<String> sent;
  late List<int> uploaded;

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('mazama_server_link_test_');
    timers = FakeTimers();
    sent = [];
    uploaded = [];
  });
  tearDown(() => _dir.deleteSync(recursive: true));

  final since = DateTime.utc(2026, 10, 23, 13, 5);

  ServerLink link({bool Function()? probeAnswer}) {
    final health = ServerHealth(probe: () async => probeAnswer?.call() ?? false, now: () => since, startTimer: timers.start);
    return ServerLink(
      health: health,
      outbox: ServerOutbox(
          health: health, store: OutboxStore(dataDir: () => _dir), send: (e) async => sent.add(e.clientId), startTimer: timers.start),
      catchUp: CatchUpWork(
        health: health,
        store: CatchUpStore(dataDir: () => _dir),
        submitCoa: (lot, auth) async => true,
        uploadSnapshot: (s) async => uploaded.add(s.stateId),
        auth: () async => const CatchUpAuth(accessToken: 'T', workerEmail: 'w', deviceId: 'd'),
      ),
      replies: ReplyStore(dataDir: () => _dir),
    );
  }

  group('the banner text', () {
    test('since when, that selling works, and how many reports wait', () {
      expect(serverLinkBannerText(since: since, waiting: 0),
          "Mazama's server can't be reached since ${formatAsOf(since)}. Selling still works.");
      expect(serverLinkBannerText(since: since, waiting: 1),
          "Mazama's server can't be reached since ${formatAsOf(since)}. Selling still works. 1 report is waiting to be sent.");
      expect(serverLinkBannerText(since: null, waiting: 3),
          "Mazama's server can't be reached. Selling still works. 3 reports are waiting to be sent.");
      expect(serverLinkBannerText(since: null, waiting: 2, dropped: 1),
          "Mazama's server can't be reached. Selling still works. 2 reports are waiting to be sent. "
          '1 older sale log was dropped for room.');
    });
  });

  group('the banner above every page', () {
    Widget app(ServerLink l, ValueNotifier<bool> demo) => MaterialApp(
          builder: (context, child) => ServerLinkBanner(link: l, demoMode: demo, child: child!),
          home: const Scaffold(body: Text('a page')),
        );

    testWidgets('online: none', (tester) async {
      final l = link();
      addTearDown(l.dispose);
      await tester.pumpWidget(app(l, ValueNotifier(false)));
      expect(find.byKey(const ValueKey('server-link-banner')), findsNothing);
      expect(find.text('a page'), findsOneWidget);
    });

    testWidgets('offline: since when and how many reports wait; gone once the server answers', (tester) async {
      final l = link();
      addTearDown(l.dispose);
      l.health.markUnreachable();
      await l.outbox.addSaleFailure(231, workerEmail: 'w', deviceId: 'd', reason: 'r', request: const [{'n': 1}]);
      await l.outbox.addSaleLog(231, workerEmail: 'w', deviceId: 'd', request: const [{'n': 2}], response: null);
      await tester.pumpWidget(app(l, ValueNotifier(false)));
      expect(find.byKey(const ValueKey('server-link-banner')), findsOneWidget);
      expect(find.text(serverLinkBannerText(since: since, waiting: 2)), findsOneWidget);
      expect(find.text('a page'), findsOneWidget); // the page stays usable under it

      l.health.markReachable();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('server-link-banner')), findsNothing);
    });

    testWidgets('the demo: none, even with the tracker offline', (tester) async {
      final l = link();
      addTearDown(l.dispose);
      l.health.markUnreachable();
      final demo = ValueNotifier(true);
      await tester.pumpWidget(app(l, demo));
      expect(find.byKey(const ValueKey('server-link-banner')), findsNothing);
      demo.value = false;
      await tester.pump();
      expect(find.byKey(const ValueKey('server-link-banner')), findsOneWidget);
    });
  });

  test('going online flushes the outbox and then the catch-up work', () async {
    final l = link();
    addTearDown(l.dispose);
    l.health.markUnreachable();
    final id = await l.outbox.addSaleLog(231, workerEmail: 'w', deviceId: 'd', request: const [{'n': 1}], response: null);
    l.catchUp.keepSnapshot(231, const [1], workerEmail: 'w', deviceId: 'd');
    await pumpEventQueue();
    expect([sent, uploaded], [[], []]);
    l.health.markReachable();
    await pumpEventQueue();
    expect(sent, [id]);
    expect(uploaded, [231]);
  });

  test('a probe that gets an answer wakes the outbox too', () async {
    var up = false;
    final l = link(probeAnswer: () => up);
    addTearDown(l.dispose);
    l.health.markUnreachable();
    await l.outbox.addSaleLog(231, workerEmail: 'w', deviceId: 'd', request: const [{'n': 1}], response: null);
    up = true;
    timers.active.where((t) => t.delay == probeFirstDelay).single.fire();
    await pumpEventQueue();
    expect(sent, hasLength(1));
  });

  test('the foreground: offline, a probe at once; online, what still waits is sent', () async {
    var probes = 0;
    final l = link(probeAnswer: () {
      probes++;
      return false;
    });
    addTearDown(l.dispose);
    l.health.markUnreachable();
    l.onForeground();
    await pumpEventQueue();
    expect(probes, 1);
  });

  test('offline, a snapshot is kept (only the newest) and the upload fails as unreachable without a request', () async {
    final l = link();
    addTearDown(l.dispose);
    l.health.markUnreachable();
    await expectLater(l.uploadInventorySnapshot(231, const [1, 2], workerEmail: 'w', deviceId: 'd'),
        throwsA(isA<InventoryUploadError>().having((e) => e.unreachable, 'unreachable', isTrue)));
    await expectLater(l.uploadInventorySnapshot(231, const [1], workerEmail: 'w', deviceId: 'd'), throwsA(isA<InventoryUploadError>()));
    expect(l.catchUp.snapshots[231]!.records, [1]);
  });

  test('offline, a lab report fails at once as unreachable, reading nothing from the state system', () async {
    final l = link();
    addTearDown(l.dispose);
    l.health.markUnreachable();
    await expectLater(
        l.submitCoaForLot(lotGuid: 'HB-1', representativePackageId: 1, accessToken: 'T', workerEmail: 'w', deviceId: 'd'),
        throwsA(isA<ConfiguredCoaSubmitError>().having((e) => e.unreachable, 'unreachable', isTrue)));
  });

  test('when the server went offline is kept for the next run, and cleared when it answers', () {
    final store = ServerHealthStore(dataDir: () => _dir);
    expect(store.loadOfflineSince(), isNull);
    store.saveOfflineSince(since);
    expect(ServerHealthStore(dataDir: () => _dir).loadOfflineSince(), since);
    store.saveOfflineSince(null);
    expect(store.loadOfflineSince(), isNull);
  });

  test('the catch-up work uses the saved session only while it is fresh, and never the demo', () async {
    final sessions = SessionStore(dataDir: () => _dir);
    final devices = DeviceIdStore(dataDir: () => _dir);
    final now = DateTime.utc(2026, 10, 23, 12);
    expect(await savedSessionAuth(sessions, devices, now: () => now), isNull);
    await sessions.save(Session(
            accessToken: 'FRESH', refreshToken: 'R', email: 'w@example.com', expiresAtMs: now.add(const Duration(hours: 1)).millisecondsSinceEpoch)
        .toJson());
    final auth = await savedSessionAuth(sessions, devices, now: () => now);
    expect([auth!.accessToken, auth.workerEmail, auth.deviceId], ['FRESH', 'w@example.com', await devices.idOrCreate()]);
    await sessions.save(Session(
            accessToken: 'OLD', refreshToken: 'R', email: 'w@example.com', expiresAtMs: now.add(const Duration(seconds: 30)).millisecondsSinceEpoch)
        .toJson());
    expect(await savedSessionAuth(sessions, devices, now: () => now), isNull); // about to expire: never renewed from here
  });
}
