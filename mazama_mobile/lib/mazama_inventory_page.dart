// specs/mazama-inventory MI-R3: what Mazama Mushrooms itself holds, as the server's manufacturer pages show it - total
// mg TPE "By strain" and "By type" (stock_mix.dart, the shared rules of mazama_modules/stock README § 5). The left page
// of the center home (MI-D1: Mazama inventory | Stock | Cart). One pie at a time, swiped or picked by its dots
// (MI-D3, swipe_pies.dart); tapping a slice or its key line shows that strain's types or that type's strains (MI-D4),
// one breakdown at a time, which stays open (or closed) when the other pie is swiped to.
// It loads once when the center home opens; there is no pull to refresh (MI-D5), and a failed load offers Retry.
// "Order" at its top right opens the order: par levels set or confirmed first (MI-D21, order_par_page.dart), then the
// order form ("Order from Mazama") (MI-D6, order_form_page.dart). At the bottom,
// the collapsible table of the lots in stock with their potency and minor analytes (MI-R7, mazama_lot_table.dart); a lot
// id opens its product information sheet in the browser (MI-D18), and a strain or type picked on a pie narrows the
// table to it (MI-D20). "Contact" at the top left, across from Order, offers
// Mazama's website, Signal and email (MI-D19, mazama_contact.dart).
// While Mazama's server can't be reached, the page shows the last stock it sent (kept on the phone, server_offline.dart)
// with no notice of its own: the app-wide banner says the server can't be reached (server_link.dart, README R87), and
// the page reloads by itself once it answers again. With none kept, the error and Retry as before.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'mazama_contact.dart';
import 'mazama_inventory_client.dart';
import 'mazama_lot_table.dart';
import 'responsive.dart';
import 'server_health.dart';
import 'server_offline.dart';
import 'stock_mix.dart';
import 'stock_pie.dart';
import 'swipe_pies.dart';

class MazamaInventoryPage extends StatefulWidget {
  const MazamaInventoryPage(
      {super.key,
      required this.load,
      this.orderForm,
      this.openSheet,
      this.openLink,
      this.kept,
      this.keep,
      this.now = DateTime.now,
      this.health});

  /// Mazama's mix: route C12 in the app (mazama_inventory_client.dart), the demo's in demo mode, anything in tests.
  final Future<MazamaInventory> Function() load;

  /// The copy of the mix kept on the phone, shown while the server can't be reached; none kept when null
  /// (mazama_inventory_cache_store.dart in the app).
  final Future<ServerRead<MazamaInventory>?> Function()? kept;

  /// Keeps each mix the server sends, with when; nothing kept when null.
  final Future<void> Function(MazamaInventory inventory, DateTime at)? keep;

  /// The clock, for when a mix was kept. Overridable for tests.
  final DateTime Function() now;

  /// MI-D6, MI-D21: what the "Order" button at the top right opens (the par step, order_par_page.dart, then the
  /// order form); no button when null.
  final Widget Function()? orderForm;

  /// MI-D18: opens a lot's product information sheet; null opens it in the browser, as the stock page's sheets.
  final Future<void> Function(MazamaLot lot)? openSheet;

  /// MI-D19: how the Contact sheet's links open (tests); null opens them outside the app.
  final OpenLink? openLink;

  /// The app's server tracker (server_health.dart, README R56): while the page shows the copy kept on the phone, it
  /// reloads by itself once the server answers again (README R87), and Retry asks the server first. Null: neither
  /// (tests, the demo).
  final ServerHealth? health;

  @override
  State<MazamaInventoryPage> createState() => _MazamaInventoryPageState();
}

/// The two pies, in order: what they're called, the mix's key for them and for their cards, and the hint under them.
const _pies = [
  (title: 'By strain', pie: 'by_strain', cards: 'strain_cards', key: 'strain', hint: 'Tap a strain for its types.',
    breakdown: 'by type'),
  (title: 'By type', pie: 'by_type', cards: 'type_cards', key: 'type', hint: 'Tap a type for its strains.',
    breakdown: 'by strain'),
];

class _MazamaInventoryPageState extends State<MazamaInventoryPage> {
  MazamaInventory? _inventory;
  Map<String, Object?>? _mix;
  String? _error;
  int _pie = 0;

  /// The mix on screen is the copy kept on the phone (the server can't be reached).
  bool _fromCache = false;

  /// The breakdown that shows, if any: the pie it was picked on (0 By strain, 1 By type) and the strain or type. One
  /// for the page, not one per pie, so an open breakdown stays open, and a closed one closed, across a swipe.
  ({int pie, String name})? _picked;

  bool get _showingKeptCopy => _fromCache;

  /// Reloads when the tracker comes back online while the page shows the copy kept on the phone ([ServerHealth]).
  bool _wasOffline = false;

  void _onHealth() {
    final h = widget.health;
    if (h == null) return;
    final cameBack = _wasOffline && h.online;
    _wasOffline = h.offline;
    if (cameBack && mounted && !_retrying && _showingKeptCopy) _load();
  }

  /// Set while Retry asks the server: Retry reloads itself, so [_onHealth] doesn't as well.
  bool _retrying = false;

  /// Retry: asks the server first when it is counted as unreachable (the probe brings it back at once if it answers,
  /// so the reload below isn't short-circuited), then reloads.
  Future<void> _retry() async {
    final h = widget.health;
    if (h != null && h.offline) {
      _retrying = true;
      try {
        await h.checkNow();
      } finally {
        _retrying = false;
      }
      if (!mounted) return;
    }
    _load();
  }

  @override
  void dispose() {
    widget.health?.removeListener(_onHealth);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _wasOffline = widget.health?.offline ?? false;
    widget.health?.addListener(_onHealth);
    _load();
  }

  void _load() {
    setState(() {
      _inventory = null;
      _mix = null;
      _error = null;
      _fromCache = false;
    });
    unawaited(() async {
      try {
        final keep = widget.keep;
        final kept = widget.kept;
        final read = await readWithCache<MazamaInventory>(
          fetch: widget.load,
          save: (inv, at) async {
            if (keep != null) await keep(inv, at);
          },
          load: () async => kept == null ? null : await kept(),
          now: widget.now,
        );
        if (!mounted) return;
        final inv = read.value;
        setState(() {
          _inventory = inv;
          _mix = stockMix(inv.cells);
          _fromCache = read.fromCache;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = '$e');
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    // No title bar: it sits under the home's tab labels, whose "Mazama" is its title (owner, 2026-10-22). One row
    // under them, whether or not the mix loaded: Contact at the left (MI-D19), the Order button at the right.
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              children: [
                MazamaContactButton(open: widget.openLink),
                const Spacer(),
                if (widget.orderForm != null)
                  TextButton.icon(
                    key: const ValueKey('order-button'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => widget.orderForm!())),
                    icon: const Icon(Icons.add_shopping_cart),
                    label: const Text('Order'),
                  ),
              ],
            ),
          ),
          Expanded(child: ResponsiveBody(child: _body())),
        ],
      ),
    );
  }

  Widget _body() {
    final inv = _inventory;
    final mix = _mix;
    if (inv == null || mix == null) {
      if (_error == null) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text('Mazama inventory did not load: $_error', textAlign: TextAlign.center),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _retry, child: const Text('Retry')),
          ],
        ),
      );
    }
    final theme = Theme.of(context);
    final total = mix['total'] as num;
    final picked = total > 0 ? _card(mix) : null;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // No maker's name or explanation line above the total (owner, 2026-10-22): the tab says "Mazama".
          if (total <= 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('Nothing in stock.', textAlign: TextAlign.center),
            )
          else ...[
            Text('${formatMixMg(total)} mg TPE in all', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SwipePies(
              key: const ValueKey('mix-pies'),
              index: _pie,
              onIndex: (i) => setState(() => _pie = i),
              dots: [
                for (final p in _pies) (key: ValueKey('mix-pie-dot-${p.key}'), label: '${p.title} pie'),
              ],
              build: (i) => _pieCard(mix, i),
            ),
            if (picked != null) _breakdownCard(picked.card, _pies[picked.pie].breakdown),
          ],
          // MI-D20: the strain or type picked on either pie narrows the table ("Other (n)" has no card: no filter).
          if (inv.lots.isNotEmpty)
            MazamaLotTable(
              lots: inv.lots,
              onOpen: _openSheet,
              filter: picked == null
                  ? null
                  : picked.pie == 0
                      ? lotStrainFilter(picked.card['name'] as String)
                      : lotTypeFilter(picked.card['name'] as String),
            ),
        ],
      ),
    );
  }

  /// MI-D18: a lot's product information sheet, in the browser view the stock page's sheets open in.
  Future<void> _openSheet(MazamaLot lot) async {
    final open = widget.openSheet;
    if (open != null) return open(lot);
    final url = lot.url();
    final messenger = ScaffoldMessenger.of(context);
    if (url == null) {
      messenger.showSnackBar(SnackBar(content: Text("${lot.lot}'s sheet can't be opened here.")));
      return;
    }
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      opened = false;
    }
    if (!opened) messenger.showSnackBar(SnackBar(content: Text("Couldn't open ${lot.lot}'s sheet.")));
  }

  /// Shows (or, tapped again, hides) the breakdown of [name] on pie [i]. "Other (n)" has no card: nothing shows.
  /// A pick on the other pie replaces the one showing.
  void _pick(int i, String name) =>
      setState(() => _picked = _picked == (pie: i, name: name) ? null : (pie: i, name: name));

  ({int pie, Map<String, Object?> card})? _card(Map<String, Object?> mix) {
    final picked = _picked;
    if (picked == null) return null;
    final card = (mix[_pies[picked.pie].cards] as List)
        .cast<Map<String, Object?>>()
        .where((c) => c['name'] == picked.name)
        .firstOrNull;
    return card == null ? null : (pie: picked.pie, card: card);
  }

  Widget _swatch(String slot, {String strainSlot = 's1'}) => Container(
        width: 12,
        height: 12,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: stockSlotColor(slot, strainSlot: strainSlot, brightness: Theme.of(context).brightness),
          borderRadius: BorderRadius.circular(2),
        ),
      );

  /// One key line, as the server's: swatch, name, "1,234 mg · 45%".
  Widget _keyLine(Key key, Map<String, Object?> s, {VoidCallback? onTap, String strainSlot = 's1'}) => InkWell(
        key: key,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              _swatch(s['slot'] as String, strainSlot: strainSlot),
              Expanded(child: Text(s['name'] as String)),
              Text(mixKeyText(s)),
            ],
          ),
        ),
      );

  Widget _pieCard(Map<String, Object?> mix, int i) {
    final p = _pies[i];
    final slices = ((mix[p.pie] as Map)['slices'] as List).cast<Map<String, Object?>>();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Center(
              child: StockPie(
                  slices: slices, size: 160, onTapSlice: (name) => _pick(i, name), label: 'Total mg TPE ${p.title.toLowerCase()}'),
            ),
            const SizedBox(height: 8),
            for (final s in slices)
              _keyLine(ValueKey('${p.key}-key-${s['name']}'), s, onTap: () => _pick(i, s['name'] as String)),
            const SizedBox(height: 4),
            Text(p.hint, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  /// A strain's mix of types, or a type's mix of strains (the server's hover cards).
  Widget _breakdownCard(Map<String, Object?> card, String what) {
    final slot = card['slot'] as String;
    final name = card['name'] as String;
    final pie = card['pie'] as Map;
    final slices = (pie['slices'] as List).cast<Map<String, Object?>>();
    return Card(
      key: ValueKey('mix-card-$name'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _swatch(slot),
                Expanded(
                  child: Text('$name $what · ${formatMixMg(card['total'] as num)} mg TPE',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _picked = null),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Center(child: StockPie(slices: slices, size: 120, strainSlot: slot, label: '$name, $what')),
            const SizedBox(height: 8),
            for (final s in slices) _keyLine(ValueKey('mix-card-key-$name-${s['name']}'), s, strainSlot: slot),
          ],
        ),
      ),
    );
  }
}
