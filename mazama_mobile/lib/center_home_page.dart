// What a worker lands on after choosing a center (select_center_page.dart's _open): three pages
// side by side, Mazama inventory (mazama_inventory_page.dart), Stock (center_stock_page.dart) and Cart (cart_page.dart,
// unchanged apart from being hosted here), with their tab labels above them (Mazama | Stock | Cart: the labels are
// the Mazama and Stock pages' titles, they have no title bar of their own). Opens on Stock, the middle one; swiping
// left or right, or tapping a label, switches. The Cart label carries the draft cart's line count
// (CartPage.onDraftCountChanged).
//
// The pages beside the one showing are built with it and every page is kept alive while this one lives, so the cart
// restores its draft (and reports its count) before the worker ever swipes to it, and no page reloads on every swipe.
//
// Each tab shows only while its feature is on for the license's type (mazama_tab, center_stock,
// selling, recent_sales in lib/features.g.dart); the page opens on Stock when it is on, else on the first tab left.
//
// A fourth tab, Sales (sales_page.dart), right of Cart: Mazama | Stock | Cart | Sales,
// still opening on Stock. Unlike the others, Sales is built only once its
// tab first becomes the current page: it reads the center's whole sales history, which must not run while the worker
// is on the Cart beside it (the pre-build below would otherwise start it there).
//
// Above the tabs, the center bar: the center's name and a menu (center_menu.dart) with who is signed in, Change service
// center and Sign out, on every tab. The cart attaches those two actions (it knows which carts leaving would discard);
// the menu shows once it has.
//
// Opening the home asks the sync engine once for the refresh of each dataset its pages
// read through the engine ([CenterHomePage.refreshOnOpen]: the Mazama tab's mazama_inventory and the Stock page's
// sheets, sync/dataset_feed.dart), before the pages are built, so each page joins that read rather than starting its
// own. What is not asked for, and why (each would double a read a page still makes for itself on open):
//   - center_stock and center_status: the cart loads its own stock (CenterStock, the state and the server) and its
//     own settings on open; it is in the sale path, which never awaits or reads through the engine. The Stock
//     page's rows read the same server packages and state records for themselves (stock_rows.dart).
//   - recent_sales: the Sales page reads the state's sales only once its tab is first opened, never beside the Cart
//     (above), with a fresh state token; no engine refresher reads it in the app.
//   - par: read only by the order's first step (order_par_page.dart), which the home doesn't host.
import 'dart:async';

import 'package:flutter/material.dart';

import 'center_menu.dart';
import 'features.g.dart';
import 'licenses_client.dart';
import 'sync/sync_datasets.dart' show Dataset;
import 'sync/sync_engine.dart';

class CenterHomePage extends StatefulWidget {
  const CenterHomePage(
      {super.key,
      required this.center,
      required this.buildMazama,
      required this.buildStock,
      required this.buildCart,
      required this.buildSales,
      this.buildUpdateCard,
      this.engine,
      this.refreshOnOpen = const [],
      this.menu,
      this.featureTable = features});

  final License center;

  /// The feature registry the tabs follow (the generated one in the app; tests pass a copy with features off).
  final Map<String, Feature> featureTable;

  /// The Mazama inventory page, left of Stock (a MazamaInventoryPage in the app; anything in tests).
  final Widget Function() buildMazama;

  /// The Stock page (a CenterStockPage in the app; anything in tests).
  final Widget Function() buildStock;

  /// The Cart page, given the callback that keeps the Cart label's count (a CartPage in the app).
  final Widget Function(ValueChanged<int> onDraftCountChanged) buildCart;

  /// The Sales page, right of Cart (a SalesPage in the app; anything in tests), while recent_sales is on.
  final Widget Function() buildSales;

  /// The update card above the tabs (app_update_card.dart), given the draft cart's line count
  /// so it hides while a cart holds a line; null (tests, the demo) shows none.
  final Widget Function(int draftCount)? buildUpdateCard;

  /// The sync engine the pages read [refreshOnOpen] through (the app's, or the demo's); none asked for when null.
  final SyncEngine? engine;

  /// The datasets (and keys) asked for once as the home opens (the file comment): only those its pages read through
  /// [engine]'s watch, never one a page still reads for itself.
  final List<(Dataset, String)> refreshOnOpen;

  /// The center bar's menu (Change service center, Sign out), which the cart attaches its actions to; without one
  /// (tests of the tabs alone) there is no center bar.
  final CenterMenu? menu;

  @override
  State<CenterHomePage> createState() => _CenterHomePageState();
}

enum _Tab { mazama, stock, cart, sales }

class _CenterHomePageState extends State<CenterHomePage> with SingleTickerProviderStateMixin {
  /// Mazama inventory | Stock | Cart, opening on Stock; the first tab is labelled just "Mazama"; Sales after Cart.
  /// A tab whose feature is off for this license's type is left out.
  late final List<_Tab> _shown = [
    if (_on('mazama_tab')) _Tab.mazama,
    if (_on('center_stock')) _Tab.stock,
    if (_on('selling')) _Tab.cart,
    if (_on('recent_sales')) _Tab.sales,
  ];
  late final int _first = _shown.contains(_Tab.stock) ? _shown.indexOf(_Tab.stock) : 0;

  late final _pages = PageController(initialPage: _first);
  late final TabController _tabs = TabController(length: _shown.length, initialIndex: _first, vsync: this);
  int _draftCount = 0;
  late final Widget _mazama = widget.buildMazama();
  late final Widget _stock = widget.buildStock();
  late final Widget _cart = widget.buildCart(_onDraftCount);
  late final Widget _sales = widget.buildSales();

  /// Sales has been the current page (or is the first): from then on it is built and kept like the others.
  late bool _salesOpened = _shown.isNotEmpty && _shown[_first] == _Tab.sales;

  @override
  void initState() {
    super.initState();
    // Before build makes the pages: each finds its read under way and joins it (DatasetFeed.read).
    final engine = widget.engine;
    if (engine != null) {
      for (final (d, key) in widget.refreshOnOpen.toSet()) {
        unawaited(engine.refresh(d, key));
      }
    }
  }

  void _onPageChanged(int i) {
    _tabs.animateTo(i);
    if (!_salesOpened && _shown[i] == _Tab.sales) setState(() => _salesOpened = true);
  }

  bool _on(String feature) => featureOnForLicense(feature, widget.center.licenseType, table: widget.featureTable);

  void _onDraftCount(int n) {
    if (mounted && n != _draftCount) setState(() => _draftCount = n);
  }

  @override
  void dispose() {
    // With no tab on, build never made the controllers: don't create them (and a ticker) just to dispose them.
    if (_shown.isNotEmpty) {
      _pages.dispose();
      _tabs.dispose();
    }
    super.dispose();
  }

  void _show(int page) {
    _pages.animateToPage(page, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  Tab _label(_Tab t) => switch (t) {
        _Tab.mazama => const Tab(text: 'Mazama'),
        _Tab.stock => const Tab(text: 'Stock'),
        _Tab.cart => Tab(text: _draftCount > 0 ? 'Cart ($_draftCount)' : 'Cart'),
        _Tab.sales => const Tab(text: 'Sales'),
      };

  Widget _page(_Tab t) => switch (t) {
        _Tab.mazama => _mazama,
        _Tab.stock => _stock,
        _Tab.cart => _cart,
        _Tab.sales => _salesOpened ? _sales : const SizedBox.shrink(),
      };

  /// The center's name, and the menu once the cart has attached its actions.
  Widget _centerBar(CenterMenu menu) => ListenableBuilder(
        listenable: menu,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(widget.center.licenseName,
                    key: const ValueKey('center-name'),
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (menu.ready)
                PopupMenuButton<String>(
                  key: const ValueKey('center-menu'),
                  tooltip: 'Center menu',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (choice) {
                    if (choice == 'switch') unawaited(menu.switchCenter());
                    if (choice == 'signout') unawaited(menu.signOut());
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'switch',
                      child: ListTile(leading: Icon(Icons.store_outlined), title: Text('Change service center')),
                    ),
                    const PopupMenuItem(
                      value: 'signout',
                      child: ListTile(leading: Icon(Icons.logout), title: Text('Sign out')),
                    ),
                    if (menu.signedInAs case final who?)
                      PopupMenuItem(enabled: false, child: Text('Signed in as $who')),
                  ],
                ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_shown.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.center.licenseName)),
        body: const Center(child: Text('Nothing in this app is on for this license.')),
      );
    }
    return Scaffold(
      body: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.menu case final menu?) _centerBar(menu),
                  if (widget.buildUpdateCard != null && _on('app_updates')) widget.buildUpdateCard!(_draftCount),
                  TabBar(
                    controller: _tabs,
                    onTap: _show,
                    tabs: [for (final t in _shown) _label(t)],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            // The tab labels already sit below the status bar: the pages' own app bars needn't pad for it again.
            // Read from inside this Scaffold's body, where the keyboard is already taken out: this page's own
            // context still carries it, and a page's Scaffold would then make room for the keyboard a second time.
            child: Builder(
              builder: (bodyContext) => MediaQuery.removePadding(
                context: bodyContext,
                removeTop: true,
                child: PageView(
                  controller: _pages,
                  allowImplicitScrolling: true, // builds the pages beside the visible one: both load on open
                  onPageChanged: _onPageChanged,
                  children: [for (final t in _shown) _KeepAlive(child: _page(t))],
                ),
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
