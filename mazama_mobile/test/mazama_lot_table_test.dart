// MI-R7 (specs/mazama-inventory): the Mazama inventory page's lot table - closed at first (MI-R7), one row per lot
// under its strain (MI-D12), mg per gram (MI-D11), a tag per minor analyte found (MI-D13), and a tap on the heading or
// a number switching every row between TPE, psilocybin and psilocin (MI-D14).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/mazama_inventory_client.dart';
import 'package:mazama_mobile/mazama_lot_table.dart';
import 'package:yaml/yaml.dart';

const _lots = [
  MazamaLot(strain: 'Golden Teacher', lot: 'HB-aaaa0001', tpe: 8.64, psilocybin: 7.25, psilocin: 1,
      detected: ['baeocystin', 'aeruginascin'], types: ['DH', 'WF']),
  MazamaLot(strain: 'Golden Teacher', lot: 'PL-0000a002', tpe: 10.2, psilocybin: 8.9, psilocin: null, types: ['LOT']),
  MazamaLot(strain: 'Penis Envy', lot: 'HB-bbbb0002', tpe: 12.5, psilocybin: 11, psilocin: 1.08,
      detected: ['norbaeocystin', 'norpsilocin', 'something-new'], types: ['DH']),
];

Widget _table({
  List<MazamaLot> lots = _lots,
  Brightness brightness = Brightness.light,
  LotFilter? filter,
  String? note,
  bool noteIsError = false,
}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
          body: SingleChildScrollView(
              child: MazamaLotTable(lots: lots, filter: filter, note: note, noteIsError: noteIsError))),
    );

List<String> _rows(WidgetTester tester) => [
      for (final w in tester.widgetList(find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('lot-row-'))))
        (w.key as ValueKey<String>).value.substring('lot-row-'.length),
    ];

String _value(WidgetTester tester, String lot) =>
    tester.widget<Text>(find.descendant(of: find.byKey(ValueKey('lot-value-$lot')), matching: find.byType(Text))).data!;

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Opens the table by its header, whatever its title says (a filter adds to it).
Future<void> _open(WidgetTester tester) =>
    _tap(tester, find.descendant(of: find.byKey(const ValueKey('lot-table')), matching: find.byType(ListTile)).first);

/// The vendored rules.yaml's `analyte_tags` (specs/web-charts WC-R7), in its order.
List<Map> _sharedTags() =>
    ((loadYaml(File('assets/shared/stock/rules/rules.yaml').readAsStringSync()) as YamlMap)['analyte_tags'] as List)
        .cast<Map>();

/// "#RRGGBB" -> 0xFFRRGGBB.
int _argb(Object? hex) {
  final s = hex as String;
  expect(s, matches(RegExp(r'^#[0-9A-Fa-f]{6}$')));
  return 0xFF000000 | int.parse(s.substring(1), radix: 16);
}

void main() {
  testWidgets('closed at first, with how many lots and strains', (tester) async {
    await tester.pumpWidget(_table());
    expect(find.text('Strains in stock'), findsOneWidget);
    expect(find.text('3 lots · 2 strains'), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-row-Golden Teacher|HB-aaaa0001')), findsNothing);
  });

  testWidgets('open: each lot under its strain, TPE mg/g first', (tester) async {
    await tester.pumpWidget(_table());
    await _open(tester);
    expect(find.text('TPE mg/g'), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-strain-Golden Teacher')), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-strain-Penis Envy')), findsOneWidget);
    expect(_value(tester, 'HB-aaaa0001'), '8.64');
    expect(_value(tester, 'PL-0000a002'), '10.20');
    expect(_value(tester, 'HB-bbbb0002'), '12.50');
    // the strain heading comes before its lots, and the strains in the order sent
    final y = (String k) => tester.getTopLeft(find.byKey(ValueKey(k))).dy;
    expect(y('lot-strain-Golden Teacher') < y('lot-row-Golden Teacher|HB-aaaa0001'), isTrue);
    expect(y('lot-row-Golden Teacher|PL-0000a002') < y('lot-strain-Penis Envy'), isTrue);
  });

  testWidgets('a tag for each minor analyte found, and none for a lot without', (tester) async {
    await tester.pumpWidget(_table());
    await _open(tester);
    Finder tagsOf(String row) => find.descendant(of: find.byKey(ValueKey('lot-row-$row')), matching: find.byType(Container));
    expect(find.descendant(of: find.byKey(const ValueKey('lot-row-Golden Teacher|HB-aaaa0001')), matching: find.text('Baeocystin')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('lot-row-Golden Teacher|HB-aaaa0001')), matching: find.text('Aeruginascin')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('lot-row-Penis Envy|HB-bbbb0002')), matching: find.text('Norbaeocystin')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('lot-row-Penis Envy|HB-bbbb0002')), matching: find.text('Norpsilocin')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('lot-row-Penis Envy|HB-bbbb0002')), matching: find.text('Something-new')), findsOneWidget);
    expect(tagsOf('Golden Teacher|PL-0000a002'), findsNothing);
  });

  testWidgets('tapping the heading switches every row to psilocybin, then psilocin, then back to TPE', (tester) async {
    await tester.pumpWidget(_table());
    await _open(tester);

    await _tap(tester, find.byKey(const ValueKey('lot-measure')));
    expect(find.text('Psilocybin mg/g'), findsOneWidget);
    expect([_value(tester, 'HB-aaaa0001'), _value(tester, 'PL-0000a002'), _value(tester, 'HB-bbbb0002')],
        ['7.25', '8.90', '11.00']);

    await _tap(tester, find.byKey(const ValueKey('lot-measure')));
    expect(find.text('Psilocin mg/g'), findsOneWidget);
    // unknown is a dash, never 0
    expect([_value(tester, 'HB-aaaa0001'), _value(tester, 'PL-0000a002'), _value(tester, 'HB-bbbb0002')],
        ['1.00', '—', '1.08']);

    await _tap(tester, find.byKey(const ValueKey('lot-measure')));
    expect(find.text('TPE mg/g'), findsOneWidget);
    expect(_value(tester, 'HB-aaaa0001'), '8.64');
  });

  testWidgets('tapping any number switches them all', (tester) async {
    await tester.pumpWidget(_table());
    await _open(tester);
    await _tap(tester, find.byKey(const ValueKey('lot-value-HB-bbbb0002')));
    expect(find.text('Psilocybin mg/g'), findsOneWidget);
    expect(_value(tester, 'HB-aaaa0001'), '7.25');
  });

  testWidgets('one lot of one strain says so in the singular, and dark mode draws', (tester) async {
    await tester.pumpWidget(_table(lots: [_lots.first], brightness: Brightness.dark));
    expect(find.text('1 lot · 1 strain'), findsOneWidget);
    await _open(tester);
    expect(find.text('Baeocystin'), findsOneWidget);
  });

  test('WC-R7: the tags are the shared rules.yaml analyte_tags, same names in the same order, words and colours', () {
    final shared = _sharedTags();
    expect(analyteTags.keys.toList(), [for (final t in shared) t['name'] as String]);
    for (final t in shared) {
      final light = t['light'] as Map, dark = t['dark'] as Map;
      final mine = analyteTags[t['name']]!;
      expect(mine.word, t['word'], reason: '${t['name']} word');
      expect(mine.lightBg, _argb(light['bg']), reason: '${t['name']} light bg');
      expect(mine.lightFg, _argb(light['fg']), reason: '${t['name']} light fg');
      expect(mine.darkBg, _argb(dark['bg']), reason: '${t['name']} dark bg');
      expect(mine.darkFg, _argb(dark['fg']), reason: '${t['name']} dark fg');
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('WC-R7: every shared tag draws, with its word and its ${brightness.name} colours', (tester) async {
      final shared = _sharedTags();
      final names = [for (final t in shared) t['name'] as String];
      await tester.pumpWidget(_table(
          lots: [MazamaLot(strain: 'Golden Teacher', lot: 'HB-tags0001', tpe: 8, detected: names)],
          brightness: brightness));
      await _open(tester);
      for (final t in shared) {
        final colours = t[brightness.name] as Map;
        final tag = find.byKey(ValueKey('lot-tag-${t['name']}'));
        expect(tag, findsOneWidget, reason: t['name'] as String);
        final word = find.descendant(of: tag, matching: find.text(t['word'] as String));
        expect(word, findsOneWidget, reason: t['name'] as String);
        final box = tester.widget<Container>(tag).decoration as BoxDecoration;
        expect(box.color, Color(_argb(colours['bg'])), reason: '${t['name']} bg');
        expect(tester.widget<Text>(word).style?.color, Color(_argb(colours['fg'])), reason: '${t['name']} fg');
      }
    });
  }

  test('values: two places, a dash when unknown', () {
    expect(formatLotValue(8.6), '8.60');
    expect(formatLotValue(0), '0.00');
    expect(formatLotValue(null), '—');
    expect(analyteWord('norpsilocin'), 'Norpsilocin');
    expect(analyteWord('psilacetin'), 'Psilacetin');
  });
  testWidgets('MI-D20: a strain filter keeps its rows, ignoring case, and the title and count say so', (tester) async {
    await tester.pumpWidget(_table(filter: lotStrainFilter('golden teacher')));
    expect(find.text('Strains in stock: golden teacher'), findsOneWidget);
    expect(find.text('2 of 3 lots'), findsOneWidget); // closed: the filter applies all the same
    await _open(tester);
    expect(_rows(tester), ['Golden Teacher|HB-aaaa0001', 'Golden Teacher|PL-0000a002']);
  });

  testWidgets('MI-D20: a type filter keeps the lots with that type among theirs, under their own strains', (tester) async {
    await tester.pumpWidget(_table(filter: lotTypeFilter('Dehydrated')));
    expect(find.text('Strains in stock: Dehydrated'), findsOneWidget);
    expect(find.text('2 of 3 lots'), findsOneWidget);
    await _open(tester);
    expect(_rows(tester), ['Golden Teacher|HB-aaaa0001', 'Penis Envy|HB-bbbb0002']);
    expect(find.byKey(const ValueKey('lot-strain-Penis Envy')), findsOneWidget);
  });

  testWidgets('a filter that keeps nothing says so', (tester) async {
    await tester.pumpWidget(_table(filter: lotTypeFilter('Gummy')));
    expect(find.text('0 of 3 lots'), findsOneWidget);
    await _open(tester);
    expect(find.text('Nothing in stock for Gummy.'), findsOneWidget);
    expect(find.byKey(const ValueKey('lot-measure')), findsNothing);
  });

  testWidgets('"Unknown" keeps the rows whose strain is not known; a lot under two strains counts once', (tester) async {
    const lots = [
      MazamaLot(strain: '', lot: 'HB-un01'),
      MazamaLot(strain: 'Bluey', lot: 'PL-mix02'),
      MazamaLot(strain: 'Chocolate', lot: 'PL-mix02', types: ['CH']),
    ];
    await tester.pumpWidget(_table(lots: lots));
    expect(find.text('2 lots · 3 strains'), findsOneWidget);
    await _open(tester);
    expect(_rows(tester), ['Unknown|HB-un01', 'Bluey|PL-mix02', 'Chocolate|PL-mix02']);

    await tester.pumpWidget(_table(lots: lots, filter: lotStrainFilter('Unknown')));
    await tester.pumpAndSettle();
    expect(_rows(tester), ['Unknown|HB-un01']);
  });

  testWidgets('a note stands in for the counts until the rows load, in the error colour when they did not',
      (tester) async {
    await tester.pumpWidget(_table(lots: const [], note: 'Loading…'));
    expect(find.text('Loading…'), findsOneWidget);
    await tester.pumpWidget(_table(lots: const [], note: 'Lots did not load: offline', noteIsError: true));
    final t = tester.widget<Text>(find.byKey(const ValueKey('lot-table-subtitle')));
    expect(t.data, 'Lots did not load: offline');
    expect(t.style?.color, isNotNull);
    await _open(tester);
    expect(find.text('Lots did not load: offline'), findsNWidgets(2));
  });
}
