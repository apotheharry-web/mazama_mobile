// The cart's PKPR keypad (specs/hex-keypad): the PKPR field takes no system keyboard; a keypad under it shows only
// the hex keys a package in the center's stock can follow. Which keys those are, which PKPRs match and whether exactly
// one is left are the shared core's (keypad.keys); this file only shows them and edits the field.
import 'package:flutter/material.dart';

import '../../feature_entry.dart';
import '../../mazama_core.dart';
import '../../packages_client.dart' show PkprGroup;

/// The widest the keypad gets (logical pixels): a phone's width, so a tablet shows the same keys at the same size.
const double keypadMaxWidth = 440;

/// The keypad's keys, in the order they are shown.
const keypadLayout = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'a', 'b', 'c', 'd', 'e', 'f'];

/// What the keypad says while the stock isn't loaded, and while the core can't answer.
const keypadNoStock = 'Stock not loaded yet: no keys until it is.';
const keypadCoreFailed = "This build can't work out the keys.";

/// The core's answer for one text against one stock.
class KeypadAnswer {
  const KeypadAnswer({required this.keys, required this.matches, required this.only});

  final Set<String> keys;
  final List<String> matches;
  final String? only;
}

/// The core's keypad answer for [typed] against [stock]; throws when the core can't answer.
KeypadAnswer keypadAnswer(String typed, List<PkprGroup> stock, {CoreFunctions? core}) {
  final reply = (core ?? MazamaCore.instance).keypadKeys({
    'typed': typed,
    'pkprs': [for (final g in stock) g.productGuid],
  });
  final keys = reply['keys'], matches = reply['matches'], only = reply['only'];
  if (keys is! List || matches is! List || (only != null && only is! String)) {
    throw const FormatException('keypad.keys answered in another shape');
  }
  return KeypadAnswer(
    keys: {for (final k in keys) k as String},
    matches: [for (final m in matches) m as String],
    only: only as String?,
  );
}

/// A PKPR's hex part, as the field holds it: without a leading "PKPR-" (any case).
String _hexPart(String pkpr) {
  final t = pkpr.trim();
  return t.toLowerCase().startsWith('pkpr-') ? t.substring(5) : t;
}

/// The cart's PKPR row with the keypad: the field (no system keyboard), the cart's own buttons beside it, and, while
/// open, the keys that can come next and the matches under it; once one PKPR is filled in, a Clear button instead.
class HexKeypadInput extends StatefulWidget {
  const HexKeypadInput({super.key, required this.args, this.core});

  final PkprInputArgs args;

  /// The shared core; [MazamaCore.instance] when null. Tests pass a fake.
  final CoreFunctions? core;

  @override
  State<HexKeypadInput> createState() => _HexKeypadInputState();
}

class _HexKeypadInputState extends State<HexKeypadInput> {
  /// Matches are listed once this many characters are typed, as the cart's suggestions are.
  static const _minListChars = 2;

  /// Whether the keypad is up. The keypad's own, not the field's focus: the cart gives the field its focus back after
  /// an add, and the keypad stays closed then.
  bool _open = false;

  /// The PKPR the keypad filled in, while the field still holds it: Clear shows instead of the keypad.
  String? _filled;

  /// Set while this keypad changes the field itself, so a change from outside (the cart clearing it after an add)
  /// can be told apart.
  bool _editing = false;

  /// The field's text when last seen: a tap on the field only moves its cursor, which is no change of text.
  late String _lastText = widget.args.controller.text;

  @override
  void initState() {
    super.initState();
    widget.args.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(HexKeypadInput old) {
    super.didUpdateWidget(old);
    if (!identical(old.args.controller, widget.args.controller)) {
      old.args.controller.removeListener(_changed);
      widget.args.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.args.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final text = widget.args.controller.text;
    final textChanged = text != _lastText;
    _lastText = text;
    setState(() {
      if (_editing || !textChanged) return;
      // changed from outside: emptied after an add closes the keypad, and any other text is no fill of ours
      _filled = null;
      if (widget.args.controller.text.isEmpty) _open = false;
    });
  }

  /// The core's answer for [typed], or null when there is none (no stock, or the core can't answer).
  KeypadAnswer? _answerFor(String typed) {
    final stock = widget.args.stock;
    if (stock == null) return null;
    try {
      return keypadAnswer(typed, stock, core: widget.core);
    } catch (_) {
      return null;
    }
  }

  String? _problem(KeypadAnswer? answer) =>
      widget.args.stock == null ? keypadNoStock : (answer == null ? keypadCoreFailed : null);

  void _setText(String text) {
    _editing = true;
    try {
      widget.args.controller.value =
          TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    } finally {
      _editing = false;
    }
  }

  /// Fills the field with [pkpr]'s hex part and closes the keypad, leaving Clear.
  void _fill(String pkpr) {
    _setText(_hexPart(pkpr));
    setState(() {
      _filled = pkpr;
      _open = false;
    });
  }

  /// A key: appended; when that leaves exactly one PKPR, it is filled in.
  void _press(String key) {
    final typed = widget.args.controller.text + key;
    final only = _answerFor(typed)?.only;
    if (only != null) {
      _fill(only);
    } else {
      _setText(typed);
    }
  }

  void _backspace() {
    final text = widget.args.controller.text;
    if (text.isNotEmpty) _setText(text.substring(0, text.length - 1));
  }

  void _clear() {
    _setText('');
    setState(() {
      _filled = null;
      _open = true;
    });
    widget.args.focusNode.requestFocus();
  }

  void _openKeypad() {
    if (_filled != null) return; // a filled-in PKPR waits for Add or Clear
    setState(() => _open = true);
    if (!widget.args.focusNode.hasFocus) widget.args.focusNode.requestFocus();
  }

  void _close() {
    if (_open) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final args = widget.args;
    final answer = _open ? _answerFor(args.controller.text) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('keypad-field'),
                controller: args.controller,
                focusNode: args.focusNode,
                readOnly: true, // the keypad types; the phone's keyboard never comes up
                showCursor: true,
                keyboardType: TextInputType.none,
                decoration: InputDecoration(labelText: 'PKPR', errorText: args.errorText),
                onTap: _openKeypad,
                // a tap anywhere else closes the keypad; the keypad itself is inside the field's tap region
                onTapOutside: (_) => _close(),
              ),
            ),
            args.actions,
          ],
        ),
        if (_filled != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('keypad-clear'),
                onPressed: _clear,
                icon: const Icon(Icons.clear),
                label: const Text('Clear'),
              ),
            ),
          )
        else if (_open)
          TextFieldTapRegion(child: _panel(context, answer)),
      ],
    );
  }

  Widget _panel(BuildContext context, KeypadAnswer? answer) {
    final problem = _problem(answer);
    final scheme = Theme.of(context).colorScheme;
    final typed = _hexPart(widget.args.controller.text);
    final matches = answer == null || typed.length < _minListChars ? const <String>[] : answer.matches;
    final byGuid = {for (final g in widget.args.stock ?? const <PkprGroup>[]) g.productGuid: g};
    final keys = answer == null ? const <String>[] : [for (final k in keypadLayout) if (answer.keys.contains(k)) k];
    // At most a phone's width, centred: the keys are a share of the width, so on a tablet they would otherwise
    // grow into slabs a hand-span wide.
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: keypadMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(problem, key: const ValueKey('keypad-problem'), style: TextStyle(color: scheme.error)),
                ),
              if (keys.isNotEmpty)
                GridView.count(
                  key: const ValueKey('keypad-keys'),
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.6,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  children: [
                    for (final k in keys)
                      FilledButton.tonal(
                        key: ValueKey('keypad-key-$k'),
                        onPressed: () => _press(k),
                        child: Text(k.toUpperCase(), style: const TextStyle(fontSize: 26)),
                      ),
                  ],
                ),
              if (matches.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 144),
                  child: ListView(
                    key: const ValueKey('keypad-matches'),
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final m in matches)
                        ListTile(
                          dense: true,
                          title: Text(m),
                          subtitle: Text(_matchLine(byGuid[m])),
                          onTap: () => _fill(m),
                        ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  key: const ValueKey('keypad-backspace'),
                  onPressed: widget.args.controller.text.isEmpty ? null : _backspace,
                  icon: const Icon(Icons.backspace_outlined),
                  tooltip: 'Backspace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _matchLine(PkprGroup? g) {
    if (g == null) return '';
    final type = g.productType;
    return '${type.isEmpty ? '' : '$type · '}${g.quantity} in stock';
  }
}
