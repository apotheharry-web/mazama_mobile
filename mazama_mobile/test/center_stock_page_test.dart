// SP-R12, SP-R14: the phone's stock page (lib/center_stock_page.dart): the filter, the pies and their keys, a
// strain's serving-size pies, the lot table, "Other stock", and no par table (SP-D19: it is the order's first step,
// test/order_par_page_test.dart). Data comes through the
// injected loaders, as the other pages' tests inject their clients.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/center_stock_page.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/server_offline.dart';
import 'package:mazama_mobile/sheets_client.dart';
import 'package:mazama_mobile/stock_pie.dart';
import 'package:mazama_mobile/stock_rows.dart';
import 'package:mazama_mobile/stock_summary.dart';

final _center = License(id: 231, licenseId: 'SC-b1c7379a', licenseName: 'Bendable Service Center', licenseType: 'ServiceCenter');

const _rows = [
  StockRow(productGuid: 'PKPR-gt25', id: 1, quantity: 10, mazama: true, strain: 'Golden Teacher', description: 'Golden Teacher 25 mg', unitMgTpe: 25),
  StockRow(productGuid: 'PKPR-gt10', id: 2, quantity: 4, mazama: true, strain: 'Golden Teacher', description: 'Golden Teacher 10 mg', unitMgTpe: 10),
  StockRow(productGuid: 'PKPR-pe15', id: 3, quantity: 6, strain: 'Penis Envy', description: 'Penis Envy 15 mg', unitMgTpe: 15),
  StockRow(productGuid: 'PKPR-hu5', id: 4, quantity: 2, mazama: true, expired: true, strain: 'Huautla', description: 'Huautla 5 mg', unitMgTpe: 5),
  StockRow(productGuid: 'PKPR-gone', id: 5, quantity: 0, mazama: true, strain: 'Enigma', description: 'Enigma 25 mg', unitMgTpe: 25),
];

class _Failure implements Exception {
  _Failure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// [loadRows] gives fresh server rows (mg TPE, not partial); [load] a whole StockLoad instead.
Widget _page({
  Future<List<StockRow>> Function()? loadRows,
  Future<StockLoad> Function()? load,
  DateTime Function()? now,
  Future<List<ProductSheet>> Function()? loadSheets,
  Future<void> Function(ProductSheet)? openSheet,
  Future<ServerRead<List<ProductSheet>>?> Function()? keptSheets,
  Future<void> Function(List<ProductSheet>, DateTime)? keepSheets,
}) =>
    MaterialApp(
      home: CenterStockPage(
        center: _center,
        loadRows: load ?? () async => StockLoad(await (loadRows ?? () async => _rows)()),
        now: now ?? DateTime.now,
        loadSheets: loadSheets,
        openSheet: openSheet,
        keptSheets: keptSheets,
        keepSheets: keepSheets,
      ),
    );

// SP-D11, SP-D18: a sheet per strain in _rows, one made into two strains, and one whose strain isn't known; their lab
// figures and types for the lot table.
const _sheets = [
  ProductSheet(guid: 'HB-gt01', name: 'GT 6.26', product: 'Whole Fungi', tested: 'Aug 27, 2026', path: '/p/lots/mazama/HB-gt01',
      strains: ['Golden Teacher'], tpe: 8.64, psilocybin: 7.25, psilocin: 1, detected: ['baeocystin'], types: ['FD']),
  ProductSheet(guid: 'PL-pe02', name: 'PE extract lot', product: 'Edible Psilocybin Product', tested: '', path: '/p/held/x/PL-pe02',
      strains: ['Penis Envy'], tpe: 6, types: ['DH']),
  ProductSheet(guid: 'PL-mix03', name: 'Mixed lot', product: 'Edible Psilocybin Product', tested: 'Sep 1, 2026', path: '/p/lots/mazama/PL-mix03',
      strains: ['golden teacher', 'Penis Envy'], types: ['DH']),
  ProductSheet(guid: 'HB-un04', name: 'No name', product: 'Whole Fungi', tested: '', path: '/p/lots/mazama/HB-un04', strains: ['']),
];

/// Opens or closes the lot table (SP-D18).
Future<void> _openLots(WidgetTester tester) =>
    _tap(tester, find.descendant(of: find.byKey(const ValueKey('stock-lot-table')), matching: find.byType(ListTile)).first);

/// The lot table's rows, "strain|lot", as shown.
List<String> _lotRows(WidgetTester tester) => [
      for (final w in tester.widgetList(find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('lot-row-'))))
        (w.key as ValueKey<String>).value.substring('lot-row-'.length),
    ];

/// Rows as the state alone gives them (stock_rows.dart's stockRowsFromState): no strain, no mg TPE.
const _stateRows = [
  StockRow(productGuid: 'PKPR-gt25', id: 1, quantity: 10, mazama: true, description: 'GT 25 mg TPE FD', weightPerUnit: 0.5, analyteWeight: 10),
  StockRow(productGuid: 'PKPR-x', id: 2, quantity: 3, mazama: true, description: 'GT 25 mg TPE FD', weightPerUnit: 0.5),
];

String _keyText(WidgetTester tester, String key) {
  final texts = tester.widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)));
  return texts.map((t) => t.data).join(' ');
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// "Other stock" starts collapsed (only its title and count show); this opens it.
Future<void> _openOther(WidgetTester tester) => _tap(tester, find.byKey(const ValueKey('other-toggle')));

/// The two main pies share one spot; a horizontal swipe on it shows the other one.
Future<void> _swipePies(WidgetTester tester, {bool towardsMg = true}) async {
  await tester.drag(find.byKey(const ValueKey('stock-pies')), Offset(towardsMg ? -300 : 300, 0));
  await tester.pumpAndSettle();
}

/// A strain's serving-size pies share one spot too; a horizontal swipe on it shows the other one.
Future<void> _swipeSizes(WidgetTester tester, {bool towardsMg = true}) async {
  final f = find.byKey(const ValueKey('size-pies'));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.drag(f, Offset(towardsMg ? -300 : 300, 0));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on All', (tester) async {
    await tester.pumpWidget(_page());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();

    final filter = tester.widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>));
    expect(filter.selected, {'all'});
    // No title bar under the home's tabs: the "Stock" tab label is its title (owner, 2026-10-22).
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Bendable Service Center stock'), findsNothing);
    // Every unexpired package with units, any maker: Golden Teacher 10 + 4, Penis Envy 6.
    expect(find.text('20 units'), findsOneWidget);
    expect(find.text('380 mg TPE'), findsOneWidget); // 10 x 25 + 4 x 10 + 6 x 15
    // Key texts as the server's web page writes them (charts.render_stock): "{value:g} units · {pct}%".
    expect(_keyText(tester, 'units-key-Golden Teacher'), 'Golden Teacher 14 units · 70%');
    expect(_keyText(tester, 'units-key-Penis Envy'), 'Penis Envy 6 units · 30%');
    // One pie at a time: units first, mg TPE a swipe away; no serving-size pies until a strain is tapped.
    expect(find.byType(StockPie), findsOneWidget);
    expect(find.text('Units in stock'), findsOneWidget);
    expect(find.text('mg TPE in stock'), findsNothing);
    await _swipePies(tester);
    expect(find.byType(StockPie), findsOneWidget);
    expect(find.text('Units in stock'), findsNothing);
    expect(_keyText(tester, 'mg-key-Golden Teacher'), 'Golden Teacher 290 mg TPE · 76%');
  });

  testWidgets('Mazama only redraws without other makers', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Mazama only'));

    expect(tester.widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>)).selected, {'mazama'});
    expect(find.text('14 units'), findsOneWidget);
    expect(_keyText(tester, 'units-key-Golden Teacher'), 'Golden Teacher 14 units · 100%');
    expect(find.byKey(const ValueKey('units-key-Penis Envy')), findsNothing);
  });

  testWidgets('tapping a strain shows its serving-size pies', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    expect(find.text('Quantity'), findsNothing);

    await _tap(tester, find.byKey(const ValueKey('units-key-Golden Teacher')));
    expect(find.text('Golden Teacher serving sizes'), findsOneWidget);
    expect(find.text('Quantity'), findsOneWidget);
    expect(_keyText(tester, 'size-key-Quantity-25 mg'), '25 mg 10 · 71%');
    expect(_keyText(tester, 'size-key-Quantity-10 mg'), '10 mg 4 · 29%');
    expect(find.text(' · 14 units'), findsOneWidget); // the size pie's total, as the web's title shows it
    // One size pie at a time, as the main pies: the units pie and the strain's Quantity pie.
    expect(find.byType(StockPie), findsNWidgets(2));
    expect(find.byKey(const ValueKey('size-key-Total mg TPE-25 mg')), findsNothing);
    // The size pies are shades of the strain's own colour (s1: it has the most units).
    final sizePie = tester.widgetList<StockPie>(find.byType(StockPie)).elementAt(1);
    expect(sizePie.strainSlot, 's1');

    await _swipeSizes(tester);
    expect(find.byKey(const ValueKey('size-key-Quantity-25 mg')), findsNothing);
    expect(_keyText(tester, 'size-key-Total mg TPE-25 mg'), '25 mg 250 · 86%');
    expect(find.text(' · 290 mg TPE'), findsOneWidget);
    expect(find.byType(StockPie), findsNWidgets(2));
    expect(find.text('Units in stock'), findsOneWidget); // the main pie didn't move

    // Tapping a slice of the units pie picks that strain too.
    final unitsPie = find.byType(StockPie).first;
    await tester.ensureVisible(unitsPie);
    await tester.pumpAndSettle();
    final box = tester.getRect(unitsPie);
    // Penis Envy is the last 30%, ending at the top: just left of 12 o'clock.
    await tester.tapAt(box.center + Offset(-box.width / 8, -box.height / 4));
    await tester.pumpAndSettle();
    expect(find.text('Penis Envy serving sizes'), findsOneWidget);
  });

  testWidgets("a strain's Quantity and mg pies swap with a swipe either way, or a tap on their dots", (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('units-key-Golden Teacher')));
    expect(find.text('Quantity'), findsOneWidget);

    await _swipeSizes(tester, towardsMg: false); // already on the first: stays
    expect(find.text('Quantity'), findsOneWidget);
    await _swipeSizes(tester);
    expect(find.text('Total mg TPE'), findsOneWidget);
    expect(find.text('Quantity'), findsNothing);
    await _swipeSizes(tester); // already on the last: stays
    expect(find.text('Total mg TPE'), findsOneWidget);
    await _swipeSizes(tester, towardsMg: false);
    expect(find.text('Quantity'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('size-pie-dot-mg')));
    expect(find.text('Total mg TPE'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('size-pie-dot-units')));
    expect(find.text('Quantity'), findsOneWidget);
  });

  testWidgets('other stock lists reasons', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.text('Other stock (1)'), findsOneWidget);
    await _openOther(tester);
    expect(_keyText(tester, 'other-PKPR-hu5-4'), contains('expired'));
    expect(find.text('other maker'), findsNothing);

    await _tap(tester, find.text('Mazama only'));
    expect(find.text('Other stock (2)'), findsOneWidget);
    expect(_keyText(tester, 'other-PKPR-pe15-3'), contains('other maker'));
    // Nothing on hand is in neither list.
    expect(find.byKey(const ValueKey('other-PKPR-gone-5')), findsNothing);
  });

  testWidgets('no stock says so, with no pies', (tester) async {
    await tester.pumpWidget(_page(loadRows: () async => const []));
    await tester.pumpAndSettle();

    expect(find.text('Nothing in stock.'), findsOneWidget);
    expect(find.byType(StockPie), findsNothing);
  });

  testWidgets('SP-D19: no par table on the stock page; par levels are set when ordering', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    expect(find.text('Par levels'), findsNothing);
    expect(find.byKey(const ValueKey('par-toggle')), findsNothing);
    expect(find.text('Edit par levels'), findsNothing);
    expect(find.textContaining('below par'), findsNothing);
  });

  testWidgets('a failed load says so and Retry reloads', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_page(loadRows: () async {
      calls++;
      if (calls == 1) throw _Failure('no network');
      return _rows;
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stock did not load: no network'), findsOneWidget);
    await _tap(tester, find.widgetWithText(FilledButton, 'Retry'));
    expect(find.text('20 units'), findsOneWidget);
  });

  testWidgets('server unreachable shows the partial banner and the psilocybin title', (tester) async {
    await tester.pumpWidget(_page(load: () async => const StockLoad(_stateRows, mgMode: 'psilocybin', partial: true)));
    await tester.pumpAndSettle();
    expect(find.text("Partial: the Mazama server isn't reachable"), findsOneWidget);
    await _swipePies(tester);
    expect(find.text('mg psilocybin in stock (state figures; TPE needs the server)'), findsOneWidget);
    expect(find.text('mg TPE in stock'), findsNothing);
    expect(find.text('13 units'), findsOneWidget);
    expect(find.text('50 mg psilocybin'), findsOneWidget); // 10 x 0.5 x 10; the row with no analyte counts 0 mg
    await _swipePies(tester, towardsMg: false);
    expect(_keyText(tester, 'units-key-Unknown'), 'Unknown 13 units · 100%');
  });

  testWidgets('nothing reachable shows the last charts and their age', (tester) async {
    await tester.pumpWidget(_page(
      load: () async => StockLoad(_rows, partial: true, drawnAt: DateTime.utc(2026, 10, 21, 6)),
      now: () => DateTime.utc(2026, 10, 21, 9, 20),
    ));
    await tester.pumpAndSettle();
    expect(
        find.text('Neither the Mazama server nor the state system can be reached: these are the charts drawn on this phone 3 h ago.'),
        findsOneWidget);
    expect(find.text("Partial: the Mazama server isn't reachable"), findsNothing);
    expect(find.text('20 units'), findsOneWidget);
  });

  test('ages in words', () {
    expect(stockAge(const Duration(seconds: 20)), 'less than a minute');
    expect(stockAge(const Duration(minutes: 59)), '59 min');
    expect(stockAge(const Duration(hours: 47)), '47 h');
    expect(stockAge(const Duration(days: 3, hours: 2)), '3 days');
  });

  testWidgets('a center the server has not set up says so, not that the server is unreachable', (tester) async {
    await tester.pumpWidget(_page(load: () async => const StockLoad(_stateRows, mgMode: 'psilocybin', partial: true, notSetUp: true)));
    await tester.pumpAndSettle();
    expect(find.text("This center isn't set up on the Mazama server: these are the state's figures only."), findsOneWidget);
    expect(find.text("Partial: the Mazama server isn't reachable"), findsNothing);
  });

  testWidgets('an expired state sign-in asks the worker to sign in again', (tester) async {
    final asked = <BuildContext>[];
    await tester.pumpWidget(MaterialApp(
      home: CenterStockPage(
        center: _center,
        loadRows: () async => throw StockSignInNeeded(),
        onSignInAgain: asked.add,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('sign in again'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in again'));
    expect(asked, hasLength(1));

    // With charts kept from before, they show with the same request.
    await tester.pumpWidget(const SizedBox()); // a new page, not an update of the one above
    await tester.pumpWidget(MaterialApp(
      home: CenterStockPage(
        center: _center,
        loadRows: () async => StockLoad(_rows, partial: true, drawnAt: DateTime.now(), signInNeeded: true),
        onSignInAgain: asked.add,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('20 units'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Sign in again'));
    expect(asked, hasLength(2));
  });

  testWidgets('other stock starts collapsed, showing only its title and count, and opens and closes on a tap',
      (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    expect(find.text('Other stock (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('other-PKPR-hu5-4')), findsNothing);
    expect(find.textContaining('Not counted in the charts'), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('other-toggle')), matching: find.byIcon(Icons.expand_more)),
        findsOneWidget);

    await _openOther(tester);
    expect(find.byKey(const ValueKey('other-PKPR-hu5-4')), findsOneWidget);
    expect(find.textContaining('Not counted in the charts'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('other-toggle')), matching: find.byIcon(Icons.expand_less)),
        findsOneWidget);

    await _openOther(tester); // again: closes
    expect(find.byKey(const ValueKey('other-PKPR-hu5-4')), findsNothing);
    expect(find.text('Other stock (1)'), findsOneWidget);
  });

  testWidgets("other stock lists what can't be sold, with the server's reason, and says so", (tester) async {
    const locked = StockRow(productGuid: 'PKPR-lk', id: 9, quantity: 4, mazama: true, strain: 'Golden Teacher', description: 'Golden Teacher 25 mg');
    await tester.pumpWidget(_page(load: () async => const StockLoad(_rows, heldBack: [(row: locked, reason: 'locked (Recall)')])));
    await tester.pumpAndSettle();
    expect(find.text('Other stock (2)'), findsOneWidget); // the locked one and the expired one
    await _openOther(tester);
    expect(_keyText(tester, 'other-PKPR-lk-9'), contains('locked (Recall)'));
    expect(find.text('20 units'), findsOneWidget); // not counted
    expect(find.text("Not counted in the charts or towards par: anything expired, and packages that can't be sold "
        '(locked, flagged or pending a transfer).'), findsOneWidget);
    await _tap(tester, find.text('Mazama only'));
    expect(find.textContaining("Not counted in these charts: other makers' product (it still counts towards par)"), findsOneWidget);
  });

  testWidgets("online with the state's sign-in expired: the server's quantities, and Sign in again beside the charts",
      (tester) async {
    final asked = <BuildContext>[];
    await tester.pumpWidget(MaterialApp(
      home: CenterStockPage(
        center: _center,
        loadRows: () async => const StockLoad(_rows, serverQuantities: true, signInNeeded: true),
        onSignInAgain: asked.add,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text("The state system didn't answer: these quantities are the Mazama server's, as of its last sync."), findsOneWidget);
    expect(find.text('20 units'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Sign in again'));
    expect(asked, hasLength(1));
  });

  testWidgets('the stock charts page has no pull to refresh: only the PKPR list re-downloads the inventory', (tester) async {
    var rowLoads = 0;
    await tester.pumpWidget(_page(
      loadRows: () async {
        rowLoads++;
        return _rows;
      },
    ));
    await tester.pumpAndSettle();
    expect(find.byType(RefreshIndicator), findsNothing);

    await tester.fling(find.text('20 units'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(rowLoads, 1);
  });

  testWidgets('the units, mg and By type pies swap with a swipe either way, or a tap on their dots', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    expect(find.text('Units in stock'), findsOneWidget);

    await _swipePies(tester, towardsMg: false); // already on the first: stays
    expect(find.text('Units in stock'), findsOneWidget);
    await _swipePies(tester);
    expect(find.text('mg TPE in stock'), findsOneWidget);
    await _swipePies(tester); // SP-D17: the third pie
    expect(find.text('By type'), findsOneWidget);
    await _swipePies(tester); // already on the last: stays
    expect(find.text('By type'), findsOneWidget);
    await _swipePies(tester, towardsMg: false);
    expect(find.text('mg TPE in stock'), findsOneWidget);
    await _swipePies(tester, towardsMg: false);
    expect(find.text('Units in stock'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('stock-pie-dot-mg')));
    expect(find.text('mg TPE in stock'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('stock-pie-dot-type')));
    expect(find.text('By type'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('stock-pie-dot-units')));
    expect(find.text('Units in stock'), findsOneWidget);

    // A strain picked on either pie keeps its serving sizes open across a swipe.
    await _tap(tester, find.byKey(const ValueKey('units-key-Golden Teacher')));
    await _swipePies(tester);
    expect(find.text('Golden Teacher serving sizes'), findsOneWidget);
  });

  testWidgets('with no mg figures there is no mg pie, and By type counts units', (tester) async {
    await tester.pumpWidget(_page(loadRows: () async => const [
          StockRow(productGuid: 'PKPR-nomg', id: 7, quantity: 4, mazama: true, strain: 'Golden Teacher', description: 'Golden Teacher FD'),
        ]));
    await tester.pumpAndSettle();
    expect(find.text('Units in stock'), findsOneWidget);
    expect(find.byKey(const ValueKey('stock-pie-dot-mg')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('stock-pie-dot-type')));
    expect(find.text('By type'), findsOneWidget);
    expect(_keyText(tester, 'type-key-Other type'), 'Other type 4 units · 100%');
  });

  testWidgets('SP-D17: By type weighs the counted stock as the mg pie does, named by type', (tester) async {
    await tester.pumpWidget(_page(loadRows: () async => const [
          StockRow(productGuid: 'PKPR-a', id: 1, quantity: 10, mazama: true, strain: 'Golden Teacher', description: 'GT 25 mg TPE FD',
              unitMgTpe: 25, type: 'FD'),
          StockRow(productGuid: 'PKPR-b', id: 2, quantity: 4, mazama: true, strain: 'Penis Envy', description: 'PE 10 mg TPE DH',
              unitMgTpe: 10, type: 'DH'),
          StockRow(productGuid: 'PKPR-c', id: 3, quantity: 2, mazama: true, strain: 'Penis Envy', description: 'PE 5 mg TPE FD',
              unitMgTpe: 5),
        ]));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('stock-pie-dot-type')));
    expect(_keyText(tester, 'type-key-Freeze dried'), 'Freeze dried 260 mg TPE · 87%'); // 250 + 10 (code from the name)
    expect(_keyText(tester, 'type-key-Dehydrated'), 'Dehydrated 40 mg TPE · 13%');
  });

  // --- SP-D18: the lot table, in place of the product information sheets ----------------------------------------

  testWidgets('without a sheets loader there is no lot table', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-lot-table')), findsNothing);
  });

  testWidgets('the lot table replaces the sheets list: closed, counted, one row per lot under each of its strains',
      (tester) async {
    await tester.pumpWidget(_page(loadSheets: () async => _sheets));
    await tester.pumpAndSettle();
    expect(find.textContaining('Product information sheets'), findsNothing);
    expect(find.text('Strains in stock'), findsOneWidget);
    expect(find.text('4 lots · 3 strains'), findsOneWidget);
    expect(_lotRows(tester), isEmpty);

    await _openLots(tester);
    // the mixed lot's "golden teacher" is under the "Golden Teacher" heading: one heading per strain, whatever its case
    expect(_lotRows(tester), ['Golden Teacher|HB-gt01', 'Golden Teacher|PL-mix03', 'Penis Envy|PL-mix03', 'Penis Envy|PL-pe02',
        'Unknown|HB-un04']);
    expect(find.descendant(of: find.byKey(const ValueKey('lot-value-HB-gt01')), matching: find.text('8.64')), findsOneWidget);
    expect(find.text('Baeocystin'), findsOneWidget);
  });

  testWidgets('a strain picked on the units or mg pie narrows the table; picking it again shows every lot',
      (tester) async {
    await tester.pumpWidget(_page(loadSheets: () async => _sheets));
    await tester.pumpAndSettle();

    await _tap(tester, find.byKey(const ValueKey('units-key-Golden Teacher')));
    expect(find.text('Strains in stock: Golden Teacher'), findsOneWidget);
    expect(find.text('2 of 4 lots'), findsOneWidget); // the mixed lot's "golden teacher" matches ignoring case
    await _openLots(tester);
    expect(_lotRows(tester), ['Golden Teacher|HB-gt01', 'Golden Teacher|PL-mix03']);

    await _tap(tester, find.byKey(const ValueKey('stock-pie-dot-mg')));
    await _tap(tester, find.byKey(const ValueKey('mg-key-Penis Envy')));
    expect(find.text('Strains in stock: Penis Envy'), findsOneWidget);
    expect(_lotRows(tester), ['Penis Envy|PL-mix03', 'Penis Envy|PL-pe02']);

    await _tap(tester, find.byKey(const ValueKey('mg-key-Penis Envy')));
    expect(find.text('Strains in stock'), findsOneWidget);
    expect(_lotRows(tester), hasLength(5));
  });

  testWidgets('SP-D17: a type picked on By type narrows the table and replaces a picked strain', (tester) async {
    await tester.pumpWidget(_page(loadSheets: () async => _sheets, loadRows: () async => const [
          StockRow(productGuid: 'PKPR-a', id: 1, quantity: 10, mazama: true, strain: 'Golden Teacher', description: 'GT 25 mg TPE FD',
              unitMgTpe: 25, type: 'FD'),
          StockRow(productGuid: 'PKPR-b', id: 2, quantity: 4, mazama: true, strain: 'Penis Envy', description: 'PE 10 mg TPE DH',
              unitMgTpe: 10, type: 'DH'),
        ]));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('units-key-Golden Teacher')));
    expect(find.text('Golden Teacher serving sizes'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('stock-pie-dot-type')));
    await _tap(tester, find.byKey(const ValueKey('type-key-Dehydrated')));
    expect(find.text('Golden Teacher serving sizes'), findsNothing); // one pick at a time
    expect(find.text('Strains in stock: Dehydrated'), findsOneWidget);
    expect(find.text('2 of 4 lots'), findsOneWidget);
    await _openLots(tester);
    // the mixed lot is dehydrated: it shows under both its strains
    expect(_lotRows(tester), ['golden teacher|PL-mix03', 'Penis Envy|PL-mix03', 'Penis Envy|PL-pe02']);

    await _tap(tester, find.byKey(const ValueKey('type-key-Dehydrated')));
    expect(find.text('Strains in stock'), findsOneWidget);
  });

  testWidgets('a strain with no lots says so, while the table is closed and once it is open', (tester) async {
    await tester.pumpWidget(_page(loadSheets: () async => [_sheets.first]));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('units-key-Penis Envy')));
    expect(find.text('Strains in stock: Penis Envy'), findsOneWidget);
    expect(find.text('0 of 1 lot'), findsOneWidget);
    await _openLots(tester);
    expect(find.text('Nothing in stock for Penis Envy.'), findsOneWidget);
  });

  testWidgets('an unknown strain on the pie keeps the lots whose strain is not known', (tester) async {
    await tester.pumpWidget(_page(
      loadRows: () async => const [StockRow(productGuid: 'PKPR-x', id: 9, quantity: 3, mazama: true, description: 'Mystery 10 mg', unitMgTpe: 10)],
      loadSheets: () async => _sheets,
    ));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('units-key-Unknown')));
    await _openLots(tester);
    expect(_lotRows(tester), ['Unknown|HB-un04']);
  });

  testWidgets('tapping a lot id opens its sheet', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_page(loadSheets: () async => _sheets, openSheet: (s) async => opened.add(s.guid)));
    await tester.pumpAndSettle();
    await _openLots(tester);
    await _tap(tester, find.byKey(const ValueKey('lot-link-PL-pe02')));
    expect(opened, ['PL-pe02']);
  });

  testWidgets("a lot with no page to open (the demo's) is plain text", (tester) async {
    const sheet = ProductSheet(guid: 'HB-DEMO0001', name: 'Demo', product: 'Whole Fungi', tested: '', path: null, strains: ['Demo']);
    await tester.pumpWidget(_page(loadSheets: () async => [sheet]));
    await tester.pumpAndSettle();
    await _openLots(tester);
    expect(find.byKey(const ValueKey('lot-link-HB-DEMO0001')), findsNothing);
    expect(find.text('HB-DEMO0001'), findsOneWidget);
  });

  testWidgets('lots that did not load say so in the table, and the rest of the page still shows', (tester) async {
    await tester.pumpWidget(_page(loadSheets: () async => throw SheetsError('cannot reach sales.mazamamushrooms.com: SocketException')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Lots did not load: cannot reach'), findsOneWidget);
    expect(find.text('20 units'), findsOneWidget);
  });

  // --- Mazama's server unreachable: the sheets it last sent, kept on the phone ----------------------------------

  testWidgets('the sheets the server sends are kept with when; no notice shows', (tester) async {
    final kept = <(List<ProductSheet>, DateTime)>[];
    final now = DateTime.utc(2026, 10, 23, 8);
    await tester.pumpWidget(_page(loadSheets: () async => _sheets, keepSheets: (s, t) async => kept.add((s, t)), now: () => now));
    await tester.pumpAndSettle();
    expect(kept.single.$1, same(_sheets));
    expect(kept.single.$2, now);
    expect(find.byKey(const ValueKey('server-offline-notice')), findsNothing);
  });

  testWidgets('unreachable: the kept sheets fill the lot table under a notice with their date', (tester) async {
    final at = DateTime.utc(2026, 10, 20, 15, 5);
    await tester.pumpWidget(_page(
      loadSheets: () async => throw SheetsError('cannot reach sales.mazamamushrooms.com: SocketException', unreachable: true),
      keptSheets: () async => ServerRead.cached(_sheets, at),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining(serverOfflineNotice(at)), findsOneWidget);
    expect(find.textContaining('Lots did not load'), findsNothing);
    await _openLots(tester);
    expect(_lotRows(tester), contains('Golden Teacher|HB-gt01'));
  });

  testWidgets("a 4xx is the server's own answer: the error in the table, not the kept sheets", (tester) async {
    await tester.pumpWidget(_page(
      loadSheets: () async => throw SheetsError('No such service center.'),
      keptSheets: () async => ServerRead.cached(_sheets, DateTime.utc(2026, 10, 20)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Lots did not load: No such service center.'), findsOneWidget);
    expect(find.byKey(const ValueKey('server-offline-notice')), findsNothing);
  });
}
