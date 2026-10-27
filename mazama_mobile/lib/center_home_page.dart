// SP-D8, SP-R11, MI-D1: what a worker lands on after choosing a center (select_center_page.dart's _open): three pages
// side by side, Mazama inventory (mazama_inventory_page.dart), Stock (center_stock_page.dart) and Cart (cart_page.dart,
// unchanged apart from being hosted here), with their tab labels above them (Mazama | Stock | Cart: the labels are
// the Mazama and Stock pages' titles, they have no title bar of their own). Opens on Stock, the middle one; swiping
// left or right, or tapping a label, switches. The Cart label carries the draft cart's line count
// (CartPage.onDraftCountChanged).
//
// The pages beside the one showing are built with it and every page is kept alive while this one lives, so the cart
// restores its draft (and reports its count) before the worker ever swipes to it, and no page reloads on every swipe.
import 'package:flutter/material.dart';

import 'licenses_client.dart';

class CenterHomePage extends StatefulWidget {
  const CenterHomePage(
      {super.key, required this.center, required this.buildMazama, required this.buildStock, required this.buildCart});

  final License center;

  /// The Mazama inventory page, left of Stock (a MazamaInventoryPage in the app; anything in tests).
  final Widget Function() buildMazama;

  /// The Stock page (a CenterStockPage in the app; anything in tests).
  final Widget Function() buildStock;

  /// The Cart page, given the callback that keeps the Cart label's count (a CartPage in the app).
  final Widget Function(ValueChanged<int> onDraftCountChanged) buildCart;

  @override
  State<CenterHomePage> createState() => _CenterHomePageState();
}

class _CenterHomePageState extends State<CenterHomePage> with SingleTickerProviderStateMixin {
  /// MI-D1: Mazama inventory | Stock | Cart, opening on Stock; the first tab is labelled just "Mazama".
  static const _stockPage = 1;

  final _pages = PageController(initialPage: _stockPage);
  late final TabController _tabs = TabController(length: 3, initialIndex: _stockPage, vsync: this);
  int _draftCount = 0;
  late final Widget _mazama = widget.buildMazama();
  late final Widget _stock = widget.buildStock();
  late final Widget _cart = widget.buildCart(_onDraftCount);

  void _onDraftCount(int n) {
    if (mounted && n != _draftCount) setState(() => _draftCount = n);
  }

  @override
  void dispose() {
    _pages.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _show(int page) {
    _pages.animateToPage(page, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              bottom: false,
              child: TabBar(
                controller: _tabs,
                onTap: _show,
                tabs: [
                  const Tab(text: 'Mazama'),
                  const Tab(text: 'Stock'),
                  Tab(text: _draftCount > 0 ? 'Cart ($_draftCount)' : 'Cart'),
                ],
              ),
            ),
          ),
          Expanded(
            // The tab labels already sit below the status bar: the pages' own app bars needn't pad for it again.
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: PageView(
                controller: _pages,
                allowImplicitScrolling: true, // builds the pages beside the visible one: both load on open
                onPageChanged: (i) => _tabs.animateTo(i),
                children: [_KeepAlive(child: _mazama), _KeepAlive(child: _stock), _KeepAlive(child: _cart)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
