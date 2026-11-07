// The app's one look: Mazama's own colours (the server's web pages use the same forest green on warm paper, ink
// text and fine warm lines, web/static/app.css), set once here so every page, dialog and sheet takes them instead of
// Flutter's default purple. Pages keep reading Theme.of(context); nothing here changes what a page says or does.
//
// Figures are tabular everywhere (every digit the same width), so units, mg and dollars line up down a list and a
// total doesn't jiggle as it changes.
import 'package:flutter/material.dart';

/// Mazama's colours, as the server's app.css names them.
abstract final class MazamaColors {
  /// The brand green (`--brand`): primary buttons, the selected tab, focus.
  static const forest = Color(0xFF3B5D3A);

  /// The page background (`--bg`): warm paper rather than a cold white.
  static const paper = Color(0xFFFBFAF7);

  /// Raised surfaces (`--surf`): cards and sheets sit just above the paper.
  static const surface = Color(0xFFFCFCFB);

  /// Striped and grouped rows (`--stripe`): section headers, selected segments' neighbours.
  static const stripe = Color(0xFFF0EDE4);

  /// Text (`--fg`).
  static const ink = Color(0xFF1D1D1B);

  /// Secondary text (`--muted`).
  static const muted = Color(0xFF6B6A64);

  /// Hairlines and outlines (`--line`).
  static const line = Color(0xFFD9D6CC);

  /// Errors and shortfalls, the same red as the web's.
  static const error = Color(0xFFB3261E);
}

/// The light theme the app runs in.
ThemeData mazamaTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: MazamaColors.forest,
    primary: MazamaColors.forest,
    onPrimary: Colors.white,
    // a pale moss for selected segments, chips and the selected stock row: clearly the brand, quiet enough to read on
    primaryContainer: const Color(0xFFDCE7D6),
    onPrimaryContainer: const Color(0xFF14291A),
    secondaryContainer: const Color(0xFFDCE7D6),
    onSecondaryContainer: const Color(0xFF14291A),
    surface: MazamaColors.paper,
    onSurface: MazamaColors.ink,
    onSurfaceVariant: MazamaColors.muted,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: MazamaColors.surface,
    surfaceContainer: const Color(0xFFF5F3EE),
    surfaceContainerHigh: MazamaColors.stripe,
    surfaceContainerHighest: const Color(0xFFEAE6DB),
    outline: const Color(0xFF8E8B82),
    outlineVariant: MazamaColors.line,
    error: MazamaColors.error,
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final text = _tabular(base.textTheme).copyWith(
    titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
    titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
  );
  final textTheme = _tabular(text);

  const radius = 14.0;
  final roundedBorder = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

  return base.copyWith(
    textTheme: textTheme,
    scaffoldBackgroundColor: MazamaColors.paper,
    appBarTheme: AppBarThemeData(
      backgroundColor: MazamaColors.paper,
      foregroundColor: MazamaColors.ink,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(color: MazamaColors.ink),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: MazamaColors.forest,
      unselectedLabelColor: MazamaColors.muted,
      labelStyle: textTheme.titleSmall,
      unselectedLabelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
      indicatorColor: MazamaColors.forest,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: MazamaColors.line,
    ),
    // flat cards on the paper, set apart by a hairline rather than a shadow
    cardTheme: CardThemeData(
      color: MazamaColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: const BorderSide(color: MazamaColors.line),
      ),
    ),
    dividerTheme: const DividerThemeData(color: MazamaColors.line, thickness: 1),
    listTileTheme: const ListTileThemeData(iconColor: MazamaColors.muted),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        textStyle: textTheme.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 44),
        foregroundColor: MazamaColors.forest,
        side: const BorderSide(color: MazamaColors.line),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: MazamaColors.forest,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    // segments shrink their padding so three choices fit across a phone without their words breaking
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        textStyle: WidgetStatePropertyAll(textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
        side: const WidgetStatePropertyAll(BorderSide(color: MazamaColors.line)),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      labelStyle: const TextStyle(color: MazamaColors.muted),
      floatingLabelStyle: WidgetStateTextStyle.resolveWith((states) => TextStyle(
            color: states.contains(WidgetState.error)
                ? MazamaColors.error
                : states.contains(WidgetState.focused)
                    ? MazamaColors.forest
                    : MazamaColors.muted,
          )),
      enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: MazamaColors.line, width: 1.5)),
      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: MazamaColors.forest, width: 2)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: MazamaColors.stripe,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: textTheme.labelMedium?.copyWith(color: MazamaColors.ink, fontWeight: FontWeight.w600),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: MazamaColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: MazamaColors.surface,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: MazamaColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: roundedBorder,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: MazamaColors.ink,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: MazamaColors.forest),
  );
}

/// [theme] with every style's figures tabular.
TextTheme _tabular(TextTheme theme) {
  const features = [FontFeature.tabularFigures()];
  TextStyle? t(TextStyle? s) => s?.copyWith(fontFeatures: features);
  return theme.copyWith(
    displayLarge: t(theme.displayLarge),
    displayMedium: t(theme.displayMedium),
    displaySmall: t(theme.displaySmall),
    headlineLarge: t(theme.headlineLarge),
    headlineMedium: t(theme.headlineMedium),
    headlineSmall: t(theme.headlineSmall),
    titleLarge: t(theme.titleLarge),
    titleMedium: t(theme.titleMedium),
    titleSmall: t(theme.titleSmall),
    bodyLarge: t(theme.bodyLarge),
    bodyMedium: t(theme.bodyMedium),
    bodySmall: t(theme.bodySmall),
    labelLarge: t(theme.labelLarge),
    labelMedium: t(theme.labelMedium),
    labelSmall: t(theme.labelSmall),
  );
}
