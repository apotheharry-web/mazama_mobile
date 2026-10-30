// sync/sync_migration.dart: the first start with the sync engine moves the outbox, the catch-up list and the sent lab
// reports into the engine's tables (specs/phone-sync PS-R9) - each item once, the documents gone only once their move
// committed, a second run changing nothing - and (phase 2) the reply store's kept par levels, sheets and Mazama stock into
// the datasets with their times (Task 10: the stores themselves are gone; the tests write their documents as an older
// build did). Invented fixtures (this folder is published).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/server_outbox.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/sync_migration.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';

/// Tables whose [failOn]th enqueue throws, as a full disk would mid-move.
class _FailingTables extends SyncTables {
  _FailingTables(super.store, this.failOn);
  final int failOn;
  int _calls = 0;

  @override
  int enqueue(QueueItem item) {
    if (++_calls == failOn) throw StateError('disk full');
    return super.enqueue(item);
  }
}

/// Keeps [value] as an older build's reply store did (reply_store.dart, removed in Task 10): one document per route and
/// parameters, `server_replies/<the key, URI-encoded>.json`, holding {"atMs": ..., "value": ...}.
void _keepReply(LocalStore store, String key, Object? value, DateTime at) => store.write(
    'server_replies/${Uri.encodeComponent(key)}.json', jsonEncode({'atMs': at.toUtc().millisecondsSinceEpoch, 'value': value}));

/// The keys of the replies still kept, as the reply store listed them.
List<String> _repliesLeft(LocalStore store) => [
      for (final n in store.names('server_replies/'))
        Uri.decodeComponent(n.substring('server_replies/'.length, n.length - '.json'.length)),
    ]..sort();

void main() {
  late Directory dir;
  late LocalStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mazama_sync_migration_test_');
    store = LocalStore.forDir(dir);
  });
  tearDown(() {
    LocalStore.debugCloseAll();
    dir.deleteSync(recursive: true);
  });

  final t0 = DateTime.utc(2026, 10, 29, 9);

  OutboxEntry entry(String id, OutboxKind kind, int n, {int attempts = 0, String? lastError, int? status}) => OutboxEntry(
        clientId: id,
        kind: kind,
        stateId: 231,
        workerEmail: 'worker@example.com',
        deviceId: 'D-1',
        request: [
          {'n': n}
        ],
        response: kind == OutboxKind.saleLog ? [{'saleNumber': 'S-$n'}] : null,
        reason: kind == OutboxKind.saleFailure ? 'expired $n' : null,
        createdAt: t0.add(Duration(minutes: n)),
        attempts: attempts,
        lastError: lastError,
        status: status,
      );

  /// Today's documents: sale logs, a failure past the cap, a dead letter, two lab reports, a snapshot of each kind,
  /// and two sent lots.
  void writeFixture() {
    store.write(
        'server_outbox.json',
        jsonEncode({
          'pending': [
            entry('c-1', OutboxKind.saleLog, 1, attempts: 2, lastError: 'cannot reach x').toJson(),
            entry('c-2', OutboxKind.saleFailure, 2).toJson(),
            entry('c-3', OutboxKind.saleLog, 3).toJson(),
            entry('c-4', OutboxKind.saleFailure, 4).toJson(), // queued past the cap
          ],
          'dead': [
            entry('c-0', OutboxKind.saleFailure, 0, attempts: 1, lastError: 'reason is required.', status: 400).toJson(),
          ],
          'droppedLogs': 7,
        }));
    CatchUpStore(dataDir: () => dir).save(CatchUpState(
      lots: [
        PendingCoaLot(lotGuid: 'HB-aaaa0001', packageId: 101, stateId: 231, statePsilocybin: 4.5, addedAt: t0),
        PendingCoaLot(lotGuid: 'HB-bbbb0002', packageId: 102, stateId: 183, addedAt: t0.add(const Duration(minutes: 1))),
      ],
      snapshots: {
        'inventory:231': PendingSnapshot(stateId: 231, records: const [1, 2], workerEmail: 'w', deviceId: 'd', readAt: t0),
        'sales:231': PendingSnapshot(
            stateId: 231, kind: snapshotKindSales, records: const [9], workerEmail: 'w', deviceId: 'd', readAt: t0),
      },
    ));
    store.write(
        'coa_sent.json',
        jsonEncode({
          'lots': [
            {'lotGuid': 'hb-cccc0003', 'sentAtMs': t0.millisecondsSinceEpoch},
            {'lotGuid': 'HB-DDDD0004', 'sentAtMs': t0.add(const Duration(hours: 1)).millisecondsSinceEpoch},
          ],
        }));
  }

  List<String> keys(SyncTables t, String kind, {String? state}) => [for (final i in t.items(kind, state: state)) i.key];

  test('every kind of queued work survives the move once', () {
    writeFixture();
    final tables = SyncTables(store);
    migrateQueues(store, tables);

    final reports = [...tables.items('sale_log'), ...tables.items('sale_failure')].where((i) => i.state == 'waiting').toList()
      ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    expect([for (final i in reports) i.key], ['c-1', 'c-2', 'c-3', 'c-4']); // same clientIds, same order
    expect(reports.first.attempts, 2);
    final first = OutboxEntry.fromJson(jsonDecode(reports.first.body))!;
    expect([first.clientId, first.stateId, first.request, first.response, first.lastError, first.createdAt],
        ['c-1', 231, [{'n': 1}], [{'saleNumber': 'S-1'}], 'cannot reach x', t0.add(const Duration(minutes: 1))]);
    expect(OutboxEntry.fromJson(jsonDecode(reports[1].body))!.reason, 'expired 2');

    final dead = tables.items('sale_failure', state: 'dead').single;
    expect([dead.key, dead.reason, OutboxEntry.fromJson(jsonDecode(dead.body))!.status], ['c-0', 'reason is required.', 400]);
    expect(jsonDecode(store.read('sync_dropped_sale_logs')!.body), 7);

    expect(keys(tables, 'lab_report'), ['hb-aaaa0001', 'hb-bbbb0002']);
    final lot = PendingCoaLot.fromJson(jsonDecode(tables.items('lab_report').first.body))!;
    expect([lot.lotGuid, lot.packageId, lot.stateId, lot.statePsilocybin], ['HB-aaaa0001', 101, 231, 4.5]);
    expect(keys(tables, 'inventory_snapshot'), ['231']);
    expect(PendingSnapshot.fromJson(jsonDecode(tables.items('inventory_snapshot').single.body))!.records, [1, 2]);
    expect(keys(tables, 'sales_snapshot'), ['231']);
    expect(PendingSnapshot.fromJson(jsonDecode(tables.items('sales_snapshot').single.body))!.kind, snapshotKindSales);
    expect([for (final s in tables.sentList('lab_report')) (s.key, s.at)],
        [('hb-cccc0003', t0), ('hb-dddd0004', t0.add(const Duration(hours: 1)))]);

    expect(store.names(''), ['sync_dropped_sale_logs']); // the old documents are gone

    migrateQueues(store, tables); // a second run changes nothing
    expect([for (final k in ['sale_log', 'sale_failure', 'lab_report', 'inventory_snapshot', 'sales_snapshot']) tables.items(k).length],
        [2, 3, 2, 1, 1]);
    expect(jsonDecode(store.read('sync_dropped_sale_logs')!.body), 7);
    expect(tables.sentList('lab_report'), hasLength(2));
  });

  test('a failed move keeps the document and the next start moves it', () {
    writeFixture();
    migrateQueues(store, _FailingTables(store, 3)); // the outbox's third item fails
    expect(store.read('server_outbox.json'), isNotNull);
    final tables = SyncTables(store);
    expect(tables.items('sale_log'), isEmpty, reason: 'nothing of the failed document was moved');
    expect(tables.items('sale_failure'), isEmpty);
    expect(store.read('sync_dropped_sale_logs'), isNull);
    expect(store.read('server_catch_up.json'), isNull, reason: 'one failure does not stop the next document');
    expect(keys(tables, 'lab_report'), hasLength(2));

    migrateQueues(store, tables); // the next start
    expect(store.read('server_outbox.json'), isNull);
    expect(keys(tables, 'sale_log'), ['c-1', 'c-3']);
    expect(keys(tables, 'sale_failure'), ['c-0', 'c-2', 'c-4']);
    expect(keys(tables, 'lab_report'), hasLength(2));
  });

  test('a document this build cannot read is left where it is', () {
    store.write('server_outbox.json', '{not json');
    final tables = SyncTables(store);
    migrateQueues(store, tables);
    expect(store.read('server_outbox.json')!.body, '{not json');
    expect(tables.items('sale_log'), isEmpty);
  });

  test('a document waiting moves beside work already in the queue, never replacing a newer item', () {
    final tables = SyncTables(store);
    tables.enqueue(QueueItem(
        kind: 'inventory_snapshot', key: '231', body: '{"newer": true}', queuedAt: t0.add(const Duration(days: 1)), nextAt: t0));
    writeFixture();
    migrateQueues(store, tables);
    expect([for (final i in tables.items('inventory_snapshot')) i.body], ['{"newer": true}']);
  });

  test('a newer snapshot an older build kept replaces an older one this build left queued (M2)', () {
    final tables = SyncTables(store);
    tables.enqueue(QueueItem(
        kind: 'inventory_snapshot', key: '231', body: '{"older": true}', queuedAt: t0.subtract(const Duration(days: 1)), nextAt: t0));
    tables.enqueue(QueueItem(
        kind: 'sales_snapshot', key: '231', body: '{"older": true}', queuedAt: t0.subtract(const Duration(hours: 1)), nextAt: t0));
    writeFixture(); // both snapshots read at t0
    migrateQueues(store, tables);
    expect(PendingSnapshot.fromJson(jsonDecode(tables.items('inventory_snapshot').single.body))!.records, [1, 2]);
    expect(PendingSnapshot.fromJson(jsonDecode(tables.items('sales_snapshot').single.body))!.records, [9]);
  });

  group('kept replies (phase 2)', () {
    final at = DateTime.utc(2026, 10, 21, 9, 30);

    test('kept replies become datasets with their times', () {
      _keepReply(store, 'par/231', [
        {'strain': 'Golden Teacher', 'size': 25, 'par': 12}
      ], at);
      _keepReply(store, 'sheets/183', [], at.add(const Duration(hours: 1)));
      _keepReply(store, 'mazama_inventory', {'name': 'Mazama', 'cells': [], 'lots': []}, at);
      _keepReply(store, 'state_sales/231', [1, 2], at); // phase 4: the recent_sales dataset, read from the state
      _keepReply(store, 'packages/231', [3], at); // a route that was never a reply of the app's: left
      final tables = SyncTables(store);
      migrateReplies(store, tables);

      final par = tables.dataset('par', '231')!;
      expect(jsonDecode(par.body), [
        {'strain': 'Golden Teacher', 'size': 25, 'par': 12}
      ]);
      expect([par.source, par.fetchedAt], ['server', at]);
      expect(tables.dataset('sheets', '183')!.fetchedAt, at.add(const Duration(hours: 1)));
      expect(jsonDecode(tables.dataset('mazama_inventory', '')!.body)['name'], 'Mazama');
      final sales = tables.dataset('recent_sales', '231')!;
      expect([jsonDecode(sales.body), sales.source, sales.fetchedAt], [[1, 2], 'state', at]);
      expect(_repliesLeft(store), ['packages/231']); // the moved ones are gone

      migrateReplies(store, tables); // a second run changes nothing
      expect(tables.allDatasets(), hasLength(4));
    });

    test('a dataset already stored and newer is kept; an older one is replaced', () {
      final tables = SyncTables(store);
      tables.putDataset('par', '231', '["newer"]', source: 'server', fetchedAt: at.add(const Duration(days: 1)));
      tables.putDataset('sheets', '231', '["older"]', source: 'server', fetchedAt: at.subtract(const Duration(days: 1)));
      _keepReply(store, 'par/231', ['kept'], at);
      _keepReply(store, 'sheets/231', ['kept'], at);
      migrateReplies(store, tables);
      expect(tables.dataset('par', '231')!.body, '["newer"]');
      expect(tables.dataset('sheets', '231')!.body, '["kept"]');
      expect(_repliesLeft(store), isEmpty);
    });

    test('a dataset read after now (the clock moved back) counts as older than the reply', () {
      final tables = SyncTables(store);
      final now = DateTime.utc(2026, 10, 30, 12);
      tables.putDataset('par', '231', '["future"]', source: 'server', fetchedAt: now.add(const Duration(days: 2)));
      _keepReply(store, 'par/231', ['kept'], at);
      migrateReplies(store, tables, now: () => now);
      final row = tables.dataset('par', '231')!;
      expect([row.body, row.fetchedAt], ['["kept"]', at]);
    });

    test('a reply this build cannot read is left where it is', () {
      store.write('server_replies/par%2F231.json', '{not json');
      store.write('server_replies/par%2Fnot-a-center.json', jsonEncode({'atMs': 1, 'value': []}));
      final tables = SyncTables(store);
      migrateReplies(store, tables);
      expect(tables.allDatasets(), isEmpty);
      expect(store.names('server_replies/'), hasLength(2));
    });

    test('nothing under lib/ writes the reply store any more: its documents are only read here, by name (Task 10)', () {
      final writers = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final path = f.path.replaceAll(Platform.pathSeparator, '/');
        if (path == 'lib/sync/sync_migration.dart' || path == 'lib/local_store_import.dart') continue;
        if (f.readAsStringSync().contains("'server_replies/")) writers.add(path);
      }
      expect(writers, isEmpty);
      expect(File('lib/reply_store.dart').existsSync(), isFalse);
      expect(replyRoutesMoved.values.toSet(), {Dataset.par, Dataset.sheets, Dataset.mazamaInventory, Dataset.recentSales});
    });
  });

  group('kept stock (phase 3)', () {
    final at = DateTime.utc(2026, 10, 28, 8);

    test('a kept inventory and enrichment become datasets with their times', () {
      store.write(inventoryCacheDocument, jsonEncode({
        'centerId': 231,
        'fetchedAtMs': at.millisecondsSinceEpoch,
        'packages': [
          {'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'id': 101, 'weightPerUnit': 5, 'analyteWeight': 1, 'quantity': 4},
        ],
      }));
      final enrichment = {
        'version': 1,
        'entries': [
          {'productGuid': 'PKPR-ab12c', 'id': 101, 'weightPerUnit': 5, 'analyteWeight': 1, 'strain': 'GT', 'tpeMg': 8, 'seenAtMs': 1},
        ],
      };
      store.write(enrichmentDocument, jsonEncode(enrichment));
      final tables = SyncTables(store);
      final now = DateTime.utc(2026, 10, 30, 12);
      migrateStockCaches(store, tables, now: () => now);

      final stock = tables.dataset('center_stock', '231')!;
      expect([stock.source, stock.fetchedAt], ['merged', at]);
      final body = jsonDecode(stock.body) as Map;
      expect([(body['packages'] as List).single['id'], body['source']], [101, 'merged']);
      final kept = tables.dataset('enrichment', '')!;
      expect(jsonDecode(kept.body), enrichment);
      expect(kept.fetchedAt, now);
      expect(store.read(inventoryCacheDocument), isNull);
      expect(store.read(enrichmentDocument), isNull);

      migrateStockCaches(store, tables, now: () => now); // a second run changes nothing
      expect(tables.allDatasets(), hasLength(2));
    });

    test('a newer stock already stored is kept; what this build cannot read is left', () {
      final tables = SyncTables(store);
      tables.putDataset('center_stock', '231', '{"packages": [], "source": "state"}',
          source: 'state', fetchedAt: at.add(const Duration(hours: 1)));
      tables.putDataset('enrichment', '', '{"version": 1, "entries": []}', source: 'server', fetchedAt: at);
      store.write(inventoryCacheDocument,
          jsonEncode({'centerId': 231, 'fetchedAtMs': at.millisecondsSinceEpoch, 'packages': []}));
      store.write(enrichmentDocument, jsonEncode({'version': 1, 'entries': [{'old': true}]}));
      migrateStockCaches(store, tables, now: () => at.add(const Duration(days: 1)));
      expect(tables.dataset('center_stock', '231')!.source, 'state');
      expect(tables.dataset('enrichment', '')!.body, '{"version": 1, "entries": []}'); // this build's own
      expect(store.read(inventoryCacheDocument), isNull);

      store.write(inventoryCacheDocument, '{"centerId": 231, "packages": []}'); // no time
      store.write(enrichmentDocument, '{"version": 99, "entries": []}');
      migrateStockCaches(store, tables);
      expect(store.read(inventoryCacheDocument), isNotNull);
      expect(store.read(enrichmentDocument), isNotNull);
    });
  });

  group('the stock-page copies and Mazama stock (Task 8b Step 6b)', () {
    final at = DateTime.utc(2026, 10, 27, 8);

    test('every kept stock-page copy survives the move once', () {
      store.write('stock_cache_231.json', jsonEncode({
        'par': [
          {'strain': 'Golden Teacher', 'size': 25, 'par': 12}
        ],
        'parAtMs': at.millisecondsSinceEpoch,
        'sheets': [],
        'sheetsAtMs': at.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        'rows': [
          {'productGuid': 'PKPR-a', 'id': 1, 'quantity': 3}
        ],
        'rowsMgMode': 'psilocybin',
        'rowsAtMs': at.add(const Duration(hours: 2)).millisecondsSinceEpoch,
        'mazamaLicenses': ['mf-1'],
        'parColumns': {'added': [15], 'removed': []},
      }));
      store.write('stock_cache_183.json', jsonEncode({'par': [], 'rows': []})); // no times recorded
      store.write('mazama_inventory_cache.json',
          jsonEncode({'atMs': at.millisecondsSinceEpoch, 'inventory': {'name': 'Mazama', 'cells': [], 'lots': []}}));
      final tables = SyncTables(store);
      migrateStockCaches(store, tables, now: () => at.add(const Duration(days: 1)));

      final par = tables.dataset('par', '231')!;
      expect([jsonDecode(par.body), par.fetchedAt, par.source], [
        [
          {'strain': 'Golden Teacher', 'size': 25, 'par': 12}
        ],
        at,
        'server'
      ]);
      expect(tables.dataset('sheets', '231')!.fetchedAt, at.add(const Duration(hours: 1)));
      final rows = tables.dataset('stock_rows', '231')!;
      expect([(jsonDecode(rows.body) as Map)['mgMode'], rows.source, rows.fetchedAt],
          ['psilocybin', 'state', at.add(const Duration(hours: 2))]);
      // Task 10: Mazama's licenses become their dataset (no time recorded: the oldest there is), the par columns their
      // own document, and nothing is left in the stock page's
      final licenses = tables.dataset('mazama_licenses', '231')!;
      expect([jsonDecode(licenses.body), licenses.source, licenses.fetchedAt.millisecondsSinceEpoch], [['mf-1'], 'server', 0]);
      expect(jsonDecode(store.read('par_columns_231.json')!.body), {'added': [15], 'removed': []});
      expect(store.read('stock_cache_231.json'), isNull);
      expect(tables.dataset('par', '183')!.fetchedAt.millisecondsSinceEpoch, 0); // no time: the oldest there is
      expect(store.read('stock_cache_183.json'), isNull); // nothing left in it
      final inventory = tables.dataset('mazama_inventory', '')!;
      expect([(jsonDecode(inventory.body) as Map)['name'], inventory.fetchedAt], ['Mazama', at]);
      expect(store.read('mazama_inventory_cache.json'), isNull);

      migrateStockCaches(store, tables, now: () => at.add(const Duration(days: 1))); // a second run changes nothing
      expect(tables.allDatasets(), hasLength(7));
      expect(jsonDecode(store.read('par_columns_231.json')!.body), {'added': [15], 'removed': []});
    });

    test("an older build's Mazama licenses and par columns alone are moved too, once (Task 10)", () {
      // what a Task 8b build leaves in the document once its datasets have moved
      store.write('stock_cache_231.json', jsonEncode({
        'mazamaLicenses': ['mf-1', 7, 'mf-2'],
        'parColumns': {'added': [], 'removed': [25]},
      }));
      final tables = SyncTables(store);
      migrateStockCaches(store, tables, now: () => at);
      expect(jsonDecode(tables.dataset('mazama_licenses', '231')!.body), ['mf-1', 'mf-2']);
      expect(jsonDecode(store.read('par_columns_231.json')!.body), {'added': [], 'removed': [25]});
      expect(store.read('stock_cache_231.json'), isNull);
      migrateStockCaches(store, tables, now: () => at); // a second run changes nothing
      expect(tables.allDatasets(), hasLength(1));
      expect(store.names('par_columns_'), ['par_columns_231.json']);
    });

    test('licenses read since and par columns chosen since are kept over an older copy', () {
      final tables = SyncTables(store);
      tables.putDataset('mazama_licenses', '231', '["mf-new"]', source: 'server', fetchedAt: at);
      store.write('par_columns_231.json', jsonEncode({'added': [10], 'removed': []}));
      store.write('stock_cache_231.json', jsonEncode({
        'mazamaLicenses': ['mf-old'],
        'parColumns': {'added': [], 'removed': [25]},
      }));
      migrateStockCaches(store, tables, now: () => at);
      expect(tables.dataset('mazama_licenses', '231')!.body, '["mf-new"]');
      expect(jsonDecode(store.read('par_columns_231.json')!.body), {'added': [10], 'removed': []});
      expect(store.read('stock_cache_231.json'), isNull);
    });

    test('anything else in a stock-page copy (nothing an older build wrote) is left in it', () {
      store.write('stock_cache_231.json', jsonEncode({'mazamaLicenses': ['mf-1'], 'other': 1}));
      migrateStockCaches(store, SyncTables(store), now: () => at);
      expect(jsonDecode(store.read('stock_cache_231.json')!.body), {'other': 1});
    });

    test('a newer dataset already stored is kept; a document this build cannot read is left', () {
      final tables = SyncTables(store);
      tables.putDataset('par', '231', '["newer"]', source: 'server', fetchedAt: at.add(const Duration(days: 1)));
      store.write('stock_cache_231.json', jsonEncode({'par': ['older'], 'parAtMs': at.millisecondsSinceEpoch}));
      store.write('stock_cache_183.json', '{not json');
      store.write('stock_cache_x.json', jsonEncode({'par': []})); // not a center's
      migrateStockCaches(store, tables, now: () => at.add(const Duration(days: 2)));
      expect(tables.dataset('par', '231')!.body, '["newer"]');
      expect(store.read('stock_cache_231.json'), isNull);
      expect(store.read('stock_cache_183.json')!.body, '{not json');
      expect(store.read('stock_cache_x.json'), isNotNull);
    });
  });
}
