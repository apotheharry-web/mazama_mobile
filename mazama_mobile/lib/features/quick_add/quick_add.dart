// The cart's one-screen add (specs/quick-add): the package's label on top, a Primary and a Secondary button that
// count a unit per tap (long press: back to 0), Clear, and the price when the cart prices each line. It closes with
// the counts and price (LineChoice); the cart makes the lines and runs its own checks on them.
import 'package:flutter/material.dart';

import '../../feature_entry.dart';

/// The most units of one dose a tap can count, whatever the stock.
const quickAddMaxPerDose = 5;

class QuickAddScreen extends StatefulWidget {
  const QuickAddScreen({super.key, required this.args});

  final LineEditorArgs args;

  @override
  State<QuickAddScreen> createState() => _QuickAddScreenState();
}

class _QuickAddScreenState extends State<QuickAddScreen> {
  late int _primary = widget.args.primary;
  late int _secondary = widget.args.secondary;
  bool _perMg = false;
  late final TextEditingController _price = TextEditingController(
      text: widget.args.priceCentsEach == null ? '' : (widget.args.priceCentsEach! / 100).toStringAsFixed(2));

  /// Shown once the worker has typed a price or tried to add without a good one.
  bool _showPriceError = false;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  /// A dose's ceiling: the lowest of 5, the server's units per line and what the stock still holds once the
  /// other dose's count is taken out; never below 0.
  int _ceiling(int otherCount) {
    final a = widget.args;
    final left = a.stockLeft - otherCount;
    final c = [quickAddMaxPerDose, a.maxUnitsPerLine, left].reduce((x, y) => x < y ? x : y);
    return c < 0 ? 0 : c;
  }

  ({int? cents, String? error})? _priceNow() {
    final check = widget.args.price;
    return check == null ? null : check(perMg: _perMg, text: _price.text);
  }

  void _add() {
    final price = _priceNow();
    if (price != null && price.cents == null) {
      setState(() => _showPriceError = true);
      return;
    }
    Navigator.of(context).pop(LineChoice(primary: _primary, secondary: _secondary, priceCentsEach: price?.cents));
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.args;
    final g = a.group;
    final small = Theme.of(context).textTheme.bodySmall;
    final price = _priceNow();
    final none = _primary == 0 && _secondary == 0;
    return AlertDialog(
      // the price field can bring the keyboard up: everything stays reachable above it
      scrollable: true,
      title: Text(g.productType.isEmpty ? g.productGuid : g.productType),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(key: const ValueKey('quick-label'), width: 280, height: 200, child: a.label),
          const SizedBox(height: 8),
          Text(g.productGuid, textAlign: TextAlign.center),
          if (g.strain.isNotEmpty) Text(g.strain, style: small, textAlign: TextAlign.center),
          Text('${g.quantity} in stock (as of last sync)', style: small, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DoseButton(
                  key: const ValueKey('quick-primary'),
                  label: 'Primary',
                  count: _primary,
                  atCeiling: _primary >= _ceiling(_secondary),
                  onTap: () => setState(() => _primary++),
                  onLongPress: () => setState(() => _primary = 0),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _DoseButton(
                  key: const ValueKey('quick-secondary'),
                  label: 'Secondary',
                  count: _secondary,
                  atCeiling: _secondary >= _ceiling(_primary),
                  onTap: () => setState(() => _secondary++),
                  onLongPress: () => setState(() => _secondary = 0),
                ),
              ),
            ],
          ),
          Align(
            child: TextButton(
              key: const ValueKey('quick-clear'),
              onPressed: none ? null : () => setState(() => _primary = _secondary = 0),
              child: const Text('Clear'),
            ),
          ),
          Text('Tap to add one, hold to set back to 0.', style: small, textAlign: TextAlign.center),
          if (a.price != null) ...[
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Price each')),
                ButtonSegment(value: true, label: Text('Price per mg')),
              ],
              selected: {_perMg},
              onSelectionChanged: (s) => setState(() {
                _perMg = s.first;
                _price.clear();
                _showPriceError = false;
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('quick-price'),
              controller: _price,
              decoration: InputDecoration(
                labelText: _perMg ? a.perMgLabel : 'Price each',
                prefixText: '\$',
                errorText: _showPriceError ? price?.error : null,
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() => _showPriceError = true),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text("Priced automatically by the cart's own pricing mode.",
                  style: small?.copyWith(fontStyle: FontStyle.italic), textAlign: TextAlign.center),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('quick-add'),
          onPressed: none ? null : _add,
          child: Text(a.editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

/// One dose's button: its name and count, a unit per tap until [atCeiling], back to 0 on a long press.
class _DoseButton extends StatelessWidget {
  const _DoseButton({
    super.key,
    required this.label,
    required this.count,
    required this.atCeiling,
    required this.onTap,
    required this.onLongPress,
  });

  final String label;
  final int count;
  final bool atCeiling;
  final VoidCallback onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final chosen = count > 0;
    final style = FilledButton.styleFrom(minimumSize: const Size.fromHeight(72));
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 16)),
        Text('$count', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
      ],
    );
    // at its ceiling a tap does nothing, but the button stays pressable for the long press back to 0
    final tap = atCeiling ? () {} : onTap;
    return chosen
        ? FilledButton(style: style, onPressed: tap, onLongPress: onLongPress, child: child)
        : FilledButton.tonal(style: style, onPressed: tap, onLongPress: onLongPress, child: child);
  }
}
