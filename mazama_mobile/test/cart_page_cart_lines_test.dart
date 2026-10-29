import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/cart_slots.dart';
import 'package:mazama_mobile/label_client.dart';
import 'package:mazama_mobile/phone_label.dart';
import 'package:mazama_mobile/session_timer_store.dart';

import 'cart_page_test_support.dart';

void main() {
  // rootBundle.loadString caches its Future by asset key for the lifetime of the whole test *process*, not
  // per-test (see widget_test.dart's own note on this). CartPage's constructor loads assets/flows/sale.yaml
  // via rootBundle whenever a test doesn't pass saleSpec: explicitly, which is most tests in this file - without
  // clearing it, a later test can get an earlier test's already-created Future, straddling two different
  // testWidgets async zones. That doesn't throw - it just leaves that test's pumpAndSettle waiting on a Future
  // that never resolves in its own zone, hanging for the full default test timeout (10 minutes) instead of
  // failing fast. Only a few tests happened to lose this race on any given run, never a reliable repro.
  tearDown(() => rootBundle.clear());

  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  group('cart session timer', () {
    testWidgets('the home-screen widget is sent the running timer, counting down to the dose\'s session end, then nothing after Reset',
        (tester) async {
      final fakeNow = DateTime.now();
      final timers = RecordingTimerWidget();
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => fakeNow, cartTimerWidget: timers));
      await tester.pumpAndSettle();
      expect(timers.lastCarts, isEmpty);
      expect(timers.snapshots.last['center'], 'Bendable Service Center');

      // 2 x 5.0 g x 4.5 mg/g = 45 mg psilocybin: a 6 hour session (sessionTable).
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');
      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      await tester.pump();
      expect(timers.lastCarts, [
        {
          'id': defaultCartId,
          'name': 'Cart 1',
          'startMs': fakeNow.millisecondsSinceEpoch,
          'endMs': fakeNow.add(const Duration(hours: 6)).millisecondsSinceEpoch,
          'booster': false,
        }
      ]);

      await tester.tap(find.text('Reset'));
      await tester.pump();
      await tester.pump();
      expect(timers.lastCarts, isEmpty);
    });

    testWidgets('starts at "Start Timer", switches to a counting-up elapsed display once tapped', (tester) async {
      var fakeNow = DateTime.now();
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => fakeNow));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      expect(find.text('Start Timer'), findsOneWidget);
      expect(find.textContaining('Elapsed:'), findsNothing);

      await tester.tap(find.text('Start Timer'));
      await tester.pump();

      expect(find.text('Start Timer'), findsNothing);
      expect(find.text('Elapsed: 00:00'), findsOneWidget);

      // The on-page ticker redraws once a second against widget.now() (never the real wall clock) - advancing
      // the fake clock and then pumping one tick is enough to see the new elapsed figure, regardless of how
      // many real ticker callbacks fired in between.
      fakeNow = fakeNow.add(const Duration(minutes: 1, seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 01:30'), findsOneWidget);

      fakeNow = fakeNow.add(const Duration(hours: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 1:01:30'), findsOneWidget);

      // Reset before the test ends, so the periodic ticker is cancelled rather than left pending.
      await tester.tap(find.text('Reset'));
      await tester.pump();
    });

    testWidgets('Reset clears the timer back to the Start Timer button', (tester) async {
      var fakeNow = DateTime.now();
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => fakeNow));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      fakeNow = fakeNow.add(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 05:00'), findsOneWidget);

      await tester.tap(find.text('Reset'));
      await tester.pump();

      expect(find.text('Start Timer'), findsOneWidget);
      expect(find.textContaining('Elapsed:'), findsNothing);
    });

    testWidgets('a running timer survives a simulated app restart (same sessionTimerStore)', (tester) async {
      var fakeNow = DateTime.now();
      final store = SessionTimerStore(dataDir: () => tempDir);
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => fakeNow, sessionTimerStore: store));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.text('Start Timer'));
      await tester.pump();
      fakeNow = fakeNow.add(const Duration(minutes: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Elapsed: 03:00'), findsOneWidget);

      // Simulate the app being force-closed and reopened: a brand new CartPage/State reading from the same
      // sessionTimerStore (and the same tempDir the cart itself restores from) - the same scenario the
      // existing "restores a draft cart across restart" tests already simulate this same way, with another
      // 2 minutes having passed on the fake clock while the app was "closed".
      fakeNow = fakeNow.add(const Duration(minutes: 2));
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => fakeNow, sessionTimerStore: store));
      await tester.pumpAndSettle();

      // Picks the original start time back up - the elapsed figure reflects the full 5 minutes since the
      // timer was first started, not a reset back to zero.
      expect(find.text('Elapsed: 05:00'), findsOneWidget);
      expect(find.text('Start Timer'), findsNothing);

      // Reset before the test ends, so the periodic ticker is cancelled rather than left pending.
      await tester.tap(find.text('Reset'));
      await tester.pump();
    });

    testWidgets('the timer resets itself automatically once sessionTimerMaxAge has passed', (tester) async {
      var fakeNow = DateTime.now();
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => fakeNow));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.text('Start Timer'));
      await tester.pump();

      // A worker who starts a session and simply never comes back to reset it (the client's visit runs long,
      // or the "Reset" tap is just forgotten) shouldn't see the stopwatch keep counting into the next day -
      // once sessionTimerMaxAge has passed, the next tick resets it back to "Start Timer" on its own, with
      // nothing left for the test to clean up (the periodic ticker cancels itself as part of that reset).
      fakeNow = fakeNow.add(sessionTimerMaxAge);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Start Timer'), findsOneWidget);
      expect(find.textContaining('Elapsed:'), findsNothing);
    });

    testWidgets('a persisted timer older than sessionTimerMaxAge is not restored on reopen, and is cleared', (tester) async {
      final fakeNow = DateTime.now();
      final store = SessionTimerStore(dataDir: () => tempDir);
      // A worker started a session, then the app was force-closed for well over sessionTimerMaxAge (an
      // overnight shutdown, say) - by the time it's reopened, resuming the stopwatch from that stale start
      // time would show a nonsensical elapsed figure, so this is treated the same as a timer that already
      // aged out while the app stayed open: not resumed, and cleared from disk.
      await store.save(231, fakeNow.subtract(sessionTimerMaxAge + const Duration(minutes: 1)));

      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory, now: () => fakeNow, sessionTimerStore: store));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      expect(find.text('Start Timer'), findsOneWidget);
      expect(find.textContaining('Elapsed:'), findsNothing);
      expect(await store.load(231), isNull);
    });
  });

  group('editing a cart line', () {
    testWidgets('tapping a line reopens the dialog pre-filled, and Save updates it in place', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '2', price: '12.50');

      await tester.tap(find.text('Extract'));
      await tester.pumpAndSettle();

      // Pre-filled from the existing line, not reset to the dialog's own "new line" defaults.
      expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Quantity')).controller!.text, '2');
      expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Price each')).controller!.text, '12.50');
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
      // Scoped to the dialog - the main screen's own 'Add' FilledButton (next to the PKPR field) is still in
      // the tree underneath it, so an unscoped check here would find that one instead.
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Add')),
          findsNothing);

      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '5');
      await tester.enterText(find.widgetWithText(TextFormField, 'Price each'), '20.00');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('5 x \$20.00'), findsOneWidget);
      expect(find.text('\$100.00'), findsWidgets); // the one line now totals $100, same as the cart
      expect(find.textContaining('2 x \$12.50'), findsNothing); // the old figures are gone, not duplicated
    });

    testWidgets('the edit icon opens the same dialog as tapping the line', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    });

    testWidgets('cancelling an edit leaves the line untouched', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.text('Extract'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '99');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 x \$10.00'), findsOneWidget);
      expect(find.textContaining('99'), findsNothing);
    });

    testWidgets('editing does not merge the line into another one with the same price and dose', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      await addLine(tester, pkpr: 'ff99aa', qty: '1', price: '10.00');

      // Edit the second line (ff99aa) to the same price - if this merged the way adding a matching PKPR does,
      // the cart would collapse to one line; it must stay two, since the worker only meant to change this one.
      await tester.tap(find.text('Whole Fungi'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Save')));
      await tester.pumpAndSettle();

      expect(find.text('Extract'), findsOneWidget);
      expect(find.text('Whole Fungi'), findsOneWidget);
    });
  });

  group('label comparison', () {
    testWidgets('shows the fetched label image after a successful add, for this center\'s own state id', (tester) async {
      final bytes = fakeLabelPng;
      int? seenStateId;
      String? seenGuid;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        fetchLabel: (stateId, guid) async {
          seenStateId = stateId;
          seenGuid = guid;
          return bytes;
        },
      ));
      await tester.pumpAndSettle();
      await addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.widgetWithText(AlertDialog, 'Compare label · PKPR-ab12c'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(seenStateId, 231); // this cart's own center id, not anything from the package payload
      expect(seenGuid, 'PKPR-ab12c');

      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('shows a plain message, not a crash, when the server has no label for this package', (tester) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        fetchLabel: (stateId, guid) async => throw LabelError('no label on file for $guid'),
      ));
      await tester.pumpAndSettle();
      await addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.textContaining('No label on file'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('draws the label on the phone when the server has none', (tester) async {
      final drawn = <String>[];
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        fetchLabel: (stateId, guid) async => throw LabelError('no label on file for $guid'),
        drawLabel: (stateId, pkpr, {required accessToken, strain = ''}) async {
          drawn.add('$stateId $pkpr $accessToken $strain');
          return drawnSpec;
        },
      ));
      await tester.pumpAndSettle();
      await addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      // the cart's own center, the package, the worker's state session and the strain the server already knows
      expect(drawn, ['231 PKPR-ab12c TOKEN Golden Teacher']);
      expect(find.text('Drawn on this phone: no label on file at the server'), findsOneWidget);
      expect(find.text('Lot: ab12c'), findsOneWidget);
      expect(find.text('Psilocybin: 22.98 mg'), findsOneWidget);
      expect(find.textContaining('No label on file'), findsNothing);
      expect(find.byType(Image), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Extract')); // the edit dialog shows the same drawing, without reading the report again
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Lot: ab12c')), findsOneWidget);
      expect(drawn, hasLength(1));
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('never draws on the phone when the server has a label', (tester) async {
      var drew = false;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        fetchLabel: (stateId, guid) async => fakeLabelPng,
        drawLabel: (stateId, pkpr, {required accessToken, strain = ''}) async {
          drew = true;
          return drawnSpec;
        },
      ));
      await tester.pumpAndSettle();
      await addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.byType(Image), findsOneWidget);
      expect(drew, isFalse);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
    });

    testWidgets('says why when neither the server nor the phone has a label, and tries the phone again next time', (tester) async {
      var tries = 0;
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        drawLabel: (stateId, pkpr, {required accessToken, strain = ''}) async {
          tries++;
          throw PhoneLabelError('lot HB-aaaa0001 has no accepted lab report on file at the state yet');
        },
      ));
      await tester.pumpAndSettle();
      await addLineLeavingLabelDialogOpen(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.textContaining('No label on file'), findsOneWidget);
      expect(find.textContaining("The phone couldn't draw one: lot HB-aaaa0001 has no accepted lab report on file"), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Extract'));
      await tester.pumpAndSettle();
      expect(tries, 2); // a failed drawing isn't kept
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('editing a line in the cart shows that package\'s label in the edit dialog', (tester) async {
      final seenGuids = <String>[];
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        fetchLabel: (stateId, guid) async {
          seenGuids.add(guid);
          return fakeLabelPng;
        },
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');
      seenGuids.clear(); // only count what the edit dialog fetches

      await tester.tap(find.text('Extract')); // reopens the line in the edit dialog
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Image)), findsOneWidget);
      // Typing in the dialog rebuilds it; the label must not be fetched again for each keystroke.
      await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
      await tester.pumpAndSettle();
      expect(seenGuids, ['PKPR-ab12c']);

      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('the edit dialog shows a plain message when the package has no label', (tester) async {
      await tester.pumpWidget(cartPage(fetchPackages: (id) async => inventory)); // default fetchLabel throws
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      await tester.tap(find.text('Extract'));
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('No label on file')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget); // the rest of the dialog still works

      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('the add dialog does not show the label (the compare popup after the add does)', (tester) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        fetchLabel: (stateId, guid) async => fakeLabelPng,
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'PKPR'), 'ab12c');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Image)), findsNothing);

      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('closing it does not affect the line that was already added to the cart', (tester) async {
      await tester.pumpWidget(cartPage(
        fetchPackages: (id) async => inventory,
        fetchLabel: (stateId, guid) async => fakeLabelPng,
      ));
      await tester.pumpAndSettle();
      await addLine(tester, pkpr: 'ab12c', qty: '1', price: '10.00');

      expect(find.text('Nothing in the cart yet.'), findsNothing);
      expect(find.text('Extract'), findsOneWidget);
    });
  });
}
