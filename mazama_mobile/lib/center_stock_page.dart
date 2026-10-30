// SP-R12: a center's stock page on the phone, the same content as the server's center page (SP-D7): the All /
// Mazama only filter (SP-D3), the units pie and the mg pie with their keys, the serving-size pies of the strain a
// worker taps, the lot table, and "Other stock" with the reason each package is left out (collapsed at first,
// SP-D16). The par table is no longer here (SP-D19): it is the first step of an order (par_levels_editor.dart,
// order_par_page.dart, MI-D21). Every number comes from stock_summary.dart (the shared rules, held to the server's
// vectors); this file only lays them out and formats texts as the server's templates do (formatG for Python's {x:g}).
//
// Data comes through injected loaders, so the page is testable without a network and whoever hosts it decides
// where rows come from (center_home_page.dart). Rows come as a StockLoad (stock_rows.dart): partial ones (SP-R13, the
// server unreachable) get the mg pie in mg psilocybin when they say so (SP-D6); the last rows drawn on this phone
// (the state system unreachable too) say how old they are. The lot table's product information sheets, while
// Mazama's server can't be reached, are the copy kept on the phone (sync/server_read.dart). Neither has a notice of its
// own that the server can't be reached: the app-wide banner says so (server_link.dart, README R87), and the page
// reloads by itself once the server answers again.
//
// The units pie and the mg pie share one spot, one at a time: a horizontal swipe on it (or a tap on the dots below
// it) shows the other; a picked strain's Quantity and mg serving-size pies work the same way. At either end the
// swipe goes on to the Stock / Cart pages (center_home_page.dart), so the pie never traps a worker on this page.
// There is no pull to refresh here: the owner's rule is that only the PKPR list (stock_page.dart) re-downloads the
// inventory by pulling down.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'licenses_client.dart';
import 'mazama_lot_table.dart';
import 'responsive.dart';
import 'server_health.dart';
import 'sync/server_read.dart';
import 'sheets_client.dart';
import 'stock_mix.dart';
import 'stock_pie.dart';
import 'stock_rows.dart';
import 'stock_summary.dart';
import 'swipe_pies.dart';

const _serverQuantitiesBanner =
    "The state system didn't answer: these quantities are the Mazama server's, as of its last sync.";
const _notSetUpBanner = "This center isn't set up on the Mazama server: these are the state's figures only.";
const _signInBanner = 'Your state system sign-in has expired: sign in again to read the state\'s stock.';

/// How long ago something was, in words: "5 min", "3 h", "2 days".
String stockAge(Duration d) {
  if (d.inMinutes < 1) return 'less than a minute';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 48) return '${d.inHours} h';
  return '${d.inDays} days';
}

class CenterStockPage extends StatefulWidget {
  const CenterStockPage({
    super.key,
    required this.center,
    required this.loadRows,
    this.now = DateTime.now,
    this.onSignInAgain,
    this.loadSheets,
    this.openSheet,
    this.keptSheets,
    this.keepSheets,
    this.health,
  });

  final License center;

  /// The center's packages as stock rows (every package; the page filters), with how they are to be shown.
  final Future<StockLoad> Function() loadRows;

  /// The clock, for the age of the last charts drawn here. Overridable for tests.
  final DateTime Function() now;

  /// Takes the worker to sign in again when the state's sign-in has expired (a "Sign in again" button shows).
  final void Function(BuildContext context)? onSignInAgain;

  /// SP-D11: the product information sheets of the center's stock (route C13); no bar when null.
  final Future<List<ProductSheet>> Function()? loadSheets;

  /// Opens a sheet's page; by default in the in-app browser. Overridable for tests.
  final Future<void> Function(ProductSheet sheet)? openSheet;

  /// The sheets kept on the phone, shown while the server can't be reached; none kept when null
  /// (the sheets dataset in the app, sync_datasets.dart).
  final Future<ServerRead<List<ProductSheet>>?> Function()? keptSheets;

  /// Keeps each list of sheets the server sends, with when ([now]); nothing kept when null.
  final Future<void> Function(List<ProductSheet> sheets, DateTime at)? keepSheets;

  /// The app's server tracker (server_health.dart, README R56): while the page shows the copy kept on the phone (or
  /// partial stock), it reloads by itself once the server answers again (README R87), and Retry asks the server first.
  /// Null: neither (tests, the demo).
  final ServerHealth? health;

  @override
  State<CenterStockPage> createState() => _CenterStockPageState();
}

class _CenterStockPageState extends State<CenterStockPage> {
  List<StockRow>? _rows;

  /// From the last StockLoad: 'tpe' or 'psilocybin' (SP-D6); drawn without the server (SP-R13); and when the rows
  /// are the last ones drawn on this phone, when that was.
  String _mgMode = 'tpe';
  bool _partial = false;
  DateTime? _drawnAt;
  bool _notSetUp = false;
  bool _signInNeeded = false;
  bool _serverQuantities = false;
  List<({StockRow row, String reason})> _heldBack = const [];
  String? _error;
  String _makers = stockFilters.first;
  String? _strain;

  /// SP-D17: the type picked on the By type pie (its word, "Dehydrated"); one pick at a time with [_strain].
  String? _type;

  /// "Other stock" starts collapsed (owner, 2026-10-22): its title and count always show; the explanation and
  /// the list only once opened.
  bool _otherOpen = false;

  /// Which main pie shows: units, mg (when there are mg figures), By type (SP-D17), in that order (swipe_pies.dart).
  int _pie = 0;

  /// Which of a picked strain's serving-size pies shows: 0 Quantity, 1 mg. Kept when another strain is picked.
  int _sizePie = 0;

  /// SP-D11, SP-D18: the center's product information sheets (null until loaded) and why they didn't load. They are
  /// the rows of the lot table (it starts closed).
  List<ProductSheet>? _sheets;
  String? _sheetsError;

  /// The sheets shown are the copy kept on the phone (the server couldn't be reached).
  bool _sheetsFromCache = false;

  bool get _showingKeptCopy => _sheetsFromCache || _partial;

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
      _rows = null;
      _error = null;
    });
    unawaited(_refresh());
  }

  /// Loads rows and the lot table's sheets together. Run once when the page opens (and by Retry, through _load); this
  /// page has no pull to refresh (only the PKPR list does), so the keep-what's-on-screen branch below only matters if
  /// a reload is added back.
  Future<void> _refresh() async {
    Object? rowsError, sheetsError;
    StockLoad? rows;
    ServerRead<List<ProductSheet>>? sheets;
    final loadSheets = widget.loadSheets;
    final keep = widget.keepSheets;
    final kept = widget.keptSheets;
    await Future.wait<void>([
      if (loadSheets != null)
        Future(() async {
          try {
            sheets = await readWithCache<List<ProductSheet>>(
              fetch: loadSheets,
              save: (s, at) async {
                if (keep != null) await keep(s, at);
              },
              load: () async => kept == null ? null : await kept(),
              now: widget.now,
            );
          } catch (e) {
            sheetsError = e;
          }
        }),
      Future(() async {
        try {
          rows = await widget.loadRows();
        } catch (e) {
          rowsError = e;
        }
      }),
    ]);
    if (!mounted) return;
    setState(() {
      if (rows != null) {
        _rows = rows!.rows;
        _mgMode = rows!.mgMode;
        _partial = rows!.partial;
        _drawnAt = rows!.drawnAt;
        _notSetUp = rows!.notSetUp;
        _signInNeeded = rows!.signInNeeded;
        _serverQuantities = rows!.serverQuantities;
        _heldBack = rows!.heldBack;
        _error = null;
      } else if (_rows == null) {
        _error = '$rowsError';
        _signInNeeded = rowsError is StockSignInNeeded;
      }
      if (sheets != null) {
        _sheets = sheets!.value;
        _sheetsFromCache = sheets!.fromCache;
        _sheetsError = null;
      } else if (sheetsError != null) {
        _sheetsError = '$sheetsError';
      }
    });
  }

  String get _mgUnit => _mgMode == 'psilocybin' ? 'mg psilocybin' : 'mg TPE';

  String get _mgHeading =>
      _mgMode == 'psilocybin' ? 'mg psilocybin in stock (state figures; TPE needs the server)' : 'mg TPE in stock';

  @override
  Widget build(BuildContext context) {
    // No title bar: it sits under the home's tab labels, whose "Stock" is its title (owner, 2026-10-22).
    return Scaffold(body: ResponsiveBody(child: _body()));
  }

  Widget _body() {
    final rows = _rows;
    if (rows == null) {
      if (_error != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text('Stock did not load: $_error', textAlign: TextAlign.center),
              ),
              const SizedBox(height: 8),
              if (_signInNeeded && widget.onSignInAgain != null)
                FilledButton(onPressed: () => widget.onSignInAgain!(context), child: const Text('Sign in again'))
              else
                FilledButton(onPressed: _retry, child: const Text('Retry')),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    final filtered = filterRows(rows, _makers);
    final counted = (filtered['counted'] as List).cast<StockRow>();
    // "Other stock", as the server's: what can't be sold (SP-D9), then what the filter leaves out, by name.
    final other = [
      for (final h in _heldBack) (row: h.row, reason: h.reason),
      for (final o in (filtered['other'] as List).cast<Map<String, Object?>>())
        (row: o['row'] as StockRow, reason: _reasons[o['reason']] ?? '${o['reason']}'),
    ]..sort((a, b) => _otherName(a.row).toLowerCase().compareTo(_otherName(b.row).toLowerCase()));
    final summary = summarize(counted, _mgMode);
    final view = pies(summary);

    final units = view['units'] as Map<String, Object?>?;
    final mg = view['mg'] as Map<String, Object?>?;
    final strainRows = (view['rows'] as List).cast<Map<String, Object?>>();
    final selected = strainRows.where((r) => r['name'] == _strain).firstOrNull;
    // SP-D17: the By type pie, weighed as the mg pie when there are mg figures, else by units.
    final byType = stockByType(counted, _mgMode);
    final typeNames = stockByTypeWords(counted, _mgMode);
    final pickedType = typeNames.contains(_type) ? _type : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_drawnAt != null)
            _banner("The state system can't be reached: these are the charts drawn on "
                'this phone ${stockAge(widget.now().difference(_drawnAt!))} ago.')
          else if (_notSetUp)
            _banner(_notSetUpBanner)
          else if (_serverQuantities)
            _banner(_serverQuantitiesBanner),
          if (_signInNeeded) _signInRow(),
          Center(
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('All')),
                ButtonSegment(value: 'mazama', label: Text('Mazama only')),
              ],
              selected: {_makers},
              onSelectionChanged: (s) => setState(() {
                _makers = s.single;
                _strain = null;
                _type = null;
              }),
            ),
          ),
          const SizedBox(height: 12),
          if (units == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(_makers == 'mazama' ? 'No Mazama stock.' : 'Nothing in stock.', textAlign: TextAlign.center),
            )
          else ...[
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              children: [
                Text('${formatG(summary['total'] as num)} units', style: Theme.of(context).textTheme.titleMedium),
                if (mg != null)
                  Text('${formatG(summary['mg_total'] as num)} $_mgUnit', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            _pies(units, mg, byType, mg != null),
            if (selected != null) _sizes(selected),
            if ((view['more'] as int) > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Showing the ${strainRows.length} largest of ${strainRows.length + (view['more'] as int)} strains.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          if (widget.loadSheets != null) ...[
            const SizedBox(height: 16),
            _lotTable(selected != null
                ? lotStrainFilter(selected['name'] as String)
                : pickedType != null
                    ? lotTypeFilter(pickedType)
                    : null),
          ],
          if (other.isNotEmpty) ...[
            const SizedBox(height: 16),
            _otherSection(other),
          ],
        ],
      ),
    );
  }

  Widget _signInRow() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Expanded(child: Text(_signInBanner, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer))),
          if (widget.onSignInAgain != null)
            TextButton(onPressed: () => widget.onSignInAgain!(context), child: const Text('Sign in again')),
        ]),
      );

  Widget _banner(String text) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer)),
      );

  /// Shows (or, tapped again, hides) a strain's serving-size pies. "Other (n strains)" has no row: nothing shows.
  /// A strain picked replaces a picked type (SP-D17: one pick at a time).
  void _pick(String name) => setState(() {
        _strain = _strain == name ? null : name;
        _type = null;
      });

  /// SP-D17: picks (or, tapped again, unpicks) a type on the By type pie, replacing a picked strain.
  void _pickType(String name) => setState(() {
        _type = _type == name ? null : name;
        _strain = null;
      });

  Widget _swatch(String slot, {String strainSlot = 's1'}) => Container(
        width: 12,
        height: 12,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: stockSlotColor(slot, strainSlot: strainSlot, brightness: Theme.of(context).brightness),
          borderRadius: BorderRadius.circular(2),
        ),
      );

  /// One key line, as the server's: swatch, name, "{value:g}{unit} · {pct}%".
  Widget _keyLine(Key key, Map<String, Object?> s, String unit, {VoidCallback? onTap, String strainSlot = 's1'}) {
    final line = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          _swatch(s['slot'] as String, strainSlot: strainSlot),
          Expanded(child: Text(s['name'] as String)),
          Text('${formatG(s['value'] as num)}$unit · ${s['pct']}%'),
        ],
      ),
    );
    return InkWell(key: key, onTap: onTap, child: line);
  }

  /// The units pie, the mg pie when there are mg figures, and the By type pie (SP-D17), one at a time in the same
  /// spot: swipe it, or tap a dot, for another.
  Widget _pies(Map<String, Object?> units, Map<String, Object?>? mg, Map<String, Object?>? type, bool byMg) {
    final build = <Widget Function()>[
      () => _strainPie('Units in stock', units, 'units', ' units'),
      if (mg != null) () => _strainPie(_mgHeading, mg, 'mg', ' $_mgUnit'),
      if (type != null) () => _typePie(type, byMg ? ' $_mgUnit' : ' units'),
    ];
    return SwipePies(
      key: const ValueKey('stock-pies'),
      index: _pie.clamp(0, build.length - 1),
      onIndex: (i) => setState(() => _pie = i),
      dots: [
        (key: const ValueKey('stock-pie-dot-units'), label: 'Units pie'),
        if (mg != null) (key: const ValueKey('stock-pie-dot-mg'), label: 'mg pie'),
        if (type != null) (key: const ValueKey('stock-pie-dot-type'), label: 'By type pie'),
      ],
      build: (i) => build[i](),
    );
  }

  /// SP-D17: the stock by type, as the Mazama page's By type pie; tapping a type narrows the lot table to it.
  Widget _typePie(Map<String, Object?> pie, String unit) {
    final slices = (pie['slices'] as List).cast<Map<String, Object?>>();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('By type', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Center(child: StockPie(slices: slices, size: 160, onTapSlice: _pickType, label: 'Stock by type')),
            const SizedBox(height: 8),
            for (final s in slices)
              _keyLine(ValueKey('type-key-${s['name']}'), s, unit, onTap: () => _pickType(s['name'] as String)),
            const SizedBox(height: 4),
            Text('Tap a type to show only its lots below.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _strainPie(String title, Map<String, Object?> pie, String keyPrefix, String unit) {
    final slices = (pie['slices'] as List).cast<Map<String, Object?>>();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Center(child: StockPie(slices: slices, size: 160, onTapSlice: _pick, label: title)),
            const SizedBox(height: 8),
            for (final s in slices)
              _keyLine(ValueKey('$keyPrefix-key-${s['name']}'), s, unit, onTap: () => _pick(s['name'] as String)),
            const SizedBox(height: 4),
            Text('Tap a strain for its serving sizes.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _sizes(Map<String, Object?> row) {
    final slot = row['slot'] as String;
    final sizePies = (row['size_pies'] as List).cast<Map<String, Object?>>();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _swatch(slot),
                Expanded(child: Text('${row['name']} serving sizes', style: Theme.of(context).textTheme.titleSmall)),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _strain = null),
                ),
              ],
            ),
            // Quantity and mg, one at a time in the same spot, as the main pies: swipe it, or tap a dot, for the other.
            if (sizePies.isNotEmpty)
              SwipePies(
                key: const ValueKey('size-pies'),
                index: _sizePie,
                onIndex: (i) => setState(() => _sizePie = i),
                dots: [
                  for (final p in sizePies)
                    p['title'] == 'Quantity'
                        ? (key: const ValueKey('size-pie-dot-units'), label: 'Quantity pie')
                        : (key: const ValueKey('size-pie-dot-mg'), label: 'mg pie'),
                ],
                build: (i) => _sizePieView(row, sizePies[i]),
              ),
          ],
        ),
      ),
    );
  }

  /// One of a strain's serving-size pies: its title and total, the pie, its key lines.
  Widget _sizePieView(Map<String, Object?> row, Map<String, Object?> p) {
    final slot = row['slot'] as String;
    final slices = (p['slices'] as List).cast<Map<String, Object?>>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(children: [
          Text(p['title'] as String),
          Text(' · ${formatG(p['total'] as num)} ${p['title'] == 'Quantity' ? 'units' : _mgUnit}'),
        ]),
        const SizedBox(height: 4),
        Center(child: StockPie(slices: slices, size: 120, strainSlot: slot, label: '${row['name']}: ${p['title']}')),
        for (final s in slices)
          _keyLine(
            ValueKey('size-key-${p['title']}-${s['name']}'),
            s,
            '', // the server's size keys carry no unit: "10 · 71%"
            strainSlot: slot,
          ),
      ],
    );
  }

  // --- product information sheets (SP-D11, SP-R16) -------------------------------------------------------------

  Future<void> _open(ProductSheet sheet) async {
    final open = widget.openSheet;
    if (open != null) return open(sheet);
    final url = sheet.url();
    final messenger = ScaffoldMessenger.of(context);
    if (url == null) {
      messenger.showSnackBar(SnackBar(content: Text("${sheet.guid}'s sheet can't be opened here.")));
      return;
    }
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      opened = false;
    }
    if (!opened) messenger.showSnackBar(SnackBar(content: Text("Couldn't open ${sheet.guid}'s sheet.")));
  }

  /// SP-D18: the center's lots as the Mazama page's lot table, in place of the product information sheets list:
  /// [sheetLotRows] of the sheets, narrowed by the strain or type picked on a pie ([filter]).
  Widget _lotTable(LotFilter? filter) {
    final sheets = _sheets;
    final error = _sheetsError;
    return MazamaLotTable(
      key: const ValueKey('stock-lot-table'),
      lots: sheets == null ? const [] : sheetLotRows(sheets),
      filter: filter,
      note: sheets != null ? null : (error != null ? 'Lots did not load: $error' : 'Loading…'),
      noteIsError: sheets == null && error != null,
      onOpen: (lot) {
        final sheet = sheets?.where((s) => s.guid == lot.lot).firstOrNull;
        if (sheet != null) _open(sheet);
      },
    );
  }

  // --- other stock ---------------------------------------------------------------------------------------------

  /// stockview.filter_rows' reasons in the server's words (stockdata.OTHER_REASONS).
  static const _reasons = {'expired': 'expired', 'other_maker': 'other maker'};

  /// A row's name in "Other stock": the product name, else its package id (the server's order and label).
  static String _otherName(StockRow r) => (r.description == null || r.description!.isEmpty) ? r.productGuid : r.description!;

  Widget _otherSection(List<({StockRow row, String reason})> other) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              expanded: _otherOpen,
              child: InkWell(
                key: const ValueKey('other-toggle'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _otherOpen = !_otherOpen),
                child: Row(
                  children: [
                    Expanded(child: Text('Other stock (${other.length})', style: theme.textTheme.titleSmall)),
                    Icon(_otherOpen ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
            if (_otherOpen) ...[
              const SizedBox(height: 4),
              Text(
                  _makers == 'mazama'
                      ? "Not counted in these charts: other makers' product (it still counts towards par), anything "
                          "expired, and packages that can't be sold (locked, flagged or pending a transfer)."
                      : "Not counted in the charts or towards par: anything expired, and packages that can't be sold "
                          '(locked, flagged or pending a transfer).',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              for (final o in other) _otherLine(o.row, o.reason),
            ],
          ],
        ),
      ),
    );
  }

  Widget _otherLine(StockRow r, String reason) {
    final what = _otherName(r);
    return Padding(
      key: ValueKey('other-${r.productGuid}-${r.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(what == r.productGuid ? what : '$what · ${r.productGuid}')),
          Text('${formatG(r.quantity ?? 0)} units'),
          const SizedBox(width: 12),
          Text(reason),
        ],
      ),
    );
  }
}
