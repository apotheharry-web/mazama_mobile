// specs/core row 6 (Task 12): the cart's prices come from the shared core and fail closed (PRICE-8): a core that throws
// (StateError, MazamaCoreError, an exception of a type nothing names), answers with something that isn't a map, or
// answers a price of the wrong shape (a wrong number of lines, a negative or non-whole cent, a price over the unit
// cap, an error code it doesn't have) leaves the cart unpriced and Sell off. PRICE-3: the line dialog's rate per mg is
// held to the $10,000 unit cap. PRICE-9: a cart whose center's tax and split this phone doesn't know adds no tax and
// splits no total, and the last cart settings the server sent are kept for when it can't be reached.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/cart_pricing.dart';
import 'package:mazama_mobile/center_status_client.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/pricing.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';

import 'cart_page_test_support.dart';
import 'support/core.dart';

/// An exception of a type nothing in the app names.
class _Odd implements Exception {}

/// A core whose pricing functions all answer [answer] (or throw what it throws); everything else is not called.
class _Pricing implements CoreFunctions {
  _Pricing(this.answer);
  final Object? Function() answer;

  @override
  dynamic noSuchMethod(Invocation invocation) => answer();
}

/// The real core, but for price_cart, which answers [answer].
class _BadCart implements CoreFunctions {
  _BadCart(this.answer);
  final Map<String, Object?> Function(Map<String, Object?> input) answer;
  CoreFunctions get _real => MazamaCore.instance;

  @override
  Map<String, Object?> sellingPriceCart(Map<String, Object?> input) => answer(input);
  @override
  Map<String, Object?> sellingGroupOf(Map<String, Object?> input) => _real.sellingGroupOf(input);
  @override
  Map<String, Object?> sellingLinePrice(Map<String, Object?> input) => _real.sellingLinePrice(input);
  @override
  Map<String, Object?> sellingParsePrice(Map<String, Object?> input) => _real.sellingParsePrice(input);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _lines = [CartPricingLine(group: 'A', mgTpe: 5, qty: 2), CartPricingLine(group: 'B', mgTpe: 9, qty: 1)];

CartPricingResult _total(CoreFunctions core, {String total = '130'}) =>
    priceWholeCart(mode: CartPricingMode.total, lines: _lines, totalText: total, core: core);

final _throwing = <String, Object Function()>{
  'StateError': () => StateError('no core loaded'),
  'MazamaCoreError': () => const MazamaCoreError('it said no'),
  'an exception of a type nothing names': _Odd.new,
};

final _badReplies = <String, Map<String, Object?>>{
  'a wrong number of prices': {'each': [100], 'line_errors': [null, null], 'error': null},
  'a negative cent': {'each': [-1, 100], 'line_errors': [null, null], 'error': null},
  'a cent that is not whole': {'each': [1.5, 100], 'line_errors': [null, null], 'error': null},
  'a price over the unit cap': {'each': [maxUnitCents + 1, 100], 'line_errors': [null, null], 'error': null},
  'prices and an error': {'each': [100, 100], 'line_errors': [null, null], 'error': 'total'},
  'an error code it does not have': {'each': null, 'line_errors': [null, null], 'error': 'nope'},
  'no line errors': {'each': [100, 100], 'error': null},
  'no_mg naming no line': {'each': null, 'line_errors': [null, null], 'error': 'no_mg'},
  'an empty map': {},
};

void main() {
  setUpAll(loadTestCore);
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_pricing_core_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  group('PRICE-8: a core that fails prices nothing', () {
    for (final MapEntry(key: what, value: error) in _throwing.entries) {
      test('a core that throws $what', () {
        final core = _Pricing(() => throw error());
        final r = _total(core);
        expect(r.errorCode, 'core');
        expect(r.error, coreFailedPriceMessage);
        expect(r.priceCentsEach, isNull);
        expect(priceWholeCart(mode: CartPricingMode.perMg, lines: _lines, perMgText: '1', core: core).errorCode, 'core');
        expect(linePrice(perMg: false, text: '5', mg: 5, core: core), (cents: null, error: 'core'));
        expect(toCents('5', core: core), isNull);
        expect(groupOf('Extract', core: core), isNull);
        expect(() => shareTotal(100, [1, 1], core: core), throwsStateError);
        expect(() => withTax(100, 15, core: core), throwsStateError);
        expect(() => perMgPriceCentsEach(10, 5, core: core), throwsStateError);
        final lot = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 1, weightPerUnit: 1, analyteWeight: 1, quantity: 3);
        expect(() => drawOrder([lot], core: core), throwsStateError);
        expect(allocateLots([lot], 1, core: core), isNull);
      });
    }

    test('a core that answers with something that is not a map', () {
      final core = _Pricing(() => [1, 2, 3]);
      expect(_total(core).errorCode, 'core');
      expect(linePrice(perMg: true, text: '1', mg: 5, core: core).error, 'core');
      expect(toCents('5', core: core), isNull);
      expect(groupOf('Extract', core: core), isNull);
    });

    for (final MapEntry(key: what, value: reply) in _badReplies.entries) {
      test('a cart price with $what', () {
        final r = _total(_BadCart((_) => reply));
        expect(r.errorCode, 'core');
        expect(r.priceCentsEach, isNull);
      });
    }

    test('a line price of the wrong shape', () {
      for (final reply in <Map<String, Object?>>[
        {'cents': -5, 'error': null},
        {'cents': 2.5, 'error': null},
        {'cents': maxUnitCents + 1, 'error': null},
        {'cents': 5, 'error': 'price'},
        {'cents': null, 'error': 'nope'},
        {'cents': null, 'error': null},
      ]) {
        expect(linePrice(perMg: false, text: '5', mg: 5, core: _Pricing(() => reply)).error, 'core', reason: '$reply');
      }
    });

    test('a draw of the wrong shape', () {
      final lots = [
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 1, weightPerUnit: 1, analyteWeight: 1, quantity: 3),
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 2, weightPerUnit: 1, analyteWeight: 1, quantity: 3),
      ];
      for (final reply in <Map<String, Object?>>[
        {'positions': [0, 0], 'takes': null, 'take_positions': null},
        {'positions': [0], 'takes': null, 'take_positions': null},
        {'positions': [1, 0], 'takes': [[2, 4]], 'take_positions': [1]},
        {'positions': [1, 0], 'takes': [[1, 2]], 'take_positions': [1]},
        {'positions': [1, 0], 'takes': [[2, 1]], 'take_positions': [1]},
        {'positions': [1, 0], 'takes': [[2, 2]], 'take_positions': null},
      ]) {
        expect(allocateLots(lots, 2, core: _Pricing(() => reply)), isNull, reason: '$reply');
      }
      final good = allocateLots(lots, 2, core: _Pricing(() => <String, Object?>{'positions': [1, 0], 'takes': [[2, 2]], 'take_positions': [1]}));
      expect([for (final (l, n) in good!) (l.id, n)], [(2, 2)]);
    });

    testWidgets("the cart can't be sold when its core can't price it", (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, core: _BadCart((_) => throw _Odd())));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await tester.tap(find.text('Whole cart total'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Total price for the whole cart'), '40.00');
      await tester.pumpAndSettle();
      expect(find.text(coreFailedPriceMessage), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell')).onPressed, isNull);
    });

    testWidgets("a line can't be added when the core can't price it", (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, core: _Pricing(() => throw const MazamaCoreError('no'))));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), '10.00');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();
      expect(find.text(coreFailedPriceMessage), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget); // still open: nothing was added
    });
  });

  group('PRICE-3: the line dialog holds a rate per mg to the unit cap', () {
    test(r'$1,000 per mg on 11 mg is refused; on 10 mg it is $10,000', () {
      expect(linePrice(perMg: true, text: '1000', mg: 11), (cents: null, error: 'unit_cap'));
      expect(linePrice(perMg: true, text: '1000', mg: 10), (cents: maxUnitCents, error: null));
    });

    testWidgets('the dialog says so and adds nothing', (tester) async {
      final big = Package(productGuid: 'PKPR-cc33d', productType: 'Extract', id: 103, weightPerUnit: 1, analyteWeight: 1, tpeMg: 11, quantity: 4);
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => [...inventory, big]));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'cc33d');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Price per mg'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Price per mg (TPE)'), '1000');
      await tester.pump();
      expect(find.textContaining('= \$'), findsNothing); // no "each" preview of a price it won't take
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')));
      await tester.pumpAndSettle();
      expect(find.text('A single unit would cost more than \$10,000'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });

  group("PRICE-9: a center's tax and split this phone doesn't know", () {
    test('no tax is added and no total is split on the built-in settings', () {
      final both = [CartPricingLine(group: 'A', mgTpe: 5, qty: 1), CartPricingLine(group: 'B', mgTpe: 9, qty: 1)];
      final one = [CartPricingLine(group: 'A', mgTpe: 5, qty: 1)];
      CartPricingResult price(List<CartPricingLine> lines, {CartPricingMode mode = CartPricingMode.total, CartTaxMode tax = CartTaxMode.included}) =>
          priceWholeCart(mode: mode, lines: lines, totalText: '130', perMgText: '1', tax: tax, settingsKnown: false);
      expect(price(both).errorCode, 'settings');
      expect(price(both).error, settingsUnknownMessage);
      expect(price(one, tax: CartTaxMode.addPercent).errorCode, 'settings');
      expect(price(both, mode: CartPricingMode.perMg, tax: CartTaxMode.addPercent).errorCode, 'settings');
      expect(price(one).priceCentsEach, [13000]); // one group, no tax: nothing of the settings is used
      expect(price(both, mode: CartPricingMode.perMg).priceCentsEach, [500, 900]);
    });

    testWidgets("when the server can't say and nothing is kept, a two-group total isn't priced", (tester) async {
      await tester.pumpWidget(cartPage(
          fetchPackages: (id) async => inventory, fetchCartSettings: (id) async => throw CenterStatusError('offline')));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '10.00');
      await tester.tap(find.text('Whole cart total'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Total price for the whole cart'), '130.00');
      await tester.pumpAndSettle();
      expect(find.text(settingsUnknownMessage), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell')).onPressed, isNull);
    });

    group('the kept settings', () {
      late Directory dir;
      setUp(() => dir = Directory.systemTemp.createTempSync('mazama_price9_'));
      tearDown(() => dir.deleteSync(recursive: true));

      const host = CartSettings(minutes: 600, taxPercent: 10, agreementEdible: 1, agreementDried: 2, dedupeSeconds: 20, maxUnitsPerLine: 999);

      test("the server's answer is kept, and used when it can't be reached", () async {
        final datasets = Datasets.forDir(() => dir);
        final got = await fetchCartSettings(225, datasets: datasets, fetch: (id) async => const CenterStatus(configured: true, cart: host));
        expect(got.taxPercent, 10);
        final offline = await fetchCartSettings(225, datasets: Datasets.forDir(() => dir), fetch: (id) async => throw CenterStatusError('offline'));
        expect((offline.taxPercent, offline.agreementEdible, offline.agreementDried), (10, 1, 2));
      });

      test("with nothing kept it says it can't, rather than giving the built-in settings", () async {
        expect(fetchCartSettings(225, datasets: Datasets.forDir(() => dir), fetch: (id) async => throw CenterStatusError('offline')),
            throwsA(isA<CenterStatusError>()));
        expect(fetchCartSettings(225, fetch: (id) async => throw CenterStatusError('offline')), throwsA(isA<CenterStatusError>()));
      });

      test("an older build's center_status copy (the sync engine's refresher kept it) is read", () async {
        final body = jsonEncode(const CenterStatus(configured: true, cart: host).toJson());
        Datasets.forDir(() => dir).put(Dataset.centerStatus, '225', body, source: sourceServer);
        final got = await fetchCartSettings(225, datasets: Datasets.forDir(() => dir), fetch: (id) async => throw CenterStatusError('offline'));
        expect(got.taxPercent, 10);
      });

      test("another center's copy is never used", () async {
        final datasets = Datasets.forDir(() => dir);
        await fetchCartSettings(226, datasets: datasets, fetch: (id) async => const CenterStatus(configured: true, cart: host));
        expect(fetchCartSettings(225, datasets: datasets, fetch: (id) async => throw CenterStatusError('offline')),
            throwsA(isA<CenterStatusError>()));
      });
    });
  });

  group('review M6/M7: one refusal stays where it is', () {
    test('a lot the core refuses makes only its product unsellable; the rest of the stock still groups and sells', () {
      Package lot(String guid, int id, {DateTime? expires}) => Package(
          productGuid: guid, productType: 'Extract', id: id, weightPerUnit: 1, analyteWeight: 1, quantity: 3, expires: expires);
      final bad = lot('PKPR-bad1', 1, expires: DateTime(10000, 1, 1)); // a year the core's dates refuse
      final good = [lot('PKPR-ok22', 2, expires: DateTime(2027, 6, 1)), lot('PKPR-ok22', 3, expires: DateTime(2027, 3, 1))];
      expect(() => drawOrder([bad]), throwsStateError); // the draw itself still refuses
      final groups = groupByPkpr([bad, ...good]);
      expect([for (final g in groups) (g.productGuid, g.drawRefused)], [('PKPR-bad1', true), ('PKPR-ok22', false)]);
      expect([for (final l in groups[1].lots) l.id], [3, 2]);
      expect(groups[0].lots.single.id, 1);
      expect([for (final g in sortedPkprGroups([bad, ...good])) g.productGuid], containsAll(['PKPR-bad1', 'PKPR-ok22']));
      // fail closed for selling: the refused product can't be drawn from, the others can
      expect(allocateLots(groups[0].lots, 1), isNull);
      final draw = allocateBulkSales([(lots: groups[0].lots, qty: 1)], 1);
      expect([draw.perSale, draw.shortLine], [null, 0]);
      final ok = allocateBulkSales([(lots: groups[1].lots, qty: 4)], 1);
      expect([for (final (l, n) in ok.perSale!.single.single) (l.id, n)], [(3, 3), (2, 1)]);
    });

    test('a per-mg price of an mg that is not a number refuses as every other core failure does', () {
      expect(() => perMgPriceCentsEach(10, double.nan), throwsStateError);
      expect(() => perMgPriceCentsEach(10, double.infinity), throwsStateError);
      expect(perMgPriceCentsEach(10, 5), 50);
    });
  });
}
