import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/app_installer.dart';
import 'package:mazama_mobile/app_update_check.dart';
import 'package:mazama_mobile/app_update_store.dart';
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/center_home_page.dart';
import 'package:mazama_mobile/center_stock_page.dart';
import 'package:mazama_mobile/device_id.dart';
import 'package:mazama_mobile/features.g.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/mazama_inventory_page.dart';
import 'package:mazama_mobile/order_form_page.dart';
import 'package:mazama_mobile/order_par_page.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/resilience_options.dart';
import 'package:mazama_mobile/sales_page.dart';
import 'package:mazama_mobile/select_center_page.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/session_store.dart';
import 'package:mazama_mobile/sheets_client.dart';
import 'package:mazama_mobile/state_packages_client.dart';
import 'package:mazama_mobile/stock_mix.dart';
import 'package:mazama_mobile/stock_summary.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/updated_line.dart';

import 'app_release_signing.dart';
import 'features_off.dart';
import 'temp_app_data_dir.dart';

License _license(int id, String name, String type) =>
    License(id: id, licenseId: 'L-$id', licenseName: name, licenseType: type);

Future<List<Package>> _noPackages(int stateId) async => [];

// The REAL default for SelectCenterPage.fetchRawPackagesFromState is a live network call, forwarded straight
// through to whichever CartPage this page opens - see that field's own doc comment and cart_page_test_support.dart's
// own fetchRawPackagesFromState fixture for why this is no longer a tier-2-only fallback a test can just never
// reach: CartPage's _fetchMergedForCart calls it on every configured-center load. Every test below that taps or
// auto-opens through to a CartPage needs this wired or it hangs on a real (and in a test sandbox, unreachable)
// network call.
Future<List<Object?>> _noRawState(int stateId, {required String accessToken}) async =>
    throw StatePackagesError('no raw-state fixture wired for this test');

// Far from expiry - none of these tests exercise ensureFreshSession's renewal path (see session_test.dart for
// that), so _ensureFreshThenFetch's own startup check returns immediately with no network call, same as every
// other widget test in this app not wanting to depend on flow_runner.dart/fake_state.dart machinery it isn't
// testing.
Session _freshSession() =>
    Session(accessToken: 'TOKEN', refreshToken: 'REFRESH', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

final _dummySpec = FlowSpec(const {}, const {});

late Directory _tempDir;

/// MI-R3: the Mazama inventory page loads as soon as a center's home opens; a fixed mix, never the network.
Future<MazamaInventory> _mazamaMix() async =>
    const MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [MixCell(strain: 'Golden Teacher', type: 'DH', mg: 3888)]);

/// SP-D11: the stock page's product information sheets load with it; a fixed list, never the network.
Future<List<ProductSheet>> _sheets(int stateId) async => const [
      ProductSheet(guid: 'HB-aaaa0001', name: 'GT 6.26', product: 'Whole Fungi', tested: 'Aug 27, 2026',
          path: '/p/lots/mazama/HB-aaaa0001', strains: ['Golden Teacher']),
    ];

void main() {
  useTempAppDataDir();
  // Same rootBundle.loadString Future-caching race widget_test.dart and the cart_page_*_test.dart files guard against:
  // with exactly one license, this page auto-opens a CartPage, which loads assets/flows/sale.yaml via
  // rootBundle unless saleSpec: is given - clear the cache between tests so a later test can't be left
  // awaiting an earlier test's already-resolved (and wrong-zone) Future.
  tearDown(() => rootBundle.clear());

  setUp(() => _tempDir = Directory.systemTemp.createTempSync('mazama_select_center_test_'));
  tearDown(() {
    LocalStore.debugCloseAll();
    _tempDir.deleteSync(recursive: true);
  });

  SessionStore sessionStore() => SessionStore(dataDir: () => _tempDir);

  testWidgets('with exactly one service-center license, it skips the picker and opens the cart', (tester) async {
    var packagesCalledWith = -1;
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => const [],
        fetchLicenses: (token) async {
          expect(token, 'TOKEN');
          return [_license(294, 'Mazama Mushrooms LLC', 'Manufacturer'), _license(231, 'Bendable Service Center', 'ServiceCenter')];
        },
        fetchCenterPackages: (stateId) async {
          packagesCalledWith = stateId;
          return [];
        },
        fetchRawPackagesFromState: _noRawState,
      ),
    ));
    await tester.pumpAndSettle();

    // Only one ServiceCenter license (294 is a Manufacturer, filtered out) - auto-opens straight to its home
    // page (SP-D8), on Stock, with the cart built beside it.
    expect(find.byType(CenterHomePage), findsOneWidget);
    expect(find.byType(CenterStockPage), findsOneWidget); // on Stock (no title bar of its own: the tab is its title)
    expect(tester.widget<CenterHomePage>(find.byType(CenterHomePage)).center.id, 231);
    expect(find.byType(CartPage, skipOffstage: false), findsOneWidget);
    expect(packagesCalledWith, 231);
  });

  testWidgets('resilienceOptions is forwarded unchanged to the CartPage it opens', (tester) async {
    const options = ResilienceOptions(enableStateFallback: false, cacheMaxAge: Duration(hours: 6));
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => const [],
        fetchLicenses: (token) async => [_license(231, 'Bendable Service Center', 'ServiceCenter')],
        fetchCenterPackages: _noPackages,
        resilienceOptions: options,
        fetchRawPackagesFromState: _noRawState,
      ),
    ));
    await tester.pumpAndSettle();

    final cartPage = tester.widget<CartPage>(find.byType(CartPage, skipOffstage: false));
    expect(cartPage.resilienceOptions.enableStateFallback, isFalse);
    expect(cartPage.resilienceOptions.cacheMaxAge, const Duration(hours: 6));
  });

  testWidgets('with more than one service-center license, it shows a picker', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => const [],
        fetchLicenses: (token) async => [
          _license(225, 'Unstuck Psilocybin Treatment Center', 'ServiceCenter'),
          _license(183, 'EPIC Healing Eugene', 'ServiceCenter'),
          _license(231, 'Bendable Service Center', 'ServiceCenter'),
        ],
        fetchCenterPackages: _noPackages,
        fetchRawPackagesFromState: _noRawState,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Choose a service center'), findsOneWidget);
    expect(find.text('Unstuck Psilocybin Treatment Center'), findsOneWidget);
    expect(find.text('EPIC Healing Eugene'), findsOneWidget);
    expect(find.text('Bendable Service Center'), findsOneWidget);

    await tester.tap(find.text('EPIC Healing Eugene'));
    await tester.pumpAndSettle();
    expect(tester.widget<CenterHomePage>(find.byType(CenterHomePage)).center.id, 183); // its home, on Stock
    expect(find.byType(CenterStockPage), findsOneWidget);
    expect(find.text('Choose a service center'), findsNothing);
  });

  testWidgets('the stock page shows the server\'s stock; Order sets par first, saved as this worker on this device',
      (tester) async {
    final deviceIds = DeviceIdStore(dataDir: () => _tempDir);
    final saved = <(int, String, String, List<ParLevel>)>[];
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => const [],
        fetchLicenses: (token) async => [_license(231, 'Bendable Service Center', 'ServiceCenter')],
        fetchCenterPackages: (id) async => [
          Package(productGuid: 'PKPR-gt25', productType: 'Edible', id: 1, weightPerUnit: 1, analyteWeight: 25, strain: 'Golden Teacher',
              tpeMg: 25, quantity: 10, mazama: true, unitMgTpe: 25, description: 'Golden Teacher 25 mg'),
          Package(productGuid: 'PKPR-old', productType: 'Edible', id: 2, weightPerUnit: 1, analyteWeight: 25, strain: 'Golden Teacher',
              tpeMg: 25, quantity: 4, mazama: true, expired: true, unitMgTpe: 25, description: 'Golden Teacher 25 mg (2020-01-01)'),
        ],
        fetchRawPackagesFromState: _noRawState,
        fetchParLevels: (id) async {
          expect(id, 231);
          return const [ParLevel(strain: 'Golden Teacher', size: 25, par: 12)];
        },
        saveParLevels: (id, {required workerEmail, required deviceId, required levels}) async {
          saved.add((id, workerEmail, deviceId, levels));
          return levels;
        },
        deviceIdStore: deviceIds,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(CenterStockPage), findsOneWidget);
    expect(find.text('10 units'), findsOneWidget); // the expired package is other stock
    expect(find.text('250 mg TPE'), findsOneWidget); // the server's exact mg TPE per unit
    expect(find.text('Other stock (1)'), findsOneWidget);
    expect(find.text('Par levels'), findsNothing); // SP-D19: par is set when ordering, not on the stock page

    // MI-D21: Order (on the Mazama page) opens the par step first, with the same stock and the server's par.
    await tester.tap(find.text('Mazama'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('order-button')));
    await tester.pumpAndSettle();
    expect(find.byType(OrderParPage), findsOneWidget);
    expect(find.text('10 / 12'), findsOneWidget); // its size from the product name; the expired package isn't counted
    final edit = find.text('Edit par levels');
    await tester.ensureVisible(edit);
    await tester.pumpAndSettle();
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('par-Golden Teacher-25')), '15');
    final save = find.text('Save and continue');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    final (id, email, deviceId, levels) = saved.single;
    expect(id, 231);
    expect(email, 'worker@example.com');
    expect(deviceId, await deviceIds.idOrCreate());
    expect(levels.map((l) => '${l.strain}|${l.size}|${l.par}'), ['Golden Teacher|25|15']);
    // The order form, starting from the levels just saved; they are kept on the phone for offline too.
    expect(find.byType(OrderFormPage), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('qty-Golden Teacher|25'))).controller!.text, '15');
    final kept = (await parDataset(Datasets.forDir(() => _tempDir), 231).load())!; // the par dataset (specs/phone-sync)
    expect(kept.value.single.par, 15);
  });

  testWidgets('with the server unreachable the stock page draws the state\'s records, partial, with the kept licenses',
      (tester) async {
    // kept by an older build (stock_cache_store.dart, removed in Task 10): moved into the datasets on the first open
    LocalStore.forDir(_tempDir).write(
        'stock_cache_231.json',
        jsonEncode({
          'mazamaLicenses': ['mf-1e72fc8f'],
          'par': [const ParLevel(strain: 'Unknown', size: 25, par: 12).toJson()],
        }));
    final tokens = <String>[];
    // The session as last saved (the cart renews and saves it): its token is the one the state read uses.
    await sessionStore().save(Session(
            accessToken: 'SAVED', refreshToken: 'REFRESH', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000)
        .toJson());
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => throw Exception('the server is down'),
        fetchLicenses: (token) async => [_license(231, 'Bendable Service Center', 'ServiceCenter')],
        fetchCenterPackages: (id) async => throw PackagesError('cannot reach sales.mazamamushrooms.com'),
        fetchRawPackagesFromState: (id, {required accessToken}) async {
          tokens.add(accessToken);
          return [
            {'id': 1, 'productGuid': 'PKPR-a', 'manufacturerLicenseId': 'MF-1e72fc8f', 'description': 'GT 25 mg TPE CH',
             'quantity': 10, 'weightPerUnit': 0.5, 'analyteWeight': 10},
            {'id': 2, 'productGuid': 'PKPR-b', 'manufacturerLicenseId': 'MF-other', 'description': 'X 25 mg TPE CH',
             'quantity': 4, 'weightPerUnit': 0.5, 'analyteWeight': 10},
          ];
        },
        fetchParLevels: (id) async => throw const SocketException('the server is down'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tokens, contains('SAVED')); // ensureFreshSession on the saved session: fresh, so used as it is
    expect(find.byType(CenterStockPage), findsOneWidget);
    expect(find.textContaining('Partial'), findsNothing); // R87: the app-wide banner says the server can't be reached
    expect(find.text('14 units'), findsOneWidget);
    // The mg pie is a swipe away from the units pie.
    await tester.drag(find.byKey(const ValueKey('stock-pies')), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('mg psilocybin in stock (state figures; TPE needs the server)'), findsOneWidget);

    final mazamaOnly = find.text('Mazama only');
    await tester.ensureVisible(mazamaOnly);
    await tester.tap(mazamaOnly);
    await tester.pumpAndSettle();
    expect(find.text('10 units'), findsOneWidget); // the kept license tells Mazama's product apart

    // MI-D21: the par step shows the kept par levels read-only; they can still be confirmed for the order.
    await tester.tap(find.text('Mazama'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('order-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('last sent'), findsNothing); // no notice of the page's own (R87)
    expect(
        find.text("Mazama's server can't be reached, so par levels can't be saved now - try again later. "
            'The order starts from the par levels above.'),
        findsOneWidget);
    expect(find.text('Edit par levels'), findsNothing);
    final go = find.byKey(const ValueKey('par-continue'));
    await tester.ensureVisible(go);
    await tester.pumpAndSettle();
    await tester.tap(go);
    await tester.pumpAndSettle();
    expect(find.byType(OrderFormPage), findsOneWidget);
  });

  testWidgets('choosing a center opens the home page', (tester) async {
    final salesReads = <(int, String)>[];
    final salesUploads = <(int, int, String)>[];
    final today = DateTime.now().toUtc().toIso8601String();
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => const [],
        fetchLicenses: (token) async => [
          _license(225, 'Unstuck Psilocybin Treatment Center', 'ServiceCenter'),
          _license(183, 'EPIC Healing Eugene', 'ServiceCenter'),
        ],
        fetchCenterPackages: _noPackages,
        fetchRawPackagesFromState: _noRawState,
        fetchSalesRecords: (id, {required accessToken}) async {
          salesReads.add((id, accessToken));
          return [
            {'id': 1, 'saleNumber': 'S-0001', 'dateOfSale': today, 'productName': 'GT 5 mg', 'numberSold': 1, 'productCost': 25},
          ];
        },
        uploadSalesSnapshot: (id, records, {required workerEmail, required deviceId}) async {
          salesUploads.add((id, records.length, workerEmail));
          return const {'rows': 1, 'skipped': 0};
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EPIC Healing Eugene'));
    await tester.pumpAndSettle();

    final home = tester.widget<CenterHomePage>(find.byType(CenterHomePage));
    expect(home.center.id, 183);
    expect(find.byType(CenterStockPage), findsOneWidget); // opens on Stock
    // SP-D18: the lot table in place of the sheets list, closed, its rows the center's sheets
    expect(find.byKey(const ValueKey('stock-lot-table'), skipOffstage: false), findsOneWidget);
    expect(find.text('1 lot · 1 strain', skipOffstage: false), findsOneWidget);
    expect(find.text('Stock'), findsOneWidget);
    expect(find.text('Cart'), findsOneWidget);

    // MI-D1: Mazama inventory (its tab labelled "Mazama") sits left of Stock, built beside it, loaded from
    // fetchMazamaInventory.
    await tester.tap(find.text('Mazama'));
    await tester.pumpAndSettle();
    expect(find.byType(MazamaInventoryPage), findsOneWidget);
    expect(find.byKey(const ValueKey('order-button')), findsOneWidget); // MI-D6
    expect(find.text('3,888 mg TPE in all'), findsOneWidget);
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cart'));
    await tester.pumpAndSettle();
    expect(find.byType(CartPage), findsOneWidget);
    expect(find.text('EPIC Healing Eugene'), findsOneWidget); // the cart's own AppBar title
    expect(salesReads, isEmpty); // review I-1: nothing of the Sales page runs while the worker is on the Cart
    expect(salesUploads, isEmpty);

    // specs/center-web CW-R10: Sales, right of Cart: the center's sales read with the session's token, every record
    // uploaded as the signed-in worker.
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    final sales = tester.widget<SalesPage>(find.byType(SalesPage));
    expect(sales.stateId, 183);
    expect(sales.demo, isFalse);
    expect(find.text('S-0001'), findsOneWidget);
    expect(salesReads, [(183, 'TOKEN')]);
    expect(salesUploads, [(183, 1, 'worker@example.com')]);
  });

  // SM-21: the picker lists what the server's directory.service_centers would keep - an id once, never id 0.
  testWidgets('the picker lists each usable service center once', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => const [],
        fetchLicenses: (token) async => [
          _license(225, 'Unstuck Psilocybin Treatment Center', 'ServiceCenter'),
          _license(225, 'Unstuck again', 'ServiceCenter'),
          _license(0, 'No id', 'ServiceCenter'),
          _license(183, 'EPIC Healing Eugene', 'ServiceCenter'),
        ],
        fetchCenterPackages: _noPackages,
        fetchRawPackagesFromState: _noRawState,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Choose a service center'), findsOneWidget);
    expect(find.text('Unstuck Psilocybin Treatment Center'), findsOneWidget);
    expect(find.text('EPIC Healing Eugene'), findsOneWidget);
    expect(find.text('Unstuck again'), findsNothing);
    expect(find.text('No id'), findsNothing);
  });

  testWidgets('the debug-diagnostics icon opens the debug tools hub, and its Adhoc-COA entry opens the real page '
      'pre-filled with the first loaded center', (tester) async {
    // kDebugMode is always true under `flutter test` (it mirrors assert()'s own on/off switch) - this icon
    // is unconditionally present here, the same way it would be in a real debug build. select_center_page.dart
    // itself is what makes it disappear from a profile/release build, not anything this test can toggle.
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => const [],
        fetchLicenses: (token) async => [
          _license(225, 'Unstuck Psilocybin Treatment Center', 'ServiceCenter'),
          _license(183, 'EPIC Healing Eugene', 'ServiceCenter'),
        ],
        fetchCenterPackages: _noPackages,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bug_report_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Debug tools'), findsOneWidget);
    await tester.tap(find.text('Adhoc-COA diagnostics'));
    await tester.pumpAndSettle();

    expect(find.text('Adhoc-COA diagnostics (debug)'), findsOneWidget);
    expect((tester.widget(find.byType(TextField)) as TextField).controller!.text, '225'); // the first loaded center
  });

  testWidgets('a license fetch error shows a retry button', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => const [],
        fetchLicenses: (token) async {
          attempts += 1;
          throw Exception('cannot reach the state system');
        },
        fetchCenterPackages: _noPackages,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot reach the state system'), findsOneWidget);
    expect(attempts, 1);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  // specs/phone-sync PS-R3: the licenses dataset.
  group("the worker's licenses kept on the phone (specs/phone-sync PS-R3, PS-R7)", () {
    late Object? failWith;
    late int attempts;
    late Completer<void>? gate;
    setUp(() {
      failWith = null;
      attempts = 0;
      gate = null;
    });
    Widget page({String email = 'worker@example.com'}) => MaterialApp(
          home: SelectCenterPage(
            session: Session(
                accessToken: 'TOKEN',
                refreshToken: 'REFRESH',
                email: email,
                expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000),
            spec: _dummySpec,
            sessionStore: sessionStore(),
            fetchMazamaInventory: _mazamaMix,
            fetchProductSheets: _sheets,
            fetchMazamaLicenses: (id) async => const [],
            fetchLicenses: (token) async {
              attempts += 1;
              final g = gate;
              if (g != null) await g.future;
              final f = failWith;
              if (f != null) throw f;
              return [
                _license(231, 'Bendable Service Center', 'ServiceCenter'),
                _license(183, 'Second Service Center', 'ServiceCenter'),
              ];
            },
            fetchCenterPackages: _noPackages,
          ),
        );

    testWidgets('shown at once, with their age, while the state is asked', (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.byKey(updatedLineKey), findsNothing); // the state's answer just now: no age to show
      gate = Completer<void>(); // the next read waits
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());
      await tester.pump();
      expect(find.text('Second Service Center'), findsOneWidget); // before the state answers
      expect(find.text('Updated just now'), findsOneWidget);
      gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(updatedLineKey), findsNothing); // the fresh answer now
    });

    testWidgets("the state can't be reached: they stay, with their age, and Try again reads again", (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      failWith = LicensesError('cannot reach oregonpsilocybinprodb2c.b2clogin.com: SocketException', unreachable: true);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('Bendable Service Center'), findsOneWidget);
      expect(find.text('Updated just now'), findsOneWidget);
      expect(find.textContaining('cannot reach'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('licenses-retry')));
      await tester.pumpAndSettle();
      expect(attempts, 3);
    });

    testWidgets("the state's refusal is the error, not the kept list", (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      failWith = LicensesError('GET licenses failed: HTTP 403');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP 403'), findsOneWidget);
      expect(find.text('Bendable Service Center'), findsNothing);
    });

    testWidgets('pulling the list down reads the licenses again (PS-R7)', (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(attempts, 1);
      final refresh = tester.widget<RefreshIndicator>(find.byKey(const ValueKey('licenses-refresh'))).onRefresh;
      await refresh();
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('Second Service Center'), findsOneWidget);
    });

    testWidgets("another worker on this phone never sees the previous worker's centers", (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      failWith = LicensesError('cannot reach the state system: SocketException', unreachable: true);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page(email: 'someone.else@example.com'));
      await tester.pump();
      expect(find.text('Bendable Service Center'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Bendable Service Center'), findsNothing);
      expect(find.textContaining('cannot reach the state system'), findsOneWidget);
    });
  });

  testWidgets('no service-center license at all shows a clear message, not an empty picker', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SelectCenterPage(
        session: _freshSession(),
        spec: _dummySpec,
        sessionStore: sessionStore(),
        fetchMazamaInventory: _mazamaMix,
        fetchProductSheets: _sheets,
        fetchMazamaLicenses: (id) async => const [],
        fetchLicenses: (token) async => [_license(294, 'Mazama Mushrooms LLC', 'Manufacturer')],
        fetchCenterPackages: _noPackages,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('no service-center access'), findsOneWidget);
  });

  // specs/features FR-3: the picker and the Order button follow the feature registry.
  Widget picker(List<License> licenses, {Map<String, Feature> featureTable = features}) => MaterialApp(
        home: SelectCenterPage(
          session: _freshSession(),
          spec: _dummySpec,
          sessionStore: sessionStore(),
          fetchMazamaInventory: _mazamaMix,
          fetchProductSheets: _sheets,
          fetchMazamaLicenses: (id) async => const [],
          fetchLicenses: (token) async => licenses,
          fetchCenterPackages: _noPackages,
          fetchRawPackagesFromState: _noRawState,
          featureTable: featureTable,
        ),
      );

  final twoCentersAndMazama = [
    _license(294, 'Mazama Mushrooms LLC', 'Manufacturer'),
    _license(225, 'Unstuck Psilocybin Treatment Center', 'ServiceCenter'),
    _license(183, 'EPIC Healing Eugene', 'ServiceCenter'),
  ];

  testWidgets('lists service centers when center features are on', (tester) async {
    await tester.pumpWidget(picker(twoCentersAndMazama));
    await tester.pumpAndSettle();
    expect(find.text('Choose a service center'), findsOneWidget);
    expect(find.text('Unstuck Psilocybin Treatment Center'), findsOneWidget);
    expect(find.text('EPIC Healing Eugene'), findsOneWidget);
  });

  testWidgets('a Manufacturer license is never listed while no manufacturer feature is on', (tester) async {
    expect(licenseTypeListed('Manufacturer'), isFalse);
    await tester.pumpWidget(picker(twoCentersAndMazama));
    await tester.pumpAndSettle();
    expect(find.text('Mazama Mushrooms LLC'), findsNothing);

    // And a service center is not listed either once nothing beyond sign-in, the picker, demo and debug
    // is on for its license type (Q3).
    final centerOff = featuresWithOff([
      for (final f in features.values)
        if (!licensePickerIgnores.contains(f.name)) f.name,
    ]);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(picker(twoCentersAndMazama, featureTable: centerOff));
    await tester.pumpAndSettle();
    expect(find.text('Unstuck Psilocybin Treatment Center'), findsNothing);
    expect(find.textContaining('no service-center access'), findsOneWidget);
  });

  // CW-R9: the inventory portal left the phone, with its button.
  testWidgets('the picker has no inventory portal button', (tester) async {
    await tester.pumpWidget(picker(twoCentersAndMazama));
    await tester.pumpAndSettle();
    expect(find.text('EPIC Healing Eugene'), findsOneWidget);
    expect(find.text('Mazama Mushrooms Inventory'), findsNothing);
    expect(find.widgetWithIcon(OutlinedButton, Icons.open_in_new), findsNothing);
    expect(find.byIcon(Icons.open_in_new), findsNothing);
  });

  testWidgets('no Order button when ordering is off', (tester) async {
    final one = [_license(231, 'Bendable Service Center', 'ServiceCenter')];
    await tester.pumpWidget(picker(one));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mazama'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('order-button')), findsOneWidget);
    expect(tester.widget<MazamaInventoryPage>(find.byType(MazamaInventoryPage)).orderForm, isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(picker(one, featureTable: featuresWithOff(['ordering'])));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mazama'));
    await tester.pumpAndSettle();
    expect(tester.widget<MazamaInventoryPage>(find.byType(MazamaInventoryPage)).orderForm, isNull);
    expect(find.byKey(const ValueKey('order-button')), findsNothing);
  });

  testWidgets('the center home it opens follows the same table', (tester) async {
    await tester.pumpWidget(picker([_license(231, 'Bendable Service Center', 'ServiceCenter')],
        featureTable: featuresWithOff(['mazama_tab'])));
    await tester.pumpAndSettle();
    expect([for (final t in tester.widget<TabBar>(find.byType(TabBar)).tabs) (t as Tab).text], ['Stock', 'Cart', 'Sales']);
    expect(find.byType(CenterStockPage), findsOneWidget);
    expect(tester.widget<CenterHomePage>(find.byType(CenterHomePage)).featureTable['mazama_tab']!.onPhone, isEmpty);
  });

  // specs/app-updates AU-D10: the update card on the license picker (no center open, so no cart holds it back).
  testWidgets('the update card shows on the picker when there is an offer, and not without one', (tester) async {
    Widget picker(AppUpdateChecker checker) => MaterialApp(
          home: SelectCenterPage(
            session: _freshSession(),
            spec: _dummySpec,
            sessionStore: sessionStore(),
            fetchMazamaInventory: _mazamaMix,
            fetchProductSheets: _sheets,
            fetchMazamaLicenses: (id) async => const [],
            fetchLicenses: (token) async => [
              _license(225, 'Unstuck Psilocybin Treatment Center', 'ServiceCenter'),
              _license(183, 'EPIC Healing Eugene', 'ServiceCenter'),
            ],
            fetchCenterPackages: _noPackages,
            fetchRawPackagesFromState: _noRawState,
            updateChecker: checker,
          ),
        );
    AppUpdateChecker checker({required bool android}) => AppUpdateChecker(
          store: AppUpdateStore(dataDir: () => _tempDir, publicKey: testPublicKey),
          installer: _UpdateInstaller(),
          fetchLatest: (_) => signedRelease(build: 26103001),
          isAndroid: android,
          isDemo: () => false,
          featureOn: () => true,
        );

    final offering = checker(android: true);
    await tester.runAsync(() => offering.check());
    await tester.pumpWidget(picker(offering));
    await tester.pumpAndSettle();
    expect(find.text('Version 0.2.4 is ready to install'), findsOneWidget);
    expect(find.text('EPIC Healing Eugene'), findsOneWidget);

    final ios = checker(android: false);
    await tester.runAsync(() => ios.check());
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(picker(ios));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-card')), findsNothing);
  });
}

class _UpdateInstaller extends AppInstaller {
  @override
  Future<InstalledApp> installed() async => const InstalledApp(
      versionName: '0.2.3',
      versionCode: 26102901,
      sdkInt: 30,
      signers: {'aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11'},
      canInstall: true);
}
