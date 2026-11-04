// How the app opens a feature built in its own folder under lib/features/<name>/ (FR-11): that folder's entry.dart
// exports `const FeatureEntry entry`, and the generated feature_pages.g.dart lists them by feature name.
import 'package:flutter/widgets.dart';

import 'licenses_client.dart';

/// Builds a feature's tab for the center home, for the signed-in [license].
typedef FeatureTabBuilder = Widget Function(BuildContext context, License license);

/// Builds a feature's page, for the signed-in [license].
typedef FeaturePageBuilder = Widget Function(BuildContext context, License license);

/// The tab and page builders a feature folder offers; a feature with no tab leaves [tab] null, and so for [page].
class FeatureEntry {
  const FeatureEntry({this.tab, this.page});

  final FeatureTabBuilder? tab;
  final FeaturePageBuilder? page;
}
