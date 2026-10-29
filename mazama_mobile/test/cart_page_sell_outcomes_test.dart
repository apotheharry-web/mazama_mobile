import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/state_packages_client.dart';
import 'package:mazama_mobile/sale_failure_client.dart';
import 'package:mazama_mobile/sellability.dart';
import 'package:mazama_mobile/session.dart';

import 'flow/fake_state.dart';
import 'cart_page_test_support.dart';

void main() {
  // rootBundle.loadString caches its Future by asset key for the lifetime of the whole test *process*, not
  // per-test (see widget_test.dart's own note on this). CartPage's constructor loads assets/flows/sale.yaml
  // via rootBundle whenever a test doesn't pass saleSpec: explicitly, which is most tests in this file - without
  // clearing it, a later test can get an earlier test's already-created Future, straddling two different
  // testWidgets async zones. That doesn't throw - it just leaves that test's pumpAndSettle waiting on a Future
  // that never resolves in its own zone, hanging for the full default test timeout (10 minutes) instead of
  // failing fast. Only a few tests happened to lose this race on any given run, never a reliable repro.
  tearDown(() => rootBundle.clear());

  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  group('Sell', () {
    // A real access_token FakeState's own ProductTracking bearer check will accept - minted by actually
    // running the real `login` flow against it, the same way session_test.dart does, rather than a made-up
    // string the fake's generic branch would just 401 on.
    late final FlowSpec loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());

    testWidgets('an unconfirmed reply keeps the cart and refuses to call it safe to retry', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      // A 200 whose body decodes to JSON null - the generic branch returns exactly `data[path]` on a hit, and
      // this key exists (with a null value), so it's a 200, not the 404 the previous test relies on. sale.yaml's
      // own then_require then rejects `created` (null) as unconfirmed - the real "got a 200, still don't know
      // for sure" case classifySaleFailure treats as uncertain, the same as a 5xx.
      fake.data['CreateSalesRecords/false'] = null;

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(find.textContaining('NOT safe to just try again'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing); // the line is still there either way
    });

    // SM-12: the reported bug. The phone had sent the sale and the connection dropped before the answer came
    // back; the dialog said "not sent, safe to try again".
    Future<void> sellWith(WidgetTester tester, FakeState fake, Map<String, Object?> login) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
    }

    testWidgets('a connection reset after the sale was sent is uncertain, never "safe to try again"', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.override['CreateSalesRecords/false'] =
          (req) async => throw const SocketException('Connection reset by peer', osError: OSError('Connection reset by peer', 104));

      await sellWith(tester, fake, login);
      await tester.pumpAndSettle();

      expect(fake.posted, hasLength(1)); // it really was sent
      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(find.textContaining('safe to try again'), findsNothing);
      expect(find.textContaining('NOT safe to just try again'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing);
    });

    testWidgets('a state system that never answers stops after 60 s as uncertain, not a spinner forever', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.override['CreateSalesRecords/false'] = (req) => Completer<http.Response>().future;

      String? queuedReason;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          queuedReason = reason;
        },
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      // Not pumpAndSettle: the Sell button's spinner never settles while the request is outstanding. The test
      // clock is advanced by hand instead, so the real 60 s from sale.yaml is what is being tested.
      await tester.pump();
      await tester.pump(const Duration(seconds: 59));
      expect(fake.posted, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsWidgets); // still waiting just before the limit
      expect(find.text('The sale may or may not have been recorded'), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(find.textContaining('within 60 s'), findsOneWidget);
      expect(queuedReason, startsWith('[uncertain]'));
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing);
    });

    testWidgets('a failed host lookup (nothing left the phone) is still "not sent, safe to try again"', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.override['CreateSalesRecords/false'] =
          (req) async => throw const SocketException("Failed host lookup: 'psilocybin.oregon.gov'");

      await sellWith(tester, fake, login);
      await tester.pumpAndSettle();

      expect(find.text('The sale was not sent'), findsOneWidget);
      expect(find.textContaining('safe to try again'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    testWidgets('a 200 with two different sale numbers for one sale is uncertain (SM-D2)', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [
        {'id': 9001, 'saleNumber': 'S-1'},
        {'id': 9002, 'saleNumber': 'S-2'},
      ];
      final twoLots = [
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 1.0, quantity: 1),
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 105, weightPerUnit: 5.0, analyteWeight: 1.0, quantity: 10),
      ];
      String? queuedReason;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => twoLots,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          queuedReason = reason;
        },
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '10.00'); // splits across both lots: two records
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect((fake.posted.single.$2 as List), hasLength(2));
      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(queuedReason, startsWith('[uncertain]'));
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing);
    });

    testWidgets('a 200 whose body does not look like confirmed sale records is treated as uncertain and queued', (tester) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      // A non-empty, JSON-decodable, status-200 body that still isn't what a confirmed sale looks like - not a
      // list of created records, each with its own saleNumber. A plain truthy check (flow_runner.dart's own
      // then_require) waves this through; selling.dart's looksLikeConfirmedSale is the second check that
      // catches it.
      fake.data['CreateSalesRecords/false'] = {'ok': true};

      String? queuedReason;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          queuedReason = reason;
        },
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(find.text('The sale may or may not have been recorded'), findsOneWidget);
      expect(queuedReason, contains('uncertain'));

      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing); // never cleared - this was never confirmed
    });

    testWidgets('the state system being unreachable while renewing mid-sale does not sign the worker out, and queues it',
        (tester) async {
      final loginFake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: loginFake.client());

      var fakeNow = DateTime.now();
      final session = Session(
        accessToken: login['access_token'] as String,
        refreshToken: login['refresh_token'] as String,
        email: 'worker@example.com',
        expiresAtMs: fakeNow.millisecondsSinceEpoch + 3600 * 1000,
      );

      // Answers the renewal's own token request with a 503 (the state system erroring, not refusing the
      // grant) and nothing else - this test never expects an actual sale attempt to be made at all, since
      // renewing the session is what fails, before the sale flow is ever reached.
      http.Client unreachableDuringRenewal() => http_testing.MockClient((req) async {
            if (req.url.path.endsWith('/oauth2/v2.0/token')) return http.Response('', 503);
            throw StateError('unexpected request in this test: ${req.url}');
          });

      String? queuedReason;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: session,
        now: () => fakeNow,
        // The real sign-in spec, so the renewal really sends its token request and meets the 503. With the empty
        // dummySpec there is no `renew` flow at all ("no such flow", a stage-null FlowError): once a spec mistake
        // rather than an outage (fix round 2), that signs the worker out, which is right for a spec that can't renew.
        spec: loginSpec,
        httpClientFactory: unreachableDuringRenewal,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          queuedReason = reason;
        },
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      fakeNow = fakeNow.add(const Duration(hours: 2)); // now within the refresh margin

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      // Never signed out - this was never a dead session, just an unreachable state system.
      expect(find.widgetWithText(AppBar, 'Mazama sign-in'), findsNothing);
      expect(find.text('The sale was not sent'), findsOneWidget);
      expect(queuedReason, contains('notSent'));

      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing); // the line is still there - nothing was sent
    });

    // Round 3 A: a renew spec fetched from Mazama's server could capture a token under another name and put it in its
    // error text; the failed-sale report carries a fixed text instead, and the worker still sees the message.
    for (final (status, expected) in [
      (400, "the state's sign-in session expired"),
      (503, "[notSent] the state's sign-in could not be renewed"),
    ]) {
      testWidgets('a renew error carrying a captured token (HTTP $status) never reaches the failed-sale report',
          (tester) async {
        const leaked = 'LEAKED-OTHER-TOKEN-1234';
        final leakySpec = FlowSpec.fromYaml('''
format: 1
vars:
  spec_version: "2026-10-24.3"
flows:
  login:
    - id: token
      type: request
      method: POST
      url: "https://oregonpsilocybinprodb2c.b2clogin.com/token"
      form: {email: "{{email}}", password: "{{password}}"}
      extract:
        - {var: access_token, source: body, json: access_token}
  renew:
    - id: token
      type: request
      method: POST
      url: "https://oregonpsilocybinprodb2c.b2clogin.com/token"
      form: {refresh_token: "{{refresh_token}}"}
      require:
        - check: status_in
          values: [200]
          error: "refused {{leak}} (HTTP {status})"
      capture_on_fail:
        - {var: leak, source: body, json: other_token}
      extract:
        - {var: access_token, source: body, json: access_token}
''');
        var fakeNow = DateTime.now();
        final session = Session(
          accessToken: 'TOKEN',
          refreshToken: 'REFRESH',
          email: 'worker@example.com',
          expiresAtMs: fakeNow.millisecondsSinceEpoch + 3600 * 1000,
        );
        http.Client leakyRenewal() => http_testing.MockClient((req) async {
              if (req.url.path == '/token') return http.Response(jsonEncode({'other_token': leaked}), status);
              throw StateError('unexpected request in this test: ${req.url}');
            });
        final reasons = <String>[];
        await tester.pumpWidget(cartPage(
          fetchPackages: (id) async => inventory,
          session: session,
          now: () => fakeNow,
          spec: leakySpec,
          httpClientFactory: leakyRenewal,
          postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
            reasons.add(reason);
          },
        ));
        await tester.pumpAndSettle();
        await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
        fakeNow = fakeNow.add(const Duration(hours: 2)); // now within the refresh margin

        await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
        await tester.pumpAndSettle();

        expect(reasons, [expected]);
        expect(reasons.single, isNot(contains(leaked)));
        if (status == 400) {
          // A refused renewal still sends the worker to sign-in with the message (on screen only).
          expect(find.widgetWithText(AppBar, 'Mazama sign-in'), findsOneWidget);
          expect(find.textContaining(leaked), findsOneWidget);
        } else {
          expect(find.text('The sale was not sent'), findsOneWidget);
          await tester.tap(find.widgetWithText(FilledButton, 'OK'));
          await tester.pumpAndSettle();
        }
      });
    }

    testWidgets('the Sell button is disabled while the cart is empty', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();

      final sellButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell'));
      expect(sellButton.onPressed, isNull);
    });

    testWidgets('a SessionExpired during the sale itself queues the failed sale and still goes to sign-in', (tester) async {
      // No refresh token at all, so ensureFreshSession throws SessionExpired the instant it decides renewal is
      // needed - no network call, no FakeState involved (this is deliberately the login/auth-shaped failure,
      // not an ordinary refused sale, so it never reaches the state system at all). Starts at a `now` the
      // session reads as fresh (so initState's own immediate _maybeRenewSession check, and the identical check
      // CartPage's constructor-default periodic timer would make, both see "not expired yet" and do nothing) -
      // moved to "expired" only after the page has loaded, right before Sell is tapped, so the one check inside
      // _sell itself is the only one that ever sees it as expired. This is exactly the gap CartPage.now exists
      // to let a test control, since nothing on this page can fast-forward the real wall clock.
      var fakeNow = DateTime.now();
      final session = Session(accessToken: 'TOKEN', refreshToken: null, email: 'worker@example.com', expiresAtMs: fakeNow.millisecondsSinceEpoch + 3600 * 1000);

      int calls = 0;
      int? queuedStateId;
      String? queuedEmail;
      String? queuedDeviceId;
      String? queuedReason;
      List<Map<String, Object?>>? queuedRequest;

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: session,
        now: () => fakeNow,
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          calls++;
          queuedStateId = stateId;
          queuedEmail = workerEmail;
          queuedDeviceId = deviceId;
          queuedReason = reason;
          queuedRequest = request;
        },
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      // Now within REFRESH_MARGIN of (in fact, well past) expiry - only _sell's own renewal check has run since.
      fakeNow = fakeNow.add(const Duration(hours: 2));

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(queuedStateId, 231); // this cart's own center id
      expect(queuedEmail, 'worker@example.com');
      expect(queuedDeviceId, isNotEmpty); // this install's own id (device_id.dart), not a hardware identifier
      expect(queuedReason, contains('expired'));
      expect(queuedRequest, hasLength(1));
      expect(queuedRequest!.single['productGuid'], 'PKPR-ab12c');

      // The worker still ends up back at sign-in, exactly as if _queueFailedSale didn't exist at all.
      expect(find.widgetWithText(AppBar, 'Mazama sign-in'), findsOneWidget);
    });

    testWidgets('a postSaleFailure failure never blocks or changes the trip back to sign-in', (tester) async {
      var fakeNow = DateTime.now();
      final session = Session(accessToken: 'TOKEN', refreshToken: null, email: 'worker@example.com', expiresAtMs: fakeNow.millisecondsSinceEpoch + 3600 * 1000);

      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        session: session,
        now: () => fakeNow,
        // Deliberately always throws - this is the one thing _queueFailedSale exists to swallow. If this ever
        // escapes, the test fails loudly on an unhandled exception rather than quietly passing.
        postSaleFailure: (stateId, {required workerEmail, required deviceId, required reason, required request}) async {
          throw SaleFailureError('sale-failure server unreachable');
        },
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      fakeNow = fakeNow.add(const Duration(hours: 2));

      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Mazama sign-in'), findsOneWidget);
    });
  });

  group('bulk sell (specs/multi-cart MC-D8 to MC-D13)', () {
    late final FlowSpec loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
    final ab12cRecord = <String, Object?>{
      'id': 101, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5.0, 'analyteWeight': 4.5,
      'quantity': 10, 'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false, 'pendingTransfer': false,
    };

    /// Opens the cart (the state's stock readable only once the page has loaded, as [reread] answers), adds 2 x
    /// PKPR-ab12c at $12.50 and long-presses the cart button. -> the fake state system, every sale answered S-1.
    Future<FakeState> openBulk(WidgetTester tester,
        {Future<List<Object?>> Function()? reread,
        Future<void> Function(int, {required String workerEmail, required String deviceId, required String reason, required List<Map<String, Object?>> request})?
            postSaleFailure}) async {
      final fake = FakeState();
      final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fake.data['CreateSalesRecords/false'] = [{'id': 9001, 'saleNumber': 'S-1'}];
      var loaded = false;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        fetchRawPackagesFromState: (id, {required accessToken}) async {
          if (!loaded) throw StatePackagesError('not read at load in this test');
          if (reread == null) return [ab12cRecord];
          return reread();
        },
        session: freshSession(accessToken: login['access_token'] as String),
        saleSpec: Future.value(realSaleSpec),
        httpClientFactory: fake.client,
        postSaleFailure: postSaleFailure,
      ));
      await tester.pumpAndSettle();
      loaded = true;
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await tester.longPress(find.byKey(const Key('cartsButton')));
      await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('long-pressing the cart button sells the cart N times, each its own sale, then clears it', (tester) async {
      final fake = await openBulk(tester);
      expect(find.text('Bulk sell Cart 1'), findsOneWidget);
      expect(find.text('Each sale: 1 line(s), 2 unit(s), \$25.00.'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, 'Number of sales'), '3');
      await tester.pumpAndSettle();
      expect(find.text('All 3 sales: 6 unit(s), \$75.00.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm 3 sales'));
      await tester.pumpAndSettle();

      expect(fake.posted, hasLength(3)); // three requests, so three sale numbers
      for (final (path, body) in fake.posted) {
        expect(path, 'CreateSalesRecords/false');
        expect(body, hasLength(1));
        expect(body.single['productGuid'], 'PKPR-ab12c');
        expect(body.single['numberSold'], 2);
        expect(body.single['productCost'], 25.0);
        expect(body.single['serviceCenterId'], 231);
      }
      expect(find.text('3 sales recorded with the state system.'), findsOneWidget);
      expect(find.text('Nothing in the cart yet.'), findsOneWidget);
    });

    testWidgets('too little stock for N sales, or too many sales, is refused in the dialog', (tester) async {
      final fake = await openBulk(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Number of sales'), '6');
      await tester.pumpAndSettle();
      expect(find.text('Only 10 of PKPR-ab12c in stock: 6 sales need 12.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);

      await tester.enterText(find.widgetWithText(TextFormField, 'Number of sales'), '51');
      await tester.pumpAndSettle();
      expect(find.text('At most $maxBulkSales sales at once.'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(fake.posted, isEmpty);
    });

    testWidgets('a sale refused part way stops the run, says how many were recorded, and keeps the cart', (tester) async {
      final reasons = <String>[];
      final fake = await openBulk(tester,
          postSaleFailure: (id, {required workerEmail, required deviceId, required reason, required request}) async =>
              reasons.add(reason));
      var calls = 0;
      fake.override['CreateSalesRecords/false'] = (req) async {
        calls++;
        return calls < 3
            ? http.Response(jsonEncode([{'id': 9000 + calls, 'saleNumber': 'S-$calls'}]), 200)
            : http.Response('', 400);
      };
      await tester.enterText(find.widgetWithText(TextFormField, 'Number of sales'), '4');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm 4 sales'));
      await tester.pumpAndSettle();

      expect(fake.posted, hasLength(3)); // the fourth was never attempted
      expect(find.text('2 of 4 sales recorded'), findsOneWidget);
      expect(find.textContaining('Sale 3 was not sent'), findsOneWidget);
      expect(find.textContaining('The other 1 sale was never attempted.'), findsOneWidget);
      expect(reasons, hasLength(1));
      expect(reasons.single, startsWith('[bulk 3 of 4] [notSent]'));

      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in the cart yet.'), findsNothing); // the cart is kept
    });

    testWidgets('the stock is always read again first: a lot locked since refuses them all, nothing sent', (tester) async {
      final locked = {...ab12cRecord, 'locked': true, 'reasonLocked': 'Recall 2026-10'};
      final fake = await openBulk(tester, reread: () async => [locked]);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm 2 sales'));
      await tester.pumpAndSettle();

      expect(fake.posted, isEmpty);
      expect(find.text('The sales were not sent'), findsOneWidget);
      expect(find.textContaining(saleLineRefusal(locked, 'PKPR-ab12c', 4)!), findsOneWidget);
    });

    testWidgets('long-pressing with an empty cart says so and opens nothing', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const Key('cartsButton')));
      await tester.pumpAndSettle();
      expect(find.text('Bulk sell: add items to the cart first.'), findsOneWidget);
      expect(find.text('Number of sales'), findsNothing);
    });
  });

  group('sessionTimeLeftText (MC-D14)', () {
    test('the session table length less the time elapsed, the booster named only when there is one', () {
      expect(sessionTimeLeftText(22.5, const Duration(minutes: 7), booster: false), '3:53:00 left');
      expect(sessionTimeLeftText(45, const Duration(minutes: 30), booster: true), '5:30:00 left w/ booster');
      expect(sessionTimeLeftText(2, const Duration(minutes: 29, seconds: 30), booster: false), '00:30 left');
      // part of a second left counts as a whole one
      expect(sessionTimeLeftText(22.5, const Duration(minutes: 7, microseconds: 1), booster: false), '3:53:00 left');
      expect(sessionTimeLeftText(22.5, const Duration(hours: 3, minutes: 59, seconds: 59, milliseconds: 500), booster: false),
          '00:01 left');
    });

    test('says how far over once the time is up, and nothing over the limit per sale', () {
      expect(sessionTimeLeftText(22.5, const Duration(hours: 4), booster: false), 'Time up · 00:00 over');
      expect(sessionTimeLeftText(22.5, const Duration(hours: 4, minutes: 12), booster: false), 'Time up · 12:00 over');
      expect(sessionTimeLeftText(60, Duration.zero, booster: false), isNull);
    });
  });

  testWidgets("a cart add whose lab report can't reach the server keeps the lot for later; another failure doesn't",
      (tester) async {
    final kept = <(int, String, int, double?)>[];
    final pkgs = [
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5,
          strain: 'Golden Teacher', tpeMg: 5, quantity: 10, lotGuid: 'HB-aaaa0001', coaAvailable: false),
      Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0,
          strain: 'Enigma', tpeMg: 90, quantity: 3, lotGuid: 'HB-bbbb0002', labelAvailable: false),
    ];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => pkgs,
      submitCoaForLot: ({required lotGuid, required representativePackageId, required accessToken, required workerEmail,
          required deviceId, statePsilocybin}) async {
        if (lotGuid == 'HB-aaaa0001') throw CoaDataError('cannot reach sales.mazamamushrooms.com', unreachable: true);
        throw CoaDataError('Not a PDF.'); // the server's own refusal: not kept
      },
      keepCoaLotForLater: (stateId, {required lotGuid, required packageId, statePsilocybin}) =>
          kept.add((stateId, lotGuid, packageId, statePsilocybin)),
    ));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10');
    await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '10');
    expect(kept, [(231, 'HB-aaaa0001', 101, 4.5)]);
  });

  // README R64: the phone fetches a lab report from the state system only when the server has no COA for the lot. A lot
  // whose COA the server has but whose label it hasn't drawn yet costs no state calls: the server draws the label itself.
  testWidgets('a cart add submits a lab report only for a lot the server has no COA for', (tester) async {
    final submitted = <String>[];
    final pkgs = [
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5,
          strain: 'Golden Teacher', tpeMg: 5, quantity: 10, lotGuid: 'HB-aaaa0001', coaAvailable: false, labelAvailable: false),
      Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0,
          strain: 'Enigma', tpeMg: 90, quantity: 3, lotGuid: 'HB-bbbb0002', labelAvailable: false),
    ];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => pkgs,
      submitCoaForLot: ({required lotGuid, required representativePackageId, required accessToken, required workerEmail,
          required deviceId, statePsilocybin}) async {
        submitted.add(lotGuid);
        return null;
      },
    ));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10');
    await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '10');
    expect(submitted, ['HB-aaaa0001']);
  });

  testWidgets("a cart add doesn't submit a lot the background uploader already has waiting or under way", (tester) async {
    final submitted = <String>[];
    final pkgs = [
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5,
          strain: 'Golden Teacher', tpeMg: 5, quantity: 10, lotGuid: 'HB-aaaa0001', coaAvailable: false),
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 103, weightPerUnit: 5.0, analyteWeight: 4.5,
          strain: 'Golden Teacher', tpeMg: 5, quantity: 10, lotGuid: 'HB-cccc0003', coaAvailable: false),
    ];
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => pkgs,
      coaUploadPending: (lotGuid) => lotGuid == 'HB-aaaa0001',
      submitCoaForLot: ({required lotGuid, required representativePackageId, required accessToken, required workerEmail,
          required deviceId, statePsilocybin}) async {
        submitted.add(lotGuid);
        return null;
      },
    ));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10');
    expect(submitted, ['HB-cccc0003']);
  });
}
