// specs/mazama-inventory MI-D21: the order's first step. "Order" on the Mazama inventory page opens this page, where
// the worker sets or confirms the center's par levels (par_levels_editor.dart, the table that was on the stock page
// until SP-D19) before the order form (order_form_page.dart), which starts from exactly the levels confirmed or saved
// here. Back from the form comes back here; Done once the order is sent closes both.
//
// It loads the center's stock (for the units on hand) and par levels together, through the same loaders the stock
// page uses (select_center_page.dart). Stock that doesn't load still lets the par levels be set (on hand shows 0); par
// levels that don't load can only be retried. Partial stock (the server unreachable, SP-R13), or par levels that are
// the copy kept on the phone (Mazama's server can't be reached, sync/server_read.dart), show the table read-only: the
// levels can be confirmed but not saved, and the editor says why. The page has no notice of its own that the server
// can't be reached: the app-wide banner says so (server_link.dart, README R87), and the page reloads by itself once
// the server answers again.
import 'dart:async';

import 'package:flutter/material.dart';

import 'licenses_client.dart';
import 'par_levels_editor.dart';
import 'responsive.dart';
import 'server_health.dart';
import 'sync/server_read.dart' show ServerRead;
import 'par_columns.dart';
import 'stock_rows.dart';
import 'stock_summary.dart';

class OrderParPage extends StatefulWidget {
  const OrderParPage({
    super.key,
    required this.center,
    required this.loadRows,
    required this.loadPar,
    required this.savePar,
    required this.orderForm,
    this.loadParColumns,
    this.saveParColumns,
    this.health,
  });

  final License center;

  /// The center's packages as stock rows, with how they are to be shown (the stock page's loader).
  final Future<StockLoad> Function() loadRows;

  /// The center's par levels: the server's, else (the server can't be reached) the copy kept for offline, with when.
  final Future<ServerRead<List<ParLevel>>> Function() loadPar;

  /// Sends the edited par levels (null par removes one) and returns the levels as stored.
  final Future<List<ParLevel>> Function(List<ParLevel> levels) savePar;

  /// SP-D14: the par table's serving-size columns chosen on this phone; none chosen when null.
  final Future<ParColumns> Function()? loadParColumns;

  /// Keeps the columns chosen once a save has gone through; kept for this visit only when null.
  final Future<void> Function(ParColumns columns)? saveParColumns;

  /// The order form, starting from [levels]: the ones confirmed or saved here.
  final Widget Function(List<ParLevel> levels) orderForm;

  /// The app's server tracker (server_health.dart, README R56): while the page shows the copy kept on the phone (or
  /// partial stock), it reloads by itself once the server answers again (README R87), and Retry asks the server first.
  /// Null: neither (tests, the demo).
  final ServerHealth? health;

  @override
  State<OrderParPage> createState() => _OrderParPageState();
}

class _OrderParPageState extends State<OrderParPage> {
  bool _loading = true;
  StockLoad? _stock;
  String? _stockError;
  List<ParLevel>? _levels;
  String? _parError;

  /// The levels shown are the copy kept on the phone (the server couldn't be reached).
  bool _parFromCache = false;
  ParColumns _columns = const ParColumns();

  bool get _showingKeptCopy => _parFromCache || (_stock?.partial ?? false);

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
      _loading = true;
      _parError = null;
    });
    unawaited(() async {
      Object? stockError, parError;
      StockLoad? stock;
      ServerRead<List<ParLevel>>? levels;
      ParColumns? columns;
      await Future.wait<void>([
        Future(() async {
          try {
            stock = await widget.loadRows();
          } catch (e) {
            stockError = e;
          }
        }),
        Future(() async {
          try {
            levels = await widget.loadPar();
          } catch (e) {
            parError = e;
          }
        }),
        Future(() async {
          try {
            columns = await widget.loadParColumns?.call();
          } catch (_) {
            // the columns chosen here are a convenience: without them the table shows the sizes in stock
          }
        }),
      ]);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _stock = stock;
        _stockError = stock == null ? '$stockError' : null;
        _levels = levels?.value;
        _parError = levels == null ? '$parError' : null;
        _parFromCache = levels?.fromCache ?? false;
        if (columns != null) _columns = columns!;
      });
    }());
  }

  /// Opens the order form; the form answers true when it closes on Done after the order was sent, and then this step
  /// is done too.
  Future<void> _continue(List<ParLevel> levels) async {
    final sent = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => widget.orderForm(levels)));
    if (sent == true && mounted) await Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order from Mazama')),
      body: ResponsiveBody(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final levels = _levels;
    if (levels == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text('Par levels did not load: $_parError', textAlign: TextAlign.center),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _retry, child: const Text('Retry')),
          ],
        ),
      );
    }
    final theme = Theme.of(context);
    final stock = _stock;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Set or confirm your par levels: the order starts from them.', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          if (stock == null) _banner('Stock did not load ($_stockError): units on hand show as 0.'),
          ParLevelsEditor(
            rows: stock?.rows ?? const [],
            mgMode: stock?.mgMode ?? 'tpe',
            levels: levels,
            columns: _columns,
            readOnly: _parFromCache || (stock?.partial ?? false),
            savePar: widget.savePar,
            saveParColumns: widget.saveParColumns,
            onContinue: _continue,
          ),
        ],
      ),
    );
  }

  Widget _banner(String text) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer)),
      );
}
