// specs/mazama-inventory MI-D6..D9, MI-D16, MI-R6: the order form the Mazama inventory page opens ("Order from
// Mazama"), opened by the par step (MI-D21, order_par_page.dart). One line per par level the worker has just
// confirmed or saved there (it amends MI-D16: no longer the copy on the phone), strains added in the par editor with no
// stock included, then the combined All strains lines (any strain); each line starts at its full par level
// (MI-D7) and is ordered freeze dried, dehydrated or homogenized (MI-D8), with an "All lines" setter. A quantity of
// 0 leaves a line out. "Review order" opens the review page (MI-D10, order_review_page.dart: the lines, notes, Back to
// edit, Submit order); once it is sent there, the form shows the order's number. Going back to edit keeps the notes.
// Edibles (Chocolate, Gummy, Honey: specs/edibles ED-A6, MI-D17) come below every strain line, one row per product with
// a par level, with just two fields, Booster and Microdose (each starting at its par, else 0). They are of their own
// kind: no freeze dried / dehydrated / homogenized choice, and "All lines" leaves them alone.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'licenses_client.dart';
import 'order_client.dart';
import 'order_review_page.dart';
import 'responsive.dart';
import 'stock_summary.dart';

class OrderFormPage extends StatefulWidget {
  const OrderFormPage({super.key, required this.center, required this.loadPar, required this.submit});

  final License center;

  /// The center's par levels, as confirmed or saved on the par step (MI-D21).
  final Future<List<ParLevel>> Function() loadPar;

  /// Sends the order and its notes; the host adds who and which device (order_client.submitOrder in the app).
  final Future<OrderReceipt> Function(List<OrderLine> lines, String note) submit;

  @override
  State<OrderFormPage> createState() => _OrderFormPageState();
}

class _Line {
  _Line(this.strain, this.size, int par)
      : quantity = TextEditingController(text: '$par'),
        type = stockProductCode(strain);
  final String strain;
  final int size;
  final TextEditingController quantity;
  String? type;

  /// An edible product's line: its type is the product's own code, fixed.
  bool get product => stockIsProduct(strain);

  int get units => int.tryParse(quantity.text.trim()) ?? 0;
  String get key => '$strain|$size';
}

/// An edible's two order sizes, the only fields its row has (MI-D17): Booster, Microdose.
final List<int> _edibleSizes = [for (final e in stockEdibleSizes.values) e.$1];

class _OrderFormPageState extends State<OrderFormPage> {
  List<_Line>? _lines;
  String? _loadError;

  /// The notes typed on the review page, kept while the worker goes back to edit (MI-D10).
  String _note = '';
  OrderReceipt? _sent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final l in _lines ?? const <_Line>[]) {
      l.quantity.dispose();
    }
    super.dispose();
  }

  void _load() {
    setState(() {
      _lines = null;
      _loadError = null;
    });
    unawaited(() async {
      try {
        final levels = await widget.loadPar();
        if (!mounted) return;
        // The par table's order: strain ignoring case, then 25 ... 5 mg, other last; a later level for the same
        // strain and size replaces an earlier one, as on the server. The combined All strains lines follow the
        // strains'; the edibles come last, Booster and Microdose for every product with a par in either.
        final byKey = <String, ParLevel>{};
        for (final l in levels) {
          // a size the row doesn't take (a product's serving size, a strain's Booster) can't be ordered: ED-A6; nor is
          // an edible's Other, which the par table no longer shows (MI-D17)
          if (l.par == null || !stockSizesFor(l.strain).contains(l.size)) continue;
          if (stockIsProduct(l.strain) && l.size == 0) continue;
          final name = stockIsAll(l.strain) ? stockAllStrains : l.strain;
          byKey['${name.toLowerCase()}|${l.size}'] = l;
        }
        int bySize(ParLevel a, ParLevel b) => stockParColumns.indexOf(a.size).compareTo(stockParColumns.indexOf(b.size));
        final strains = [
          for (final l in byKey.values)
            if (!stockIsProduct(l.strain) && !stockIsAll(l.strain)) l,
        ]..sort((a, b) {
            final c = a.strain.toLowerCase().compareTo(b.strain.toLowerCase());
            return c != 0 ? c : bySize(a, b);
          });
        final combined = [for (final l in byKey.values) if (stockIsAll(l.strain)) l]..sort(bySize);
        final products = {for (final l in byKey.values) if (stockIsProduct(l.strain)) stockProductWord(l.strain)};
        setState(() => _lines = [
              for (final l in strains) _Line(l.strain, l.size, l.par!),
              for (final l in combined) _Line(stockAllStrains, l.size, l.par!),
              for (final w in stockEdibles.values)
                if (products.contains(w))
                  for (final d in _edibleSizes) _Line(w, d, byKey['${w.toLowerCase()}|$d']?.par ?? 0),
            ]);
      } catch (e) {
        if (mounted) setState(() => _loadError = '$e');
      }
    }());
  }

  List<_Line> get _ordered => [for (final l in _lines ?? const <_Line>[]) if (l.units > 0) l];

  bool get _ready => _ordered.isNotEmpty && _ordered.every((l) => l.type != null);

  /// The strains' lines: the ones "All lines" sets (a product's line has its own type).
  List<_Line> get _strainLines => [for (final l in _lines ?? const <_Line>[]) if (!l.product) l];

  /// The type every strain's line shares, for the "All lines" setter's selection; null when they differ or none is set.
  String? get _common {
    final types = {for (final l in _strainLines) l.type};
    return types.length == 1 ? types.single : null;
  }

  Future<void> _review() async {
    final lines = [
      for (final l in _ordered) OrderLine(strain: l.strain, size: l.size, type: l.type!, quantity: l.units),
    ];
    final result = await Navigator.of(context).push<OrderReviewResult>(MaterialPageRoute(
      builder: (_) => OrderReviewPage(center: widget.center, lines: lines, initialNote: _note, submit: widget.submit),
    ));
    if (result == null || !mounted) return;
    setState(() {
      _note = result.note;
      _sent = result.receipt;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order from Mazama')),
      body: ResponsiveBody(child: _body()),
    );
  }

  Widget _body() {
    final sent = _sent;
    if (sent != null) return _sentView(sent);
    final lines = _lines;
    if (lines == null) {
      if (_loadError == null) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text('Par levels did not load: $_loadError', textAlign: TextAlign.center),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    if (lines.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text('This center has no par levels yet. Go back to set them; the order starts from them.',
              textAlign: TextAlign.center),
        ),
      );
    }
    final theme = Theme.of(context);
    final ordered = _ordered;
    final units = ordered.fold<int>(0, (s, l) => s + l.units);
    final missingType = ordered.any((l) => l.type == null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The "All lines" setter stays put above the lines, however far down the worker has scrolled.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('From ${widget.center.licenseName}\'s par levels. Change any quantity; 0 leaves a line out.',
                style: theme.textTheme.bodySmall),
            if (_strainLines.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('All lines', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              _typeChoice(const ValueKey('type-all'), _common, (t) => setState(() {
                for (final l in _strainLines) {
                  l.type = t;
                }
              })),
            ],
          ]),
        ),
        const Divider(height: 24),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              for (final l in lines)
                if (!l.product) _lineRow(l),
              ..._edibleSection(lines),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (missingType)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('Choose freeze dried, dehydrated or homogenized for every line you order.',
                      style: theme.textTheme.bodySmall),
                ),
              Row(children: [
                Expanded(child: Text('${ordered.length} ${ordered.length == 1 ? 'line' : 'lines'} · $units units')),
                FilledButton(onPressed: _ready ? _review : null, child: const Text('Review order')),
              ]),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _typeChoice(Key key, String? selected, ValueChanged<String?> onChanged) => SegmentedButton<String>(
        key: key,
        segments: [for (final e in orderKinds.entries) ButtonSegment(value: e.key, label: Text(e.value))],
        selected: {if (selected != null) selected},
        emptySelectionAllowed: true,
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        onSelectionChanged: (s) => onChanged(s.isEmpty ? null : s.single),
      );

  Widget _quantity(_Line l, {String? label}) => SizedBox(
        width: 80,
        child: TextField(
          key: ValueKey('qty-${l.key}'),
          controller: l.quantity,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
          textAlign: TextAlign.end,
          decoration: InputDecoration(isDense: true, suffixText: ' units', labelText: label),
          onChanged: (_) => setState(() {}),
        ),
      );

  /// MI-D17: the edibles below the strain lines, one row per product, with a Booster and a Microdose field.
  List<Widget> _edibleSection(List<_Line> lines) {
    final byProduct = <String, Map<int, _Line>>{};
    for (final l in lines) {
      if (l.product) byProduct.putIfAbsent(l.strain, () => {})[l.size] = l;
    }
    if (byProduct.isEmpty) return const [];
    final theme = Theme.of(context);
    return [
      const Divider(height: 24),
      Text('Edibles', style: theme.textTheme.titleSmall),
      for (final e in byProduct.entries)
        Padding(
          key: ValueKey('edible-${e.key}'),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(e.key, style: theme.textTheme.titleSmall)),
            for (final d in _edibleSizes)
              if (e.value[d] != null)
                Padding(padding: const EdgeInsets.only(left: 12), child: _quantity(e.value[d]!, label: orderSizeLabel(d))),
          ]),
        ),
    ];
  }

  Widget _lineRow(_Line l) => Padding(
        key: ValueKey('line-${l.key}'),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                    l.strain == stockAllStrains
                        ? 'All strains (any strain) · ${orderSizeLabel(l.size)}'
                        : '${l.strain} · ${orderSizeLabel(l.size)}',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              _quantity(l),
            ]),
            if (!l.product) ...[
              const SizedBox(height: 6),
              _typeChoice(ValueKey('type-${l.key}'), l.type, (t) => setState(() => l.type = t)),
            ],
          ],
        ),
      );

  Widget _sentView(OrderReceipt r) {
    final units = r.lines.fold<int>(0, (s, l) => s + l.quantity);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Order ${r.id} sent to Mazama', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('${r.lines.length} ${r.lines.length == 1 ? 'line' : 'lines'}, $units units'),
        const SizedBox(height: 12),
        for (final l in r.lines) Text(orderLineText(l)),
        if (r.note.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Notes: ${r.note}'),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          // true: the order was sent, so the par step that opened this form closes too (MI-D21)
          child: FilledButton(onPressed: () => Navigator.of(context).maybePop(true), child: const Text('Done')),
        ),
      ],
    );
  }
}
