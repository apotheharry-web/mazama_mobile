// sales_page.dart: the center's sales of the last 30 days, newest first,
// read from the state system; every record read goes to Mazama's server for invoicing without the page waiting on it
// (never in the demo). A failed read shows the copy kept from the last good one with no notice of its own (the
// app-wide banner says so) and Retry; with none kept, the error and Retry.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/sales_page.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/updated_line.dart';

import 'support/core.dart';

late Directory _dir;

final _now = DateTime(2026, 10, 29, 15, 30);

Map<String, Object?> _sale(int id, String number, String date,
        {String? name, String guid = 'PKPR-aaaa0001', num sold = 1, num cost = 25, Object? deleted = false}) =>
    {
      'id': id,
      'saleNumber': number,
      'dateOfSale': date,
      if (name != null) 'productName': name,
      'productGuid': guid,
      'numberSold': sold,
      'productCost': cost,
      'deleted': deleted,
    };

final _records = <Object?>[
  _sale(1, 'S-0001', '2026-09-29T07:00:00.000Z', name: 'Too old'), // 30 days before the 29th: the 31st day back
  _sale(2, 'S-0002', '2026-09-30T07:00:00.000Z', name: 'Thirtieth day', cost: 12.5), // with today, 30 days
  _sale(3, 'S-0003', '10/27/2026', guid: 'PKPR-bbbb0002', sold: 3, cost: 75),
  _sale(4, 'S-0004', '2026-10-29T07:00:00.000Z', name: 'Today', sold: 2, cost: 1250),
  _sale(5, 'S-0005', '2026-10-28T07:00:00.000Z', name: 'Voided', deleted: true),
];

/// A core that can't answer anything.
class _NoCore implements CoreFunctions {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw MazamaCoreError('no core');
}

Widget _page({
  required Future<List<Object?>> Function() load,
  Future<void> Function(List<Object?>)? upload,
  bool demo = false,
  CoreFunctions? core,
}) =>
    MaterialApp(
      home: SalesPage(
        stateId: 231,
        load: load,
        upload: upload ?? (_) async {},
        datasets: Datasets.forDir(() => _dir),
        now: () => _now,
        demo: demo,
        core: core,
      ),
    );

List<String> _shownNumbers(WidgetTester tester) => [
      for (final w in tester.widgetList<Text>(find.byKey(const ValueKey('sale-number'))))
        w.data!,
    ];

void main() {
  test("a sale's collapsed line names each product once, in order, with how many times it was sold", () {
    expect(saleProductNames(['PKPR-579b4701', 'PKPR-579b4701']), 'PKPR-579b4701 ×2');
    expect(saleProductNames(['Choc', 'Gummy', 'Choc']), 'Choc ×2, Gummy');
    expect(saleProductNames(['A', 'B', 'C']), 'A, B, C'); // nothing repeated: as before
    expect(saleProductNames(['Only']), 'Only');
    expect(saleProductNames(const []), '');
  });

  setUpAll(loadTestCore);
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_sales_page_test_'));
  tearDown(() {
    LocalStore.debugCloseAll();
    _dir.deleteSync(recursive: true);
  });

  Datasets datasets() => Datasets.forDir(() => _dir);
  List<Object?>? keptRecords() {
    final row = datasets().read(Dataset.recentSales, '231');
    return row == null ? null : jsonDecode(row.body) as List;
  }

  test('recentSales: the last 30 days, newest first, deleted ones left out', () {
    final rows = recentSales(_records, now: _now);
    expect([for (final r in rows) r.saleNumber], ['S-0004', 'S-0003', 'S-0002']);
    expect([for (final r in rows) r.date], ['2026-10-29', '2026-10-27', '2026-09-30']);
    expect(rows.first.product, 'Today');
    expect(rows[1].product, 'PKPR-bbbb0002'); // no productName: the product's id
    expect(rows.first.numberSold, 2);
    expect(rows.first.costText, r'$1,250.00');
    expect(rows.last.costText, r'$12.50');
  });

  test('recentSales: a record without a usable date, or not a record, is left out; "true" deleted counts', () {
    final rows = recentSales([
      _sale(1, 'S-1', 'not a date'),
      'junk',
      _sale(2, 'S-2', '2026-10-20', deleted: 'true'),
      _sale(3, 'S-3', '2026-10-20'),
    ], now: _now);
    expect([for (final r in rows) r.saleNumber], ['S-3']);
  });

  test('recentSales: on one day, the later sale first (by id, so S-10 comes before S-9)', () {
    final rows = recentSales([
      _sale(9, 'S-9', '2026-10-20'),
      _sale(10, 'S-10', '2026-10-20'),
      _sale(11, 'S-8', '2026-10-21'),
    ], now: _now);
    expect([for (final r in rows) r.saleNumber], ['S-8', 'S-10', 'S-9']);
  });

  testWidgets('shows the window newest first, keeps the read and uploads every record read', (tester) async {
    final uploads = <List<Object?>>[];
    await tester.pumpWidget(_page(load: () async => _records, upload: (r) async => uploads.add(r)));
    await tester.pumpAndSettle();
    expect(_shownNumbers(tester), ['S-0004', 'S-0003', 'S-0002']);
    expect(find.text('Voided'), findsNothing);
    expect(find.text('Too old'), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('sale-S-0004')), matching: find.text(r'$1,250.00')), findsOneWidget);
    expect(uploads, [_records]); // all records read, not only the 30 days shown
    expect(keptRecords(), _records); // the recent_sales dataset
    expect(datasets().read(Dataset.recentSales, '231')!.source, sourceState);
    expect(find.text('Updated just now'), findsOneWidget);
    expect(find.byKey(const ValueKey('sales-retry')), findsNothing);
  });

  testWidgets('the page never waits on the upload, and a failed upload is not shown', (tester) async {
    final never = Completer<void>();
    await tester.pumpWidget(_page(load: () async => _records, upload: (_) => never.future));
    await tester.pumpAndSettle();
    expect(_shownNumbers(tester), hasLength(3));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_page(load: () async => _records, upload: (_) async => throw Exception('Not Found')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_shownNumbers(tester), hasLength(3));
    expect(find.textContaining('Not Found'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_page(load: () async => _records, upload: (_) => throw StateError('sync throw')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_shownNumbers(tester), hasLength(3));
  });

  testWidgets('the demo uploads nothing, and its kept read says demo (PS-R8)', (tester) async {
    final uploads = <List<Object?>>[];
    await tester.pumpWidget(_page(load: () async => _records, upload: (r) async => uploads.add(r), demo: true));
    await tester.pumpAndSettle();
    expect(_shownNumbers(tester), hasLength(3));
    expect(uploads, isEmpty);
    expect(datasets().read(Dataset.recentSales, '231')!.source, sourceDemo);
  });

  testWidgets('a failed read shows the kept copy with no notice of its own, and Retry reads again', (tester) async {
    datasets().put(Dataset.recentSales, '231', jsonEncode(_records), source: sourceState, at: _now.subtract(const Duration(hours: 2)));
    var fail = true;
    var reads = 0;
    final uploads = <List<Object?>>[];
    await tester.pumpWidget(_page(
        load: () async {
          reads++;
          if (fail) throw Exception('cannot reach the state system');
          return [_records[3]];
        },
        upload: (r) async => uploads.add(r)));
    await tester.pumpAndSettle();
    expect(_shownNumbers(tester), ['S-0004', 'S-0003', 'S-0002']);
    expect(find.textContaining('cannot reach'), findsNothing); // no notice of its own
    expect(uploads, isEmpty); // a kept copy is never uploaded again
    final retry = find.byKey(const ValueKey('sales-retry'));
    expect(retry, findsOneWidget);

    fail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(_shownNumbers(tester), ['S-0004']);
    expect(find.byKey(const ValueKey('sales-retry')), findsNothing);
    expect(uploads, hasLength(1));
  });

  testWidgets('a failed read with nothing kept shows the error and Retry', (tester) async {
    await tester.pumpWidget(_page(load: () async => throw Exception('the state system no longer accepts this session')));
    await tester.pumpAndSettle();
    expect(find.textContaining('no longer accepts this session'), findsOneWidget);
    expect(find.byKey(const ValueKey('sales-retry')), findsOneWidget);
    expect(_shownNumbers(tester), isEmpty);
  });

  testWidgets('no sale in the window says so', (tester) async {
    await tester.pumpWidget(_page(load: () async => [_records[0]]));
    await tester.pumpAndSettle();
    expect(find.text('No sales in the last 30 days.'), findsOneWidget);
  });

  // Local first.
  testWidgets('shows the stored copy at once with its age, then the fresh read', (tester) async {
    datasets().put(Dataset.recentSales, '231', jsonEncode([_records[2]]), source: sourceState,
        at: _now.subtract(const Duration(minutes: 20)));
    final gate = Completer<List<Object?>>();
    await tester.pumpWidget(_page(load: () => gate.future));
    await tester.pump();
    expect(_shownNumbers(tester), ['S-0003']); // before the read answers
    expect(find.text('Updated 20 min ago'), findsOneWidget);
    gate.complete(_records);
    await tester.pumpAndSettle();
    expect(_shownNumbers(tester), ['S-0004', 'S-0003', 'S-0002']);
    expect(find.text('Updated just now'), findsOneWidget);
  });

  testWidgets('a failed read keeps the stored copy and its age; the failure is recorded', (tester) async {
    datasets().put(Dataset.recentSales, '231', jsonEncode(_records), source: sourceState,
        at: _now.subtract(const Duration(hours: 2)));
    await tester.pumpWidget(_page(load: () async => throw Exception('cannot reach the state system')));
    await tester.pumpAndSettle();
    expect(_shownNumbers(tester), ['S-0004', 'S-0003', 'S-0002']);
    expect(find.byKey(updatedLineKey), findsOneWidget);
    expect(find.text('Updated just now'), findsNothing);
    expect(datasets().read(Dataset.recentSales, '231')!.lastError, contains('cannot reach'));
  });

  testWidgets('a pull-down while a read is under way joins it', (tester) async {
    final gate = Completer<List<Object?>>();
    var reads = 0;
    datasets().put(Dataset.recentSales, '231', jsonEncode(_records), source: sourceState, at: _now);
    await tester.pumpWidget(_page(load: () {
      reads++;
      return gate.future;
    }));
    await tester.pump();
    expect(reads, 1); // the read the page starts on opening, still under way
    // what a pull-down calls, while that read runs (the indicator calls it once its snap ends, so call it directly)
    final onRefresh = tester.widget<RefreshIndicator>(find.byKey(const ValueKey('sales-refresh'))).onRefresh;
    final joined = onRefresh();
    final again = onRefresh();
    expect(reads, 1);
    gate.complete(_records);
    await tester.pumpAndSettle();
    await joined;
    await again;
    expect(reads, 1);
    expect(_shownNumbers(tester), ['S-0004', 'S-0003', 'S-0002']);
  });

  testWidgets('pulling the list down reads again', (tester) async {
    var reads = 0;
    await tester.pumpWidget(_page(load: () async {
      reads++;
      return _records;
    }));
    await tester.pumpAndSettle();
    expect(reads, 1);
    await tester.fling(find.byKey(const ValueKey('sale-number')).first, const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(reads, 2);
  });

  group('one line per sale (CW-R14)', () {
    // the product rows of the open sales
    final products = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('sale-product-'));
    // a sale of three products (S-0007), one of one (S-0006), both today
    final sale = <Object?>[
      _sale(20, 'S-0007', '2026-10-29', name: 'Golden Teacher Extract', sold: 2, cost: 50),
      _sale(21, 'S-0007', '2026-10-29', name: 'Enigma Whole Fungi', sold: 1, cost: 40),
      _sale(22, 'S-0007', '2026-10-29', name: 'Golden Teacher Choc', sold: 1, cost: 30.25),
      _sale(19, 'S-0006', '2026-10-29', name: 'Penis Envy Extract', sold: 1, cost: 35),
    ];

    test("groupRecentSales: the core's groups, in the page's order, with units and total", () {
      final groups = groupRecentSales(recentSales(sale, now: _now));
      expect([for (final g in groups) g.saleNumber], ['S-0007', 'S-0006']);
      expect([for (final r in groups.first.rows) r.product],
          ['Golden Teacher Choc', 'Enigma Whole Fungi', 'Golden Teacher Extract']);
      expect(groups.first.units, 4);
      expect(groups.first.totalCents, 12025);
      expect(groups.first.totalText, r'$120.25');
    });

    test('every shared case of selling.sale_groups, through the FFI', () {
      final doc = jsonDecode(File('assets/shared/selling/history/sale_groups.json').readAsStringSync()) as Map;
      for (final c in (doc['cases'] as List).cast<Map>()) {
        expect(MazamaCore.instance.sellingSaleGroups({'sales': c['sales']})['groups'], c['groups'], reason: c['why'] as String);
      }
    });

    test("a core that can't answer: each record a line of its own, with its own cost", () {
      final groups = groupRecentSales(recentSales(sale, now: _now), core: _NoCore());
      expect(groups.length, 4);
      expect(groups.first.totalText, r'$30.25');
    });

    testWidgets('a sale of several products is one line; tapping it opens its products in place', (tester) async {
      await tester.pumpWidget(_page(load: () async => sale));
      await tester.pumpAndSettle();
      expect(_shownNumbers(tester), ['S-0007', 'S-0006']);
      expect(find.text('3 products'), findsOneWidget);
      expect(find.text(r'$120.25'), findsOneWidget);
      expect(find.textContaining('Golden Teacher Choc, Enigma Whole Fungi, Golden Teacher Extract'), findsOneWidget);
      expect(find.textContaining('2026-10-29 · 4 units'), findsOneWidget);
      expect(products, findsNothing);

      await tester.tap(find.text(r'$120.25'));
      await tester.pumpAndSettle();
      expect(products, findsNWidgets(3));
      expect(find.text(r'2 × · $50.00'), findsOneWidget);
      expect(find.text(r'1 × · $30.25'), findsOneWidget);

      await tester.tap(find.text(r'$35.00')); // another sale opens beside it
      await tester.pumpAndSettle();
      expect(products, findsNWidgets(4));

      await tester.tap(find.text(r'$120.25')); // and tapping again closes it
      await tester.pumpAndSettle();
      expect(products, findsNWidgets(1));
    });
  });

  group('the sales by calendar date', () {
    final week = <Object?>[
      _sale(30, 'S-30', '2026-10-29', name: 'A', sold: 1, cost: 10),
      _sale(31, 'S-30', '2026-10-29', name: 'B', sold: 1, cost: 5),
      _sale(29, 'S-29', '2026-10-29', name: 'C', sold: 2, cost: 20),
      _sale(28, 'S-28', '2026-10-28', name: 'D', sold: 1, cost: 7.5),
      _sale(27, 'S-27', '2026-10-25', name: 'E', sold: 1, cost: 3),
    ];

    test('recentSaleDays: the dates newest first, each with its sales and total, from the core', () {
      final days = recentSaleDays(recentSales(week, now: _now));
      expect([for (final d in days) d.date], ['2026-10-29', '2026-10-28', '2026-10-25']);
      expect([for (final d in days) [for (final s in d.sales) s.saleNumber]], [['S-30', 'S-29'], ['S-28'], ['S-27']]);
      expect([for (final d in days) d.totalText], [r'$35.00', r'$7.50', r'$3.00']);
    });

    test("a core that can't answer: still by date, each record its own line, no day total", () {
      final days = recentSaleDays(recentSales(week, now: _now), core: _NoCore());
      expect([for (final d in days) d.sales.length], [3, 1, 1]);
      expect([for (final d in days) d.totalText], ['—', '—', '—']);
    });

    testWidgets('a header per date (Today, Yesterday, else the date) with its sales and total', (tester) async {
      await tester.pumpWidget(_page(load: () async => week));
      await tester.pumpAndSettle();
      expect(find.text('Today · 2026-10-29'), findsOneWidget);
      expect(find.text('Yesterday · 2026-10-28'), findsOneWidget);
      expect(find.text('2026-10-25'), findsOneWidget);
      expect(find.text('2 sales · '), findsOneWidget);
      expect(find.text('1 sale · '), findsNWidgets(2));
      expect(_shownNumbers(tester), ['S-30', 'S-29', 'S-28', 'S-27']);
      // each date below the one before, its sales in between
      double top(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      expect(top('sale-day-2026-10-29') < top('sale-S-30'), isTrue);
      expect(top('sale-S-29') < top('sale-day-2026-10-28'), isTrue);
      expect(top('sale-day-2026-10-28') < top('sale-S-28'), isTrue);
    });

    testWidgets('tapping a date collapses it to its header, and tapping again opens it', (tester) async {
      await tester.pumpWidget(_page(load: () async => week));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today · 2026-10-29'));
      await tester.pumpAndSettle();
      expect(_shownNumbers(tester), ['S-28', 'S-27']);
      expect(find.text('Today · 2026-10-29'), findsOneWidget); // its header stays
      await tester.tap(find.text('2026-10-25'));
      await tester.pumpAndSettle();
      expect(_shownNumbers(tester), ['S-28']);

      await tester.tap(find.text('Today · 2026-10-29'));
      await tester.pumpAndSettle();
      expect(_shownNumbers(tester), ['S-30', 'S-29', 'S-28']);
    });
  });
}
