// Debug-only (reached from DebugToolsPage): what the phone's link to Mazama's server is doing (server_link.dart, README
// R56) - whether the tracker counts the server as reachable and since when, the next probe, the reports waiting in the
// outbox, the dead letters (reports the server refused: kept, never sent again, never deleted), how many sale logs were
// dropped for room, the lab reports and inventory snapshots waiting to catch up, and which replies are kept for
// offline. "Check now" probes the server; "Send now" sends what is waiting.
import 'package:flutter/material.dart';

import 'server_link.dart';
import 'server_offline.dart' show formatAsOf;
import 'server_outbox.dart';

class DebugServerLinkPage extends StatelessWidget {
  const DebugServerLinkPage({super.key, this.link});

  /// The link shown; the app's own ([serverLink]) when null. Overridable for tests.
  final ServerLink? link;

  @override
  Widget build(BuildContext context) {
    final l = link ?? serverLink;
    return Scaffold(
      appBar: AppBar(title: const Text('Server link (debug)')),
      body: ListenableBuilder(
        listenable: Listenable.merge([l.health, l.outbox, l.catchUp]),
        builder: (context, _) {
          final h = l.health;
          final since = h.offlineSince;
          final status = h.online
              ? 'Online'
              : since == null
                  ? 'Offline'
                  : 'Offline since ${formatAsOf(since)}';
          // a Column, not a lazy list: the page is short, and every line is built (and findable in tests)
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(status, key: const ValueKey('link-status'), style: Theme.of(context).textTheme.titleMedium),
              if (h.offline)
                Text(h.probeScheduled ? 'Next probe in ${h.nextProbeDelay.inSeconds} s or less' : 'A probe is out'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                OutlinedButton(onPressed: () => h.checkNow(), child: const Text('Check now')),
                OutlinedButton(onPressed: l.wake, child: const Text('Send now')),
              ]),
              const Divider(),
              Text('Outbox: ${l.outbox.pendingCount} waiting', key: const ValueKey('outbox-count')),
              if (l.outbox.droppedLogs > 0)
                Text('${l.outbox.droppedLogs} sale logs dropped because the outbox was full (cap $outboxCap)',
                    key: const ValueKey('outbox-dropped')),
              if (l.outbox.waitingOutBusy) const Text('Waiting a minute: the server said too many requests'),
              for (final e in l.outbox.pending) _entry(e),
              const Divider(),
              Text('Dead letters: ${l.outbox.dead.length}', key: const ValueKey('dead-count')),
              for (final e in l.outbox.dead) _entry(e, dead: true),
              const Divider(),
              Text('Lab reports to submit: ${l.catchUp.lots.length}'),
              for (final lot in l.catchUp.lots)
                Text('  ${lot.lotGuid} (package ${lot.packageId}, center ${lot.stateId}) since ${formatAsOf(lot.addedAt)}'),
              Text('Inventory snapshots to upload: ${l.catchUp.snapshots.length}'),
              for (final s in l.catchUp.snapshots.values)
                Text('  center ${s.stateId}: ${s.records.length} records read ${formatAsOf(s.readAt)}'),
              const Divider(),
              const Text('Replies kept for offline:'),
              for (final key in l.replies.keys()) Text('  $key${_keptAt(l, key)}'),
            ]),
          );
        },
      ),
    );
  }

  static String _keptAt(ServerLink l, String key) {
    final kept = l.replies.load(key);
    return kept == null ? '' : ' (${formatAsOf(kept.at)})';
  }

  Widget _entry(OutboxEntry e, {bool dead = false}) {
    final what = e.kind == OutboxKind.saleLog ? 'Sale log' : 'Failed sale';
    final status = e.status == null ? '' : ' HTTP ${e.status}';
    return ListTile(
      dense: true,
      key: ValueKey('${dead ? 'dead' : 'pending'}-${e.clientId}'),
      title: Text('$what, center ${e.stateId}, ${e.request.length} records, ${formatAsOf(e.createdAt)}'),
      subtitle: Text('${e.workerEmail} - ${e.clientId} - tries: ${e.attempts}$status${e.lastError == null ? '' : '\n${e.lastError}'}'),
    );
  }
}
