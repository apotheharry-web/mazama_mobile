// Scan matching on the phone, for when the Mazama server can't be reached: the same matcher the server's
// /p/scan-match/{state_id} runs (coa_core's scan.rs - the server through its Python binding, this through the C
// interface, coa_core_ffi.dart), run against the cart's own copy of the center's stock instead of the server's
// mirror. Never re-implemented in Dart: this only builds coa_core's input the way the server's public_scan_match
// builds it, and turns the answer into the same ScanMatchResult the server's reply becomes (scan_match_client.dart),
// so CartPage handles both alike.
//
// The server's route, step by step (mazama_sales/src/mazama_sales/web/stock_pages.py, public_scan_match):
// - the first scanMatchMaxLines lines, scanMatchMaxLineChars characters of each, joined into one text;
// - the packages grouped by productGuid; find_ids over their ids; each match named by its first record's
//   description, its stock the units of its sellable records (unsellable_reason - sellability.dart here);
// - when nothing matched and the text wasn't typed: closest over the sellable records only, each with its best-by,
//   each guess named by the record it scored best on.
// The cart's stock (/p/packages, or the state-system fallback) already leaves out what can't be sold, so in practice
// every record here is sellable; the check is kept so the two answers can't drift apart.
import 'api_contract.g.dart';
import 'coa_core_ffi.dart';
import 'packages_client.dart';
import 'product_names.dart';
import 'scan_match_client.dart';
import 'sellability.dart';

/// Matches a label's [lines] against [inventory] on this phone. Null when it can't: [core] is null (coa_core isn't
/// built into this app) or the library can't answer (one built before scan matching moved into coa_core).
typedef LocalScanMatcher = ScanMatchResult? Function(List<Package> inventory, List<String> lines, {bool typed});

/// [LocalScanMatcher] with this app's own coa_core (product_names.dart's sharedCoaCore).
ScanMatchResult? localScanMatch(List<Package> inventory, List<String> lines, {bool typed = false}) =>
    localScanMatchWith(sharedCoaCore(), inventory, lines, typed: typed);

/// [localScanMatch] with the library given ([core]: null when it isn't built). Never throws.
ScanMatchResult? localScanMatchWith(CoaCore? core, List<Package> inventory, List<String> lines, {bool typed = false}) {
  if (core == null) return null;
  final text = [
    for (final l in lines.take(scanMatchMaxLines)) l.length > scanMatchMaxLineChars ? l.substring(0, scanMatchMaxLineChars) : l
  ].join('\n');
  final byGuid = <String, List<Package>>{};
  for (final p in inventory) {
    if (p.productGuid.isNotEmpty) byGuid.putIfAbsent(p.productGuid, () => []).add(p);
  }
  List<Package> sellable(List<Package> recs) => [for (final r in recs) if (unsellableReason({'quantity': r.exactQuantity}) == null) r];
  String name(String guid) => byGuid[guid]!.first.description.isEmpty ? guid : byGuid[guid]!.first.description;
  int stock(List<Package> recs) => recs.fold<num>(0, (sum, r) => sum + r.exactQuantity).toInt();
  try {
    final matches = [
      for (final m in core.scanFindIds([text], byGuid.keys.toList(), typed: typed))
        if (byGuid[m['guid']] case final recs?)
          ScanMatch(
            guid: m['guid'] as String,
            name: name(m['guid'] as String),
            dist: (m['dist'] as num).toInt(),
            line: m['line'] as String,
            stock: stock(sellable(recs)),
            sellable: sellable(recs).isNotEmpty,
          ),
    ];
    final guesses = <ScanGuess>[];
    if (matches.isEmpty && !typed) {
      final ok = {for (final e in byGuid.entries) if (sellable(e.value) case final s when s.isNotEmpty) e.key: s};
      final packages = [
        for (final e in ok.entries)
          {
            'guid': e.key,
            'records': [
              for (final r in e.value)
                {
                  'weightPerUnit': r.weightPerUnit,
                  'analyteWeight': r.analyteWeight,
                  'description': r.description,
                  'quantity': r.exactQuantity,
                  'expires': r.expires == null ? null : _isoDate(r.expires!),
                }
            ],
          }
      ];
      for (final g in core.scanClosest([text], packages)) {
        final guid = g['guid'] as String;
        final record = ok[guid]![(g['record'] as num).toInt()];      // the server names a guess by its best record
        guesses.add(ScanGuess(
          guid: guid,
          name: record.description.isEmpty ? guid : record.description,
          score: (g['score'] as num).toInt(),
          why: [for (final w in g['why'] as List) w.toString()],
          stock: (g['stock'] as num).toInt(),
        ));
      }
    }
    return ScanMatchResult(matches: matches, guesses: guesses);
  } catch (_) {
    // CoaCoreUnavailable, ArgumentError from a library without the scan functions, or a reply of the wrong shape:
    // this phone can't match, and the caller says the server couldn't be reached, as before
    return null;
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
