// MI-D21, SP-D19 (specs/mazama-inventory, specs/stock-page): the order's first step (lib/order_par_page.dart): the
// par table (lib/par_levels_editor.dart, SP-R9, SP-R14, SP-D13..D15, moved here from the stock page) set or confirmed
// before the order form, which starts from the levels confirmed or saved. Data comes through the injected loaders, and
// the order form is a stand-in that records the levels it was given.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/order_par_page.dart';
import 'package:mazama_mobile/par_client.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_offline.dart';
import 'package:mazama_mobile/stock_cache_store.dart';
import 'package:mazama_mobile/stock_rows.dart';
import 'package:mazama_mobile/stock_summary.dart';

import 'fake_timers.dart';

final _center = License(id: 231, licenseId: 'SC-b1c7379a', licenseName: 'Bendable Service Center', licenseType: 'ServiceCenter');

const _rows = [
  StockRow(productGuid: 'PKPR-gt25', id: 1, quantity: 10, mazama: true, strain: 'Golden Teacher', description: 'Golden Teacher 25 mg', unitMgTpe: 25),
  StockRow(productGuid: 'PKPR-gt10', id: 2, quantity: 4, mazama: true, strain: 'Golden Teacher', description: 'Golden Teacher 10 mg', unitMgTpe: 10),
  StockRow(productGuid: 'PKPR-pe15', id: 3, quantity: 6, strain: 'Penis Envy', description: 'Penis Envy 15 mg', unitMgTpe: 15),
  StockRow(productGuid: 'PKPR-hu5', id: 4, quantity: 2, mazama: true, expired: true, strain: 'Huautla', description: 'Huautla 5 mg', unitMgTpe: 5),
  StockRow(productGuid: 'PKPR-gone', id: 5, quantity: 0, mazama: true, strain: 'Enigma', description: 'Enigma 25 mg', unitMgTpe: 25),
];

/// Rows as the state alone gives them (stock_rows.dart's stockRowsFromState): no strain, no mg TPE.
const _stateRows = [
  StockRow(productGuid: 'PKPR-gt25', id: 1, quantity: 10, mazama: true, description: 'GT 25 mg TPE FD', weightPerUnit: 0.5, analyteWeight: 10),
];

const _par = [
  ParLevel(strain: 'Golden Teacher', size: 25, par: 12),
  ParLevel(strain: 'Penis Envy', size: 15, par: 5),
  ParLevel(strain: 'Huautla', size: 5, par: 3),
];

class _Failure implements Exception {
  _Failure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The levels each opening of the order form was given.
late List<List<ParLevel>> _opened;

/// [loadRows] gives fresh server rows (mg TPE, not partial); [load] a whole StockLoad instead.
Widget _page({
  Future<List<StockRow>> Function()? loadRows,
  Future<StockLoad> Function()? load,
  Future<List<ParLevel>> Function()? loadPar,
  Future<ServerRead<List<ParLevel>>> Function()? loadParRead,
  Future<List<ParLevel>> Function(List<ParLevel>)? savePar,
  Future<ParColumns> Function()? loadParColumns,
  Future<void> Function(ParColumns)? saveParColumns,
  ServerHealth? health,
}) {
  _opened = [];
  return MaterialApp(
    home: OrderParPage(
      center: _center,
      loadRows: load ?? () async => StockLoad(await (loadRows ?? () async => _rows)()),
      loadPar: loadParRead ?? () async => ServerRead(await (loadPar ?? () async => _par)()),
      savePar: savePar ?? (levels) async => levels,
      loadParColumns: loadParColumns,
      saveParColumns: saveParColumns,
      health: health,
      orderForm: (levels) {
        _opened.add(levels);
        return const Scaffold(body: Text('the order form'));
      },
    ),
  );
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Back from the order form to the par step.
Future<void> _back(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator)).pop();
  await tester.pumpAndSettle();
}

String _level(ParLevel l) => '${l.strain}|${l.size}|${l.par}';

const _cantSave =
    "Mazama's server can't be reached, so par levels can't be saved now - try again later. The order starts from the par levels above.";

/// "Save and continue", then back from the order form it opens to look at the table again.
Future<void> _saveAndComeBack(WidgetTester tester) async {
  await _tap(tester, find.text('Save and continue'));
  expect(find.text('the order form'), findsOneWidget);
  await _back(tester);
}

void main() {
  testWidgets('opens on the par table: have, par and short, against every maker\'s stock', (tester) async {
    await tester.pumpWidget(_page());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.text('Order from Mazama'), findsOneWidget);
    expect(find.text('Set or confirm your par levels: the order starts from them.'), findsOneWidget);
    expect(find.text('5 units below par'), findsOneWidget); // Golden Teacher 25 mg short 2, Huautla 5 mg short 3
    expect(find.text('10 / 12'), findsOneWidget);
    expect(find.text('short 2'), findsOneWidget);
    expect(find.text('6 / 5'), findsOneWidget); // SP-D4: Penis Envy is another maker's, and still counts
    expect(find.text('ok'), findsOneWidget);
    // Huautla has a par level and only expired stock: a row of its own, with nothing on hand.
    expect(find.byKey(const ValueKey('par-row-Huautla')), findsOneWidget);
    expect(find.text('0 / 3'), findsOneWidget);
    expect(find.text('short 3'), findsOneWidget);
    expect(find.byType(TextField), findsNothing); // shown to confirm, not yet edited
    expect(_opened, isEmpty);
  });

  testWidgets('Continue to order confirms the levels as they are: the form starts from them', (tester) async {
    await tester.pumpWidget(_page(savePar: (levels) async => fail('confirming saves nothing')));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('par-continue')));

    expect(find.text('the order form'), findsOneWidget);
    expect(_opened.single.map(_level), _par.map(_level));
    await _back(tester); // Back from the form comes back to the par step
    expect(find.text('10 / 12'), findsOneWidget);
  });

  testWidgets('Done on the form after the order is sent closes the par step too; Back does not', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => OrderParPage(
                center: _center,
                loadRows: () async => const StockLoad(_rows),
                loadPar: () async => const ServerRead(_par),
                savePar: (levels) async => levels,
                orderForm: (levels) => Builder(
                  builder: (context) => Scaffold(
                    body: Column(children: [
                      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back')),
                      TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Done')),
                    ]),
                  ),
                ),
              ),
            )),
            child: const Text('the Mazama page'),
          ),
        ),
      ),
    ));
    await _tap(tester, find.text('the Mazama page'));
    await _tap(tester, find.byKey(const ValueKey('par-continue')));
    await _tap(tester, find.text('Back'));
    expect(find.byType(OrderParPage), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('par-continue')));
    await _tap(tester, find.text('Done'));
    expect(find.byType(OrderParPage), findsNothing);
    expect(find.text('the Mazama page'), findsOneWidget);
  });

  testWidgets('edit, Save and continue sends the levels and starts the form from the levels as stored', (tester) async {
    List<ParLevel>? sent;
    await tester.pumpWidget(_page(savePar: (levels) async {
      sent = levels;
      return [for (final l in levels) if (l.par != null) l];
    }));
    await tester.pumpAndSettle();

    await _tap(tester, find.text('Edit par levels'));
    expect(find.byKey(const ValueKey('par-continue')), findsNothing); // saved, or cancelled, before going on
    expect(tester.widget<TextField>(find.byKey(const ValueKey('par-Golden Teacher-25'))).controller!.text, '12');
    await tester.enterText(find.byKey(const ValueKey('par-Golden Teacher-25')), '20');
    await tester.enterText(find.byKey(const ValueKey('par-Penis Envy-15')), '');
    await _tap(tester, find.text('Add a strain'));
    await tester.enterText(find.byKey(const ValueKey('par-new-name-0')), 'Enigma');
    await tester.enterText(find.byKey(const ValueKey('par-new-0-25')), '4');
    await _tap(tester, find.text('Save and continue'));

    expect(sent!.map(_level).toSet(), {
      'Golden Teacher|25|20',
      'Penis Envy|15|null', // cleared: removes it
      'Huautla|5|3',
      'Enigma|25|4',
    });
    expect(find.text('the order form'), findsOneWidget);
    expect(_opened.single.map(_level).toSet(), {'Golden Teacher|25|20', 'Huautla|5|3', 'Enigma|25|4'});

    await _back(tester);
    expect(find.text('Par levels saved.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing); // back to the table
    expect(find.text('10 / 20'), findsOneWidget);
    expect(find.byKey(const ValueKey('par-row-Enigma')), findsOneWidget);
  });

  testWidgets('Cancel drops the edits and offers Continue again', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Edit par levels'));
    await tester.enterText(find.byKey(const ValueKey('par-Golden Teacher-25')), '20');
    await _tap(tester, find.text('Cancel'));

    expect(find.text('10 / 12'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('par-continue')));
    expect(_opened.single.map(_level), _par.map(_level));
  });

  testWidgets('a center with no par levels opens straight in the editor', (tester) async {
    await tester.pumpWidget(_page(loadPar: () async => const []));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('par-Golden Teacher-25')), findsOneWidget);
    expect(find.text('Save and continue'), findsOneWidget);
    expect(find.byKey(const ValueKey('par-continue')), findsNothing);
  });

  testWidgets('edibles sit below the strains with only Booster and Microdose', (tester) async {
    // specs/edibles ED-D1..D3, ED-A6; SP-D15: an edible adds no column to the strains' rows
    List<ParLevel>? sent;
    await tester.pumpWidget(_page(
      loadRows: () async => const [
        StockRow(productGuid: 'PKPR-ch', id: 1, quantity: 3, mazama: true, strain: 'Golden Teacher', description: 'GT 5 mg TPE CH', unitMgTpe: 5, type: 'CH'),
        StockRow(productGuid: 'PKPR-cm', id: 2, quantity: 4, mazama: true, strain: 'Bluey', description: 'Bluey chocolate 2 mg', unitMgTpe: 2),
        StockRow(productGuid: 'PKPR-gt', id: 3, quantity: 2, mazama: true, strain: 'Golden Teacher', description: 'GT 25 mg', unitMgTpe: 25, type: 'FD'),
      ],
      loadPar: () async => const [ParLevel(strain: 'Chocolate', size: -1, par: 5)],
      savePar: (levels) async {
        sent = levels;
        return [for (final l in levels) if (l.par != null) l];
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('Booster'), findsWidgets);
    expect(find.text('Microdose'), findsWidgets);
    expect(find.text('3 / 5'), findsOneWidget); //  Chocolate Booster: 3 on hand, par 5
    expect(find.text('short 2'), findsOneWidget);
    expect(find.text('4 / –'), findsOneWidget); //  Chocolate Microdose: 4 on hand, no par
    await _tap(tester, find.text('Edit par levels'));
    expect(find.byKey(const ValueKey('par-Chocolate--2')), findsOneWidget);
    expect(find.byKey(const ValueKey('par-Chocolate-25')), findsNothing); //       a product takes no serving size
    expect(find.byKey(const ValueKey('par-Golden Teacher--1')), findsNothing); //  a strain takes no Booster
    expect(find.byKey(const ValueKey('par-Chocolate-0')), findsNothing); //        nor does an edible show Other
    expect(find.byKey(const ValueKey('par-Gummy--1')), findsOneWidget); //         every edible can be given a par
    final strainTop = tester.getTopLeft(find.byKey(const ValueKey('par-row-Golden Teacher'))).dy;
    final combined = tester.getTopLeft(find.byKey(const ValueKey('par-row-All strains'))).dy;
    expect(tester.getTopLeft(find.byKey(const ValueKey('par-row-Chocolate'))).dy, greaterThan(combined));
    expect(combined, greaterThan(strainTop));
    await tester.enterText(find.byKey(const ValueKey('par-Chocolate--2')), '6');
    await _tap(tester, find.text('Save and continue'));
    expect(sent!.map(_level).toSet(), {'Chocolate|-1|5', 'Chocolate|-2|6'});
  });

  testWidgets('a failed save keeps the edits and shows the message, and does not go on to the form', (tester) async {
    await tester.pumpWidget(_page(savePar: (levels) async => throw _Failure('The Mazama server said no.')));
    await tester.pumpAndSettle();

    await _tap(tester, find.text('Edit par levels'));
    await tester.enterText(find.byKey(const ValueKey('par-Golden Teacher-25')), '20');
    await _tap(tester, find.text('Save and continue'));

    expect(find.textContaining('The Mazama server said no.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('par-Golden Teacher-25'))).controller!.text, '20');
    expect(find.text('Save and continue'), findsOneWidget);
    expect(_opened, isEmpty);
  });

  testWidgets('no stock shows the par rows with nothing on hand', (tester) async {
    await tester.pumpWidget(_page(loadRows: () async => const []));
    await tester.pumpAndSettle();

    expect(find.text('0 / 12'), findsOneWidget);
    expect(find.text('0 / 5'), findsOneWidget);
    expect(find.text('0 / 3'), findsOneWidget);
    expect(find.text('20 units below par'), findsOneWidget);
  });

  testWidgets('stock that did not load still lets the par levels be set, nothing on hand', (tester) async {
    await tester.pumpWidget(_page(loadRows: () async => throw _Failure('no network')));
    await tester.pumpAndSettle();

    expect(find.text('Stock did not load (no network): units on hand show as 0.'), findsOneWidget);
    expect(find.text('0 / 12'), findsOneWidget);
    expect(find.text('Edit par levels'), findsOneWidget);
  });

  testWidgets('par levels that did not load say so, and Retry loads them again', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_page(loadPar: () async {
      calls++;
      if (calls == 1) throw _Failure('par offline');
      return _par;
    }));
    await tester.pumpAndSettle();
    expect(find.text('Par levels did not load: par offline'), findsOneWidget);
    expect(find.byKey(const ValueKey('par-continue')), findsNothing);

    await _tap(tester, find.widgetWithText(FilledButton, 'Retry'));
    expect(find.text('10 / 12'), findsOneWidget);
  });

  testWidgets('par is read-only with the server unreachable, and can still be confirmed', (tester) async {
    await tester.pumpWidget(_page(
      load: () async => const StockLoad(_stateRows, mgMode: 'psilocybin', partial: true),
      savePar: (levels) async => fail('nothing is saved while the server is unreachable'),
    ));
    await tester.pumpAndSettle();
    // R87: no notice of the page's own for the server: the app-wide banner says it; the editor says why it can't save.
    expect(find.textContaining('Partial'), findsNothing);
    expect(find.text('Edit par levels'), findsNothing);
    expect(find.text(_cantSave), findsOneWidget);
    expect(find.text('0 / 12'), findsOneWidget); // the last par levels fetched, still compared with the stock

    await _tap(tester, find.byKey(const ValueKey('par-continue')));
    expect(_opened.single.map(_level), _par.map(_level));
  });

  // --- SP-D13..D14: the combined row, the columns this center uses, deleting strains ------------------------------

  testWidgets('only the sizes with stock or a par show; a column deleted while editing takes its pars with it', (tester) async {
    List<ParLevel>? sent;
    ParColumns? kept;
    await tester.pumpWidget(_page(
      savePar: (levels) async {
        sent = levels;
        return [for (final l in levels) if (l.par != null) l];
      },
      saveParColumns: (c) async => kept = c,
    ));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Edit par levels'));
    // stock in 25, 15 and 10 mg; a par in 5 mg (Huautla): no 20 mg or Other column
    for (final d in [25, 15, 10, 5]) {
      expect(find.byKey(ValueKey('par-col-remove-$d')), findsOneWidget, reason: '$d');
    }
    expect(find.byKey(const ValueKey('par-col-remove-20')), findsNothing);
    expect(find.byKey(const ValueKey('par-col-remove-0')), findsNothing);
    expect(find.byKey(const ValueKey('par-Golden Teacher-20')), findsNothing);

    await _tap(tester, find.byKey(const ValueKey('par-col-remove-25')));
    expect(find.byKey(const ValueKey('par-Golden Teacher-25')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('par-col-add')));
    await _tap(tester, find.byKey(const ValueKey('par-col-add-20')));
    await tester.enterText(find.byKey(const ValueKey('par-Penis Envy-20')), '7');
    await _saveAndComeBack(tester);

    expect(sent!.map(_level).toSet(), {'Golden Teacher|25|null', 'Penis Envy|20|7', 'Penis Envy|15|5', 'Huautla|5|3'});
    expect([kept!.added, kept!.removed], [{20}, {25}]);
    expect(find.text('10 / 12'), findsNothing); // the 25 mg column stays gone, though Golden Teacher has stock in it
    expect(find.text('6 / 7'), findsNothing);
    expect(find.text('0 / 7'), findsOneWidget); // Penis Envy 20 mg
  });

  testWidgets('columns deleted on this phone before stay hidden; a size with a par still shows', (tester) async {
    await tester.pumpWidget(_page(loadParColumns: () async => const ParColumns(removed: {10, 25})));
    await tester.pumpAndSettle();
    expect(find.text('4 / –'), findsNothing); //   Golden Teacher 10 mg: deleted here, no par
    expect(find.text('10 / 12'), findsOneWidget); // Golden Teacher 25 mg: deleted here, but it has a par (set elsewhere)
  });

  testWidgets('a strain with no stock can be deleted; one with stock cannot', (tester) async {
    List<ParLevel>? sent;
    await tester.pumpWidget(_page(
      loadPar: () async => [..._par, const ParLevel(strain: 'Enigma', size: 10, par: 4), const ParLevel(strain: 'Enigma', size: 0, par: 1)],
      savePar: (levels) async {
        sent = levels;
        return [for (final l in levels) if (l.par != null) l];
      },
    ));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Edit par levels'));
    expect(find.byKey(const ValueKey('par-row-remove-Golden Teacher')), findsNothing);
    expect(find.byKey(const ValueKey('par-row-remove-All strains')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('par-row-remove-Enigma')));
    expect(find.byKey(const ValueKey('par-row-Enigma')), findsNothing);
    await _saveAndComeBack(tester);
    expect(sent!.map(_level).where((l) => l.startsWith('Enigma')).toSet(), {'Enigma|10|null', 'Enigma|0|null'});
    expect(find.byKey(const ValueKey('par-row-Enigma')), findsNothing);
  });

  testWidgets('a new strain row can be removed before it is saved', (tester) async {
    List<ParLevel>? sent;
    await tester.pumpWidget(_page(savePar: (levels) async => sent = levels));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Edit par levels'));
    await _tap(tester, find.text('Add a strain'));
    await tester.enterText(find.byKey(const ValueKey('par-new-name-0')), 'Mistake');
    await tester.enterText(find.byKey(const ValueKey('par-new-0-25')), '9');
    await _tap(tester, find.byKey(const ValueKey('par-new-remove-0')));
    expect(find.byKey(const ValueKey('par-new-name-0')), findsNothing);
    await _tap(tester, find.text('Save and continue'));
    expect(sent!.map(_level).where((l) => l.startsWith('Mistake')), isEmpty);
  });

  testWidgets('the combined All strains row counts every strain and is saved under its own name', (tester) async {
    List<ParLevel>? sent;
    await tester.pumpWidget(_page(
      loadPar: () async => [..._par, const ParLevel(strain: 'All strains', size: 25, par: 20)],
      savePar: (levels) async {
        sent = levels;
        return [for (final l in levels) if (l.par != null) l];
      },
    ));
    await tester.pumpAndSettle();
    // 25 mg: Golden Teacher 10 of 12 (short 2); all strains 10 of 20 (short 10, 8 beyond Golden Teacher's 2);
    // Huautla 5 mg short 3: 2 + 8 + 3
    expect(find.text('13 units below par'), findsOneWidget);
    expect(find.text('10 / 20'), findsOneWidget);
    expect(find.text('short 10'), findsOneWidget);
    await _tap(tester, find.text('Edit par levels'));
    expect(tester.widget<TextField>(find.byKey(const ValueKey('par-All strains-25'))).controller!.text, '20');
    await tester.enterText(find.byKey(const ValueKey('par-All strains-10')), '6');
    await _tap(tester, find.text('Save and continue'));
    expect(sent!.map(_level), containsAll(['All strains|25|20', 'All strains|10|6']));
  });

  testWidgets('an edible or All strains typed as a new strain is refused: they have rows of their own', (tester) async {
    var saves = 0;
    await tester.pumpWidget(_page(savePar: (levels) async {
      saves++;
      return levels;
    }));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Edit par levels'));
    await _tap(tester, find.text('Add a strain'));
    await tester.enterText(find.byKey(const ValueKey('par-new-name-0')), 'chocolate');
    await _tap(tester, find.text('Save and continue'));
    expect(saves, 0);
    expect(find.textContaining('chocolate has a row of its own'), findsOneWidget);
    expect(find.text('Save and continue'), findsOneWidget); // still editing
    expect(_opened, isEmpty);
  });

  // --- Mazama's server unreachable: the copy kept on the phone, and saves that say to try later -------------------

  // R87: no notice of the page's own over the kept levels: the app-wide banner says the server can't be reached.
  testWidgets('par levels kept on the phone show read-only, with no notice of their own, and can be confirmed',
      (tester) async {
    final at = DateTime.utc(2026, 10, 20, 15, 5);
    await tester.pumpWidget(_page(
      loadParRead: () async => ServerRead.cached(_par, at),
      savePar: (levels) async => fail('nothing is saved from the copy kept on the phone'),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('last sent'), findsNothing);
    expect(find.textContaining('until it answers again'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('10 / 12'), findsOneWidget); // the kept levels against today's stock
    expect(find.text('Edit par levels'), findsNothing);
    expect(find.text(_cantSave), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('par-continue')));
    expect(_opened.single.map(_level), _par.map(_level));
  });

  group('reloads once the server tracker is online again', () {
    ServerHealth offlineTracker() {
      final health = ServerHealth(probe: () async => false, startTimer: FakeTimers().start);
      health.markUnreachable();
      return health;
    }

    testWidgets('showing the kept par levels: reloads, and they can then be edited', (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      var calls = 0;
      await tester.pumpWidget(_page(
        loadParRead: () async {
          calls++;
          return calls == 1 ? ServerRead.cached(_par, DateTime.utc(2026, 10, 20)) : const ServerRead(_par);
        },
        health: health,
      ));
      await tester.pumpAndSettle();
      expect(find.text('Edit par levels'), findsNothing);
      expect(find.text(_cantSave), findsOneWidget);

      health.markReachable();
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('Edit par levels'), findsOneWidget);
      expect(find.text(_cantSave), findsNothing);
    });

    testWidgets('showing a partial stock: reloads', (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      var loads = 0;
      await tester.pumpWidget(_page(
        load: () async {
          loads++;
          return loads == 1 ? const StockLoad(_stateRows, mgMode: 'psilocybin', partial: true) : const StockLoad(_rows);
        },
        health: health,
      ));
      await tester.pumpAndSettle();
      expect(find.text('Edit par levels'), findsNothing);

      health.markReachable();
      await tester.pumpAndSettle();
      expect(loads, 2);
      expect(find.text('Edit par levels'), findsOneWidget);
    });

    testWidgets("showing the server's own answer: no reload", (tester) async {
      final health = offlineTracker();
      addTearDown(health.dispose);
      var calls = 0;
      await tester.pumpWidget(_page(
        loadPar: () async {
          calls++;
          return _par;
        },
        health: health,
      ));
      await tester.pumpAndSettle();
      health.markReachable();
      await tester.pumpAndSettle();
      expect(calls, 1);
    });
  });

  testWidgets('a save that cannot reach the server says to try again later, never queues, and keeps the edits',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_page(savePar: (levels) async {
      calls++;
      throw ParError('cannot reach sales.mazamamushrooms.com: SocketException', unreachable: true);
    }));
    await tester.pumpAndSettle();

    await _tap(tester, find.text('Edit par levels'));
    await tester.enterText(find.byKey(const ValueKey('par-Golden Teacher-25')), '20');
    await _tap(tester, find.text('Save and continue'));

    expect(find.text("Par levels were not saved: Mazama's server can't be reached - try again later."), findsOneWidget);
    expect(calls, 1); // sent once, not retried or queued
    expect(tester.widget<TextField>(find.byKey(const ValueKey('par-Golden Teacher-25'))).controller!.text, '20');
    expect(_opened, isEmpty);

    // Still editable: the worker can try again as it is.
    await _tap(tester, find.text('Save and continue'));
    expect(calls, 2);
  });

  testWidgets("a save the server refuses (4xx) shows the server's own message", (tester) async {
    await tester.pumpWidget(_page(savePar: (levels) async => throw ParError('These values are not whole numbers.')));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Edit par levels'));
    await tester.enterText(find.byKey(const ValueKey('par-Golden Teacher-25')), '20');
    await _tap(tester, find.text('Save and continue'));
    expect(find.text('Par levels were not saved: These values are not whole numbers.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('par-Golden Teacher-25'))).controller!.text, '20');
  });
}
