// What the phone may sell (SM-10): the shared core's rule (mazama_core::selling, specs/core row 4), the same one the
// server's own sale check applies before anything is sent (mazama_sales/src/mazama_sales/recordrules.py's
// unsellable_reason calls it through the core's Python binding). Same conditions, same order, same reason texts, held
// to the golden vectors in ../../mazama_modules/selling/vectors/ (sellability.json and sellability_cases.json, the
// rows the owner decided on 2026-10-31; see test/sellability_test.dart). Nothing of the rule is written here.
//
// Applied to a raw state-system package record: the phone's state-only fallback (state_packages_client.dart)
// filters with it. The normal path, the server's /p/packages, already leaves out whatever this refuses.
//
// Fails closed (SL-15): when the core can't answer (not loaded, an error, a reply that isn't one answer per record of
// the right shape), every record is refused with [coreFailedReason], never sold.
//
// Expired stock is NOT refused (SM-D3, specs/shared-modules/decisions.md): neither side ever did.
import 'package:flutter/foundation.dart' show debugPrint;

import 'mazama_core.dart';

/// The reason a record is refused when this phone's core can't answer (SL-15).
const coreFailedReason = "this phone can't check this package (its shared core failed), so it can't be sold here";

/// The keys of a record the rule reads; nothing else is sent to the core.
const _readKeys = ['productGuid', 'quantity', 'zeroOut', 'locked', 'reasonLocked', 'flagged', 'reasonFlagged', 'pendingTransfer'];

/// Why each of [records] can't be sold [qty] at a time (null: it can), in order, in one call to [core] (default:
/// this app's, [MazamaCore.instance]). Never throws: a core that fails refuses ([coreFailedReason]). When the list's
/// call fails, each record is asked alone, so one record the core can't take (a non-finite number, a lone surrogate)
/// refuses only itself and the rest of the stock stays (row 4 review, I2).
List<String?> unsellableReasons(List<Map<String, Object?>> records, {int qty = 1, CoreFunctions? core}) {
  if (records.isEmpty) return const [];
  final all = _ask(records, qty, core);
  if (all != null) return all;
  debugPrint('sellability: the core could not judge a list of ${records.length}; judging each record alone');
  if (records.length == 1) return const [coreFailedReason];
  // a record's own answer (null: it sells) when the core gives one, else the refusal; never `?.single ??`, which would
  // read a record that sells (null) as one the core couldn't answer
  return [
    for (final r in records)
      if (_ask([r], qty, core) case final answer?) answer.single else coreFailedReason,
  ];
}

/// The core's reasons for [records], or null when it can't answer them (SL-15).
List<String?>? _ask(List<Map<String, Object?>> records, int qty, CoreFunctions? core) {
  try {
    final reply = (core ?? MazamaCore.instance).sellingSellable({
      'checks': [
        for (final r in records) {'record': {for (final k in _readKeys) if (r.containsKey(k)) k: r[k]}, 'qty': qty},
      ],
    });
    if (reply.length != records.length) return null;
    final out = <String?>[];
    for (final a in reply) {
      if (a is! Map) return null;
      final reason = a['reason'];
      if ((reason != null && reason is! String) || a['sellable_record'] is! bool) return null;
      out.add(reason as String?);
    }
    return out;
  } catch (_) {
    // StateError (no core loaded), MazamaCoreError, a record jsonEncode can't write, or anything else: no answer
    return null;
  }
}

/// Why [record] can't be sold [qty] at a time, or null when it can ([unsellableReasons] of one record).
String? unsellableReason(Map<String, Object?> record, {int qty = 1, CoreFunctions? core}) =>
    unsellableReasons([record], qty: qty, core: core).single;

bool isSellable(Map<String, Object?> record, {int qty = 1, CoreFunctions? core}) =>
    unsellableReason(record, qty: qty, core: core) == null;

/// Why [qty] units of package [guid] can't be sold from [record], the state's record for it as read just now (null:
/// not in the center's stock), or null when they can - the sale worker's own words (salejobs.line_refusal on the
/// server, held to assets/shared/selling/vectors/sale_check.json). CartPage checks every lot a sale draws from with
/// this when its stock is older than ResilienceOptions.stockRecheckAge (SM-25). A core that fails refuses (SL-15).
String? saleLineRefusal(Map<String, Object?>? record, String guid, int qty, {CoreFunctions? core}) {
  if (record == null || record['productGuid'] != guid) {
    return "$guid is no longer in the state system's inventory for this service center.";
  }
  final why = unsellableReason(record, qty: qty, core: core);
  return why == null ? null : '$guid: $why.';
}
