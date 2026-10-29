// MI-R3 (specs/mazama-inventory): the Mazama inventory page - total mg TPE By strain and By type, one pie at a time
// (MI-D3), a tap for a strain's types or a type's strains (MI-D4), no pull to refresh (MI-D5). The numbers are
// stock_mix.dart's, held to the shared vectors in stock_mix_test.dart; here, what the page shows of them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/mazama_contact.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/mazama_inventory_page.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_offline.dart';
import 'package:mazama_mobile/mazama_lot_table.dart';
import 'package:mazama_mobile/stock_mix.dart';
import 'package:mazama_mobile/stock_pie.dart';

import 'fake_timers.dart';

// Golden Teacher 4,000 (Dehydrated 3,000, Process lot 1,000), Penis Envy 2,000 (Whole fungi 1,500, Dehydrated 500).
const _mix = MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [
  MixCell(strain: 'Golden Teacher', type: 'DH', mg: 3000),
  MixCell(strain: 'Golden Teacher', type: 'LOT', mg: 1000),
  MixCell(strain: 'Penis Envy', type: 'WF', mg: 1500),
  MixCell(strain: 'Penis Envy', type: 'DH', mg: 500),
]);

Widget _page({Future<MazamaInventory> Function()? load}) =>
    MaterialApp(home: MazamaInventoryPage(load: load ?? () async => _mix));

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

Future<void> _swipe(WidgetTester tester, {bool towardsType = true}) async {
  await tester.drag(find.byKey(const ValueKey('mix-pies')), Offset(towardsType ? -300 : 300, 0));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows a spinner, then the total and the By strain pie, as the server writes them', (tester) async {
    await tester.pumpWidget(_page());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();

    // No title bar of its own: the home's "Mazama" tab label is its title (owner, 2026-10-22).
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Mazama inventory'), findsNothing);
    // No manufacturer name and no explanation line above the total (owner, 2026-10-22).
    expect(find.text('Mazama Mushrooms LLC'), findsNothing);
    expect(find.textContaining('Harvest batches'), findsNothing);
    expect(find.text('6,000 mg TPE in all'), findsOneWidget);
    expect(find.text('By strain'), findsOneWidget);
    expect(find.text('By type'), findsNothing); // one pie at a time
    expect(find.byType(StockPie), findsOneWidget);
    expect(_keyText(tester, 'strain-key-Golden Teacher'), 'Golden Teacher 4,000 mg · 67%');
    expect(_keyText(tester, 'strain-key-Penis Envy'), 'Penis Envy 2,000 mg · 33%');
  });

  testWidgets('a swipe or the dots show By type, and back', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await _swipe(tester, towardsType: false); // already on the first: stays
    expect(find.text('By strain'), findsOneWidget);
    await _swipe(tester);
    expect(find.text('By type'), findsOneWidget);
    expect(find.text('By strain'), findsNothing);
    expect(_keyText(tester, 'type-key-Dehydrated'), 'Dehydrated 3,500 mg · 58%');
    expect(_keyText(tester, 'type-key-Whole fungi'), 'Whole fungi 1,500 mg · 25%');
    expect(_keyText(tester, 'type-key-Process lot'), 'Process lot 1,000 mg · 17%');
    await _swipe(tester); // already on the last: stays
    expect(find.text('By type'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('mix-pie-dot-strain')));
    expect(find.text('By strain'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('mix-pie-dot-type')));
    expect(find.text('By type'), findsOneWidget);
  });

  testWidgets('tapping a strain shows its types; again, or Close, hides them', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await _tap(tester, find.byKey(const ValueKey('strain-key-Golden Teacher')));
    expect(find.text('Golden Teacher by type · 4,000 mg TPE'), findsOneWidget);
    expect(_keyText(tester, 'mix-card-key-Golden Teacher-Dehydrated'), 'Dehydrated 3,000 mg · 75%');
    expect(_keyText(tester, 'mix-card-key-Golden Teacher-Process lot'), 'Process lot 1,000 mg · 25%');
    expect(find.byType(StockPie), findsNWidgets(2));

    await _tap(tester, find.byKey(const ValueKey('strain-key-Golden Teacher')));
    expect(find.byKey(const ValueKey('mix-card-Golden Teacher')), findsNothing);

    await _tap(tester, find.byKey(const ValueKey('strain-key-Penis Envy')));
    expect(find.text('Penis Envy by type · 2,000 mg TPE'), findsOneWidget);
    await _tap(tester, find.byTooltip('Close'));
    expect(find.byKey(const ValueKey('mix-card-Penis Envy')), findsNothing);
  });

  testWidgets('tapping a type shows its strains', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await _swipe(tester);
    await _tap(tester, find.byKey(const ValueKey('type-key-Dehydrated')));
    expect(find.text('Dehydrated by strain · 3,500 mg TPE'), findsOneWidget);
    expect(_keyText(tester, 'mix-card-key-Dehydrated-Golden Teacher'), 'Golden Teacher 3,000 mg · 86%');
    expect(_keyText(tester, 'mix-card-key-Dehydrated-Penis Envy'), 'Penis Envy 500 mg · 14%');
  });

  testWidgets('an open breakdown stays open across a switch between the pies, and a closed one stays closed',
      (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('strain-key-Penis Envy')));

    await _swipe(tester);
    expect(find.text('By type'), findsOneWidget);
    expect(find.text('Penis Envy by type · 2,000 mg TPE'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('mix-pie-dot-strain')));
    expect(find.text('Penis Envy by type · 2,000 mg TPE'), findsOneWidget);

    // Picking on the other pie replaces it: one breakdown at a time.
    await _swipe(tester);
    await _tap(tester, find.byKey(const ValueKey('type-key-Dehydrated')));
    expect(find.byKey(const ValueKey('mix-card-Penis Envy')), findsNothing);
    expect(find.text('Dehydrated by strain · 3,500 mg TPE'), findsOneWidget);
    await _swipe(tester, towardsType: false);
    expect(find.text('Dehydrated by strain · 3,500 mg TPE'), findsOneWidget);

    await _tap(tester, find.byTooltip('Close'));
    expect(find.byKey(const ValueKey('mix-card-Dehydrated')), findsNothing);
    await _swipe(tester);
    expect(find.byKey(const ValueKey('mix-card-Dehydrated')), findsNothing);
    await _swipe(tester, towardsType: false);
    expect(find.byKey(const ValueKey('mix-card-Dehydrated')), findsNothing);
  });

  testWidgets('nothing with mg says so', (tester) async {
    await tester.pumpWidget(_page(load: () async => const MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [])));
    await tester.pumpAndSettle();
    expect(find.text('Nothing in stock.'), findsOneWidget);
    expect(find.byType(StockPie), findsNothing);
  });

  testWidgets('a failed load says so and Retry loads again', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_page(load: () async {
      calls++;
      if (calls == 1) throw MazamaInventoryError('cannot reach sales.mazamamushrooms.com: SocketException');
      return _mix;
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mazama inventory did not load: cannot reach'), findsOneWidget);

    await _tap(tester, find.widgetWithText(FilledButton, 'Retry'));
    expect(calls, 2);
    expect(find.text('6,000 mg TPE in all'), findsOneWidget);
  });

  testWidgets('MI-D5: no pull to refresh', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_page(load: () async {
      calls++;
      return _mix;
    }));
    await tester.pumpAndSettle();
    expect(find.byType(RefreshIndicator), findsNothing);
    await tester.fling(find.text('6,000 mg TPE in all'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('MI-D6: Order opens the order form; without one there is no button', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('order-button')), findsNothing);

    await tester.pumpWidget(MaterialApp(
      home: MazamaInventoryPage(load: () async => _mix, orderForm: () => const Scaffold(body: Text('the order form'))),
    ));
    await tester.pumpAndSettle();
    // The page has no title bar, but keeps its Order button.
    expect(find.byType(AppBar), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('order-button')), matching: find.text('Order')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('order-button')));
    expect(find.text('the order form'), findsOneWidget);
  });

  testWidgets('Order is there even when the mix did not load', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MazamaInventoryPage(
          load: () async => throw MazamaInventoryError('offline'), orderForm: () => const Scaffold(body: Text('the order form'))),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('did not load'), findsOneWidget);
    expect(find.byKey(const ValueKey('order-button')), findsOneWidget);
  });
  testWidgets('MI-R7: the lot table sits under the pies, closed at first', (tester) async {
    const withLots = MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [
      MixCell(strain: 'Golden Teacher', type: 'DH', mg: 3000),
    ], lots: [
      MazamaLot(strain: 'Golden Teacher', lot: 'HB-aaaa0001', tpe: 8.64, psilocybin: 7.25, psilocin: 1, detected: ['baeocystin']),
    ]);
    await tester.pumpWidget(_page(load: () async => withLots));
    await tester.pumpAndSettle();
    expect(find.byType(MazamaLotTable), findsOneWidget);
    expect(tester.getTopLeft(find.byType(MazamaLotTable)).dy > tester.getTopLeft(find.byKey(const ValueKey('mix-pies'))).dy,
        isTrue);
    expect(find.byKey(const ValueKey('lot-row-Golden Teacher|HB-aaaa0001')), findsNothing);
    await _tap(tester, find.text('Strains in stock'));
    expect(find.byKey(const ValueKey('lot-row-Golden Teacher|HB-aaaa0001')), findsOneWidget);
    expect(find.text('Baeocystin'), findsOneWidget);
  });

  testWidgets('MI-R7: no lot table when the server sends no lots, as one from before MI-R7 does', (tester) async {
    await tester.pumpWidget(_page()); // _mix has no lots
    await tester.pumpAndSettle();
    expect(find.text('6,000 mg TPE in all'), findsOneWidget);
    expect(find.byType(MazamaLotTable), findsNothing);
  });
  testWidgets('MI-D19: Contact at the left of the row Order sits at the right of, even when the mix did not load',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MazamaInventoryPage(
          load: () async => throw MazamaInventoryError('offline'), orderForm: () => const Scaffold(body: Text('form'))),
    ));
    await tester.pumpAndSettle();
    final contact = tester.getRect(find.byKey(const ValueKey('contact-button')));
    final order = tester.getRect(find.byKey(const ValueKey('order-button')));
    expect(contact.center.dy, closeTo(order.center.dy, 1)); // the same row
    expect(contact.right < order.left, isTrue);
    expect(contact.left < 40, isTrue); // at the left edge
    expect(find.descendant(of: find.byKey(const ValueKey('contact-button')), matching: find.text('Contact')), findsOneWidget);
  });

  testWidgets('MI-D19: Contact offers the website, Signal and email, each opening its own link', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(
      home: MazamaInventoryPage(load: () async => _mix, openLink: (uri) async {
        opened.add(uri);
        return true;
      }),
    ));
    await tester.pumpAndSettle();
    for (final (key, want) in [
      ('contact-login', 'https://guest:ahealingjourney@login.mazamamushrooms.com'),
      ('contact-signal', 'https://signal.me/#eu/Mazama.01'),
    ]) {
      await _tap(tester, find.byKey(const ValueKey('contact-button')));
      expect(find.text('Contact Mazama'), findsOneWidget);
      await _tap(tester, find.byKey(ValueKey(key)));
      expect(find.text('Contact Mazama'), findsNothing); // picking one closes the sheet
      expect(opened.last.toString(), want);
    }
    expect(opened, [mazamaGuestLogin, mazamaSignal]);
    // PA-D6: no email address in the sheet
    await _tap(tester, find.byKey(const ValueKey('contact-button')));
    expect(find.byKey(const ValueKey('contact-email')), findsNothing);
    expect(find.textContaining('@'), findsNothing);
  });

  testWidgets("MI-D19: a contact link that can't be opened says so", (tester) async {
    await tester.pumpWidget(MaterialApp(home: MazamaInventoryPage(load: () async => _mix, openLink: (_) async => false)));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('contact-button')));
    await _tap(tester, find.byKey(const ValueKey('contact-signal')));
    expect(find.text("Couldn't open Signal."), findsOneWidget);
  });

  testWidgets('MI-D18: a lot id with a sheet opens it; one without is plain text', (tester) async {
    const withLots = MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [
      MixCell(strain: 'Golden Teacher', type: 'DH', mg: 3000),
    ], lots: [
      MazamaLot(strain: 'Golden Teacher', lot: 'HB-aaaa0001', tpe: 8.64, path: '/p/lots/mazama/HB-aaaa0001'),
      MazamaLot(strain: 'Golden Teacher', lot: 'PL-0000a002', tpe: 10.2),
    ]);
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: MazamaInventoryPage(load: () async => withLots, openSheet: (lot) async => opened.add(lot.lot)),
    ));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Strains in stock'));
    expect(find.byKey(const ValueKey('lot-link-PL-0000a002')), findsNothing);
    expect(find.text('PL-0000a002'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('lot-link-HB-aaaa0001')));
    expect(opened, ['HB-aaaa0001']);
  });
  testWidgets('MI-D20: a strain picked on By strain, or a type on By type, narrows the lot table; unpicking shows all',
      (tester) async {
    const withLots = MazamaInventory(name: 'Mazama Mushrooms LLC', cells: [
      MixCell(strain: 'Golden Teacher', type: 'DH', mg: 3000),
      MixCell(strain: 'Golden Teacher', type: 'HG', mg: 1000),
      MixCell(strain: 'Maztapec', type: 'HG', mg: 2000),
    ], lots: [
      MazamaLot(strain: 'Golden Teacher', lot: 'HB-gt01', tpe: 8, types: ['DH']),
      MazamaLot(strain: 'Golden Teacher', lot: 'PL-gt02', tpe: 9, types: ['HG']),
      MazamaLot(strain: 'Maztapec', lot: 'HB-mz03', tpe: 7, types: ['HG']),
    ]);
    await tester.pumpWidget(_page(load: () async => withLots));
    await tester.pumpAndSettle();
    expect(find.text('Strains in stock'), findsOneWidget);
    expect(find.text('3 lots · 2 strains'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('strain-key-Maztapec')));
    expect(find.text('Strains in stock: Maztapec'), findsOneWidget);
    expect(find.text('1 of 3 lots'), findsOneWidget);
    await _tap(tester, find.text('Strains in stock: Maztapec'));
    expect(find.byKey(const ValueKey('lot-row-Maztapec|HB-mz03')), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-row-Golden Teacher|HB-gt01')), findsNothing);

    // a type picked on By type replaces the strain (one pick at a time)
    await _tap(tester, find.byKey(const ValueKey('mix-pie-dot-type')));
    await _tap(tester, find.byKey(const ValueKey('type-key-Homogenized')));
    expect(find.text('Strains in stock: Homogenized'), findsOneWidget);
    expect(find.text('2 of 3 lots'), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-row-Golden Teacher|PL-gt02')), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-row-Maztapec|HB-mz03')), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-row-Golden Teacher|HB-gt01')), findsNothing);

    await _tap(tester, find.byKey(const ValueKey('type-key-Homogenized'))); // again: unpicked
    expect(find.text('Strains in stock'), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-row-Golden Teacher|HB-gt01')), findsOneWidget);
  });

  // --- Mazama's server unreachable: the stock it last sent, kept on the phone -----------------------------------

  group('the copy kept on the phone', () {
    final at = DateTime.utc(2026, 10, 20, 15, 5);

    testWidgets('each mix the server sends is kept with when', (tester) async {
      final kept = <(MazamaInventory, DateTime)>[];
      final now = DateTime.utc(2026, 10, 23, 8);
      await tester.pumpWidget(MaterialApp(
        home: MazamaInventoryPage(
            load: () async => _mix, keep: (inv, t) async => kept.add((inv, t)), kept: () async => null, now: () => now),
      ));
      await tester.pumpAndSettle();
      expect(kept.single.$1, same(_mix));
      expect(kept.single.$2, now);
    });

    // R87: no notice of the page's own over the kept mix: the app-wide banner says the server can't be reached.
    testWidgets('unreachable: the kept mix shows, with no notice of its own; Order is still there', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MazamaInventoryPage(
          load: () async => throw MazamaInventoryError('cannot reach sales.mazamamushrooms.com: SocketException', unreachable: true),
          kept: () async => ServerRead.cached(_mix, at),
          keep: (inv, t) async => fail('nothing new to keep'),
          orderForm: () => const Scaffold(body: Text('the order form')),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining("can't be reached"), findsNothing);
      expect(find.textContaining("Orders can't be sent"), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('6,000 mg TPE in all'), findsOneWidget);
      expect(find.textContaining('did not load'), findsNothing);
      expect(find.byKey(const ValueKey('order-button')), findsOneWidget);
    });

    // README R56: the page reads whether the server answers from the app's tracker.
    testWidgets('showing the kept mix, the page reloads by itself once the server tracker is online again',
        (tester) async {
      final health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
      addTearDown(health.dispose);
      health.markUnreachable();
      var up = false;
      var loads = 0;
      await tester.pumpWidget(MaterialApp(
        home: MazamaInventoryPage(
          load: () async {
            loads++;
            if (!up) throw MazamaInventoryError("Mazama's server can't be reached", unreachable: true);
            return _mix;
          },
          kept: () async => ServerRead.cached(_mix, at),
          health: health,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('6,000 mg TPE in all'), findsOneWidget); // the kept copy
      expect(loads, 1);
      up = true;
      health.markReachable();
      await tester.pumpAndSettle();
      expect(loads, 2);
      expect(find.text('6,000 mg TPE in all'), findsOneWidget);
    });

    testWidgets("showing the server's own mix: no reload once the tracker is online again", (tester) async {
      final health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
      addTearDown(health.dispose);
      health.markUnreachable();
      var loads = 0;
      await tester.pumpWidget(MaterialApp(
        home: MazamaInventoryPage(
          load: () async {
            loads++;
            return _mix;
          },
          kept: () async => ServerRead.cached(_mix, at),
          health: health,
        ),
      ));
      await tester.pumpAndSettle();
      health.markReachable();
      await tester.pumpAndSettle();
      expect(loads, 1);
    });

    // The error's Retry (nothing kept): the notice that had a Retry of its own is gone (R87).
    testWidgets('Retry asks the server first, then reloads once', (tester) async {
      var probes = 0;
      final health = ServerHealth(probe: () async {
        probes++;
        return true;
      }, startTimer: FakeTimers().start);
      addTearDown(health.dispose);
      health.markUnreachable();
      var loads = 0;
      await tester.pumpWidget(MaterialApp(
        home: MazamaInventoryPage(
          load: () async {
            loads++;
            if (health.offline) throw MazamaInventoryError("Mazama's server can't be reached", unreachable: true);
            return _mix;
          },
          kept: () async => null,
          health: health,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(probes, 1);
      expect(loads, 2); // one reload, not one from Retry and another from the tracker
      expect(find.text('6,000 mg TPE in all'), findsOneWidget);
    });

    testWidgets("a 4xx is the server's own answer: the error, not the kept mix", (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MazamaInventoryPage(
          load: () async => throw MazamaInventoryError('No manufacturer.'),
          kept: () async => ServerRead.cached(_mix, at),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Mazama inventory did not load: No manufacturer.'), findsOneWidget);
    });

    testWidgets('unreachable with nothing kept: the error and Retry as before', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MazamaInventoryPage(
          load: () async => throw MazamaInventoryError('cannot reach sales.mazamamushrooms.com: SocketException', unreachable: true),
          kept: () async => null,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Mazama inventory did not load: cannot reach'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    });
  });
}
