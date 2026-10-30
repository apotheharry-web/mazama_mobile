// The phone's id checks (SM-09), using the patterns generated into id_patterns.g.dart from
// ../mazama_modules/ids/ids.yaml - the same ones the server (idpatterns.py) and mazama_core use. Held to the server's
// own answers by test/package_ids_test.dart (../mazama_modules/ids/vectors/ids.json).
import 'id_patterns.g.dart';

/// A harvest batch or process lot id: HB- or PL- and 5 to 8 hex digits, either case (SM-D7).
bool isLotId(String s) => lotIdPattern.hasMatch(s);

/// A packaged product id: PKPR- and 4 to 16 letters or digits (SM-D8).
bool isPackageId(String s) => packageIdPattern.hasMatch(s);

/// The batch/lot a package was made from, as the state's own record names it: the first of harvestBatchGuid,
/// processLotGuid that is a lot id, else null. The Dart twin of the server's stockdata.product_source.
String? packageSource(Map<String, Object?> record) {
  for (final key in const ['harvestBatchGuid', 'processLotGuid']) {
    final v = record[key];
    if (v is String && isLotId(v)) return v;
  }
  return null;
}
