// sales_page.dart (specs/center-web CW-R10 phone half, CW-D14): the center's sales of the last 30 days, newest first,
// read from the state system; every record read goes to Mazama's server for invoicing without the page waiting on it
// (never in the demo). A failed read shows the copy kept from the last good one with no notice of its own (sales
// README R87) and Retry; with none kept, the error and Retry.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/reply_store.dart';
import 'package:mazama_mobile/sales_page.dart';

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

Widget _page({
  required Future<List<Object?>> Function() load,
  Future<void> Function(List<Object?>)? upload,
  bool demo = false,
}) =>
    MaterialApp(
      home: SalesPage(
        stateId: 231,
        load: load,
        upload: upload ?? (_) async {},
        replies: ReplyStore(dataDir: () => _dir),
        now: () => _now,
        demo: demo,
      ),
    );

List<String> _shownNumbers(WidgetTester tester) => [
      for (final w in tester.widgetList<Text>(find.byKey(const ValueKey('sale-number'))))
        w.data!,
    ];

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_sales_page_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

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
    expect(find.text(r'$1,250.00'), findsOneWidget);
    expect(uploads, [_records]); // all records read, not only the 30 days shown
    expect(ReplyStore(dataDir: () => _dir).load(replyKey('state_sales', [231]))?.value, _records);
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

  testWidgets('the demo uploads nothing', (tester) async {
    final uploads = <List<Object?>>[];
    await tester.pumpWidget(_page(load: () async => _records, upload: (r) async => uploads.add(r), demo: true));
    await tester.pumpAndSettle();
    expect(_shownNumbers(tester), hasLength(3));
    expect(uploads, isEmpty);
  });

  testWidgets('a failed read shows the kept copy with no notice of its own, and Retry reads again', (tester) async {
    ReplyStore(dataDir: () => _dir).save(replyKey('state_sales', [231]), _records, _now.toUtc());
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
}
