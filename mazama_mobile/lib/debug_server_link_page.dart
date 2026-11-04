// Debug-only (reached from DebugToolsPage): what the phone's link to Mazama's server is doing (server_link.dart)
// - whether the tracker counts the server as reachable and since when, the next probe, the reports waiting in the
// outbox, the dead letters (reports the server refused: kept, never sent again, never deleted), how many sale logs were
// dropped for room, the lab reports and inventory snapshots waiting to catch up, the sync engine's datasets (what the
// phone knows, from where, when, and the last refresh's error). "Check now" probes the server; "Send now" sends what is
// waiting.
import 'package:flutter/material.dart';

import 'catch_up_store.dart';
import 'server_link.dart';
import 'sync/updated_line.dart' show formatAsOf;
import 'server_outbox.dart';
import 'sync/sync_tables.dart' show DatasetRow;

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
        listenable: Listenable.merge([l.health, l.queue]),
        builder: (context, _) {
          final h = l.health;
          final q = l.queue;
          final pending = q.saleReports(dead: false), dead = q.saleReports(dead: true);
          final lots = q.keptCoaLots, snapshots = q.keptSnapshots;
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
              Text('Outbox: ${q.waitingReports} waiting', key: const ValueKey('outbox-count')),
              if (q.droppedSaleLogs > 0)
                Text('${q.droppedSaleLogs} sale logs dropped because the outbox was full (cap $outboxCap)',
                    key: const ValueKey('outbox-dropped')),
              if (q.waitingOutBusy) const Text('Waiting a minute: the server said too many requests'),
              for (final e in pending) _entry(e),
              const Divider(),
              Text('Dead letters: ${dead.length}', key: const ValueKey('dead-count')),
              for (final e in dead) _entry(e, dead: true),
              const Divider(),
              Text('Lab reports to submit: ${lots.length}'),
              for (final lot in lots)
                Text('  ${lot.lotGuid} (package ${lot.packageId}, center ${lot.stateId}) since ${formatAsOf(lot.addedAt)}'),
              Text('Snapshots to upload (inventory, sales): ${snapshots.length}'),
              for (final s in snapshots.values)
                Text('  ${s.kind}, center ${s.stateId}: ${s.records.length} records read ${formatAsOf(s.readAt)}'),
              const Divider(),
              const Text('Datasets kept:'),
              for (final d in l.engine.datasets.list()) Text('  ${_dataset(d)}', key: ValueKey('dataset-${d.name}/${d.key}')),
            ]),
          );
        },
      ),
    );
  }

  /// A dataset as listed: a copy stored at the epoch has no time known, and reads "no time", as the keepers treat it.
  static String _dataset(DatasetRow d) {
    final failed = d.lastError == null ? '' : ' - the last refresh failed: ${d.lastError}';
    final when = d.fetchedAt.millisecondsSinceEpoch == 0 ? 'no time' : formatAsOf(d.fetchedAt);
    return '${d.name}${d.key.isEmpty ? '' : '/${d.key}'} from the ${d.source}, $when$failed';
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
