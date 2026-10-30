// specs/phone-sync PS-R5 (owner, 2026-10-30): a product with a lot only the state lists (no lab report on Mazama's
// server) stays one line, shown, priced and capped by its first lot's figure exactly as before; the line and its
// dialog add a note saying how many of its units only the state knows and their own figure, in mg psilocybin.
// Invented fixtures (this folder is published).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/packages_client.dart';

import 'cart_page_test_support.dart';

void main() {
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_state_only_lot_test_'));
  tearDown(() {
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
    // the dose summary and the 50 mg cap: by the product's first lot, as before (6 x 8 TPE, 6 x 5 x 1.0 psilocybin)
    expect(find.text('48.0 mg TPE · 30.0 mg psilocybin in the cart'), findsOneWidget);
    expect(find.textContaining('This sale would total'), findsNothing);
  });

  testWidgets('a product with no state-only lot has no note', (tester) async {
    await open(tester);
    await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '10.00');
    expect(find.textContaining('known only by the state'), findsNothing);
  });
}
