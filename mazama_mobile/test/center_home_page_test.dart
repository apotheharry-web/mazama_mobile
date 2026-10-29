// SP-D8, SP-R11, MI-D1: the Mazama inventory | Stock | Cart home (lib/center_home_page.dart): opens on Stock, swipes
// and tab taps switch, the Cart label shows the draft's count. The pages are stand-ins here
// (mazama_inventory_page_test.dart covers the Mazama inventory page; (cart_page_*_test.dart covers
// CartPage.onDraftCountChanged; center_stock_page_test.dart the stock page; select_center_page_test.dart the wiring).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/center_home_page.dart';
import 'package:mazama_mobile/licenses_client.dart';

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

Widget _home({int draftCount = 0, List<String> off = const [], List<int>? salesStarted}) => MaterialApp(
      home: CenterHomePage(
        center: _center,
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
  testWidgets('opens on Stock', (tester) async {
    await tester.pumpWidget(_home());
    await tester.pumpAndSettle();
    expect(find.text('the stock'), findsOneWidget);
    expect(find.text('the cart'), findsNothing); // built beside it, but not on screen
    expect(find.text('the cart', skipOffstage: false), findsOneWidget);
    expect(find.text('Stock'), findsOneWidget);
    expect(find.text('Cart'), findsOneWidget);
    // MI-D1: Mazama inventory is the first tab, labelled just "Mazama" (owner, 2026-10-22), built beside Stock too.
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

  // specs/features FR-3: the tabs follow the feature registry.
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

  // specs/center-web CW-R10 (T13): Sales is the fourth tab, right of Cart, while recent_sales is on for the license.
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

  // Review I-1: the pages beside the visible one are built ahead (allowImplicitScrolling), but Sales reads the whole
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
}
