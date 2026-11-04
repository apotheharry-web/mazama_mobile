// What the stock page, the Mazama page and the order's par step share about Mazama's server coming back: while a page
// shows the copy kept on the phone (or partial stock), it reloads by itself once the app's server tracker
// (server_health.dart) counts the server online again, and its Retry asks the server first when the tracker counts it
// unreachable (the probe brings it back at once if it answers, so the reload isn't short-circuited). A Retry under way
// reloads by itself, so the tracker's news doesn't reload a second time. [LoadFailed] is the pages' failed-load
// message with its Retry (or another action), [PageNotice] their notice above what they show.
import 'package:flutter/material.dart';

import 'server_health.dart';

mixin ServerReload<T extends StatefulWidget> on State<T> {
  /// The app's server tracker; null: neither (tests, the demo).
  ServerHealth? get serverHealth;

  /// The page shows the copy kept on the phone (or partial stock): only then does the server answering again reload it.
  bool get showingKeptCopy;

  /// Reloads the page: [cameBack] when the server answered again, else Retry's reload.
  void reload({required bool cameBack});

  bool _wasOffline = false;
  bool _retrying = false;

  /// Starts listening to [serverHealth] (from initState).
  void listenForServer() {
    _wasOffline = serverHealth?.offline ?? false;
    serverHealth?.addListener(_onHealth);
  }

  /// Stops listening (from dispose; harmless when it never started).
  void stopListeningForServer() => serverHealth?.removeListener(_onHealth);

  void _onHealth() {
    final h = serverHealth;
    if (h == null) return;
    final cameBack = _wasOffline && h.online;
    _wasOffline = h.offline;
    if (cameBack && mounted && !_retrying && showingKeptCopy) reload(cameBack: true);
  }

  /// Retry: asks the server first when it is counted as unreachable, then reloads.
  Future<void> retry() async {
    final h = serverHealth;
    if (h != null && h.offline) {
      _retrying = true;
      try {
        await h.checkNow();
      } finally {
        _retrying = false;
      }
      if (!mounted) return;
    }
    reload(cameBack: false);
  }
}

/// A load that failed: [message] centred, and under it [action] (a Retry button by default, [onRetry]).
class LoadFailed extends StatelessWidget {
  const LoadFailed({super.key, required this.message, required this.onRetry, this.action});

  final String message;
  final VoidCallback onRetry;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(message, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 8),
            action ?? FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
}

/// A notice above what a page shows (a kept copy's age, partial figures).
class PageNotice extends StatelessWidget {
  const PageNotice(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer)),
      );
}
