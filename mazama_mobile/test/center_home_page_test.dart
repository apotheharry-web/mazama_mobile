// SP-D8, SP-R11, MI-D1: the Mazama inventory | Stock | Cart home (lib/center_home_page.dart): opens on Stock, swipes
// and tab taps switch, the Cart label shows the draft's count. The pages are stand-ins here
// (mazama_inventory_page_test.dart covers the Mazama inventory page; (cart_page_test.dart covers
// CartPage.onDraftCountChanged; center_stock_page_test.dart the stock page; select_center_page_test.dart the wiring).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/center_home_page.dart';
import 'package:mazama_mobile/licenses_client.dart';

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

Widget _home({int draftCount = 0}) => MaterialApp(
      home: CenterHomePage(
        center: _center,
        buildMazama: () => Scaffold(appBar: AppBar(title: const Text('the mazama stock'))),
        buildStock: () => Scaffold(appBar: AppBar(title: const Text('the stock'))),
        buildCart: (onCount) => _FakeCart(onCount, draftCount),
      ),
    );

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
    expect([for (final t in tabs.tabs) (t as Tab).text], ['Mazama', 'Stock', 'Cart']);
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
}
