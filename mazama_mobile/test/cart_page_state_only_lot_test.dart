// A product with a lot only the state lists (no lab report on Mazama's
// server) stays one line, shown and priced by its first lot's figure (its psilocybin and cap counted from
// the lots the sale draws, each its own figures); the line and its
// dialog add a note saying how many of its units only the state knows and their own figure, in mg psilocybin.
// Invented fixtures (this folder is published).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/packages_client.dart';

import 'cart_page_test_support.dart';

void main() {
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_state_only_lot_test_'));
  tearDown(() {
    // as cart_page_sell_test.dart: no Future straddling two tests (CI's bundle shares one isolate, so a
    // rootBundle cache this file leaves behind would otherwise hang the next widget test's pumpAndSettle)
    rootBundle.clear();
    LocalStore.debugCloseAll();
    tempDir.deleteSync(recursive: true);
  });

  // PKPR-ab12c as the merge leaves it: lot 101 joined (the server's 8 mg TPE, an expiry, so drawn first), lot 102 only
  // the state lists (its own figure, the state's psilocybin: ceil(5 x 1.2) = 6).
  final stock = [
    Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 1.0,
        strain: 'Golden Teacher', tpeMg: 8, quantity: 4, expires: DateTime(2027, 3, 1)),
    Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 102, weightPerUnit: 5.0, analyteWeight: 1.2, tpeMg: 6,
        quantity: 2, coaAvailable: false, labelAvailable: false, stateOnly: true),
    inventory[1],
  ];
  const note = 'includes 2 unit(s) known only by the state: 6 mg psilocybin each';

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(cartPage(fetchPackages: (id) async => stock));
    await tester.pumpAndSettle();
  }

  testWidgets("the add dialog notes the state-only units; the product's own figure and per-mg price are unchanged", (tester) async {
    await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.text(note)), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('6 in stock (as of last sync)')), findsOneWidget);
    await tester.tap(find.text('Price per mg'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Price per mg (TPE)'), '0.10');
    await tester.pump();
    expect(find.textContaining('= \$0.80 each (8 mg TPE/unit)'), findsOneWidget);
  });

  testWidgets('the cart line keeps one line by the product figure, and carries the note', (tester) async {
    await open(tester);
    await addLine(tester, pkpr: 'ab12c', qty: '6', price: '10.00');
    expect(find.textContaining('6 x \$10.00 · 8mg TPE each'), findsOneWidget);
    expect(find.text(note), findsOneWidget);
    // the TPE: by the product's first lot (6 x 8); the psilocybin and the 50 mg cap count the lots
    // the sale draws, each its own figure: 4 x 5 x 1.0 from lot 101, then 2 x 5 x 1.2 from the state-only lot 102 (the
    // first-lot figure said 30.0)
    expect(find.text('48.0 mg TPE · 32.0 mg psilocybin in the cart'), findsOneWidget);
    expect(find.textContaining('This sale would total'), findsNothing);
  });

  // Lab lot first: with no
  // expiry known for the lab lot, the lab lot still comes before the smaller state-only lot and gives the product its
  // figure (not "6mg TPE", $0.60 at $0.10/mg, 6 x 6.0 = 36.0 mg psilocybin from the state-only lot).
  testWidgets('lab lot first: an undated lab lot still gives the product its figure, price and dose', (tester) async {
    final undated = [
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 1.0,
          strain: 'Golden Teacher', tpeMg: 8, quantity: 4),
      stock[1],
    ];
    await tester.pumpWidget(cartPage(fetchPackages: (id) async => undated));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Price per mg'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Price per mg (TPE)'), '0.10');
    await tester.pump();
    expect(find.textContaining('= \$0.80 each (8 mg TPE/unit)'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
    await tester.pumpAndSettle();
    await addLine(tester, pkpr: 'ab12c', qty: '6', price: '10.00');
    expect(find.textContaining('6 x \$10.00 · 8mg TPE each'), findsOneWidget);
    // The psilocybin counts the lots drawn, the lab lot's 4 units then the state-only lot's 2 (20 + 12)
    expect(find.text('48.0 mg TPE · 32.0 mg psilocybin in the cart'), findsOneWidget);
  });

  testWidgets('a product with no state-only lot has no note', (tester) async {
    await open(tester);
    await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '10.00');
    expect(find.textContaining('known only by the state'), findsNothing);
  });
}
