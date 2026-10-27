// SL-R13: askSignInValue, the dialog the sign-in page shows when a sign-in spec's `await_input` step needs a value from
// the worker (an MFA code, say). Continue (or the keyboard's "done") answers the text typed, trimmed, and does nothing
// while that is empty; Cancel, a tap outside the dialog or the back button answer null, which the flow runner turns
// into reason `cancelled`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/sign_in_prompt.dart';

/// What askSignInValue answered, once it has.
class _Answer {
  bool done = false;
  String? value;
}

/// Opens the dialog from a button on a plain page and returns where its answer will land.
Future<_Answer> _open(WidgetTester tester,
    {String prompt = 'Enter the most recent code the state sent you', bool secret = true}) async {
  final answer = _Answer();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              answer.value = await askSignInValue(context, prompt, secret: secret);
              answer.done = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await _settle(tester);
  return answer;
}

/// Lets a dialog's open or close transition finish (explicit pumps: the dialog's field is focused).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder get _field => find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

void main() {
  testWidgets('shows the prompt and answers the text typed on Continue', (tester) async {
    final answer = await _open(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Enter the most recent code the state sent you'), findsOneWidget);

    await tester.enterText(_field, '123456');
    await tester.pump(); // let Continue see the text
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await _settle(tester);

    expect(answer.done, isTrue);
    expect(answer.value, '123456');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets("the keyboard's done answers the text typed", (tester) async {
    final answer = await _open(tester);
    await tester.enterText(_field, '42');
    await tester.pump(); // let Continue see the text
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);

    expect(answer.done, isTrue);
    expect(answer.value, '42');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Cancel answers null, whatever was typed', (tester) async {
    final answer = await _open(tester);
    await tester.enterText(_field, '123456');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await _settle(tester);

    expect(answer.done, isTrue);
    expect(answer.value, isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a tap outside the dialog answers null, like Cancel', (tester) async {
    final answer = await _open(tester);
    await tester.enterText(_field, '123456');
    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);

    expect(answer.done, isTrue);
    expect(answer.value, isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a secret answer is obscured and not autocorrected; the field has focus', (tester) async {
    await _open(tester, secret: true);
    final field = tester.widget<TextField>(_field);
    expect(field.obscureText, isTrue);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.autofocus, isTrue);
    expect(field.textInputAction, TextInputAction.done);
    expect(field.keyboardType, isNot(TextInputType.number)); // a code isn't assumed to be digits
  });

  testWidgets('an answer that is not secret is shown as typed', (tester) async {
    await _open(tester, prompt: 'Which office?', secret: false);
    expect(find.text('Which office?'), findsOneWidget);
    expect(tester.widget<TextField>(_field).obscureText, isFalse);
  });

  // Final review Important 1: an empty Continue used to cancel the sign-in (and, on the SL-D11 retry, cost two more
  // password posts and two more codes); a pasted code's stray space or line break reached the state as part of it.
  testWidgets('Continue is disabled while nothing but spaces has been typed', (tester) async {
    final answer = await _open(tester);
    FilledButton continueButton() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));
    expect(continueButton().onPressed, isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Continue'), warnIfMissed: false);
    await _settle(tester);
    expect(answer.done, isFalse);
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(_field, '   ');
    await tester.pump();
    expect(continueButton().onPressed, isNull);

    await tester.enterText(_field, '1');
    await tester.pump();
    expect(continueButton().onPressed, isNotNull);

    await tester.enterText(_field, '');
    await tester.pump();
    expect(continueButton().onPressed, isNull);
  });

  testWidgets("the keyboard's done does nothing while the field is empty or only spaces", (tester) async {
    final answer = await _open(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(answer.done, isFalse);
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(_field, '  ');
    await tester.pump(); // let Continue see the text
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(answer.done, isFalse);
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(_field, '7');
    await tester.pump(); // let Continue see the text
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(answer.value, '7');
  });

  testWidgets('Continue answers the text without leading or trailing spaces', (tester) async {
    final answer = await _open(tester);
    await tester.enterText(_field, '  123456 ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await _settle(tester);

    expect(answer.value, '123456');
  });

  testWidgets("the keyboard's done answers the trimmed text too", (tester) async {
    final answer = await _open(tester);
    await tester.enterText(_field, ' 42  ');
    await tester.pump(); // let Continue see the text
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);

    expect(answer.value, '42');
  });

  testWidgets('the field offers one-time-code autofill', (tester) async {
    await _open(tester);
    expect(tester.widget<TextField>(_field).autofillHints, [AutofillHints.oneTimeCode]);
  });

  testWidgets('the dialog scrolls, so a long prompt fits a small phone', (tester) async {
    tester.view.physicalSize = const Size(320, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _open(tester, prompt: List.filled(80, 'Enter the most recent code the state sent you.').join(' '));

    expect(tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable, isTrue);
    expect(tester.takeException(), isNull); // no overflow
    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
  });

  testWidgets('Continue pressed twice closes only the dialog', (tester) async {
    final answer = await _open(tester);
    await tester.enterText(_field, '123456');
    await tester.pump(); // let Continue see the text
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'), warnIfMissed: false);
    await _settle(tester);

    expect(answer.value, '123456');
    expect(find.text('open'), findsOneWidget); // the page underneath is still there
    expect(tester.takeException(), isNull);
  });
}
