// MI-D6..D10, MI-R6 (specs/mazama-inventory): the order form the Mazama inventory page opens and its review page.
// Built from the center's par levels (a strain with a par level and no stock included), each line at its full par,
// freeze dried / dehydrated / homogenized per line with an "All lines" setter; reviewed with notes, Back to edit
// keeping everything, then sent by Submit order through the injected submit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/order_client.dart';
import 'package:mazama_mobile/order_form_page.dart';
import 'package:mazama_mobile/order_review_page.dart';
import 'package:mazama_mobile/stock_summary.dart';

final _center = License(id: 225, licenseId: 'SC-unstuck', licenseName: 'Unstuck', licenseType: 'ServiceCenter');

// Out of order on purpose; Enigma is a strain added in the par editor with no stock; Huautla's par is 0; the null par
// and the size 7 are not levels the form can use.
const _par = [
  ParLevel(strain: 'Golden Teacher', size: 5, par: 4),
  ParLevel(strain: 'Golden Teacher', size: 25, par: 12),
  ParLevel(strain: 'Enigma', size: 0, par: 3),
  ParLevel(strain: 'Huautla', size: 10, par: 0),
  ParLevel(strain: 'Bluey', size: 25, par: null),
  ParLevel(strain: 'Bluey', size: 7, par: 9),
];

/// A tall screen, so every line of the form is built (the list builds only what is on screen).
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _form({
  Future<List<ParLevel>> Function()? loadPar,
  Future<OrderReceipt> Function(List<OrderLine>, String)? submit,
}) =>
    MaterialApp(
      home: OrderFormPage(
        center: _center,
        loadPar: loadPar ?? () async => _par,
        submit: submit ?? (lines, note) async => OrderReceipt(id: 42, center: 'unstuck', lines: lines, note: note),
      ),
    );

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

String _qty(WidgetTester tester, String key) => tester.widget<TextField>(find.byKey(ValueKey('qty-$key'))).controller!.text;

Finder _type(String key, String word) =>
    find.descendant(of: find.byKey(ValueKey('type-$key')), matching: find.text(word));

FilledButton _send(WidgetTester tester) => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Review order'));

Future<void> _openReview(WidgetTester tester) => _tap(tester, find.widgetWithText(FilledButton, 'Review order'));

void main() {
  testWidgets('one line per par level, in the par table order, each at its full par', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_form());
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Order from Mazama'), findsOneWidget);
    final lines = [
      for (final p in tester.widgetList<Padding>(find.byWidgetPredicate((w) => w is Padding && w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('line-'))))
        (p.key as ValueKey<String>).value,
    ];
    expect(lines, ['line-Enigma|0', 'line-Golden Teacher|25', 'line-Golden Teacher|5', 'line-Huautla|10']);
    expect(_qty(tester, 'Golden Teacher|25'), '12');
    expect(_qty(tester, 'Enigma|0'), '3'); // a strain added in the par editor, no stock: still ordered
    expect(_qty(tester, 'Huautla|10'), '0'); // par 0 starts at 0, so it is left out
    expect(find.text('Enigma · Other size'), findsOneWidget);
    expect(find.text('3 lines · 19 units'), findsOneWidget);
  });

  testWidgets('Send waits for a type on every ordered line; All lines sets them all', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_form());
    await tester.pumpAndSettle();
    expect(_send(tester).onPressed, isNull);
    expect(find.text('Choose freeze dried, dehydrated or homogenized for every line you order.'), findsOneWidget);

    await _tap(tester, _type('Golden Teacher|25', 'Freeze dried'));
    expect(_send(tester).onPressed, isNull); // two more lines to go

    await _tap(tester, _type('all', 'Homogenized'));
    expect(_send(tester).onPressed, isNotNull);
    await _tap(tester, _type('Golden Teacher|25', 'Dehydrated')); // a line can still differ
    expect(_send(tester).onPressed, isNotNull);
    expect(find.textContaining('Choose freeze dried'), findsNothing);
  });

  testWidgets('quantities can be changed, and 0 leaves a line out', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_form());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('qty-Golden Teacher|5')), '0');
    await tester.enterText(find.byKey(const ValueKey('qty-Golden Teacher|25')), '20');
    await tester.pumpAndSettle();
    expect(find.text('2 lines · 23 units'), findsOneWidget);
    await _tap(tester, _type('Enigma|0', 'Dehydrated'));
    await _tap(tester, _type('Golden Teacher|25', 'Freeze dried'));
    expect(_send(tester).onPressed, isNotNull); // the line left out needs no type
  });

  testWidgets('Review order shows the order with notes; Back to edit keeps everything; Submit order sends it',
      (tester) async {
    _tall(tester);
    final sent = <(List<OrderLine>, String)>[];
    await tester.pumpWidget(_form(submit: (lines, note) async {
      sent.add((lines, note));
      return OrderReceipt(id: 42, center: 'unstuck', lines: lines, note: note);
    }));
    await tester.pumpAndSettle();
    await _tap(tester, _type('all', 'Freeze dried'));
    await _tap(tester, _type('Enigma|0', 'Homogenized'));

    await _openReview(tester);
    expect(find.widgetWithText(AppBar, 'Review order'), findsOneWidget);
    expect(find.text('To Mazama from Unstuck'), findsOneWidget);
    expect(find.text('3 lines, 19 units'), findsOneWidget);
    expect(find.text('12 × Golden Teacher 25 mg, Freeze dried'), findsOneWidget);
    expect(find.text('3 × Enigma Other size, Homogenized'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('order-notes')), 'Freeze dried first, please.');

    // Back to edit: the form as it was; nothing sent.
    await _tap(tester, find.widgetWithText(OutlinedButton, 'Back to edit'));
    expect(find.widgetWithText(AppBar, 'Order from Mazama'), findsOneWidget);
    expect(_qty(tester, 'Golden Teacher|25'), '12');
    expect(sent, isEmpty);
    await tester.enterText(find.byKey(const ValueKey('qty-Golden Teacher|25')), '20');
    await tester.pumpAndSettle();

    // The review again: the new quantity, the notes kept.
    await _openReview(tester);
    expect(find.text('20 × Golden Teacher 25 mg, Freeze dried'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('order-notes'))).controller!.text, 'Freeze dried first, please.');

    await _tap(tester, find.widgetWithText(FilledButton, 'Submit order'));
    expect(sent, hasLength(1));
    expect([for (final l in sent.single.$1) l.toJson()], [
      {'strain': 'Enigma', 'size': 0, 'type': 'HG', 'quantity': 3},
      {'strain': 'Golden Teacher', 'size': 25, 'type': 'FD', 'quantity': 20},
      {'strain': 'Golden Teacher', 'size': 5, 'type': 'FD', 'quantity': 4},
    ]);
    expect(sent.single.$2, 'Freeze dried first, please.');
    expect(find.text('Order 42 sent to Mazama'), findsOneWidget);
    expect(find.text('Notes: Freeze dried first, please.'), findsOneWidget);
  });

  testWidgets('the back gesture on the review page is Back to edit, notes kept', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_form());
    await tester.pumpAndSettle();
    await _tap(tester, _type('all', 'Dehydrated'));
    await _openReview(tester);
    await tester.enterText(find.byKey(const ValueKey('order-notes')), 'Call before delivery.');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Order from Mazama'), findsOneWidget);
    await _openReview(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('order-notes'))).controller!.text, 'Call before delivery.');
  });

  testWidgets('a refusal keeps the review page as it was, with the reason', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_form(submit: (lines, note) async => throw OrderError('cannot reach sales.mazamamushrooms.com: SocketException')));
    await tester.pumpAndSettle();
    await _tap(tester, _type('all', 'Dehydrated'));
    await _openReview(tester);
    await tester.enterText(find.byKey(const ValueKey('order-notes')), 'Thanks!');
    await _tap(tester, find.widgetWithText(FilledButton, 'Submit order'));
    expect(find.textContaining('The order was not sent: cannot reach'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Review order'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('order-notes'))).controller!.text, 'Thanks!');
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Submit order')).onPressed, isNotNull);
  });

  testWidgets('an order that cannot reach the server says to try again later, never queues, and keeps the notes',
      (tester) async {
    _tall(tester);
    var calls = 0;
    await tester.pumpWidget(_form(submit: (lines, note) async {
      calls++;
      throw OrderError('cannot reach sales.mazamamushrooms.com: SocketException', unreachable: true);
    }));
    await tester.pumpAndSettle();
    await _tap(tester, _type('all', 'Dehydrated'));
    await _openReview(tester);
    await tester.enterText(find.byKey(const ValueKey('order-notes')), 'Thanks!');
    await _tap(tester, find.widgetWithText(FilledButton, 'Submit order'));

    expect(find.text("The order was not sent: Mazama's server can't be reached - try again later."), findsOneWidget);
    expect(calls, 1);
    expect(find.widgetWithText(AppBar, 'Review order'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('order-notes'))).controller!.text, 'Thanks!');
    // Back to edit keeps the lines and the notes, so nothing typed is lost.
    await _tap(tester, find.widgetWithText(OutlinedButton, 'Back to edit'));
    expect(_qty(tester, 'Golden Teacher|25'), '12');
    await _openReview(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('order-notes'))).controller!.text, 'Thanks!');
    await _tap(tester, find.widgetWithText(FilledButton, 'Submit order'));
    expect(calls, 2); // tried again by the worker, not by the phone
  });

  testWidgets("an order the server refuses (4xx) shows the server's own message", (tester) async {
    _tall(tester);
    await tester.pumpWidget(_form(submit: (lines, note) async => throw OrderError('The order has no lines.')));
    await tester.pumpAndSettle();
    await _tap(tester, _type('all', 'Dehydrated'));
    await _openReview(tester);
    await _tap(tester, find.widgetWithText(FilledButton, 'Submit order'));
    expect(find.text('The order was not sent: The order has no lines.'), findsOneWidget);
  });

  test('the review page writes each line as the form does', () {
    expect(orderLineText(const OrderLine(strain: 'Bluey', size: 15, type: 'DH', quantity: 2)), '2 × Bluey 15 mg, Dehydrated');
    // specs/edibles ED-A6: an edible product is its own kind
    expect(orderLineText(const OrderLine(strain: 'Chocolate', size: -1, type: 'CH', quantity: 20)), '20 × Chocolate Booster');
    expect(orderLineText(const OrderLine(strain: 'Gummy', size: -2, type: 'GM', quantity: 4)), '4 × Gummy Microdose');
  });

  testWidgets('edibles sit below the strains, one row each with Booster and Microdose, and All lines leaves them alone',
      (tester) async {
    _tall(tester);
    List<OrderLine>? sent;
    await tester.pumpWidget(_form(
      loadPar: () async => const [
        ParLevel(strain: 'chocolate', size: -1, par: 6),
        ParLevel(strain: 'Gummy', size: -2, par: 2),
        ParLevel(strain: 'Chocolate', size: 25, par: 9), // a size a product doesn't take: not a line
        ParLevel(strain: 'Bluey', size: -1, par: 9), //     nor a strain's Booster
        ParLevel(strain: 'Bluey', size: 5, par: 3),
        ParLevel(strain: 'Honey', size: 0, par: 5), //       an edible's Other: no longer in the par table, not a line
      ],
      submit: (lines, note) async {
        sent = lines;
        return OrderReceipt(id: 7, center: 'unstuck', lines: lines, note: note);
      },
    ));
    await tester.pumpAndSettle();
    // MI-D17: one row per product, both fields each, at its par or 0; below every strain line
    expect([_qty(tester, 'Chocolate|-1'), _qty(tester, 'Chocolate|-2'), _qty(tester, 'Gummy|-1'), _qty(tester, 'Gummy|-2')],
        ['6', '0', '0', '2']);
    expect(find.byKey(const ValueKey('edible-Honey')), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('edible-Chocolate'))).dy,
        greaterThan(tester.getTopLeft(find.byKey(const ValueKey('line-Bluey|5'))).dy));
    expect(find.byKey(const ValueKey('line-Chocolate|-1')), findsNothing); // no line (or column) of its own
    expect(find.byKey(const ValueKey('type-Chocolate|-1')), findsNothing); // no freeze dried / dehydrated / homogenized
    expect(find.byKey(const ValueKey('type-Bluey|5')), findsOneWidget);
    expect(_send(tester).onPressed, isNull); //                             Bluey still needs its kind
    await _tap(tester, find.descendant(of: find.byKey(const ValueKey('type-all')), matching: find.text('Dehydrated')));
    expect(_send(tester).onPressed, isNotNull);
    await _openReview(tester);
    expect(find.text('6 × Chocolate Booster'), findsOneWidget);
    await _tap(tester, find.widgetWithText(FilledButton, 'Submit order'));
    expect([for (final l in sent!) '${l.strain}|${l.size}|${l.type}|${l.quantity}'],
        ['Bluey|5|DH|3', 'Chocolate|-1|CH|6', 'Gummy|-2|GM|2']);
  });

  testWidgets('no par levels says where to set them', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_form(loadPar: () async => const []));
    await tester.pumpAndSettle();
    expect(find.textContaining('no par levels yet'), findsOneWidget);
  });

  testWidgets('par levels that did not load say so, and Retry loads them', (tester) async {
    var calls = 0;
    _tall(tester);
    await tester.pumpWidget(_form(loadPar: () async {
      calls++;
      if (calls == 1) throw Exception('offline');
      return _par;
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('Par levels did not load'), findsOneWidget);
    await _tap(tester, find.widgetWithText(FilledButton, 'Retry'));
    expect(find.text('3 lines · 19 units'), findsOneWidget);
  });

  testWidgets('a par for all strains combined is ordered as any strain, after the strains', (tester) async {
    _tall(tester);
    List<OrderLine>? sent;
    await tester.pumpWidget(_form(
      loadPar: () async => const [
        ParLevel(strain: 'All strains', size: 10, par: 30),
        ParLevel(strain: 'Bluey', size: 5, par: 3),
        ParLevel(strain: 'all  strains', size: 25, par: 8), // any spelling of the combined row
        ParLevel(strain: 'Chocolate', size: -1, par: 2),
      ],
      submit: (lines, note) async {
        sent = lines;
        return OrderReceipt(id: 8, center: 'unstuck', lines: lines, note: note);
      },
    ));
    await tester.pumpAndSettle();
    final lines = [
      for (final p in tester.widgetList<Padding>(find.byWidgetPredicate((w) => w is Padding && w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('line-'))))
        (p.key as ValueKey<String>).value,
    ];
    expect(lines, ['line-Bluey|5', 'line-All strains|25', 'line-All strains|10']);
    expect(find.text('All strains (any strain) · 25 mg'), findsOneWidget);
    await _tap(tester, _type('all', 'Freeze dried'));
    await _openReview(tester);
    await _tap(tester, find.widgetWithText(FilledButton, 'Submit order'));
    expect([for (final l in sent!) '${l.strain}|${l.size}|${l.type}|${l.quantity}'],
        ['Bluey|5|FD|3', 'All strains|25|FD|8', 'All strains|10|FD|30', 'Chocolate|-1|CH|2']);
  });

  testWidgets('the form reads the par levels again every time it opens', (tester) async {
    _tall(tester);
    var par = const [ParLevel(strain: 'Bluey', size: 5, par: 3)];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => FilledButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => OrderFormPage(
              center: _center,
              loadPar: () async => par,
              submit: (lines, note) async => OrderReceipt(id: 1, center: 'unstuck', lines: lines, note: note),
            ),
          )),
          child: const Text('Order from Mazama'),
        ),
      ),
    ));
    await _tap(tester, find.text('Order from Mazama'));
    expect(_qty(tester, 'Bluey|5'), '3');
    await tester.pageBack();
    await tester.pumpAndSettle();
    par = const [ParLevel(strain: 'Bluey', size: 5, par: 11)]; // changed on the stock page meanwhile
    await _tap(tester, find.text('Order from Mazama'));
    expect(_qty(tester, 'Bluey|5'), '11');
  });
}
