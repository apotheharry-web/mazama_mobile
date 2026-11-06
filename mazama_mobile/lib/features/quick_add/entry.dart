// The one-screen add's entry point (specs/quick-add, FR-11): the cart's add-line screen, which the cart opens in place
// of its own dialog while this feature is on for the center's license (in debug builds only until it is released).
import 'package:flutter/widgets.dart';

import '../../feature_entry.dart';
import 'quick_add.dart';

const FeatureEntry entry = FeatureEntry(lineEditor: _editor);

Widget _editor(BuildContext context, LineEditorArgs args) => QuickAddScreen(args: args);
