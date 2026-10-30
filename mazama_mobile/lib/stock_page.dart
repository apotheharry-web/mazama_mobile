// A read-only browse of this center's current stock - the exact same /p/packages/{state_id} data CartPage
// already downloads to match a scanned PKPR (packages_client.dart), just laid out as a plain searchable list
// instead of requiring an exact PKPR to look anything up. Deliberately NOT the public HTML stock page
// (mazama_sales' web/stock_pages.py's public_stock_page, served at /p/{slug}/) - that page is built for a
// browser (server-rendered charts, par levels, other-maker stock, full HTML markup, no stable contract this
// app could parse without breaking on the next CSS change), whereas the one thing a worker actually wants
// here - what's in stock right now, by name and quantity - is already served, field for field, by the same
// plain JSON endpoint this app already calls. No sale happens from this screen; it's read-only start to finish.
// It is the one page in the app where pulling down re-downloads the inventory (the owner's rule). Above the list, its
// age (specs/phone-sync PS-R7, PS-D5): when the stock it shows was read, asked of [StockPage.readAt] after each
// download (the cart passes the center_stock dataset's time, which every load it runs keeps).
import 'package:flutter/material.dart';

import 'enrichment_store.dart';
import 'features.g.dart';
import 'licenses_client.dart';
import 'packages_client.dart';
import 'packages_client.dart' as packages_client; // see StockPage.fetchPackages: avoids a same-name default-value ambiguity
import 'product_type_icon.dart';
import 'reconcile_page.dart';
import 'responsive.dart';
import 'sync/updated_line.dart';

class StockPage extends StatefulWidget {
  final License center;

  /// Overridable for tests, so a widget test never makes a real network call - same reasoning and the same
  /// real default (against Mazama's own public /p/packages/{state_id}, no login) as CartPage.fetchPackages.
  final Future<List<Package>> Function(int stateId) fetchPackages;

  /// The signed-in worker's own email (Session.email) - forwarded straight through to ReconcilePage, which
  /// prints it on a generated report so whoever reads it later knows who counted it. Defaults to '' (shown as
  /// nothing on the report) rather than required, so existing tests/callers that construct this page without
  /// a session in hand don't need to change.
  final String workerEmail;

  /// The feature registry (specs/features FR-3): the reconcile button shows only while reconcile is on for this
  /// center's license type. The generated one in the app; tests pass a copy with features off.
  final Map<String, Feature> featureTable;

  /// When the stock [fetchPackages] last handed back was read, asked after each download, for the age line (PS-R7);
  /// null (none known, or no [readAt]) shows none. Its failure only leaves the line out.
  final Future<DateTime?> Function(int stateId)? readAt;

  /// The clock the age is counted against; overridable for tests.
  final DateTime Function() now;

  const StockPage(
      {super.key,
      required this.center,
      this.fetchPackages = packages_client.fetchPackages,
      this.workerEmail = '',
      this.featureTable = features,
      this.readAt,
      this.now = DateTime.now});

  @override
  State<StockPage> createState() => _StockPageState();
}

class _StockPageState extends State<StockPage> {
  List<Package>? _inventory;
  String? _error;

  /// When the stock on screen was read ([StockPage.readAt]); null when not known.
  DateTime? _readAt;
  final _searchController = TextEditingController();
  String _query = '';

  /// Which PKPRs (by productGuid) a worker has tapped to select, so they can be added to the cart in one go -
  /// see _toggleSelected/_addSelectedToCart and _body's own ListTile below for the highlight. Cleared only by
  /// leaving this page (a fresh StockPage, same as _query never surviving a pop either); nothing here is
  /// persisted, unlike the cart itself.
  final Set<String> _selectedGuids = {};

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(() {
      final q = _searchController.text.trim().toLowerCase();
      if (q != _query) setState(() => _query = q);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _load() {
    setState(() {
      _inventory = null;
      _error = null;
    });
    widget.fetchPackages(widget.center.id).then((pkgs) async {
      final at = await _readTime();
      if (!mounted) return;
      setState(() {
        _inventory = pkgs;
        _readAt = at;
      });
    }).catchError((e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    });
  }

  /// Pull to refresh (the one page in the app that has it): downloads the inventory again with the list kept on
  /// screen, so the search and any ticked PKPRs stay put. A ticked PKPR no longer in stock is unticked. A failure
  /// leaves the list as it was and says so; with nothing on screen yet, it shows the same error and Retry as _load.
  Future<void> _refresh() async {
    try {
      final pkgs = await widget.fetchPackages(widget.center.id);
      final at = await _readTime();
      if (!mounted) return;
      final guids = {for (final p in pkgs) p.productGuid};
      setState(() {
        _inventory = pkgs;
        _readAt = at;
        _error = null;
        _selectedGuids.retainAll(guids);
      });
    } catch (e) {
      if (!mounted) return;
      if (_inventory == null) {
        setState(() => _error = e.toString());
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Stock did not refresh: $e')));
      }
    }
  }

  /// When the stock just downloaded was read ([StockPage.readAt]); null when it can't be told.
  Future<DateTime?> _readTime() async {
    final readAt = widget.readAt;
    if (readAt == null) return null;
    try {
      return await readAt(widget.center.id);
    } catch (_) {
      return null; // only the age line is left out
    }
  }

  /// By product type, then strain, then serving size decreasing (packages_client.dart's sortedPkprGroups,
  /// shared with ReconcilePage so a worker sees the exact same order on both screens) - a worker scanning
  /// this list for "do we have any Golden Teacher left" wants like products grouped together and the biggest
  /// unit of a given strain listed first, not server-sync order.
  List<PkprGroup> _visible() {
    final inventory = _inventory;
    if (inventory == null) return const [];
    final sorted = sortedPkprGroups(inventory);
    if (_query.isEmpty) return sorted;
    return sorted.where((g) => g.productType.toLowerCase().contains(_query) || g.productGuid.toLowerCase().contains(_query)).toList();
  }

  void _onReconcilePressed() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReconcilePage(center: widget.center, fetchPackages: widget.fetchPackages, workerEmail: widget.workerEmail),
      ),
    );
  }

  void _toggleSelected(PkprGroup g) {
    setState(() {
      if (!_selectedGuids.remove(g.productGuid)) _selectedGuids.add(g.productGuid);
    });
  }

  /// Hands the selected PKPRs back to whoever pushed this page (CartPage's _onViewStockPressed) as a plain
  /// List<PkprGroup>, same shape CartPage already builds everywhere else it has one - CartPage decides how
  /// each one actually gets priced and added (its own job, not this read-only page's), see that method's own
  /// comment for why. Looked up fresh from _inventory rather than carrying PkprGroup objects in _selectedGuids
  /// itself, so a group's own quantity reflects whatever _load most recently saw even if a retry happened while
  /// some were already selected.
  void _addSelectedToCart() {
    final inventory = _inventory;
    if (inventory == null || _selectedGuids.isEmpty) return;
    final selected = groupByPkpr(inventory).where((g) => _selectedGuids.contains(g.productGuid)).toList();
    Navigator.of(context).pop(selected);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.center.licenseName} stock'),
        actions: [
          if (_selectedGuids.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: _addSelectedToCart,
                icon: const Icon(Icons.add_shopping_cart, size: 18),
                label: Text('Add ${_selectedGuids.length}'),
              ),
            ),
        ],
      ),
      body: ResponsiveBody(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(labelText: 'Search by product type or PKPR', prefixIcon: Icon(Icons.search)),
              ),
            ),
            if (_inventory != null) Align(alignment: Alignment.centerLeft, child: UpdatedLine.at(_readAt, now: widget.now)),
            Expanded(child: _body()),
            // Shown while reconcile is on for this license's type (specs/features FR-3); not gated on
            // _selectedGuids or search state - reconciling is a separate activity from picking PKPRs to add to a
            // cart, so it's reachable the same way regardless of what else a worker is doing on this screen.
            if (featureOnForLicense('reconcile', widget.center.licenseType, table: widget.featureTable))
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: OutlinedButton.icon(
                  onPressed: _onReconcilePressed,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Reconcile inventory with state'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Text('Stock did not load: $_error', textAlign: TextAlign.center)),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    final inventory = _inventory;
    if (inventory == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final visible = _visible();
    if (visible.isEmpty) {
      // Still a scrollable list, so an empty center can be pulled down to check again.
      final message = inventory.isEmpty ? 'Nothing in stock.' : 'No match for "$_query".';
      return RefreshIndicator(
        onRefresh: _refresh,
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [SizedBox(height: constraints.maxHeight, child: Center(child: Text(message)))],
          ),
        ),
      );
    }
    final rows = _rows(visible);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length,
        itemBuilder: (context, i) => rows[i].build(context, this),
      ),
    );
  }

  /// Flattens the sorted PkprGroups into one list mixing in a header row every time the type or strain changes
  /// from the row before it (_visible already sorted by type, then strain, so a change is always a real
  /// boundary, never a group split across two spots) - a type header ("Chocolate", with its own icon) whenever
  /// the type itself changes, and a lighter strain header right under it whenever the strain changes, even
  /// when the type didn't (the common case: several strains of the same type back to back). The very first
  /// group always gets both headers, same as any other boundary.
  List<_Row> _rows(List<PkprGroup> visible) {
    final rows = <_Row>[];
    String? lastType;
    String? lastStrain;
    for (final g in visible) {
      if (g.productType != lastType) {
        rows.add(_TypeHeader(g.productType));
        lastType = g.productType;
        lastStrain = null; // a new type always shows its first strain's header too, even if the name repeats
      }
      if (g.strain != lastStrain) {
        rows.add(_StrainHeader(g.strain));
        lastStrain = g.strain;
      }
      rows.add(_ItemRow(g));
    }
    return rows;
  }

  /// The type and strain are both already shown by the section headers above this row (_TypeHeader/
  /// _StrainHeader - see _rows), so this tile itself only needs what's specific to this one PKPR: its own
  /// guid and per-unit TPE dose.
  Widget _itemTile(BuildContext context, PkprGroup g) {
    final selected = _selectedGuids.contains(g.productGuid);
    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      leading: Checkbox(value: selected, onChanged: (_) => _toggleSelected(g)),
      title: Text(g.productGuid),
      // A figure read from the state system alone says which it is and where it came from (SM-D31: mg psilocybin when
      // only the state's is known; enrichment_store.dart's tpeProvenanceNote).
      subtitle: Text('${g.tpeMg}${g.mgLabel} each${tpeProvenanceNote(g)}'),
      trailing: Text('${g.quantity}\nin stock', textAlign: TextAlign.right),
      onTap: () => _toggleSelected(g),
    );
  }
}

/// One row of the stock list as actually rendered - either a section header or a real PkprGroup. A plain
/// sealed-ish class (not an enum, since _TypeHeader/_StrainHeader/_ItemRow each carry different data) just so
/// _StockPageState._rows can build one flat, correctly-ordered list instead of StockPage's build() needing to
/// re-derive "is this a boundary" from index math every time it's asked for a row.
abstract class _Row {
  Widget build(BuildContext context, _StockPageState state);
}

/// A bold section divider for a new product type - the state's own productType string, plus
/// iconForProductType's best guess at what kind of product that is. Shown with real visual weight (a tinted
/// background, a divider above) since a type change is the biggest boundary in this list - a worker should
/// never mistake a new type's first row for still being part of the one before it.
class _TypeHeader extends _Row {
  final String productType;
  _TypeHeader(this.productType);

  @override
  Widget build(BuildContext context, _StockPageState state) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(iconForProductType(productType), size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Text(
            productType.isEmpty ? '(no product type on file)' : productType,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

/// A lighter sub-header for a new strain within the current type - just the strain name (or a plain dash when
/// a package has none on file), so several strains of the same type back to back are still easy to tell apart
/// without the heavier styling a whole new type gets.
class _StrainHeader extends _Row {
  final String strain;
  _StrainHeader(this.strain);

  @override
  Widget build(BuildContext context, _StockPageState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Text(
        strain.isEmpty ? '—' : strain,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _ItemRow extends _Row {
  final PkprGroup group;
  _ItemRow(this.group);

  @override
  Widget build(BuildContext context, _StockPageState state) => state._itemTile(context, group);
}
