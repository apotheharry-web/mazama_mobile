// The compact label drawn from a LabelSpec on the phone (plan 08 Task 8; layout: specs/labels/04-label-spec.md).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/label_preview.dart';

/// The canonical_dated golden case's spec (assets/shared/coa/corpus/labels/expected.json), with two optional
/// alkaloids: one above the 0.01 mg line and one just under it.
Map<String, Object?> _spec({Map<String, Object?>? perUnit}) => {
      'spec_version': 2,
      'pkpr': 'PKPR-71C5E6AD',
      'strain': 'Huautla',
      'dose_mg_tpe': 25,
      'net_wt_g': 2.62,
      'tpe_mg_per_g': 9.54,
      'per_unit_mg': perUnit ??
          {'psilocybin': 24.9948, 'psilocin': 0.0, 'baeocystin': 2.8034, 'norbaeocystin': 0.0099, 'norpsilocin': 0.0},
      'psilocybin_from': 'coa',
      'best_by': '2027-08-31',
      'best_by_from': 'name',
      'type_code': 'DH',
      'source': 'PL-de20657a',
      'description': 'Huautla 25 mg TPE DH (2027-08-31)',
    };

Future<void> _pump(WidgetTester tester, Map<String, Object?> spec) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: LabelPreview(spec: spec)))));

void main() {
  testWidgets('shows the printed lines and hides tiny alkaloids', (tester) async {
    await _pump(tester, _spec());

    expect(find.text('Huautla'), findsOneWidget);
    expect(find.text('25 mg Equiv'), findsOneWidget);
    expect(find.text('Lot: 71c5e6ad'), findsOneWidget);
    expect(find.text('Best By: 2027-08-31'), findsOneWidget);
    expect(find.text('Net wt: 2.62 g'), findsOneWidget);
    expect(find.text('Psilocin: 0.00 mg'), findsOneWidget); // always printed, as the server's label does
    expect(find.text('Psilocybin: 24.99 mg'), findsOneWidget);
    expect(find.text('Baeocystin: 2.80 mg'), findsOneWidget);
    expect(find.textContaining('Norbaeocystin'), findsNothing); // 0.0099 mg: not above 0.01
    expect(find.textContaining('Norpsilocin'), findsNothing);
    expect(find.textContaining('Aeruginascin'), findsNothing); // not in the spec at all
    expect(find.text('PREVIEW, not a printable label'), findsOneWidget);
  });

  testWidgets('the right column keeps the printed order', (tester) async {
    await _pump(tester, _spec(perUnit: {'psilocybin': 5.2, 'psilocin': 0.42, 'aeruginascin': 0.05, 'norpsilocin': 0.02}));
    final lines = [
      'Lot: 71c5e6ad',
      'Best By: 2027-08-31',
      'Net wt: 2.62 g',
      'Psilocin: 0.42 mg',
      'Psilocybin: 5.20 mg',
      'Norpsilocin: 0.02 mg',
      'Aeruginascin: 0.05 mg',
    ];
    final ys = [for (final l in lines) tester.getTopLeft(find.text(l)).dy];
    expect(ys, orderedEquals([...ys]..sort()), reason: 'top to bottom in the label\'s order');
  });

  testWidgets('every alkaloid and a long strain name fit the label without overflowing', (tester) async {
    await _pump(tester, {
      ..._spec(perUnit: {'psilocybin': 5.2, 'psilocin': 0.42, 'baeocystin': 1, 'norbaeocystin': 1, 'norpsilocin': 1, 'aeruginascin': 1}),
      'strain': 'Golden Teacher Albino Penis Envy Reverse',
    });
    expect(tester.takeException(), isNull);
    expect(find.text('Aeruginascin: 1.00 mg'), findsOneWidget);
  });

  testWidgets('strain and dose are turned a quarter turn, as on the printed label', (tester) async {
    await _pump(tester, _spec());
    final rotated = find.ancestor(of: find.text('Huautla'), matching: find.byType(RotatedBox));
    expect(rotated, findsOneWidget);
    expect((tester.widget(rotated) as RotatedBox).quarterTurns.isOdd, isTrue);
  });
}
