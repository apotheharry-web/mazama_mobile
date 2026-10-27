// specs/mazama-inventory MI-D10: the review page between the order form and Mazama. It shows the order as it will be
// sent (each line, the units in all) with a box for notes that go along with it. "Back to edit" (or the back gesture)
// returns to the form with everything kept, the notes included; "Submit order" is what sends it
// (order_client.dart, route C14). A refusal keeps this page as it was, with the server's message; an order that
// can't reach Mazama's server is never queued: the page says to try again later, with the order and notes as they were
// (server_offline.dart).
import 'package:flutter/material.dart';

import 'api_contract.g.dart';
import 'licenses_client.dart';
import 'order_client.dart';
import 'responsive.dart';
import 'server_error.dart';
import 'server_offline.dart';
import 'stock_summary.dart';

/// What the review page hands back to the form: the notes as they stand, and the stored order once it was sent.
class OrderReviewResult {
  final String note;
  final OrderReceipt? receipt;
  const OrderReviewResult({required this.note, this.receipt});
}

/// "12 × Golden Teacher 25 mg, Freeze dried", or "20 × Chocolate Booster" for an edible product (specs/edibles ED-A6:
/// the product is its own kind): one line as the review page, the confirmation and the form's summary write it.
String orderLineText(OrderLine l) => stockIsProduct(l.strain)
    ? '${l.quantity} × ${l.strain} ${orderSizeLabel(l.size)}'
    : '${l.quantity} × ${l.strain} ${orderSizeLabel(l.size)}, ${orderKinds[l.type] ?? l.type}';

class OrderReviewPage extends StatefulWidget {
  const OrderReviewPage({super.key, required this.center, required this.lines, required this.submit, this.initialNote = ''});

  final License center;
  final List<OrderLine> lines;

  /// The notes typed on an earlier visit to this page (kept when the worker went back to edit).
  final String initialNote;

  /// Sends the order with its notes.
  final Future<OrderReceipt> Function(List<OrderLine> lines, String note) submit;

  @override
  State<OrderReviewPage> createState() => _OrderReviewPageState();
}

class _OrderReviewPageState extends State<OrderReviewPage> {
  late final TextEditingController _note = TextEditingController(text: widget.initialNote);
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _back() => Navigator.of(context).pop(OrderReviewResult(note: _note.text));

  Future<void> _submit() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final receipt = await widget.submit(widget.lines, _note.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop(OrderReviewResult(note: _note.text, receipt: receipt));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'The order was not sent: ${isServerUnreachable(e) ? serverTryLater : e}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final units = widget.lines.fold<int>(0, (s, l) => s + l.quantity);
    final n = widget.lines.length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_sending) _back();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Review order')),
        body: ResponsiveBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text('To Mazama from ${widget.center.licenseName}', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text('$n ${n == 1 ? 'line' : 'lines'}, $units units', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    for (final l in widget.lines)
                      Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(orderLineText(l))),
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('order-notes'),
                      controller: _note,
                      enabled: !_sending,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: orderMaxNoteChars,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Notes for Mazama (optional)',
                        hintText: 'Anything Mazama should know about this order',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                      ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Row(children: [
                    OutlinedButton.icon(
                      onPressed: _sending ? null : _back,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Back to edit'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _sending ? null : _submit,
                      child: _sending
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Submit order'),
                    ),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
