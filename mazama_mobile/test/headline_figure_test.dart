// A page's headline figure (lib/headline_figure.dart): the number large and bold, its unit small and muted, still
// one text whose words read as they did ("41 units").
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/app_theme.dart';
import 'package:mazama_mobile/headline_figure.dart';

void main() {
  testWidgets('reads as one text, the number larger and bolder than its muted unit', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: mazamaTheme(),
      home: const Scaffold(body: HeadlineFigure('221.54', 'mg TPE')),
    ));
    expect(find.text('221.54 mg TPE'), findsOneWidget);
    final text = tester.widget<Text>(find.text('221.54 mg TPE'));
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.map((s) => s.text), ['221.54', ' mg TPE']);
    final number = spans[0].style!, unit = spans[1].style!;
    expect(number.fontSize!, greaterThan(unit.fontSize!));
    expect(number.fontWeight, FontWeight.w700);
    expect(unit.color!.toARGB32(), MazamaColors.muted.toARGB32());
  });
}
