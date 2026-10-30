// How the phone reads fields of the state's own records, by the same rules as the server's state/mapping.py (SM-21),
// so a record the server skips is skipped here too, and an odd one (an id written as a string) is read, not a crash.
// The key of a packaged-product record is the shared core's (specs/core row 10), held to the server's answers by
// test/state_records_test.dart (../mazama_modules/contracts/vectors/). wholeNumber and textOrNull stay for the other
// fields this app reads (their own rows' turn comes later).

import 'dart:convert' show JsonUnsupportedObjectError;

import 'mazama_core.dart';

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

typedef PackageKey = ({int stateId, String pkpr});

/// The state id and PKPR of each GetPackagedProducts record in [records], in order, or null for one the server skips
/// (no whole-number id, or no PKPR): the shared core's rule (records.package_keys, specs/core row 10, SM-21), the one
/// the server's mapping.packaged_product asks too, in one call; [core] defaults to this app's ([MazamaCore.instance]).
/// Only the two fields the rule reads are sent. A core that can't answer skips every record, as the server does for
/// one it can't read, never a crash.
List<PackageKey?> packagedProductKeys(List<Map<String, Object?>> records, {CoreFunctions? core}) {
  if (records.isEmpty) return const [];
  final reader = core ?? MazamaCore.instance;
  try {
    final got = reader.recordsPackageKeys({
      'records': [
        for (final r in records) {'id': r['id'], 'productGuid': r['productGuid']}
      ]
    });
    if (got.length != records.length) return List.filled(records.length, null);
    return [
      for (final a in got)
        if (a is Map && a['state_id'] is int && a['pkpr'] is String) (stateId: a['state_id'] as int, pkpr: a['pkpr'] as String) else null
    ];
  } on MazamaCoreError {
    return List.filled(records.length, null);
  } on JsonUnsupportedObjectError {
    return List.filled(records.length, null);
  }
}

/// [packagedProductKeys] for one record.
PackageKey? packagedProductKey(Map<String, Object?> record, {CoreFunctions? core}) =>
    packagedProductKeys([record], core: core).single;
