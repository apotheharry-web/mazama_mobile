// The cart's one-screen add (lib/features/quick_add/, specs/quick-add): the label on top, a unit per tap on Primary
// or Secondary up to each dose's ceiling, long press and Clear back to 0, and the price when the cart asks for one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/feature_entry.dart';
import 'package:mazama_mobile/features/quick_add/quick_add.dart';
import 'package:mazama_mobile/packages_client.dart';

final _group = groupByPkpr([
  Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 1, weightPerUnit: 1.0, analyteWeight: 1.0,
      strain: 'Golden Teacher', tpeMg: 5, quantity: 20),
]).single;

/// A price check standing in for the cart's: dollars (cents allowed), a per-mg rate times 5 mg; refused otherwise.
({int? cents, String? error}) _price({required bool perMg, required String text}) {
  final n = double.tryParse(text.trim());
  if (n == null || n < 0) return (cents: null, error: 'Enter a price');
  return (cents: ((perMg ? n * 5 : n) * 100).round(), error: null);
}

LineEditorArgs _args({
  int primary = 0,
  int secondary = 0,
  bool editing = false,
  int maxUnitsPerLine = 50,
  int stockLeft = 20,
  LinePriceCheck? price,
  int? priceCentsEach,
}) =>
    LineEditorArgs(
      group: _group,
      label: const Text('the label'),
      primary: primary,
      secondary: secondary,
      editing: editing,
      maxUnitsPerLine: maxUnitsPerLine,
      stockLeft: stockLeft,
      price: price,
      priceCentsEach: priceCentsEach,
    );

void main() {
  late List<LineChoice?> closed;
  setUp(() => closed = []);

  Future<void> show(WidgetTester tester, LineEditorArgs args) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1400); // a phone-tall screen: the whole screen on view
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async =>
                  closed.add(await showDialog<LineChoice>(context: context, builder: (_) => QuickAddScreen(args: args))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  final primary = find.byKey(const ValueKey('quick-primary'));
  final secondary = find.byKey(const ValueKey('quick-secondary'));
  final add = find.byKey(const ValueKey('quick-add'));
  String count(WidgetTester tester, Finder button) =>
      tester.widgetList<Text>(find.descendant(of: button, matching: find.byType(Text))).last.data!;
  bool enabled(WidgetTester tester, Finder f) => tester.widget<ButtonStyleButton>(f).onPressed != null;

  Future<void> tap(WidgetTester tester, Finder f, [int times = 1]) async {
    for (var i = 0; i < times; i++) {
      await tester.tap(f);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('the label is on top, then Primary and Secondary at 0, and Add waits for a unit', (tester) async {
    await show(tester, _args());
    expect(find.text('the label'), findsOneWidget);
    expect(tester.getTopLeft(find.text('the label')).dy, lessThan(tester.getTopLeft(primary).dy));
    expect(count(tester, primary), '0');
    expect(count(tester, secondary), '0');
    expect(find.text('Add'), findsOneWidget);
    expect(enabled(tester, add), isFalse);
  });

  testWidgets('a tap counts one unit, and Add closes with both counts', (tester) async {
    await show(tester, _args());
    await tap(tester, primary, 3);
    await tap(tester, secondary);
    expect(count(tester, primary), '3');
    expect(count(tester, secondary), '1');
    await tap(tester, add);
    expect(closed.single!.primary, 3);
    expect(closed.single!.secondary, 1);
    expect(closed.single!.priceCentsEach, isNull); // the cart prices every line: no price asked for
  });

  testWidgets('each dose counts at most 5', (tester) async {
    await show(tester, _args());
    await tap(tester, primary, 7);
    await tap(tester, secondary, 6);
    expect(count(tester, primary), '5');
    expect(count(tester, secondary), '5');
  });

  testWidgets("the server's units per line and the stock left lower the ceiling, shared by both doses", (tester) async {
    await show(tester, _args(maxUnitsPerLine: 3, stockLeft: 4));
    await tap(tester, primary, 5);
    expect(count(tester, primary), '3'); // the server's 3 per line
    await tap(tester, secondary, 5);
    expect(count(tester, secondary), '1'); // 4 left in stock, 3 of them primary
  });

  testWidgets('a long press sets that dose back to 0, and Clear sets both', (tester) async {
    await show(tester, _args());
    await tap(tester, primary, 2);
    await tap(tester, secondary, 2);
    await tester.longPress(primary);
    await tester.pumpAndSettle();
    expect(count(tester, primary), '0');
    expect(count(tester, secondary), '2');

    await tap(tester, primary);
    await tap(tester, find.byKey(const ValueKey('quick-clear')));
    expect(count(tester, primary), '0');
    expect(count(tester, secondary), '0');
    expect(enabled(tester, add), isFalse);
  });

  testWidgets('Cancel closes with nothing', (tester) async {
    await show(tester, _args());
    await tap(tester, primary);
    await tap(tester, find.text('Cancel'));
    expect(closed, [null]);
  });

  testWidgets('pricing each line: the price is asked for, checked, and given with the counts', (tester) async {
    await show(tester, _args(price: _price));
    await tap(tester, primary, 2);
    await tap(tester, add);
    expect(closed, isEmpty); // no price yet: not added
    expect(find.text('Enter a price'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('quick-price')), '12');
    await tester.pumpAndSettle();
    await tap(tester, add);
    expect(closed.single!.primary, 2);
    expect(closed.single!.priceCentsEach, 1200);
  });

  testWidgets('pricing each line per mg uses the per-mg check and its label', (tester) async {
    await show(tester, _args(price: _price));
    await tap(tester, find.text('Price per mg'));
    expect(find.widgetWithText(TextField, 'Price per mg (TPE)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('quick-price')), '2');
    await tester.pumpAndSettle();
    await tap(tester, secondary);
    await tap(tester, add);
    expect(closed.single!.secondary, 1);
    expect(closed.single!.priceCentsEach, 1000); // 2 a mg times the stand-in check's 5 mg
  });

  testWidgets("editing: the line's own count, above 5 if it is, its price, and Save", (tester) async {
    await show(tester, _args(secondary: 8, editing: true, price: _price, priceCentsEach: 1500));
    expect(count(tester, secondary), '8');
    expect(find.text('Save'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('quick-price'))).controller!.text, '15.00');
    await tap(tester, secondary); // already above its ceiling: no more
    expect(count(tester, secondary), '8');
    await tap(tester, primary);
    await tap(tester, add);
    expect(closed.single!.secondary, 8);
    expect(closed.single!.primary, 1);
    expect(closed.single!.priceCentsEach, 1500);
  });
}
