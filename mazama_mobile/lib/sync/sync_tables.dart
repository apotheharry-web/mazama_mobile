// The sync engine's tables (specs/phone-sync PS-R2, PS-D4), beside the local store's documents in the same database
// (local_store.dart's second migration creates them):
//   - sync_dataset: one row per page's worth of data (a center's stock, its par levels), with where it came from, when
//     it was read, and the newest refresh attempt and its error. A failed refresh changes only those last two.
//   - sync_queue: everything still to send, one row per item, by kind (PS-R4). At most one item per kind and key is
//     waiting or being sent (the partial unique index); dead letters are kept beside it, never sent again.
//   - sync_sent: what was sent lately, by kind and key (the lab reports' 24-hour memory, CU-D2).
// Typed rows over LocalStore's execute/select, synchronous as every LocalStore call (its header says why). Every value
// goes in as a parameter, never into the SQL text.
import '../local_store.dart';

DateTime _time(Object? ms) => DateTime.fromMillisecondsSinceEpoch(ms as int, isUtc: true);
DateTime? _timeOrNull(Object? ms) => ms == null ? null : _time(ms);

/// One dataset as stored: [body] is what its page reads (JSON), [source] `state`, `server`, `merged` or `demo`.
class DatasetRow {
  const DatasetRow({
    required this.name,
    required this.key,
    required this.body,
    required this.source,
    required this.fetchedAt,
    this.lastTry,
    this.lastError,
  });

  final String name, key, body, source;

  /// When [body] was read.
  final DateTime fetchedAt;

  /// The newest refresh attempt, and why it failed (null after a success).
  final DateTime? lastTry;
  final String? lastError;
}

/// Queue states.
const queueWaiting = 'waiting', queueSending = 'sending', queueDead = 'dead';

/// One item to send (or, [state] `dead`, refused for good with its [reason]).
class QueueItem {
  const QueueItem({
    this.id,
    required this.kind,
    required this.key,
    required this.body,
    required this.queuedAt,
    required this.nextAt,
    this.attempts = 0,
    this.state = queueWaiting,
    this.reason,
  });

  /// Null until stored.
  final int? id;
  final String kind, key, body;
  final DateTime queuedAt;

  /// Not sent before this.
  final DateTime nextAt;
  final int attempts;
  final String state;
  final String? reason;

  static QueueItem _fromRow(Map<String, Object?> r) => QueueItem(
        id: r['id'] as int,
        kind: r['kind'] as String,
        key: r['key'] as String,
        body: r['body'] as String,
        queuedAt: _time(r['queued_at_ms']),
        nextAt: _time(r['next_at_ms']),
        attempts: r['attempts'] as int,
        state: r['state'] as String,
        reason: r['reason'] as String?,
      );
}

const _queueColumns = 'id, kind, key, body, queued_at_ms, next_at_ms, attempts, state, reason';

/// The oldest first: by when queued, then by the order stored.
const _oldestFirst = 'ORDER BY queued_at_ms, id';

class SyncTables {
  SyncTables(this.store);

  final LocalStore store;

  // ---- datasets

  static const _datasetColumns = 'name, key, body, source, fetched_at_ms, last_try_ms, last_error';

  static DatasetRow _datasetOf(Map<String, Object?> r) => DatasetRow(
        name: r['name'] as String,
        key: r['key'] as String,
        body: r['body'] as String,
        source: r['source'] as String,
        fetchedAt: _time(r['fetched_at_ms']),
        lastTry: _timeOrNull(r['last_try_ms']),
        lastError: r['last_error'] as String?,
      );

  DatasetRow? dataset(String name, String key) {
    final rows = store.select('SELECT $_datasetColumns FROM sync_dataset WHERE name = ? AND key = ?', [name, key]);
    return rows.isEmpty ? null : _datasetOf(rows.first);
  }

  /// Removes [name]'s copy for [key], or every copy of [name] when [key] is null.
  void deleteDataset(String name, {String? key}) => key == null
      ? store.execute('DELETE FROM sync_dataset WHERE name = ?', [name])
      : store.execute('DELETE FROM sync_dataset WHERE name = ? AND key = ?', [name, key]);

  /// Every dataset stored, by name and key (the debug page).
  List<DatasetRow> allDatasets() => [
        for (final r in store.select('SELECT $_datasetColumns FROM sync_dataset ORDER BY name, key')) _datasetOf(r),
      ];

  /// A refresh that worked: [body] read from [source] at [fetchedAt], which is also the newest attempt.
  void putDataset(String name, String key, String body, {required String source, required DateTime fetchedAt}) {
    final ms = fetchedAt.millisecondsSinceEpoch;
    store.execute(
        'INSERT INTO sync_dataset (name, key, body, source, fetched_at_ms, last_try_ms, last_error) '
        'VALUES (?, ?, ?, ?, ?, ?, NULL) '
        'ON CONFLICT (name, key) DO UPDATE SET body = excluded.body, source = excluded.source, '
        'fetched_at_ms = excluded.fetched_at_ms, last_try_ms = excluded.last_try_ms, last_error = NULL',
        [name, key, body, source, ms, ms]);
  }

  /// A refresh that failed: only the attempt and its [error] are recorded; the body stays as it was. Nothing is
  /// recorded for a dataset with nothing stored yet.
  void datasetFailed(String name, String key, String error, DateTime at) {
    store.execute('UPDATE sync_dataset SET last_try_ms = ?, last_error = ? WHERE name = ? AND key = ?',
        [at.millisecondsSinceEpoch, error, name, key]);
  }

  // ---- the queue

  /// Stores [item], replacing the item of the same kind and key that is waiting or being sent (never a dead letter;
  /// a dead letter stored replaces nothing); its id.
  int enqueue(QueueItem item) => store.transaction(() {
        if (item.state != queueDead) {
          store.execute("DELETE FROM sync_queue WHERE kind = ? AND key = ? AND state <> 'dead'", [item.kind, item.key]);
        }
        store.execute(
            'INSERT INTO sync_queue (kind, key, body, queued_at_ms, next_at_ms, attempts, state, reason) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            [
              item.kind,
              item.key,
              item.body,
              item.queuedAt.millisecondsSinceEpoch,
              item.nextAt.millisecondsSinceEpoch,
              item.attempts,
              item.state,
              item.reason,
            ]);
        return store.select('SELECT last_insert_rowid() AS id').single['id'] as int;
      });

  /// The waiting items of [kind] whose time has come, oldest first.
  List<QueueItem> due(String kind, DateTime now, {int? limit}) => [
        for (final r in store.select(
            "SELECT $_queueColumns FROM sync_queue WHERE kind = ? AND state = 'waiting' AND next_at_ms <= ? $_oldestFirst"
            '${limit == null ? '' : ' LIMIT ?'}',
            [kind, now.millisecondsSinceEpoch, if (limit != null) limit]))
          QueueItem._fromRow(r),
      ];

  /// Every item of [kind] (in [state], when given), oldest first: for the pages that list them.
  List<QueueItem> items(String kind, {String? state}) => [
        for (final r in store.select(
            'SELECT $_queueColumns FROM sync_queue WHERE kind = ?${state == null ? '' : ' AND state = ?'} $_oldestFirst',
            [kind, if (state != null) state]))
          QueueItem._fromRow(r),
      ];

  void markSending(int id) => store.execute("UPDATE sync_queue SET state = 'sending' WHERE id = ?", [id]);

  /// Sent: the item leaves the queue. An item replaced meanwhile is already gone: nothing happens.
  void done(int id) => store.execute('DELETE FROM sync_queue WHERE id = ?', [id]);

  /// Tried once more: waiting again, not before [at]; [body], when given, replaces the item's (its last error).
  void retryAt(int id, DateTime at, {String? body}) => store.execute(
      "UPDATE sync_queue SET state = 'waiting', next_at_ms = ?, attempts = attempts + 1, body = coalesce(?, body) "
      'WHERE id = ?',
      [at.millisecondsSinceEpoch, body, id]);

  /// Refused for good: kept as a dead letter with [reason], never sent again.
  void dead(int id, String reason, {String? body}) => store.execute(
      "UPDATE sync_queue SET state = 'dead', reason = ?, attempts = attempts + 1, body = coalesce(?, body) WHERE id = ?",
      [reason, body, id]);

  /// Removes the item of [kind] and [key] that is waiting or being sent (a newer one reached the server meanwhile).
  void remove(String kind, String key) =>
      store.execute("DELETE FROM sync_queue WHERE kind = ? AND key = ? AND state <> 'dead'", [kind, key]);

  /// Items left `sending` by an app that stopped mid-send wait again.
  void resetSending() => store.execute("UPDATE sync_queue SET state = 'waiting' WHERE state = 'sending'");

  int count(String kind, {String state = queueWaiting}) =>
      store.select('SELECT count(*) AS n FROM sync_queue WHERE kind = ? AND state = ?', [kind, state]).single['n'] as int;

  /// Keeps only the newest [keep] waiting items of [kind].
  void dropOldest(String kind, int keep) => store.execute(
      "DELETE FROM sync_queue WHERE kind = ? AND state = 'waiting' AND id NOT IN "
      "(SELECT id FROM sync_queue WHERE kind = ? AND state = 'waiting' ORDER BY queued_at_ms DESC, id DESC LIMIT ?)",
      [kind, kind, keep < 0 ? 0 : keep]);

  // ---- what was sent

  /// Remembers [key] of [kind] as sent [at] (replacing an older time).
  void sent(String kind, String key, DateTime at) => store.execute(
      'INSERT INTO sync_sent (kind, key, sent_at_ms) VALUES (?, ?, ?) '
      'ON CONFLICT (kind, key) DO UPDATE SET sent_at_ms = excluded.sent_at_ms',
      [kind, key, at.millisecondsSinceEpoch]);

  /// Whether [key] of [kind] was sent less than [keep] before [now].
  bool wasSent(String kind, String key, DateTime now, Duration keep) {
    final rows = store.select('SELECT sent_at_ms FROM sync_sent WHERE kind = ? AND key = ?', [kind, key]);
    if (rows.isEmpty) return false;
    return now.toUtc().difference(_time(rows.first['sent_at_ms'])) < keep;
  }

  /// Forgets what of [kind] was sent [keep] or more before [now], then all but the newest [max].
  void pruneSent(String kind, DateTime now, Duration keep, int max) => store.transaction(() {
        store.execute('DELETE FROM sync_sent WHERE kind = ? AND sent_at_ms <= ?',
            [kind, now.toUtc().subtract(keep).millisecondsSinceEpoch]);
        store.execute(
            'DELETE FROM sync_sent WHERE kind = ? AND rowid NOT IN '
            '(SELECT rowid FROM sync_sent WHERE kind = ? ORDER BY sent_at_ms DESC, rowid DESC LIMIT ?)',
            [kind, kind, max < 0 ? 0 : max]);
      });

  /// What of [kind] is remembered as sent, the oldest first.
  List<({String key, DateTime at})> sentList(String kind) => [
        for (final r in store.select('SELECT key, sent_at_ms FROM sync_sent WHERE kind = ? ORDER BY sent_at_ms, rowid', [kind]))
          (key: r['key'] as String, at: _time(r['sent_at_ms'])),
      ];

  /// Replaces everything remembered as sent of [kind] with [sent] (coa_uploader.dart's CoaSentStore.save).
  void replaceSent(String kind, Map<String, DateTime> sent) => store.transaction(() {
        store.execute('DELETE FROM sync_sent WHERE kind = ?', [kind]);
        for (final e in sent.entries) {
          this.sent(kind, e.key, e.value);
        }
      });
}
