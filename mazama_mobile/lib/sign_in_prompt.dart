// SL-R13: the question a sign-in spec's `await_input` step asks the worker (an MFA code the state sent, say), shown by
// SignInPage (main.dart) as the `ask` it hands runFlow. Continue, or the keyboard's "done", answers the text typed
// without leading or trailing spaces and line breaks (a code pasted from a text or an email often brings one), and does
// nothing while that is empty: a code that hasn't arrived yet is not a cancelled sign-in (final review Important 1).
// Cancel, a tap outside the dialog or the back button answer null, which runFlow turns into reason `cancelled` before
// anything more is sent. Never shown during renew: renew runs with nobody there to ask.
import 'package:flutter/material.dart';

/// Asks the worker [prompt] in a dialog and answers what they typed (trimmed, never empty), or null when they
/// cancelled. With [secret] the field is obscured and nothing is suggested or autocorrected. The field offers the
/// platform's one-time-code autofill, and the dialog scrolls, so a long prompt fits a small phone with the keyboard up.
Future<String?> askSignInValue(BuildContext context, String prompt, {required bool secret}) {
  return showDialog<String>(
    context: context,
    // A tap outside is Cancel: the dialog closes with null, never in some third state.
    barrierDismissible: true,
    builder: (_) => _SignInValueDialog(prompt: prompt, secret: secret),
  );
}

class _SignInValueDialog extends StatefulWidget {
  final String prompt;
  final bool secret;

  const _SignInValueDialog({required this.prompt, required this.secret});

  @override
  State<_SignInValueDialog> createState() => _SignInValueDialogState();
}

class _SignInValueDialogState extends State<_SignInValueDialog> {
  final _controller = TextEditingController();

  /// Set by the first Continue/Cancel: a second press (or "done" right after a tap) must not pop the page underneath.
  bool _closed = false;

  void _close(String? answer) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(answer);
  }

  /// Continue or "done": answers the text typed, trimmed; does nothing while that is empty.
  void _submit() {
    final answer = _controller.text.trim();
    if (answer.isEmpty) return;
    _close(answer);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('The state is asking'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.prompt),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: widget.secret,
            autocorrect: !widget.secret,
            enableSuggestions: !widget.secret,
            keyboardType: TextInputType.text, // a code isn't assumed to be digits only
            autofillHints: const [AutofillHints.oneTimeCode],
            textInputAction: TextInputAction.done,
            // Keeps the field focused (and the keyboard up) when "done" is pressed on an empty field.
            onEditingComplete: () {},
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => _close(null), child: const Text('Cancel')),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => FilledButton(
            onPressed: value.text.trim().isEmpty ? null : _submit,
            child: const Text('Continue'),
          ),
        ),
      ],
    );
  }
}
