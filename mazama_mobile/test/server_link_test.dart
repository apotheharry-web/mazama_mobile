// server_link.dart: the app's one link to Mazama's server (README R56) - the banner above every page, the outbox and
// catch-up work woken when the server answers again, the snapshot and lab-report defaults, and when the server went
// offline kept across restarts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/api_contract.g.dart' show ingestMaxRecords;
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/coa_uploader.dart';
import 'package:mazama_mobile/configured_coa_submit.dart';
import 'package:mazama_mobile/device_id.dart';
import 'package:mazama_mobile/inventory_upload_client.dart';
import 'package:mazama_mobile/reply_store.dart';
import 'package:mazama_mobile/sales_upload_client.dart';
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

    // R87: the one banner has a close button; dismissed, it stays hidden for the rest of this outage.
    group('dismissed', () {
      final dismiss = find.byKey(const ValueKey('server-link-banner-dismiss'));
      final banner = find.byKey(const ValueKey('server-link-banner'));

      /// The page's own top padding, as MediaQuery gives it under the banner.
      double topPadding(WidgetTester tester) => MediaQuery.of(tester.element(find.text('a page'))).padding.top;

      /// As [app], with a 24 px status bar above the banner.
      Widget paddedApp(ServerLink l, ValueNotifier<bool> demo) => MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(top: 24)),
              child: ServerLinkBanner(link: l, demoMode: demo, child: child!),
            ),
            home: const Scaffold(body: Text('a page')),
          );

      testWidgets('the close button hides the banner and gives the page its top padding back', (tester) async {
        final l = link();
        addTearDown(l.dispose);
        l.health.markUnreachable();
        await tester.pumpWidget(paddedApp(l, ValueNotifier(false)));
        expect(banner, findsOneWidget);
        expect(topPadding(tester), 0); // the banner takes the status bar's room
        // The close button carries an explicit Semantics(button: true, label: 'Dismiss') in ServerLinkBanner; a
        // find.bySemanticsLabel check of it found nothing in CI with the banner in MaterialApp's builder, so it isn't
        // asserted here.

        await tester.tap(dismiss);
        await tester.pumpAndSettle();
        expect(banner, findsNothing);
        expect(find.byKey(const ValueKey('server-link-banner-off')), findsOneWidget);
        expect(find.text('a page'), findsOneWidget);
        expect(topPadding(tester), 24);
        expect(l.health.offline, isTrue); // only the banner went: the server is still counted as offline
      });

      testWidgets('stays hidden while still offline, across a page change and more reports waiting', (tester) async {
        final l = link();
        addTearDown(l.dispose);
        l.health.markUnreachable();
        final nav = GlobalKey<NavigatorState>();
        await tester.pumpWidget(MaterialApp(
          navigatorKey: nav,
          builder: (context, child) => ServerLinkBanner(link: l, demoMode: ValueNotifier(false), child: child!),
          home: const Scaffold(body: Text('a page')),
        ));
        await tester.tap(dismiss);
        await tester.pumpAndSettle();
        expect(banner, findsNothing);

        unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('another page')))));
        await tester.pumpAndSettle();
        expect(find.text('another page'), findsOneWidget);
        expect(banner, findsNothing);

        await l.outbox.addSaleLog(231, workerEmail: 'w', deviceId: 'd', request: const [{'n': 1}], response: null);
        await tester.pump();
        expect(banner, findsNothing);

        nav.currentState!.pop();
        await tester.pumpAndSettle();
        expect(banner, findsNothing);
      });

      testWidgets('shows again when the server answers and then stops answering again', (tester) async {
        final l = link();
        addTearDown(l.dispose);
        l.health.markUnreachable();
        await tester.pumpWidget(app(l, ValueNotifier(false)));
        await tester.tap(dismiss);
        await tester.pumpAndSettle();
        expect(banner, findsNothing);

        l.health.markReachable();
        await tester.pump();
        expect(banner, findsNothing);
        l.health.markUnreachable();
        await tester.pump();
        expect(banner, findsOneWidget);
        expect(dismiss, findsOneWidget);
      });

      testWidgets('the demo: never shown, dismissed or not', (tester) async {
        final l = link();
        addTearDown(l.dispose);
        l.health.markUnreachable();
        final demo = ValueNotifier(true);
        await tester.pumpWidget(app(l, demo));
        expect(banner, findsNothing);
        expect(dismiss, findsNothing);

        // Dismissed out of the demo, then a new outage: the dismiss is gone (the banner shows), but not in the demo.
        demo.value = false;
        await tester.pump();
        await tester.tap(dismiss);
        await tester.pumpAndSettle();
        expect(banner, findsNothing);
        l.health.markReachable();
        l.health.markUnreachable();
        await tester.pump();
        expect(l.health.bannerDismissed, isFalse);
        expect(banner, findsOneWidget); // proves the rule reads the new outage's state, not the old dismiss
        demo.value = true;
        await tester.pump();
        expect(banner, findsNothing); // the demo alone hides it
      });
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
    expect(l.catchUp.snapshots['inventory:231']!.records, [1]);
  });

  test('sales: offline, the newest read is kept beside the inventory one, failing at once as unreachable', () async {
    final l = link();
    addTearDown(l.dispose);
    l.health.markUnreachable();
    await expectLater(l.uploadInventorySnapshot(231, const [1], workerEmail: 'w', deviceId: 'd'), throwsA(isA<InventoryUploadError>()));
    await expectLater(l.uploadSalesSnapshot(231, const [1, 2], workerEmail: 'w', deviceId: 'd'),
        throwsA(isA<SalesUploadError>().having((e) => e.unreachable, 'unreachable', isTrue)));
    await expectLater(l.uploadSalesSnapshot(231, const [3], workerEmail: 'w', deviceId: 'd'), throwsA(isA<SalesUploadError>()));
    expect(l.catchUp.snapshots['sales:231']!.records, [3]);
    expect(l.catchUp.snapshots['inventory:231']!.records, [1]);
  });

  test('sales: a newer read that reaches the server makes the kept one moot (the inventory one stays)', () async {
    final l = link();
    addTearDown(l.dispose);
    l.catchUp.keepSnapshot(231, const [1], workerEmail: 'w', deviceId: 'd');
    l.catchUp.keepSnapshot(231, const [2], workerEmail: 'w', deviceId: 'd', kind: 'sales');
    final ok = http_testing.MockClient((_) async => http.Response('{"rows": 1, "skipped": 0}', 200));
    expect(await l.uploadSalesSnapshot(231, const [4], workerEmail: 'w', deviceId: 'd', client: ok), {'rows': 1, 'skipped': 0});
    expect(l.catchUp.snapshots.keys, ['inventory:231']);
  });

  test("sales: a read over the route's limit sends (and keeps) only the newest records it takes", () async {
    final l = link();
    addTearDown(l.dispose);
    final records = [
      for (var i = 0; i < ingestMaxRecords + 2; i++)
        {'id': i, 'dateOfSale': DateTime.utc(2020, 1, 1).add(Duration(days: i)).toIso8601String()},
    ];
    List<Object?>? sentRecords;
    final ok = http_testing.MockClient((req) async {
      sentRecords = (jsonDecode(req.body) as Map)['records'] as List;
      return http.Response('{"rows": 1, "skipped": 0}', 200);
    });
    await l.uploadSalesSnapshot(231, records, workerEmail: 'w', deviceId: 'd', client: ok);
    expect(sentRecords, hasLength(ingestMaxRecords));
    final ids = {for (final r in sentRecords!) (r as Map)['id']};
    expect([ids.contains(0), ids.contains(1), ids.contains(ingestMaxRecords + 1)], [false, false, true]); // the two oldest left out
    l.health.markUnreachable();
    await expectLater(l.uploadSalesSnapshot(231, records, workerEmail: 'w', deviceId: 'd'), throwsA(isA<SalesUploadError>()));
    expect(l.catchUp.snapshots['sales:231']!.records, hasLength(ingestMaxRecords));
  });

  test('sales: an unreachable send keeps the read for later; a refusal keeps nothing', () async {
    final l = link();
    addTearDown(l.dispose);
    final down = http_testing.MockClient((_) async => throw const SocketException('down'));
    await expectLater(l.uploadSalesSnapshot(231, const [1], workerEmail: 'w', deviceId: 'd', client: down),
        throwsA(isA<SalesUploadError>()));
    expect(l.catchUp.snapshots['sales:231']!.records, [1]);
    final refused = http_testing.MockClient((_) async => http.Response('{"detail": "Records for another service center."}', 400));
    await expectLater(l.uploadSalesSnapshot(183, const [1], workerEmail: 'w', deviceId: 'd', client: refused),
        throwsA(isA<SalesUploadError>()));
    expect(l.catchUp.snapshots.containsKey('sales:183'), isFalse);
  });

  test("the catch-up uploader sends each kept snapshot to its own kind's route", () async {
    final seen = <String>[];
    final c = http_testing.MockClient((req) async {
      seen.add(req.url.path);
      return http.Response('{"rows": 0, "skipped": 0}', 200);
    });
    PendingSnapshot snap(String kind) =>
        PendingSnapshot(stateId: 231, kind: kind, records: const [], workerEmail: 'w', deviceId: 'd', readAt: since);
    await uploadPendingSnapshot(snap('inventory'), client: c);
    await uploadPendingSnapshot(snap('sales'), client: c);
    expect(seen, ['/p/inventory/231', '/p/ingest/sales/231']);
    await expectLater(uploadPendingSnapshot(snap('harvest'), client: c), throwsA(isA<ArgumentError>()));
    expect(seen, hasLength(2)); // an unknown kind is never sent anywhere
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

  // specs/coa-upload: the link's one background uploader, and one memory of the lab reports sent, whichever way.
  group('lab reports sent in the background', () {
    /// The state system and the server for one lot's chain: package 777, document 42, the upload answered [status].
    http.Client chain(int status) => http_testing.MockClient((req) async {
          final p = req.url.path;
          if (p.endsWith('/GetPackagedProductInfo/777')) {
            return http.Response(
                jsonEncode({
                  'testResults': [
                    {
                      'test': 'Potency', 'status': 'Accepted', 'dateCompleted': '01/02/2026',
                      'testingManifest': {
                        'documents': [
                          {'id': 42, 'extension': '.pdf', 'deprecated': false},
                        ],
                      },
                    },
                  ],
                }),
                200);
          }
          if (p.endsWith('/DownloadDocument/42')) return http.Response('%PDF-1.4 report', 200);
          if (p == '/p/coa-data/parse') {
            return status == 200
                ? http.Response(jsonEncode({'strain': 'Golden Teacher', 'psilocybin': 10.4, 'psilocin': 0.6, 'tpe': 11.2}), 200)
                : http.Response(jsonEncode({'queued': true}), status);
          }
          return http.Response('{}', 404);
        });

    test("the app's uploader is the link's: what it has waiting is pending; offline it lets the lots go, unkept",
        () async {
      final l = link();
      addTearDown(l.dispose);
      useServerLink(l);
      addTearDown(() => releaseServerLink(l));
      l.health.markUnreachable();
      queueCoaUploads([const CoaUploadLot(lotGuid: 'HB-1', packageId: 1, stateId: 231, statePsilocybin: 4.5)]);
      expect(coaUploadPending('hb-1'), isTrue);
      await pumpEventQueue(); // its first start is on a timer of no delay
      expect(coaUploadPending('HB-1'), isFalse);
      expect(l.coaUploads.idle, isTrue);
      expect(l.catchUp.lots, isEmpty); // never filled in bulk: the next load enqueues the lot again
    });

    for (final status in [200, 202]) {
      test('a cart add the server answered ($status) is remembered, so the uploader does not send it again', () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final l = link();
        addTearDown(l.dispose);
        try {
          await l.submitCoaForLot(
              lotGuid: 'HB-9bc7d118', representativePackageId: 777, accessToken: 'T', workerEmail: 'w', deviceId: 'd', client: chain(status));
        } on ConfiguredCoaSubmitError catch (e) {
          expect(e.status, status);
        }
        expect(l.coaUploads.sent.wasSent('hb-9BC7D118'), isTrue);
        l.coaUploads.enqueue([const CoaUploadLot(lotGuid: 'HB-9bc7d118', packageId: 777, stateId: 231)]);
        expect(l.coaUploads.waiting, 0);
      });
    }

    test('a cart add the server was too busy for (429) is not remembered', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final l = link();
      addTearDown(l.dispose);
      await expectLater(
          l.submitCoaForLot(
              lotGuid: 'HB-9bc7d118', representativePackageId: 777, accessToken: 'T', workerEmail: 'w', deviceId: 'd', client: chain(429)),
          throwsA(isA<ConfiguredCoaSubmitError>()));
      expect(l.coaUploads.sent.wasSent('HB-9bc7d118'), isFalse);
    });

    test('a catch-up submission the server answered is remembered in the memory it is given', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final sent = CoaSentMemory(store: CoaSentStore(dataDir: () => _dir));
      final lot = PendingCoaLot(lotGuid: 'HB-9bc7d118', packageId: 777, stateId: 231, addedAt: DateTime.utc(2026, 10, 27));
      const auth = CatchUpAuth(accessToken: 'T', workerEmail: 'w', deviceId: 'd');
      expect(await submitPendingCoaLot(lot, auth, sent: sent, client: chain(200)), isTrue);
      expect(sent.wasSent('HB-9bc7d118'), isTrue);
    });
  });
}
