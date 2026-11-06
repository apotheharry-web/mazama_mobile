// The Mazama inventory | Stock | Cart home (lib/center_home_page.dart): opens on Stock, swipes
// and tab taps switch, the Cart label shows the draft's count. The pages are stand-ins here
// (mazama_inventory_page_test.dart covers the Mazama inventory page; (cart_page_*_test.dart covers
// CartPage.onDraftCountChanged; center_stock_page_test.dart the stock page; select_center_page_test.dart the wiring).
// Opening it asks the sync engine once for each dataset its pages read through it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/center_home_page.dart';
import 'package:mazama_mobile/center_menu.dart';
import 'package:mazama_mobile/center_stock_page.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/mazama_inventory_page.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/sheets_client.dart';
import 'package:mazama_mobile/stock_mix.dart';
import 'package:mazama_mobile/stock_rows.dart';
import 'package:mazama_mobile/sync/dataset_feed.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/sync_engine.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';

import 'fake_timers.dart';
import 'features_off.dart';

final _center = License(id: 231, licenseId: 'SC-b1c7379a', licenseName: 'Bendable Service Center', licenseType: 'ServiceCenter');

/// A cart stand-in that reports [count] lines once built, and more with its button.
class _FakeCart extends StatefulWidget {
  const _FakeCart(this.onCount, this.count);
  final ValueChanged<int> onCount;
  final int count;

  @override
  State<_FakeCart> createState() => _FakeCartState();
}

class _FakeCartState extends State<_FakeCart> {
  late int _n = widget.count;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onCount(_n));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('the cart')),
        body: Center(
          child: FilledButton(
            onPressed: () {
              _n++;
              widget.onCount(_n);
            },
            child: const Text('add a line'),
          ),
        ),
      );
}

/// A Sales stand-in that counts how often it was built into the tree (its initState: where SalesPage starts its read).
class _FakeSales extends StatefulWidget {
  const _FakeSales(this.started);
  final List<int> started;

  @override
  State<_FakeSales> createState() => _FakeSalesState();
}

class _FakeSalesState extends State<_FakeSales> {
  @override
  void initState() {
    super.initState();
    widget.started.add(1);
  }

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('the sales')));
}

Widget _home({int draftCount = 0, List<String> off = const [], List<int>? salesStarted, CenterMenu? menu}) => MaterialApp(
      home: CenterHomePage(
        center: _center,
        menu: menu,
        buildMazama: () => Scaffold(appBar: AppBar(title: const Text('the mazama stock'))),
        buildStock: () => Scaffold(appBar: AppBar(title: const Text('the stock'))),
        buildCart: (onCount) => _FakeCart(onCount, draftCount),
        buildSales: () => _FakeSales(salesStarted ?? []),
        featureTable: featuresWithOff(off),
      ),
    );

List<String?> _tabLabels(WidgetTester tester) =>
    [for (final t in tester.widget<TabBar>(find.byType(TabBar)).tabs) (t as Tab).text];

void main() {
  group('the center bar', () {
    testWidgets("without a menu there is none: the tabs are at the top, as they were", (tester) async {
      await tester.pumpWidget(_home());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('center-name')), findsNothing);
    });

    testWidgets("shows the center's name on every tab, and the menu once the cart has attached its actions",
        (tester) async {
      final menu = CenterMenu();
      await tester.pumpWidget(_home(menu: menu));
      await tester.pumpAndSettle();
      expect(find.text('Bendable Service Center'), findsOneWidget);
      expect(find.byKey(const ValueKey('center-menu')), findsNothing); // nothing attached yet

      final done = <String>[];
      final owner = Object();
      menu.attach(owner,
          switchCenter: () async => done.add('switch'), signOut: () async => done.add('signout'), signedInAs: 'w@example.com');
      await tester.pumpAndSettle();
      for (final tab in ['Mazama', 'Stock', 'Cart', 'Sales']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('center-menu')), findsOneWidget, reason: tab);
      }

      await tester.tap(find.byKey(const ValueKey('center-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Signed in as w@example.com'), findsOneWidget);
      await tester.tap(find.text('Change service center'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('center-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(done, ['switch', 'signout']);

      menu.detach(Object()); // someone else's detach changes nothing
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('center-menu')), findsOneWidget);
      menu.detach(owner);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('center-menu')), findsNothing);
    });
  });

  // The home's Scaffold already makes room for the keyboard; a page under it that made room again lost the
  // keyboard's height twice (the cart: its field and lines gone, Total/Sell up under the app bar).
  testWidgets('with the keyboard up, a page makes room for it once, not twice', (tester) async {
    const screen = Size(800, 800);
    const keyboard = 300.0;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = screen;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cart'));
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    await tester.pumpAndSettle();

    final cartScaffold = find.ancestor(of: find.text('the cart'), matching: find.byType(Scaffold)).first; // the nearest: the cart's own
    final cartBody = find.ancestor(of: find.text('add a line'), matching: find.byType(Center)).first;
    expect(tester.getRect(cartScaffold).bottom, screen.height - keyboard);
    expect(tester.getRect(cartBody).bottom, screen.height - keyboard);
    expect(MediaQuery.viewInsetsOf(tester.element(find.text('add a line'))).bottom, 0);
  });

  testWidgets('opens on Stock', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();
    expect(find.text('the stock'), findsOneWidget);
    expect(find.text('the cart'), findsNothing); // built beside it, but not on screen
    expect(find.text('the cart', skipOffstage: false), findsOneWidget);
    expect(find.text('Stock'), findsOneWidget);
    expect(find.text('Cart'), findsOneWidget);
    // Mazama inventory is the first tab, labelled just "Mazama", built beside Stock too.
    expect(find.text('Mazama'), findsOneWidget);
    expect(find.text('Mazama inventory'), findsNothing);
    expect(find.text('the mazama stock'), findsNothing);
    expect(find.text('the mazama stock', skipOffstage: false), findsOneWidget);
    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect([for (final t in tabs.tabs) (t as Tab).text], ['Mazama', 'Stock', 'Cart', 'Sales']);
    expect(tabs.controller!.index, 1);
  });

  testWidgets('swiping right from Stock shows Mazama inventory, and left comes back', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();

    await tester.fling(find.byType(PageView), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('the mazama stock'), findsOneWidget);
    expect(find.text('the stock'), findsNothing);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('the stock'), findsOneWidget);
  });

  testWidgets('tapping Mazama inventory switches, and Cart goes all the way across', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mazama'));
    await tester.pumpAndSettle();
    expect(find.text('the mazama stock'), findsOneWidget);
    await tester.tap(find.text('Cart'));
    await tester.pumpAndSettle();
    expect(find.text('the cart'), findsOneWidget);
  });

  testWidgets('swiping left shows the cart and right comes back', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('the cart'), findsOneWidget);
    expect(find.text('the stock'), findsNothing);

    await tester.fling(find.byType(PageView), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('the stock'), findsOneWidget);
    expect(find.text('the cart'), findsNothing);
  });

  testWidgets('tapping Cart switches', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cart'));
    await tester.pumpAndSettle();
    expect(find.text('the cart'), findsOneWidget);

    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    expect(find.text('the stock'), findsOneWidget);
  });

  testWidgets('the Cart tab shows the draft count', (tester) async {
    await tester.pumpWidget(_home(draftCount: 3));
    await tester.pumpAndSettle();
    // A restored draft counts before the worker ever opens the cart.
    expect(find.text('Cart (3)'), findsOneWidget);

    await tester.tap(find.text('Cart (3)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('add a line'));
    await tester.pumpAndSettle();
    expect(find.text('Cart (4)'), findsOneWidget);
  });

  testWidgets('the cart keeps its state across swipes', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cart'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('add a line'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cart (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('add a line'));
    await tester.pumpAndSettle();
    expect(find.text('Cart (2)'), findsOneWidget); // the same cart, not a fresh one
  });

  // The tabs follow the feature registry.
  testWidgets('default table shows Mazama, Stock, Cart and Sales, opening on Stock', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();
    expect(_tabLabels(tester), ['Mazama', 'Stock', 'Cart', 'Sales']);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
    expect(find.text('the stock'), findsOneWidget);
  });

  testWidgets('mazama_tab off leaves Stock and Cart, opening on Stock', (tester) async {
    await tester.pumpWidget(_home(off: ['mazama_tab']));
    await tester.pumpAndSettle();
    expect(_tabLabels(tester), ['Stock', 'Cart', 'Sales']);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
    expect(find.text('the stock'), findsOneWidget);
    expect(find.text('the mazama stock', skipOffstage: false), findsNothing);
    await tester.tap(find.text('Cart'));
    await tester.pumpAndSettle();
    expect(find.text('the cart'), findsOneWidget);
  });

  testWidgets('center_home_opens_on_stock_or_the_first_tab_left', (tester) async {
    await tester.pumpWidget(_home(off: ['center_stock']));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); // no RangeError
    expect(_tabLabels(tester), ['Mazama', 'Cart', 'Sales']);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
    expect(find.text('the mazama stock'), findsOneWidget);
    expect(find.text('the stock', skipOffstage: false), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_home(off: ['center_stock', 'mazama_tab']));
    await tester.pumpAndSettle();
    expect(_tabLabels(tester), ['Cart', 'Sales']);
    expect(find.text('the cart'), findsOneWidget);
  });

  // Sales is the fourth tab, right of Cart, while recent_sales is on for the license.
  testWidgets('the Sales tab sits right of Cart and opens its page', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    expect(find.text('the sales'), findsOneWidget);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
    await tester.fling(find.byType(PageView), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('the cart'), findsOneWidget);
  });

  // The pages beside the visible one are built ahead (allowImplicitScrolling), but Sales reads the whole
  // sales history: it must not start while the worker is on the Cart, only once its own tab is opened.
  testWidgets('Sales is not built while the worker opens the Cart, only when its tab is opened', (tester) async {
    final started = <int>[];
    await tester.pumpWidget(_home(salesStarted: started));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cart'));
    await tester.pumpAndSettle();
    expect(find.text('the cart'), findsOneWidget);
    expect(find.text('the sales', skipOffstage: false), findsNothing);
    expect(started, isEmpty);
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000); // swiped to, not tapped
    await tester.pumpAndSettle();
    expect(find.text('the sales'), findsOneWidget);
    expect(started, [1]);
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    expect(started, [1]); // kept alive: built once
  });

  testWidgets('the Sales tab is absent while recent_sales is off for the license', (tester) async {
    await tester.pumpWidget(_home(off: ['recent_sales']));
    await tester.pumpAndSettle();
    expect(_tabLabels(tester), ['Mazama', 'Stock', 'Cart']);
    expect(find.text('Sales'), findsNothing);
    expect(find.text('the sales', skipOffstage: false), findsNothing);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
  });

  testWidgets('with every tab off the page says so instead of failing', (tester) async {
    await tester.pumpWidget(_home(off: ['center_stock', 'mazama_tab', 'selling', 'recent_sales']));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Nothing in this app is on for this license.'), findsOneWidget);
  });

  // --- the pages read through the sync engine -------------------------------------------------------------------

  group('the datasets its pages read through the engine', () {
    final engines = <SyncEngine>[];
    late Directory dir;
    late ServerHealth health;
    late Map<Dataset, int> reads;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('mazama_center_home_page_test_');
      health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
      reads = {};
    });
    tearDown(() {
      for (final e in engines) {
        e.dispose();
      }
      engines.clear();
      health.dispose();
      LocalStore.debugCloseAll();
      dir.deleteSync(recursive: true);
    });

    /// An engine with a counting refresher for every dataset the home's pages could read (center_stock, center_status,
    /// par and recent_sales too, which the home must not ask for).
    SyncEngine engine() {
      final e = SyncEngine(
        store: LocalStore.forDir(dir),
        health: health,
        startTimer: FakeTimers().start,
        senders: {for (final k in QueueKind.values) k: (item) async => const Done()},
      );
      engines.add(e); // disposed in tearDown, before the store is closed
      const mix = MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [MixCell(strain: 'Golden Teacher', type: 'DH', mg: 3000)]);
      const sheets = [
        ProductSheet(guid: 'HB-gt01', name: 'GT 6.26', product: 'Whole Fungi', tested: 'Aug 27, 2026',
            path: '/p/lots/mazama/HB-gt01', strains: ['Golden Teacher']),
      ];
      final bodies = <Dataset, String>{
        Dataset.mazamaInventory: jsonEncode(mix.toJson()),
        Dataset.sheets: jsonEncode([for (final s in sheets) s.toJson()]),
        Dataset.centerStock: jsonEncode({'packages': [], 'source': sourceServer}),
        Dataset.centerStatus: jsonEncode({'configured': true}),
        Dataset.par: '[]',
        Dataset.recentSales: '[]',
      };
      for (final MapEntry(key: d, value: body) in bodies.entries) {
        e.register(d, (key) async {
          reads[d] = (reads[d] ?? 0) + 1;
          return (body: body, source: sourceServer);
        });
      }
      return e;
    }

    /// The home with the real Mazama and Stock pages on [e]'s feeds; the cart a stand-in counting its own stock reads.
    Widget home(SyncEngine e, {List<(Dataset, String)> refreshOnOpen = const [], List<int>? cartReads}) => MaterialApp(
          home: CenterHomePage(
            center: _center,
            engine: e,
            refreshOnOpen: refreshOnOpen,
            buildMazama: () => MazamaInventoryPage(feed: mazamaInventoryFeed(e)),
            buildStock: () => CenterStockPage(
                center: _center, loadRows: () async => const StockLoad([]), sheetsFeed: sheetsFeed(e, _center.id)),
            buildCart: (onCount) => _FakeSales(cartReads ?? []), // its initState: where CartPage loads its stock
            buildSales: () => _FakeSales([]),
          ),
        );

    const asked = [(Dataset.mazamaInventory, ''), (Dataset.sheets, '231')];

    testWidgets('opening the center home refreshes each dataset once', (tester) async {
      final e = engine();
      final cartReads = <int>[];
      await tester.pumpWidget(home(e, refreshOnOpen: asked, cartReads: cartReads));
      await tester.pumpAndSettle();
      // asked by the home, joined by each page as it was built: one read each, none twice
      expect(reads, {Dataset.mazamaInventory: 1, Dataset.sheets: 1});
      expect(find.text('3,000 mg TPE in all', skipOffstage: false), findsOneWidget);
      expect(e.datasets.read(Dataset.sheets, '231'), isNotNull);
      // the cart's stock read is its own, once, as before; the home asks nothing of center_stock or center_status
      expect(cartReads, [1]);
      expect(reads[Dataset.centerStock], isNull);
      expect(reads[Dataset.centerStatus], isNull);
    });

    testWidgets('a swipe to the next tab and back reads nothing again', (tester) async {
      final e = engine();
      await tester.pumpWidget(home(e, refreshOnOpen: asked));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Mazama'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Stock'));
      await tester.pumpAndSettle();
      expect(reads, {Dataset.mazamaInventory: 1, Dataset.sheets: 1});
    });

    testWidgets("without the home's ask each page reads once for itself: the ask adds no read", (tester) async {
      final e = engine();
      await tester.pumpWidget(home(e));
      await tester.pumpAndSettle();
      expect(reads, {Dataset.mazamaInventory: 1, Dataset.sheets: 1});
    });

    testWidgets('a dataset asked twice in the list is still read once', (tester) async {
      final e = engine();
      await tester.pumpWidget(home(e, refreshOnOpen: [...asked, ...asked]));
      await tester.pumpAndSettle();
      expect(reads, {Dataset.mazamaInventory: 1, Dataset.sheets: 1});
    });
  });
}
