// What the phone may sell (SM-10): the Dart twin of mazama_sales/src/mazama_sales/stockdata.py's unsellable_reason,
// the rule the server's own sale check applies before anything is sent. Same conditions, same order, same reason
// texts, held to the golden vectors in ../../mazama_modules/selling/vectors/sellability.json (generated from the
// server's Python; see test/sellability_test.dart).
//
// Applied to a raw state-system package record: the phone's state-only fallback (state_packages_client.dart)
// filters with it. The normal path, the server's /p/packages, already leaves out whatever this refuses.
//
// Expired stock is NOT refused (SM-D3, specs/shared-modules/decisions.md): neither side ever did.

/// Python's truthiness, because the server's rule is written with it: null, false, 0, '' and empty
/// collections are false.
bool _truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is Iterable) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

/// How Python's str() shows a JSON value, so a reason reads exactly as the server's does.
String _py(Object? v) => v == null ? 'None' : v is bool ? (v ? 'True' : 'False') : v.toString();

/// Why [record] can't be sold [qty] at a time, or null when it can.
String? unsellableReason(Map<String, Object?> record, {int qty = 1}) {
  if (_truthy(record['pendingTransfer'])) return 'package has a pending transfer';
  if (_truthy(record['locked'])) {
    final why = record['reasonLocked'];
    return 'package is locked (${_truthy(why) ? why : 'no reason'})';
  }
  if (_truthy(record['flagged'])) {
    final why = record['reasonFlagged'];
    return 'package is flagged (${_truthy(why) ? why : 'no reason'})';
  }
  final quantity = record['quantity'];
  final units = quantity is num ? quantity : 0;
  if (_truthy(record['zeroOut']) || units < qty) {
    return 'no units remaining (system reports quantity=${_py(quantity)}, zeroOut=${_py(record['zeroOut'])})';
  }
  return null;
}

bool isSellable(Map<String, Object?> record, {int qty = 1}) => unsellableReason(record, qty: qty) == null;

/// Why [qty] units of package [guid] can't be sold from [record], the state's record for it as read just now (null:
/// not in the center's stock), or null when they can - the sale worker's own words (salejobs.line_refusal on the
/// server, held to assets/shared/selling/vectors/sale_check.json). CartPage checks every lot a sale draws from with
/// this when its stock is older than ResilienceOptions.stockRecheckAge (SM-25).
String? saleLineRefusal(Map<String, Object?>? record, String guid, int qty) {
  if (record == null || record['productGuid'] != guid) {
    return "$guid is no longer in the state system's inventory for this service center.";
  }
  final why = unsellableReason(record, qty: qty);
  return why == null ? null : '$guid: $why.';
}
