// A copy of the generated feature table with some features switched off on the phone, for the tests of each gate
// (specs/features FR-3). The phone's real table is fixed per release (FT-D2); only tests pass another.
import 'package:mazama_mobile/features.g.dart';

Map<String, Feature> featuresWithOff(List<String> names) {
  for (final n in names) {
    if (!features.containsKey(n)) throw ArgumentError('no feature $n');
  }
  return {
    for (final e in features.entries)
      e.key: names.contains(e.key)
          ? Feature(
              name: e.value.name,
              id: e.value.id,
              what: e.value.what,
              built: e.value.built,
              onWeb: e.value.onWeb,
              onPhone: const [],
              pages: e.value.pages,
              uses: e.value.uses,
              shared: e.value.shared,
              logic: e.value.logic,
              item: e.value.item,
            )
          : e.value,
  };
}
