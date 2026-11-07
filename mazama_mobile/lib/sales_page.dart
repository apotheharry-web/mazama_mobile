// The center home's fourth tab (Mazama | Stock | Cart | Sales, still
// opening on Stock): the center's sales of the last 30 days, newest first, read from the state system (GetSalesRecords
// through the shared get_json flow, state_client.dart). One line per sale: the state writes a record per
// product sold, all carrying the sale's number, so the records are grouped by it (the shared core's
// selling.sale_groups): the sale number, how many products, the products' names, the date, the units and the total.
// Tapping a line opens it in place to show each product with its units and cost. The sales sit under a header per
// calendar date (Today, Yesterday, else the date; how many sales; the day's total, the core's too), with a gap above
// each; tapping a header collapses that date or opens it again. A deleted (voided) record isn't shown.
//
// After a good read the page keeps it on the phone (the sync engine's recent_sales dataset) and hands every record
// read (not only the 30 days shown) to [SalesPage.upload], which sends them to Mazama's server for invoicing
// (server_link.dart's uploadSalesSnapshot, kept while the server can't be reached). The page never waits on the upload
// and never shows its outcome; selling never waits on either. Never in the demo.
//
// Local first: the copy kept from the last good read shows at once, with its age ("Updated ..."), while the page
// reads again. A failed read keeps showing that copy with no notice of its own (the app-wide banner
// is the only outage notice) and Retry; with none kept, the error and Retry. It reads when its tab is first opened
// (center_home_page.dart builds it only then, never beside the Cart); Retry, or pulling the list down, reads again.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'mazama_core.dart';
import 'pricing.dart' show money;
import 'responsive.dart';
import 'state_client.dart';
import 'selling.dart' show stateDateIso;
import 'sync/sync_datasets.dart';
import 'sync/updated_line.dart';

/// How far back the page shows: today and the 29 days before it.
const recentSalesDays = 30;

/// The state system's GetSalesRecords for [stateId], through the shared get_json flow (state_client.dart).
Future<List<Object?>> fetchSalesRecordsFromState(int stateId, {required String accessToken}) async {
  final body = await fetchStateJson('GetSalesRecords/$stateId', accessToken: accessToken);
  if (body is! List) throw StateReadError('GetSalesRecords/$stateId did not answer with a list');
  return List<Object?>.from(body);
}

/// One row of the page.
class RecentSale {
  const RecentSale(
      {required this.date,
      required this.saleNumber,
      required this.product,
      required this.numberSold,
      required this.cost,
      this.id});

  /// The state's record id, when a number: orders the sales of one day (a later sale has a higher id).
  final num? id;

  /// The sale's date, ISO (YYYY-MM-DD).
  final String date;
  final String saleNumber;

  /// `productName`, else `productGuid`.
  final String product;
  final num? numberSold;

  /// `productCost`, in dollars as the state writes it.
  final num? cost;

  String get costText => cost == null ? '—' : money((cost! * 100).round());
}

bool _deleted(Object? v) => v == true || v == 1 || (v is String && const {'true', 'y', 'yes', '1'}.contains(v.toLowerCase()));

String _text(Object? v) => v == null ? '' : '$v'.trim();

/// One line of the page: a sale, its records (one per product) in the page's order, its units and its total in cents
/// (null when the core couldn't add them up, or a record lacks the figure).
class RecentSaleGroup {
  const RecentSaleGroup({required this.saleNumber, required this.rows, required this.units, required this.totalCents});

  final String saleNumber;
  final List<RecentSale> rows;
  final num? units;
  final int? totalCents;

  /// The sale's date: its first record's.
  String get date => rows.first.date;
  String get totalText => totalCents == null ? '—' : money(totalCents!);
}

/// One calendar date of the page: its sales (in the page's order), how many, and its total in cents (null when the
/// core couldn't add it up, or a sale's total is unknown).
class RecentSaleDay {
  const RecentSaleDay({required this.date, required this.sales, required this.totalCents});

  /// ISO (YYYY-MM-DD).
  final String date;
  final List<RecentSaleGroup> sales;
  final int? totalCents;

  String get totalText => totalCents == null ? '—' : money(totalCents!);
}

/// [rows] (the page's order) by calendar date, one line per sale, by the shared core's selling.sale_groups. When the
/// core can't answer, each record is a line of its own with its own cost, and no day has a total: never a figure the
/// core didn't give.
List<RecentSaleDay> recentSaleDays(List<RecentSale> rows, {CoreFunctions? core}) {
  try {
    final reply = (core ?? MazamaCore.instance).sellingSaleGroups({
      'sales': [
        for (final r in rows) {'sale_number': r.saleNumber, 'date': r.date, 'number_sold': r.numberSold, 'cost': r.cost},
      ],
    });
    final groups = reply['groups'], days = reply['days'];
    if (groups is! List || days is! List) throw const FormatException('selling.sale_groups answered in another shape');
    final sales = [
      for (final g in groups.cast<Map>())
        RecentSaleGroup(
          saleNumber: g['sale_number'] as String,
          rows: [for (final i in (g['rows'] as List).cast<int>()) rows[i]],
          units: g['units'] as num?,
          totalCents: g['total_cents'] as int?,
        ),
    ];
    return [
      for (final d in days.cast<Map>())
        RecentSaleDay(
          date: d['date'] as String,
          sales: [for (final i in (d['groups'] as List).cast<int>()) sales[i]],
          totalCents: d['total_cents'] as int?,
        ),
    ];
  } catch (_) {
    final out = <RecentSaleDay>[];
    for (final r in rows) {
      final line = RecentSaleGroup(
          saleNumber: r.saleNumber, rows: [r], units: r.numberSold, totalCents: r.cost == null ? null : (r.cost! * 100).round());
      if (out.isNotEmpty && out.last.date == r.date) {
        out.last.sales.add(line);
      } else {
        out.add(RecentSaleDay(date: r.date, sales: [line], totalCents: null));
      }
    }
    return out;
  }
}

/// [rows] (the page's order) one line per sale ([recentSaleDays]' sales, day after day).
List<RecentSaleGroup> groupRecentSales(List<RecentSale> rows, {CoreFunctions? core}) =>
    [for (final d in recentSaleDays(rows, core: core)) ...d.sales];

/// The sales of [records] dated in the last [recentSalesDays] days ([now]'s date and the days before it), newest first
/// (within a day by record id, highest first, else by sale number); deleted records, and records without a usable
/// date, are left out.
List<RecentSale> recentSales(List<Object?> records, {required DateTime now}) {
  final today = DateTime.utc(now.year, now.month, now.day);
  final first = today.subtract(const Duration(days: recentSalesDays - 1));
  final rows = <RecentSale>[];
  for (final r in records) {
    if (r is! Map || _deleted(r['deleted'])) continue;
    final iso = stateDateIso(r['dateOfSale'] is String ? r['dateOfSale'] as String : null);
    if (iso == null) continue;
    final day = DateTime.parse('${iso}T00:00:00Z');
    if (day.isBefore(first)) continue;
    final name = _text(r['productName']);
    rows.add(RecentSale(
      date: iso,
      saleNumber: _text(r['saleNumber']),
      product: name.isNotEmpty ? name : _text(r['productGuid']),
      numberSold: r['numberSold'] is num ? r['numberSold'] as num : null,
      cost: r['productCost'] is num ? r['productCost'] as num : null,
      id: r['id'] is num ? r['id'] as num : null,
    ));
  }
  rows.sort((a, b) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
    final ai = a.id, bi = b.id;
    if (ai != null && bi != null && ai != bi) return bi.compareTo(ai);
    return b.saleNumber.compareTo(a.saleNumber);
  });
  return rows;
}

/// A sale's products for its collapsed line, in order, each named once: a product sold on more than one record of
/// the sale reads "PKPR-579b4701 ×2" rather than the same name over again.
String saleProductNames(List<String> products) {
  final counts = <String, int>{};
  for (final p in products) {
    counts[p] = (counts[p] ?? 0) + 1;
  }
  return [for (final MapEntry(key: p, value: n) in counts.entries) n > 1 ? '$p ×$n' : p].join(', ');
}

class SalesPage extends StatefulWidget {
  const SalesPage({
    super.key,
    required this.stateId,
    required this.load,
    required this.upload,
    required this.datasets,
    this.now = DateTime.now,
    this.demo = false,
    this.core,
  });

  /// The center's state id.
  final int stateId;

  /// The center's sales records from the state system ([fetchSalesRecordsFromState] with a fresh token in the app).
  final Future<List<Object?>> Function() load;

  /// Sends every record read to Mazama's server (server_link.dart's uploadSalesSnapshot in the app). Not awaited;
  /// whatever it throws is dropped. Never called in the demo.
  final Future<void> Function(List<Object?> records) upload;

  /// Where the last good read is kept (the recent_sales dataset of the center), shown at once and after a failed read.
  final Datasets datasets;

  /// The clock: the 30-day window and when a read was kept. Overridable for tests.
  final DateTime Function() now;

  /// Demo mode: nothing is uploaded.
  final bool demo;

  /// The shared core, which groups the records into sales; [MazamaCore.instance] when null. Tests pass a fake.
  final CoreFunctions? core;

  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  List<RecentSale>? _rows;

  /// The sales open to show their products, by [_openKey].
  final _open = <String>{};

  /// The dates collapsed to their header (every date starts open).
  final _closedDays = <String>{};
  String? _error;
  bool _loading = true;

  /// The last read failed: Retry shows (over the kept copy, or the error).
  bool _failed = false;

  /// When the records on screen were read (the age line); null while none are.
  DateTime? _readAt;

  String get _key => '${widget.stateId}';

  @override
  void initState() {
    super.initState();
    final kept = _kept();
    if (kept != null) {
      _rows = recentSales(kept.$1, now: widget.now());
      _readAt = kept.$2;
    }
    unawaited(_load());
  }

  /// The copy kept from the last good read, with when; null when none (or none readable).
  (List<Object?>, DateTime)? _kept() {
    try {
      final row = widget.datasets.read(Dataset.recentSales, _key);
      if (row == null) return null;
      final body = jsonDecode(row.body);
      return body is List ? (List<Object?>.from(body), row.fetchedAt) : null;
    } catch (_) {
      return null;
    }
  }

  void _upload(List<Object?> records) {
    if (widget.demo) return;
    try {
      unawaited(widget.upload(records).then((_) {}, onError: (Object _) {}));
    } catch (_) {
      // the upload is best effort and never the page's concern
    }
  }

  /// The read under way; a pull-down or Retry meanwhile joins it rather than starting a second one.
  Future<void>? _reading;

  Future<void> _load() {
    final running = _reading;
    if (running != null) return running;
    final read = _read();
    _reading = read;
    return read.whenComplete(() => _reading = null);
  }

  Future<void> _read() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    List<Object?> records;
    try {
      records = await widget.load();
    } catch (e) {
      if (!mounted) return;
      try {
        widget.datasets.failed(Dataset.recentSales, _key, '$e', at: widget.now());
      } catch (_) {
        // recording the failure is best effort
      }
      final kept = _kept();
      setState(() {
        _loading = false;
        _failed = true;
        if (kept != null) {
          _rows = recentSales(kept.$1, now: widget.now());
          _readAt = kept.$2;
        } else {
          _rows = null;
          _readAt = null;
          _error = '$e';
        }
      });
      return;
    }
    final at = widget.now().toUtc();
    try {
      widget.datasets.put(Dataset.recentSales, _key, jsonEncode(records),
          source: widget.demo ? sourceDemo : sourceState, at: at); // the demo's rows say demo
    } catch (_) {
      // the copy for a failed read is best effort
    }
    _upload(records);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = false;
      _rows = recentSales(records, now: widget.now());
      _readAt = at;
    });
  }

  Widget _retry() => Padding(
        padding: const EdgeInsets.all(8),
        child: Center(
          child: OutlinedButton.icon(
            key: const ValueKey('sales-retry'),
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ),
      );

  /// "Today", "Yesterday" or the date itself, by the page's clock.
  String _dayName(String iso) {
    final now = widget.now();
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final today = DateTime(now.year, now.month, now.day);
    if (iso == ymd(today)) return 'Today · $iso';
    if (iso == ymd(today.subtract(const Duration(days: 1)))) return 'Yesterday · $iso';
    return iso;
  }

  /// A date's header: the date, how many sales and the day's total; a tap collapses or opens the date.
  Widget _dayHeader(RecentSaleDay day, {required bool first, required bool closed}) {
    final theme = Theme.of(context);
    final count = day.sales.length;
    return Padding(
      key: ValueKey('sale-day-${day.date}'),
      padding: EdgeInsets.only(top: first ? 4 : 20),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        child: InkWell(
          onTap: () => setState(() => closed ? _closedDays.remove(day.date) : _closedDays.add(day.date)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                Expanded(child: Text(_dayName(day.date), style: theme.textTheme.titleSmall)),
                Text(count == 1 ? '1 sale · ' : '$count sales · ',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                // the day's total in the same right-hand column as each sale's, so the money lines up down the page
                SizedBox(
                  width: _moneyWidth,
                  child: Text(day.totalText,
                      textAlign: TextAlign.end, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ),
                Icon(closed ? Icons.expand_more : Icons.expand_less, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A sale's key for [_open]: its number; a sale without one by its first record's place.
  String _openKey(RecentSaleGroup g, int at) => g.saleNumber.isEmpty ? '#$at' : g.saleNumber;

  static String _units(num? n) => n == null ? '—' : (n == 1 ? '1 unit' : '$n units');

  /// The width of the money column, wide enough for "$10,000.00".
  static const double _moneyWidth = 88;

  Widget _sale(RecentSaleGroup g, int at) {
    final key = _openKey(g, at);
    final open = _open.contains(key);
    final theme = Theme.of(context);
    final count = g.rows.length;
    final names = saleProductNames([for (final r in g.rows) r.product]);
    return Column(
      key: ValueKey('sale-$key'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          tileColor: open ? theme.colorScheme.surfaceContainerHighest : null,
          onTap: () => setState(() => open ? _open.remove(key) : _open.add(key)),
          title: Row(
            children: [
              const Text('Sale '),
              Text(g.saleNumber, key: const ValueKey('sale-number')),
              if (count > 1) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
                  child: Text('$count products', style: theme.textTheme.labelSmall),
                ),
              ],
            ],
          ),
          subtitle: Text(open ? '${g.date} · ${_units(g.units)}' : '$names\n${g.date} · ${_units(g.units)}'),
          isThreeLine: !open,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: _moneyWidth,
                child: Text(g.totalText,
                    textAlign: TextAlign.end, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
        if (open)
          for (final (i, r) in g.rows.indexed)
            Container(
              key: ValueKey('sale-product-$i'), // siblings: each its own key
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(32, 6, 16, 6),
              child: Row(
                children: [
                  Expanded(child: Text(r.product, overflow: TextOverflow.ellipsis)),
                  Text('${r.numberSold ?? '—'} × · ${r.costText}'),
                ],
              ),
            ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _body() {
    final rows = _rows;
    if (rows == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return ListView(children: [
        Padding(padding: const EdgeInsets.all(16), child: Text(_error ?? '', textAlign: TextAlign.center)),
        _retry(),
      ]);
    }
    final days = recentSaleDays(rows, core: widget.core);
    // a header per date (with a gap above it after the first), then its sales unless it is collapsed
    final items = <Widget>[];
    var at = 0;
    for (final (n, day) in days.indexed) {
      final closed = _closedDays.contains(day.date);
      items.add(_dayHeader(day, first: n == 0, closed: closed));
      for (final sale in day.sales) {
        if (!closed) items.add(_sale(sale, at));
        at++;
      }
    }
    // The heading (and Retry, after a failed read), then one line per sale, built as they scroll into view.
    final head = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text('The last $recentSalesDays days', style: Theme.of(context).textTheme.titleSmall),
      ),
      UpdatedLine.at(_readAt, now: widget.now),
      if (_failed) _retry(),
      if (rows.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No sales in the last 30 days.')),
    ];
    // Pulled down: read again (the stock list, the picker and this tab are the three that pull down).
    return RefreshIndicator(
      key: const ValueKey('sales-refresh'),
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: head.length + items.length,
        itemBuilder: (context, i) => i < head.length ? head[i] : items[i - head.length],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // No title bar: it sits under the home's tab labels, whose "Sales" is its title, as the other tabs' pages.
    return Scaffold(body: ResponsiveBody(child: _body()));
  }
}
