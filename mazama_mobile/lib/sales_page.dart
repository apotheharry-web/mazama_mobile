// specs/center-web CW-R10 (phone half), CW-D14: the center home's fourth tab (Mazama | Stock | Cart | Sales, still
// opening on Stock): the center's sales of the last 30 days, newest first, read from the state system (GetSalesRecords
// through the shared get_json flow, state_client.dart). Each row: the date, the sale number, the product (its name,
// else its id), how many were sold and the line's cost in dollars; a deleted (voided) record isn't shown.
//
// After a good read the page keeps it on the phone (reply_store.dart, `state_sales/<stateId>`) and hands every record
// read (not only the 30 days shown) to [SalesPage.upload], which sends them to Mazama's server for invoicing
// (server_link.dart's uploadSalesSnapshot, kept while the server can't be reached). The page never waits on the upload
// and never shows its outcome; selling never waits on either. Never in the demo.
//
// A failed read shows the copy kept from the last good one with no notice of its own (sales README R87: the app-wide
// banner is the only outage notice) and Retry; with none kept, the error and Retry. It loads once, when its tab is first
// opened (center_home_page.dart builds it only then, never beside the Cart); Retry reads again.
import 'dart:async';

import 'package:flutter/material.dart';

import 'pricing.dart' show money;
import 'reply_store.dart';
import 'responsive.dart';
import 'select_documents.dart' show stateDateIso;
import 'state_client.dart';

/// How far back the page shows (CW-D14): today and the 29 days before it.
const recentSalesDays = 30;

/// The reply-store key of [stateId]'s last good sales read.
String salesReplyKey(int stateId) => replyKey('state_sales', [stateId]);

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

class SalesPage extends StatefulWidget {
  const SalesPage({
    super.key,
    required this.stateId,
    required this.load,
    required this.upload,
    required this.replies,
    this.now = DateTime.now,
    this.demo = false,
  });

  /// The center's state id.
  final int stateId;

  /// The center's sales records from the state system ([fetchSalesRecordsFromState] with a fresh token in the app).
  final Future<List<Object?>> Function() load;

  /// Sends every record read to Mazama's server (server_link.dart's uploadSalesSnapshot in the app). Not awaited;
  /// whatever it throws is dropped. Never called in the demo.
  final Future<void> Function(List<Object?> records) upload;

  /// Where the last good read is kept, for a failed read.
  final ReplyStore replies;

  /// The clock: the 30-day window and when a read was kept. Overridable for tests.
  final DateTime Function() now;

  /// Demo mode: nothing is uploaded.
  final bool demo;

  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  List<RecentSale>? _rows;
  String? _error;
  bool _loading = true;

  /// The last read failed: Retry shows (over the kept copy, or the error).
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _upload(List<Object?> records) {
    if (widget.demo) return;
    try {
      unawaited(widget.upload(records).then((_) {}, onError: (Object _) {}));
    } catch (_) {
      // the upload is best effort and never the page's concern
    }
  }

  void _load() {
    setState(() {
      _loading = true;
      _error = null;
    });
    unawaited(() async {
      List<Object?> records;
      try {
        records = await widget.load();
      } catch (e) {
        if (!mounted) return;
        List<Object?>? kept;
        try {
          final k = widget.replies.load(salesReplyKey(widget.stateId))?.value;
          if (k is List) kept = List<Object?>.from(k);
        } catch (_) {
          kept = null;
        }
        setState(() {
          _loading = false;
          _failed = true;
          if (kept != null) {
            _rows = recentSales(kept, now: widget.now());
          } else {
            _rows = null;
            _error = '$e';
          }
        });
        return;
      }
      try {
        widget.replies.save(salesReplyKey(widget.stateId), records, widget.now().toUtc());
      } catch (_) {
        // the copy for a failed read is best effort
      }
      _upload(records);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = false;
        _rows = recentSales(records, now: widget.now());
      });
    }());
  }

  Widget _retry() => Padding(
        padding: const EdgeInsets.all(8),
        child: Center(
          child: OutlinedButton.icon(
            key: const ValueKey('sales-retry'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ),
      );

  Widget _row(RecentSale s) => ListTile(
        title: Row(
          children: [
            Text(s.saleNumber, key: const ValueKey('sale-number')),
            const SizedBox(width: 8),
            Expanded(child: Text(s.product, overflow: TextOverflow.ellipsis)),
          ],
        ),
        subtitle: Text('${s.date} · ${s.numberSold ?? '—'} sold'),
        trailing: Text(s.costText),
      );

  Widget _body() {
    final rows = _rows;
    if (rows == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return ListView(children: [
        Padding(padding: const EdgeInsets.all(16), child: Text(_error ?? '', textAlign: TextAlign.center)),
        _retry(),
      ]);
    }
    // The heading (and Retry, after a failed read), then the rows, built as they scroll into view.
    final head = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text('The last $recentSalesDays days', style: Theme.of(context).textTheme.titleSmall),
      ),
      if (_failed) _retry(),
      if (rows.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No sales in the last 30 days.')),
    ];
    return ListView.builder(
      itemCount: head.length + rows.length,
      itemBuilder: (context, i) => i < head.length ? head[i] : _row(rows[i - head.length]),
    );
  }

  @override
  Widget build(BuildContext context) {
    // No title bar: it sits under the home's tab labels, whose "Sales" is its title, as the other tabs' pages.
    return Scaffold(body: ResponsiveBody(child: _body()));
  }
}
