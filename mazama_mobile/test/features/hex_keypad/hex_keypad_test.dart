// The cart's PKPR keypad (lib/features/hex_keypad/, specs/hex-keypad): the shared cases through the core, and the
// keypad itself against the real core: which keys are lit, filling the one match left, no stock and no core.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/feature_entry.dart';
import 'package:mazama_mobile/features/hex_keypad/hex_keypad.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/packages_client.dart';

import '../../support/core.dart';

Package _package(String guid, {String type = 'Extract', int quantity = 4, int id = 1}) => Package(
    productGuid: guid, productType: type, id: id, weightPerUnit: 1.0, analyteWeight: 1.0, strain: 'Golden Teacher',
    tpeMg: 5, quantity: quantity);

final _stock = groupByPkpr([
  _package('PKPR-ab12c', type: 'Extract', quantity: 10, id: 1),
  _package('PKPR-ff99aa', type: 'Whole Fungi', quantity: 3, id: 2),
]);

/// A core that can't answer anything.
class _NoCore implements CoreFunctions {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw MazamaCoreError('no core');
}

void main() {
  late MazamaCore core;
  setUpAll(() => core = loadTestCore());

  test('every shared case: the keys lit, the matches and the one left', () {
    final doc = jsonDecode(File('assets/shared/features_vectors/hex_keypad/keys.json').readAsStringSync()) as Map;
    final cases = doc['cases'] as List;
    expect(cases.length, greaterThanOrEqualTo(10));
    for (final c in cases.cast<Map>()) {
      final reply = core.keypadKeys({'typed': c['typed'], 'pkprs': c['pkprs']});
      expect(reply['keys'], c['keys'], reason: c['why'] as String);
      expect(reply['matches'], c['matches'], reason: c['why'] as String);
      expect(reply['only'], c['only'], reason: c['why'] as String);
    }
  });

  test("keypadAnswer reads the core's answer for the stock's PKPRs", () {
    final a = keypadAnswer('a', _stock, core: core);
    expect(a.keys, {'a', 'b'});
    expect(a.matches, ['PKPR-ab12c', 'PKPR-ff99aa']);
    expect(a.only, isNull);
    expect(keypadAnswer('1', _stock, core: core).only, 'PKPR-ab12c');
    expect(() => keypadAnswer('a', _stock, core: _NoCore()), throwsA(isA<MazamaCoreError>()));
  });

  group('the keypad', () {
    late TextEditingController controller;
    late FocusNode focus;

    setUp(() {
      controller = TextEditingController();
      focus = FocusNode();
    });
    tearDown(() {
      controller.dispose();
      focus.dispose();
    });

    Widget page({List<PkprGroup>? stock, CoreFunctions? withCore, String? errorText}) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  HexKeypadInput(
                    core: withCore ?? core,
                    args: PkprInputArgs(
                      controller: controller,
                      focusNode: focus,
                      stock: stock,
                      errorText: errorText,
                      onAdd: () {},
                      actions: FilledButton(onPressed: () {}, child: const Text('Add')),
                    ),
                  ),
                  const SizedBox(height: 400, child: Center(child: Text('elsewhere on the page'))),
                ],
              ),
            ),
          ),
        );

    Finder key(String k) => find.byKey(ValueKey('keypad-key-$k'));
    Set<String> shownKeys(WidgetTester tester) => {for (final k in keypadLayout) if (key(k).evaluate().isNotEmpty) k};
    final clear = find.byKey(const ValueKey('keypad-clear'));
    final keys = find.byKey(const ValueKey('keypad-keys'));

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('keypad-field')));
      await tester.pumpAndSettle();
    }

    final threeInStock = [
      ..._stock,
      ...groupByPkpr([_package('PKPR-c0ffa', type: 'Chocolate', quantity: 7, id: 3)]),
    ];

    testWidgets("the field takes no system keyboard, and the keypad opens once it's tapped", (tester) async {
      await tester.pumpWidget(page(stock: _stock));
      final field = tester.widget<TextField>(find.byKey(const ValueKey('keypad-field')));
      expect(field.readOnly, isTrue);
      expect(field.keyboardType, TextInputType.none);
      expect(keys, findsNothing);
      expect(find.text('Add'), findsOneWidget); // the cart's own buttons sit beside the field

      await open(tester);
      expect(keys, findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('on a tablet the keypad stays phone-sized, centred under the field, not stretched to the width',
        (tester) async {
      tester.view.physicalSize = const Size(1180, 820); // an iPad in landscape, in logical pixels
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(page(stock: _stock));
      await open(tester);
      final pad = tester.getRect(keys);
      expect(pad.width, lessThanOrEqualTo(keypadMaxWidth));
      final screen = tester.getRect(find.byType(Scaffold));
      expect(pad.center.dx, closeTo(screen.center.dx, 1));
      final key = tester.getSize(find.byKey(const ValueKey('keypad-key-1')));
      expect(key.height, lessThan(80)); // a finger-sized key, not a 220-by-140 slab
    });

    testWidgets('on a phone the keypad still spans the field, as before', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(page(stock: _stock));
      await open(tester);
      final field = tester.getRect(find.byKey(const ValueKey('keypad-field')));
      expect(tester.getRect(keys).left, closeTo(field.left, 1));
    });

    testWidgets('only the keys some PKPR in stock can take are shown, in keypad order', (tester) async {
      await tester.pumpWidget(page(stock: _stock));
      await open(tester);
      expect(shownKeys(tester), {'1', '2', '9', 'a', 'b', 'c', 'f'});
      expect(key('7'), findsNothing); // not greyed: not there at all
      final order = [for (final k in ['1', '2', '9', 'a', 'b', 'c', 'f']) tester.getTopLeft(key(k))];
      for (var i = 1; i < order.length; i++) {
        final before = order[i - 1], here = order[i];
        expect(here.dy > before.dy || (here.dy == before.dy && here.dx > before.dx), isTrue,
            reason: 'packed in keypad order');
      }
    });

    testWidgets('a key types into the field and the keys follow what can come next, anywhere in a PKPR', (tester) async {
      await tester.pumpWidget(page(stock: _stock));
      await open(tester);
      await tester.tap(key('a'));
      await tester.pumpAndSettle();
      expect(controller.text, 'a');
      expect(shownKeys(tester), {'a', 'b'});
    });

    testWidgets('backspace takes the last character off', (tester) async {
      await tester.pumpWidget(page(stock: _stock));
      await open(tester);
      await tester.tap(key('a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('keypad-backspace')));
      await tester.pumpAndSettle();
      expect(controller.text, '');
      expect(shownKeys(tester), {'1', '2', '9', 'a', 'b', 'c', 'f'});
    });

    testWidgets('a key that leaves one PKPR fills it in and closes the keypad; Clear empties it and opens it again',
        (tester) async {
      await tester.pumpWidget(page(stock: _stock));
      await open(tester);
      await tester.tap(key('1'));
      await tester.pumpAndSettle();
      expect(controller.text, 'ab12c');
      expect(keys, findsNothing);
      expect(clear, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('keypad-field'))); // a filled-in PKPR waits for Add or Clear
      await tester.pumpAndSettle();
      expect(keys, findsNothing);
      expect(clear, findsOneWidget); // the tap only moved the cursor: still filled in

      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(controller.text, '');
      expect(clear, findsNothing);
      expect(shownKeys(tester), {'1', '2', '9', 'a', 'b', 'c', 'f'});
    });

    testWidgets('a tap anywhere else closes the keypad and keeps what was typed; the field opens it again', (tester) async {
      await tester.pumpWidget(page(stock: _stock));
      await open(tester);
      await tester.tap(key('a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('elsewhere on the page'));
      await tester.pumpAndSettle();
      expect(keys, findsNothing);
      expect(controller.text, 'a');

      await open(tester);
      expect(shownKeys(tester), {'a', 'b'});
    });

    testWidgets('the field emptied from outside (after an add) closes the keypad, even with the focus back', (tester) async {
      await tester.pumpWidget(page(stock: _stock));
      await open(tester);
      await tester.tap(key('1'));
      await tester.pumpAndSettle();
      expect(clear, findsOneWidget);

      controller.clear(); // what the cart does once the line is added
      focus.requestFocus(); // and it gives the field its focus back
      await tester.pumpAndSettle();
      expect(clear, findsNothing);
      expect(keys, findsNothing);
    });

    testWidgets('the matches are listed from the second character on, and tapping one fills it in', (tester) async {
      await tester.pumpWidget(page(stock: threeInStock));
      await open(tester);
      await tester.tap(key('f'));
      await tester.pumpAndSettle();
      expect(controller.text, 'f'); // in ff99aa and c0ffa: nothing filled
      expect(find.byKey(const ValueKey('keypad-matches')), findsNothing);
      await tester.tap(key('f'));
      await tester.pumpAndSettle();
      expect(controller.text, 'ff'); // still both
      expect(find.text('Whole Fungi · 3 in stock'), findsOneWidget);
      expect(find.text('Chocolate · 7 in stock'), findsOneWidget);

      await tester.tap(find.text('PKPR-c0ffa'));
      await tester.pumpAndSettle();
      expect(controller.text, 'c0ffa');
      expect(clear, findsOneWidget);
      expect(keys, findsNothing);
    });

    testWidgets('several matches and no next key: no keys, and the matches to pick from', (tester) async {
      await tester.pumpWidget(page(stock: groupByPkpr([_package('PKPR-12345', id: 1), _package('PKPR-f12345', id: 2)])));
      await open(tester);
      for (final k in ['1', '2', '3', '4', '5']) {
        await tester.tap(key(k));
        await tester.pumpAndSettle();
      }
      expect(controller.text, '12345');
      expect(keys, findsNothing);
      expect(find.text('PKPR-12345'), findsOneWidget);
      expect(find.text('PKPR-f12345'), findsOneWidget);
      expect(find.byKey(const ValueKey('keypad-backspace')), findsOneWidget);
    });

    testWidgets('no stock loaded: no keys, and the keypad says why', (tester) async {
      await tester.pumpWidget(page(stock: null));
      await open(tester);
      expect(shownKeys(tester), isEmpty);
      expect(find.text(keypadNoStock), findsOneWidget);
    });

    testWidgets("a core that can't answer shows no keys and says so, never guesses", (tester) async {
      await tester.pumpWidget(page(stock: _stock, withCore: _NoCore()));
      await open(tester);
      expect(shownKeys(tester), isEmpty);
      expect(find.text(keypadCoreFailed), findsOneWidget);
    });

    testWidgets("the field's error shows with the keypad closed", (tester) async {
      await tester.pumpWidget(page(stock: _stock, errorText: 'No PKPR 77 here.'));
      expect(find.text('No PKPR 77 here.'), findsOneWidget);
    });
  });
}
