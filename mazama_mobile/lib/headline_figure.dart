// A page's headline figure: the number large and bold, its unit small and muted beside it ("41 units",
// "221.54 mg TPE"), so the eye lands on the number. It stays one text whose words read as before ("41 units"), for
// a screen reader and for anything that looks the words up.
import 'package:flutter/material.dart';

class HeadlineFigure extends StatelessWidget {
  const HeadlineFigure(this.value, this.unit, {super.key, this.textAlign});

  /// The number, already formatted ("41", "221.54", "15,644").
  final String value;

  /// What it counts ("units", "mg TPE", "mg TPE in all").
  final String unit;

  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: value, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        TextSpan(
            text: ' $unit',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
      textAlign: textAlign,
    );
  }
}
