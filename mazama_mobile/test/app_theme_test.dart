// The app's look (lib/app_theme.dart): Mazama's own colours from the server's app.css, tabular figures, and both
// MaterialApps (the app and the missing-core screen) using it rather than Flutter's default purple.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/app_theme.dart';
import 'package:mazama_mobile/missing_core_app.dart';

void main() {
  test("the colours are the web's: brand green on warm paper, ink text, warm lines, the same red", () {
    final theme = mazamaTheme();
    final scheme = theme.colorScheme;
    expect(scheme.brightness, Brightness.light);
    expect(scheme.primary.toARGB32(), 0xFF3B5D3A);
    expect(scheme.onPrimary.toARGB32(), 0xFFFFFFFF);
    expect(scheme.surface.toARGB32(), 0xFFFBFAF7);
    expect(theme.scaffoldBackgroundColor.toARGB32(), 0xFFFBFAF7);
    expect(scheme.onSurface.toARGB32(), 0xFF1D1D1B);
    expect(scheme.outlineVariant.toARGB32(), 0xFFD9D6CC);
    expect(scheme.error.toARGB32(), 0xFFB3261E);
  });

  test('every text style has tabular figures, so numbers line up down a list', () {
    final text = mazamaTheme().textTheme;
    final styles = {
      'displayLarge': text.displayLarge,
      'headlineSmall': text.headlineSmall,
      'titleLarge': text.titleLarge,
      'titleMedium': text.titleMedium,
      'titleSmall': text.titleSmall,
      'bodyLarge': text.bodyLarge,
      'bodyMedium': text.bodyMedium,
      'bodySmall': text.bodySmall,
      'labelLarge': text.labelLarge,
      'labelSmall': text.labelSmall,
    };
    for (final MapEntry(key: name, value: style) in styles.entries) {
      expect(style?.fontFeatures, contains(const FontFeature.tabularFigures()), reason: name);
    }
  });

  test('cards are flat on the paper, set apart by a warm hairline', () {
    final card = mazamaTheme().cardTheme;
    expect(card.elevation, 0);
    final shape = card.shape as RoundedRectangleBorder;
    expect(shape.side.color.toARGB32(), 0xFFD9D6CC);
  });

  testWidgets('the missing-core screen wears the theme too', (tester) async {
    await tester.pumpWidget(const MissingCoreApp(error: 'x'));
    final context = tester.element(find.text(missingCoreMessage));
    expect(Theme.of(context).colorScheme.primary.toARGB32(), 0xFF3B5D3A);
  });
}
