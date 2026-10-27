// How the phone reads fields of the state's own records, by the same rules as the server's state/mapping.py (SM-21),
// so a record the server skips is skipped here too, and an odd one (an id written as a string) is read, not a crash.
// Held to the server's answers by test/state_records_test.dart (../mazama_modules/contracts/vectors/).

final _decimal = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

/// A whole number, as the server's mapping.whole reads one: an int, a float with no fraction, or a string of
/// one; null for anything else (a fraction, a boolean, blank, not a number).
int? wholeNumber(Object? v) {
  if (v == null || v is bool) return null;
  num? n;
  if (v is num) {
    n = v;
  } else if (v is String && _decimal.hasMatch(v.trim())) {
    n = num.tryParse(v.trim());
  }
  if (n == null || !n.isFinite || n != n.truncate()) return null;
  return n.toInt();
}

/// A field as trimmed text, or null when absent or blank - the server's mapping.text.
String? textOrNull(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

/// The state id and PKPR of a GetPackagedProducts record, or null for a record the server skips
/// (mapping.packaged_product: no whole-number id, or no PKPR).
({int stateId, String pkpr})? packagedProductKey(Map<String, Object?> record) {
  final id = wholeNumber(record['id']);
  final pkpr = textOrNull(record['productGuid']);
  if (id == null || pkpr == null) return null;
  return (stateId: id, pkpr: pkpr);
}
