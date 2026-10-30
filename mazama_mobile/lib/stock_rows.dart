// Where the stock page's rows and par levels come from (SP-R12, SP-R13, SP-D6, SP-D9, SP-D10), most complete first:
//   1. online: the merged inventory the cart uses (merged_inventory.dart): the lots the Mazama server's /p/packages
//      returned (it leaves out what it won't sell, SP-D9), with the server's strain, mazama, expired, exact mg TPE
//      and name, and the state's live quantity when the state answers too (SP-D10); charts in mg TPE;
//   2. the server unreachable, or the center not set up there (404): the state's own records (stockRowsFromState
//      below), marked partial, charts in mg psilocybin (weight per unit x the state's analyteWeight), never TPE,
//      which only the server's lab reports give. A record the server wouldn't sell (locked, flagged, pending a
//      transfer: sellability.dart, the server's own rule) is left out here too (SP-D9) and listed as held back;
//   3. neither answered: the last rows drawn on this phone, with their time; with none, a message (or "sign in
//      again" when the state refused an expired sign-in).
// Whenever the state answered, the records it won't sell come back as [StockLoad.heldBack] for "Other stock", with the
// server's words for why (held_back_reason). Mazama's licenses (/p/center-status) are fetched every time, best effort, and kept for 2. Par comes from the
// server, else, while the server can't be reached (server_error.dart's rule; a 4xx is still an error), from the copy
// last fetched with when it was (read-only: nothing can be saved without the server, sync/server_read.dart), kept in the
// sync engine's par dataset (lib/sync/sync_datasets.dart). Every successful stock read is kept for the next time as the
// center's stock_rows dataset, and Mazama's licenses as its mazama_licenses dataset (specs/phone-sync Task 10: before,
// stock_cache_store.dart's document, moved there by sync_migration.dart).
import 'dart:convert';

import 'merged_inventory.dart';
import 'package_ids.dart';
import 'packages_client.dart';
import 'sellability.dart';
import 'sync/server_read.dart';
import 'session.dart' show SessionExpired;
import 'state_records.dart';
import 'stock_summary.dart';
import 'sync/sync_datasets.dart';

/// What the stock page draws: the rows, the mg mode they are charted in, whether they are only part of the
/// picture (no server, SP-R13), why (the center isn't set up on the server; the state's sign-in has expired) and,
/// when they are the last ones drawn on this phone rather than a fresh read, when that was.
class StockLoad {
  const StockLoad(this.rows,
      {this.mgMode = 'tpe',
      this.partial = false,
      this.drawnAt,
      this.notSetUp = false,
      this.signInNeeded = false,
      this.serverQuantities = false,
      this.heldBack = const []});

  final List<StockRow> rows;
  final String mgMode;
  final bool partial;
  final DateTime? drawnAt;

  /// The Mazama server answered that it has no such service center (404).
  final bool notSetUp;

  /// The state system's sign-in has expired and couldn't be renewed: the worker has to sign in again.
  final bool signInNeeded;

  /// Online, but the state didn't answer: the quantities are the Mazama server's, as of its last sync (SP-D10).
  final bool serverQuantities;

  /// Packages with units on hand that can't be sold (SP-D9), for "Other stock": each row and why, in the server's
  /// words ("locked (Recall)", "flagged (no reason)", "pending transfer").
  final List<({StockRow row, String reason})> heldBack;
}

/// Why a package record with units on hand won't be sold, in the few words the server's "Other stock" uses
/// (stockdata.held_back_reason: unsellable_reason without "package is/has a"); null when it has none on hand, or sells.
String? heldBackReason(Map<String, Object?> record) {
  final q = record['quantity'];
  if (record['zeroOut'] == true || !(q is num && q > 0)) return null;
  final why = unsellableReason(record);
  if (why == null) return null;
  var w = why;
  for (final prefix in ['package ', 'is ', 'has a ']) {
    if (w.startsWith(prefix)) w = w.substring(prefix.length);
  }
  return w;
}

/// Neither the server nor the state system answered, and nothing was drawn on this phone before. Says only the state's
/// part: the app-wide banner says Mazama's server can't be reached (server_link.dart, README R87).
class StockUnavailable implements Exception {
  @override
  String toString() => "The state system can't be reached, and this phone hasn't drawn this center's stock before.";
}

/// The server can't be asked and the state's sign-in has expired, with nothing drawn here before.
class StockSignInNeeded implements Exception {
  @override
  String toString() => "Your state system sign-in has expired: sign in again to see this center's stock.";
}

final _dose = RegExp(r'(?<![0-9.])\d{1,4}(?:\.\d{1,2})?\s*mg\b', caseSensitive: false);
final _trailingDate = RegExp(r'\(\s*(\d{4})-(\d\d)-(\d\d)\s*\)\s*$');

/// The expiry date in a product name, as the server's names.parse_product_name reads it: a "(YYYY-MM-DD)" at the very
/// end, after the dose in mg, in a name that starts with a strain ("GT 5 mg TPE CH (2027-02-03)"); null otherwise.
DateTime? nameDate(String? name) {
  final t = (name ?? '').trim();
  final d = _dose.firstMatch(t);
  if (d == null || !RegExp('[A-Za-z]').hasMatch(t.substring(0, d.start))) return null;
  final m = _trailingDate.firstMatch(t.substring(d.end));
  if (m == null) return null;
  final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), day = int.parse(m.group(3)!);
  final date = DateTime.utc(y, mo, day);
  return date.year == y && date.month == mo && date.day == day ? date : null; // 2027-02-30 is no date
}

/// SM-18 (rules.yaml expiry.expired_after_days = 1): expired from the day after its date, never on it.
bool expiredOn(DateTime expires, DateTime today) {
  final day = DateTime.utc(today.year, today.month, today.day);
  return !day.isBefore(DateTime.utc(expires.year, expires.month, expires.day).add(const Duration(days: 1)));
}

double? _number(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// The state's GetPackagedProducts records as stock rows (SP-R13). [mazamaLicenses]: Mazama's manufacturer
/// licenses (lower-case), from the server's last /p/center-status; an empty set means none is configured, and the
/// server then counts every package as Mazama's, so this does too; null (never fetched) counts none. A producer
/// rule naming Mazama is server data, so "Mazama only" can miss those few offline. Expired from the date at the end
/// of the product name when there is one ([nameDate]). [strainOf] reads the strain in a name (product_names.dart);
/// without it, ''. unitMgTpe is always null: the charts are in mg psilocybin.
List<StockRow> stockRowsFromState(
  List<Map<String, Object?>> stateRecords,
  Set<String>? mazamaLicenses,
  DateTime today, {
  String Function(String? name)? strainOf,
}) {
  final rows = <StockRow>[];
  final keys = packagedProductKeys(stateRecords);
  for (var i = 0; i < stateRecords.length; i++) {
    final r = stateRecords[i];
    final key = keys[i];
    // SM-21: a record the server skips; SP-D9: one it won't sell (locked, flagged, pending a transfer, no units)
    if (key == null || !isSellable(r)) continue;
    rows.add(_stateRow(r, key, mazamaLicenses, today, strainOf));
  }
  return rows;
}

/// The state records with units on hand that [isSellable] refuses, as rows with the server's reason (SP-D9).
List<({StockRow row, String reason})> heldBackFromState(
  List<Map<String, Object?>> stateRecords,
  Set<String>? mazamaLicenses,
  DateTime today, {
  String Function(String? name)? strainOf,
}) =>
    [
      for (final (i, key) in packagedProductKeys(stateRecords).indexed)
        if (key != null)
          if (heldBackReason(stateRecords[i]) case final why?)
            (row: _stateRow(stateRecords[i], key, mazamaLicenses, today, strainOf), reason: why),
    ];

StockRow _stateRow(Map<String, Object?> r, ({int stateId, String pkpr}) key, Set<String>? mazamaLicenses, DateTime today,
    String Function(String? name)? strainOf) {
  final name = textOrNull(r['description']);
  final license = (textOrNull(r['manufacturerLicenseId']) ?? '').toLowerCase();
  final date = nameDate(name);
  return StockRow(
    productGuid: key.pkpr,
    id: key.stateId,
    quantity: _number(r['quantity']) ?? 0,
    zeroOut: r['zeroOut'] == true,
    expired: date != null && expiredOn(date, today),
    mazama: mazamaLicenses == null ? false : (mazamaLicenses.isEmpty || mazamaLicenses.contains(license)),
    strain: strainOf?.call(name) ?? '',
    description: name ?? '',
    weightPerUnit: _number(r['weightPerUnit']),
    analyteWeight: _number(r['analyteWeight']),
    type: stateTypeOf(r),
  );
}

/// A kind word in a record's name or state product type -> its code (mazama_modules/names/names.yaml kind_keywords,
/// the server's names_table.KIND_KEYWORDS).
const List<(String, String)> stockKindKeywords = [('freeze', 'FD'), ('dehydrat', 'DH'), ('homogen', 'HG')];

/// What a package nothing else names was made from -> its kind, by the owner's rule (the server's
/// stockdata.SOURCE_KIND): a harvest batch is dehydrated, a process lot homogenized.
const Map<String, String> stockSourceKinds = {'HB-': 'DH', 'PL-': 'HG'};

/// A state record's kind code, the server's Stock.package_code as far as the state's record says: the code in its
/// name or an edible word in it ([stockTypeOf]); else a kind word in its name or product type; else what it was made
/// from ([stockSourceKinds]); else 'WF' for a whole fungi product type; else null (unknown).
String? stateTypeOf(Map<String, Object?> r) {
  final name = textOrNull(r['description']) ?? '';
  final named = stockTypeOf(StockRow(productGuid: '', id: 0, quantity: 0, description: name));
  if (named.isNotEmpty) return named;
  final productType = textOrNull(r['productType']) ?? '';
  final text = '$name $productType'.toLowerCase();
  for (final (word, code) in stockKindKeywords) {
    if (text.contains(word)) return code;
  }
  final source = packageSource(r);
  final fromSource = source == null ? null : stockSourceKinds[source.substring(0, 3).toUpperCase()];
  if (fromSource != null) return fromSource;
  return productType.toLowerCase().contains('whole fungi') ? 'WF' : null;
}

String _lotKey(Package p) => '${p.productGuid}#${p.id}';

/// The stock page's rows by the order in this file's header. [fetchServerPackages] reads /p/packages,
/// [fetchStateRecords] the state's raw records (it may throw SessionExpired), [fetchMazamaLicenses] /p/center-status's
/// list (best effort: a failure keeps the one kept before).
Future<StockLoad> loadCenterStock({
  required int stateId,
  required Future<List<Package>> Function() fetchServerPackages,
  required Future<List<Object?>> Function() fetchStateRecords,
  required Future<List<String>> Function() fetchMazamaLicenses,
  required Datasets datasets,
  DateTime Function() now = DateTime.now,
  String Function(String? name)? strainOf,
}) async {
  // Keeping a copy is best effort: a full disk never stops the page drawing what it just read.
  Future<void> keep(Future<void> Function() save) async {
    try {
      await save();
    } catch (_) {
      // nothing kept this time; the last copy stays
    }
  }

  final licenses = keep(() async => keepMazamaLicenses(datasets, stateId, await fetchMazamaLicenses(), now().toUtc()));
  Object? serverError, stateError;
  MergedInventoryResult? merged;
  try {
    merged = await fetchMergedInventory(
      stateId,
      accessToken: '', // fetchStateRecords brings its own fresh token
      fetchMazama: (_) async {
        try {
          return await fetchServerPackages();
        } catch (e) {
          serverError = e;
          rethrow;
        }
      },
      fetchRawState: (_, {required accessToken}) async {
        try {
          return await fetchStateRecords();
        } catch (e) {
          stateError = e;
          rethrow;
        }
      },
    );
  } on MergedInventoryError {
    merged = null; // neither answered
  }
  await licenses;

  final m = merged;
  final mazamaLicenses = keptMazamaLicenses(datasets, stateId)?.toSet();
  final signInNeeded = stateError is SessionExpired;
  final raw = m?.rawStateRecords;
  final records = raw == null ? null : [for (final r in raw) if (r is Map) Map<String, Object?>.from(r)];
  final heldBack = records == null
      ? const <({StockRow row, String reason})>[]
      : heldBackFromState(records, mazamaLicenses, now(), strainOf: strainOf);

  if (m != null && m.mazamaOk) {
    final served = {for (final p in m.mazamaPackages!) _lotKey(p)};
    final rows = [for (final p in m.packages) if (served.contains(_lotKey(p))) p.toStockRow()];
    // the server answered; the state too unless it is the one that didn't (m.stateOk)
    await keep(() async => keepStockRows(datasets, stateId, rows,
        mgMode: 'tpe', at: now().toUtc(), source: m.stateOk ? sourceMerged : sourceServer));
    // The state didn't answer: the server's own quantities, as of its last sync (and say why when it's the sign-in).
    return StockLoad(rows, heldBack: heldBack, serverQuantities: !m.stateOk, signInNeeded: !m.stateOk && signInNeeded);
  }

  final e = serverError;
  final notSetUp = e is PackagesError && e.status == 404;
  if (records != null) {
    final rows = stockRowsFromState(records, mazamaLicenses, now(), strainOf: strainOf);
    await keep(() async => keepStockRows(datasets, stateId, rows, mgMode: 'psilocybin', at: now().toUtc(), source: sourceState));
    return StockLoad(rows, mgMode: 'psilocybin', partial: true, notSetUp: notSetUp, heldBack: heldBack);
  }

  final saved = keptStockRows(datasets, stateId);
  if (saved == null) throw signInNeeded ? StockSignInNeeded() : StockUnavailable();
  return StockLoad(saved.rows,
      mgMode: saved.mgMode, partial: true, drawnAt: saved.at, notSetUp: notSetUp, signInNeeded: signInNeeded);
}

/// The center's Mazama licenses last fetched (the mazama_licenses dataset); null when none are kept (or readable).
List<String>? keptMazamaLicenses(Datasets datasets, int stateId) {
  final row = datasets.read(Dataset.mazamaLicenses, '$stateId');
  if (row == null) return null;
  try {
    final j = jsonDecode(row.body);
    return j is List ? [for (final l in j) if (l is String) l] : null;
  } catch (_) {
    return null;
  }
}

/// Keeps [licenses] as the center's Mazama licenses, fetched [at].
void keepMazamaLicenses(Datasets datasets, int stateId, List<String> licenses, DateTime at) =>
    datasets.put(Dataset.mazamaLicenses, '$stateId', jsonEncode(licenses), source: sourceServer, at: at);

/// The rows last drawn for the center (the stock_rows dataset), their mg mode and when they were drawn (null for a copy
/// an older build kept without a time: moved in at the epoch); null when none are kept, or they can't be read.
({List<StockRow> rows, String mgMode, DateTime? at})? keptStockRows(Datasets datasets, int stateId) {
  final row = datasets.read(Dataset.stockRows, '$stateId');
  if (row == null) return null;
  try {
    final j = jsonDecode(row.body);
    if (j is! Map || j['rows'] is! List) return null;
    final rows = [for (final r in j['rows'] as List) StockRow.fromJson(Map<String, Object?>.from(r as Map))];
    final mode = j['mgMode'];
    return (
      rows: rows,
      mgMode: stockMgModes.contains(mode) ? mode as String : 'tpe',
      at: row.fetchedAt.millisecondsSinceEpoch == 0 ? null : row.fetchedAt,
    );
  } catch (_) {
    return null; // a damaged copy: as if nothing were kept
  }
}

/// Keeps [rows] as the center's drawn rows, with their mg mode and time; [source] is who answered the read they were
/// drawn from (sync_datasets.dart's sources), `merged` by default as the stock page's own load is.
void keepStockRows(Datasets datasets, int stateId, List<StockRow> rows,
        {required String mgMode, required DateTime at, String source = sourceMerged}) =>
    datasets.put(Dataset.stockRows, '$stateId', jsonEncode({'rows': [for (final r in rows) r.toJson()], 'mgMode': mgMode}),
        source: source, at: at);

/// The center's par levels from the server, kept for offline with when ([now]) as the sync engine's par dataset
/// (lib/sync/sync_datasets.dart, specs/phone-sync phase 2; README R56); when the server can't be reached, the last copy with its time (the page shows it
/// read-only then; a copy an older build kept is moved into the dataset on the folder's first use, sync_migration.dart);
/// else, or with none kept, the server's error.
Future<ServerRead<List<ParLevel>>> loadCenterPar({
  required int stateId,
  required Future<List<ParLevel>> Function() fetchPar,
  required Datasets datasets,
  DateTime Function() now = DateTime.now,
}) {
  final kept = parDataset(datasets, stateId);
  return readWithCache<List<ParLevel>>(fetch: fetchPar, save: kept.save, load: kept.load, now: now);
}
