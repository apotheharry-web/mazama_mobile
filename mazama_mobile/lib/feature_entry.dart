// How the app opens a feature built in its own folder under lib/features/<name>/ (FR-11): that folder's entry.dart
// exports `const FeatureEntry entry`, and the generated feature_pages.g.dart lists them by feature name.
import 'package:flutter/widgets.dart';

import 'licenses_client.dart';
import 'packages_client.dart' show PkprGroup;

/// Builds a feature's tab for the center home, for the signed-in [license].
typedef FeatureTabBuilder = Widget Function(BuildContext context, License license);

/// Builds a feature's page, for the signed-in [license].
typedef FeaturePageBuilder = Widget Function(BuildContext context, License license);

/// What the cart hands a feature that takes over its PKPR input: the field's own controller and focus (so the cart's
/// Add, scan and refocus after an add keep working), the stock it can add from, the field's error, the cart's Add and
/// the cart's own buttons that sit beside the field.
class PkprInputArgs {
  const PkprInputArgs({
    required this.controller,
    required this.focusNode,
    required this.stock,
    required this.errorText,
    required this.onAdd,
    required this.actions,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// The center's stock, one entry per PKPR; null while it isn't loaded.
  final List<PkprGroup>? stock;
  final String? errorText;

  /// Adds what the field holds, as the cart's Add button does.
  final VoidCallback onAdd;

  /// The cart's Scan and Add buttons, to sit beside the field.
  final Widget actions;
}

/// Builds the cart's PKPR row (the field and the cart's [PkprInputArgs.actions]) and anything the feature shows with it.
typedef PkprInputBuilder = Widget Function(BuildContext context, PkprInputArgs args);

/// What the cart's add-line screen closes with: the units of each dose to add (or, editing, the edited line's dose
/// count and the other dose's units to add), and the price each when the screen asked for one.
class LineChoice {
  const LineChoice({required this.primary, required this.secondary, this.priceCentsEach});

  final int primary, secondary;
  final int? priceCentsEach;
}

/// A price the worker typed, checked by the cart: the price each in cents, or the words to show when it isn't one.
typedef LinePriceCheck = ({int? cents, String? error}) Function({required bool perMg, required String text});

/// What the cart hands a feature that takes over its add-line screen: the product and its label, the counts to start
/// from, each dose's limits, and the price check when the cart is pricing each line.
class LineEditorArgs {
  const LineEditorArgs({
    required this.group,
    required this.label,
    required this.primary,
    required this.secondary,
    required this.editing,
    required this.maxUnitsPerLine,
    required this.stockLeft,
    required this.price,
    this.priceCentsEach,
    this.perMgLabel = 'Price per mg (TPE)',
  });

  final PkprGroup group;

  /// The package's label picture (the server's, else the phone's drawing), as the cart shows it.
  final Widget label;

  /// The counts the screen starts from: 0 and 0 for an add; the edited line's own dose holds its count.
  final int primary, secondary;

  /// True when a line already in the cart is being edited (Save, not Add).
  final bool editing;

  /// The server's units per line.
  final int maxUnitsPerLine;

  /// The units of the product the cart can still take: its stock less the cart's other lines of it.
  final int stockLeft;

  /// The price check; null when the cart prices every line itself (a cart-wide mode): no price is asked for.
  final LinePriceCheck? price;

  /// The edited line's price each, to start the price from.
  final int? priceCentsEach;

  /// The price-per-mg field's label for this product (TPE, or psilocybin when that is its only figure).
  final String perMgLabel;
}

/// Builds the cart's add-line screen (a dialog's content), which closes with a [LineChoice] or nothing.
typedef LineEditorBuilder = Widget Function(BuildContext context, LineEditorArgs args);

/// The builders a feature folder offers: its tab for the center home, its page, its PKPR input for the cart, which the
/// cart uses in place of its own keyboard field, and its add-line screen, which the cart opens in place of its own
/// dialog, while the feature is on. Each is null when the feature has none.
class FeatureEntry {
  const FeatureEntry({this.tab, this.page, this.pkprInput, this.lineEditor});

  final FeatureTabBuilder? tab;
  final FeaturePageBuilder? page;
  final PkprInputBuilder? pkprInput;
  final LineEditorBuilder? lineEditor;
}
