// sync/sync_tables.dart: the sync engine's tables beside the local store's documents (specs/phone-sync PS-R2) - a
// dataset per page's worth with its source and age, the queue with one waiting item per kind and key, and the memory
// of what was sent. A temporary folder each, as the other store tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';

void main() {
  late Directory dir;
  late SyncTables tables;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mazama_sync_tables_test_');
    tables = SyncTables(LocalStore.forDir(dir));
  });
  tearDown(() {
    LocalStore.debugCloseAll();
    dir.deleteSync(recursive: true);
  });

  final t0 = DateTime.utc(2026, 10, 30, 12);

  QueueItem item(String kind, String key, {String body = '{}', DateTime? at}) =>
      QueueItem(kind: kind, key: key, body: body, queuedAt: at ?? t0, nextAt: at ?? t0);

  test('a dataset written reads back with its source and time', () {
    expect(tables.dataset('par', '231'), isNull);
    tables.putDataset('par', '231', '{"rows": [1]}', source: 'server', fetchedAt: t0);
    final row = tables.dataset('par', '231')!;
    expect([row.name, row.key, row.body, row.source, row.fetchedAt, row.lastTry, row.lastError],
        ['par', '231', '{"rows": [1]}', 'server', t0, t0, null]);
    expect(tables.dataset('par', '183'), isNull);
    expect(tables.dataset('sheets', '231'), isNull);
  });

  test('a failed refresh keeps the body and sets last_error', () {
    tables.putDataset('par', '231', '{"rows": [1]}', source: 'server', fetchedAt: t0);
    final later = t0.add(const Duration(minutes: 7));
    tables.datasetFailed('par', '231', "the server can't be reached", later);
    final row = tables.dataset('par', '231')!;
    expect([row.body, row.fetchedAt, row.lastTry, row.lastError], ['{"rows": [1]}', t0, later, "the server can't be reached"]);
    tables.putDataset('par', '231', '{"rows": [2]}', source: 'server', fetchedAt: later);
    expect(tables.dataset('par', '231')!.lastError, isNull);
    tables.datasetFailed('sheets', '231', 'x', later); // nothing stored yet: nothing to record it on
    expect(tables.dataset('sheets', '231'), isNull);
  });

  test('enqueue with the same kind and key replaces the waiting item, never a dead one', () {
    final first = tables.enqueue(item('inventory_snapshot', '231', body: '{"n": 1}'));
    final second = tables.enqueue(item('inventory_snapshot', '231', body: '{"n": 2}'));
    expect(second, greaterThan(first)); // never the replaced item's id
    tables.done(first); // the old one's sender finishing: the newer one stays
    expect([for (final i in tables.items('inventory_snapshot')) i.body], ['{"n": 2}']);

    final doomed = tables.enqueue(item('sale_log', 'c-1', body: '{"n": 1}'));
    tables.dead(doomed, 'HTTP 400');
    tables.enqueue(item('sale_log', 'c-1', body: '{"n": 2}'));
    final all = tables.items('sale_log');
    expect([for (final i in all) (i.body, i.state, i.reason)], [('{"n": 1}', 'dead', 'HTTP 400'), ('{"n": 2}', 'waiting', null)]);
    expect(tables.count('sale_log'), 1);
    expect(tables.count('sale_log', state: 'dead'), 1);
  });

  test('due returns waiting items whose time has come, oldest first', () {
    tables.enqueue(item('sale_log', 'b', at: t0.add(const Duration(seconds: 2))));
    tables.enqueue(item('sale_log', 'a', at: t0));
    final later = tables.enqueue(item('sale_log', 'later', at: t0.add(const Duration(minutes: 5))));
    tables.enqueue(item('sale_failure', 'other kind', at: t0));
    final sending = tables.enqueue(item('sale_log', 'sending', at: t0));
    tables.markSending(sending);
    final now = t0.add(const Duration(minutes: 1));
    expect([for (final i in tables.due('sale_log', now)) i.key], ['a', 'b']);
    expect([for (final i in tables.due('sale_log', now, limit: 1)) i.key], ['a']);

    tables.retryAt(later, t0);
    final retried = tables.items('sale_log').firstWhere((i) => i.id == later);
    expect([retried.attempts, retried.nextAt, retried.state], [1, t0, 'waiting']);
    expect([for (final i in tables.due('sale_log', now)) i.key], ['a', 'b', 'later']);

    tables.retryAt(later, t0, body: '{"lastError": "x"}');
    expect(tables.items('sale_log').firstWhere((i) => i.id == later).body, '{"lastError": "x"}');

    tables.done(later);
    expect([for (final i in tables.due('sale_log', now)) i.key], ['a', 'b']);
    tables.resetSending(); // an app killed mid-send: the item waits again
    expect([for (final i in tables.due('sale_log', now)) i.key], ['a', 'sending', 'b']);
  });

  test('dropOldest keeps the newest n of a kind', () {
    for (var i = 0; i < 5; i++) {
      tables.enqueue(item('lab_report', 'lot-$i', at: t0.add(Duration(seconds: i))));
    }
    tables.enqueue(item('sale_log', 'x'));
    tables.dropOldest('lab_report', 2);
    expect([for (final i in tables.items('lab_report')) i.key], ['lot-3', 'lot-4']);
    expect(tables.count('sale_log'), 1);
    tables.remove('lab_report', 'lot-3');
    expect([for (final i in tables.items('lab_report')) i.key], ['lot-4']);
  });

  test('wasSent forgets after keep and pruneSent keeps at most max', () {
    const keep = Duration(hours: 24);
    tables.sent('lab_report', 'hb-1', t0);
    tables.sent('lab_report', 'hb-2', t0.add(const Duration(hours: 1)));
    tables.sent('lab_report', 'hb-3', t0.add(const Duration(hours: 2)));
    tables.sent('other', 'hb-1', t0);
    expect(tables.wasSent('lab_report', 'hb-1', t0.add(const Duration(hours: 23)), keep), isTrue);
    expect(tables.wasSent('lab_report', 'hb-1', t0.add(keep), keep), isFalse);
    expect(tables.wasSent('lab_report', 'hb-9', t0, keep), isFalse);

    tables.pruneSent('lab_report', t0.add(const Duration(hours: 24, minutes: 30)), keep, 10); // hb-1 expired
    expect([for (final s in tables.sentList('lab_report')) s.key], ['hb-2', 'hb-3']);
    tables.pruneSent('lab_report', t0, keep, 1); // at most one: the oldest goes
    expect([for (final s in tables.sentList('lab_report')) s.key], ['hb-3']);
    expect([for (final s in tables.sentList('other')) s.key], ['hb-1']);
    tables.sent('lab_report', 'hb-3', t0.add(const Duration(hours: 5))); // sent again: the newer time
    expect(tables.sentList('lab_report').single.at, t0.add(const Duration(hours: 5)));
  });

  test('the tables exist after a restart', () {
    tables.putDataset('par', '231', '{}', source: 'server', fetchedAt: t0);
    tables.enqueue(item('sale_log', 'c-1'));
    tables.sent('lab_report', 'hb-1', t0);
    LocalStore.debugCloseAll();
    final again = SyncTables(LocalStore.forDir(dir));
    expect(again.dataset('par', '231')!.source, 'server');
    expect(again.items('sale_log').single.key, 'c-1');
    expect(again.wasSent('lab_report', 'hb-1', t0, const Duration(hours: 1)), isTrue);
    final store = LocalStore.forDir(dir);
    final names = {for (final r in store.debugQuery("SELECT name FROM sqlite_master")) r['name']};
    expect(names, containsAll(['documents', 'sync_dataset', 'sync_queue', 'sync_sent', 'sync_queue_kind_key']));
    expect(store.debugQuery('PRAGMA user_version').single.values.single, localStoreSchemaVersion);
  });

  test('select and execute take parameters', () {
    final store = LocalStore.forDir(dir);
    store.execute('INSERT INTO sync_sent (kind, key, sent_at_ms) VALUES (?, ?, ?)', ['k', "it's", 5]);
    expect(store.select('SELECT key, sent_at_ms FROM sync_sent WHERE kind = ?', ['k']), [
      {'key': "it's", 'sent_at_ms': 5}
    ]);
  });
}
