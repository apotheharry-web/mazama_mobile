// What the stock page keeps on the phone for when it can't reach everything (SP-D6, SP-R13), per center: the last
// par levels fetched from the server (shown read-only offline on the order's par step, MI-D21), the par
// table's serving-size columns the workers added or deleted on this phone (SP-D14), the last Mazama license list (to tell Mazama's
// product apart in state-only data), the last rows drawn with their mg mode and time (the charts to show,
// with their age, when nothing is reachable), and the last product information sheets (the lot table). Since README
// R56 the server's par levels and sheets are kept in the app's reply store (reply_store.dart) instead; the copies
// builds before it kept here (par, sheets) are only read, once, when the reply store has none yet. One small JSON file per center in the app's data folder, written
// with the *Sync calls for the same reason as device_id.dart / cart_store.dart (an async write/read race can
// deadlock inside flutter_test's fake clock); anything unreadable counts as nothing saved.
import 'dart:convert';
import 'dart:io';

import 'session_store.dart' show defaultSessionDataDir;
import 'sheets_client.dart' show ProductSheet;
import 'stock_summary.dart';

/// What [StockCacheStore.load] gives back; any part may be missing (null).
class StockCache {
  const StockCache(
      {this.par, this.parAt, this.mazamaLicenses, this.rows, this.rowsMgMode = 'tpe', this.rowsAt, this.sheets, this.sheetsAt});

  final List<ParLevel>? par;

  /// When the server sent [par]; null when a build from before this was kept didn't record it.
  final DateTime? parAt;
  final List<String>? mazamaLicenses;
  final List<StockRow>? rows;
  final String rowsMgMode;
  final DateTime? rowsAt;

  /// The center's product information sheets as the server last sent them, and when.
  final List<ProductSheet>? sheets;
  final DateTime? sheetsAt;
}

/// The par table's serving-size columns a worker chose on this phone (SP-D14): [added] shows a size even with nothing
/// in stock; [removed] hides one even with stock. Sizes are the strain sizes 25 .. 5 and 0 (other).
class ParColumns {
  const ParColumns({this.added = const {}, this.removed = const {}});

  final Set<int> added;
  final Set<int> removed;

  factory ParColumns.fromJson(Object? j) {
    Set<int> sizes(Object? v) => {
          if (v is List)
            for (final e in v)
              if (e is int && stockSizesFor(stockAllStrains).contains(e)) e,
        };
    return j is Map ? ParColumns(added: sizes(j['added']), removed: sizes(j['removed'])) : const ParColumns();
  }

  Map<String, Object?> toJson() => {'added': added.toList()..sort(), 'removed': removed.toList()..sort()};
}

class StockCacheStore {
  const StockCacheStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  /// Overridable for tests, as the other stores.
  final Directory Function() dataDir;

  File _file(int stateId) => File('${dataDir().path}/stock_cache_$stateId.json');

  Map<String, Object?> _read(int stateId) {
    try {
      final decoded = jsonDecode(_file(stateId).readAsStringSync());
      return decoded is Map ? Map<String, Object?>.from(decoded) : {};
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }

  void _write(int stateId, Map<String, Object?> data) {
    dataDir().createSync(recursive: true);
    _file(stateId).writeAsStringSync(jsonEncode(data));
  }

  Future<StockCache> load(int stateId) async {
    final d = _read(stateId);
    List<T>? list<T>(Object? v, T Function(Map<String, Object?>) read) {
      if (v is! List) return null;
      try {
        return [for (final e in v) read(Map<String, Object?>.from(e as Map))];
      } catch (_) {
        return null; // a damaged entry: as if nothing were saved
      }
    }

    DateTime? time(Object? ms) => ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true) : null;

    final licenses = d['mazamaLicenses'];
    return StockCache(
      par: list(d['par'], ParLevel.fromJson),
      parAt: time(d['parAtMs']),
      mazamaLicenses: licenses is List ? [for (final l in licenses) if (l is String) l] : null,
      rows: list(d['rows'], StockRow.fromJson),
      rowsMgMode: stockMgModes.contains(d['rowsMgMode']) ? d['rowsMgMode'] as String : 'tpe',
      rowsAt: time(d['rowsAtMs']),
      sheets: list(d['sheets'], ProductSheet.fromJson),
      sheetsAt: time(d['sheetsAtMs']),
    );
  }

  /// Keeps [par] as the server sent (or stored) it [at]; without [at] the time is left unknown.
  Future<void> savePar(int stateId, List<ParLevel> par, {DateTime? at}) async => _write(stateId, {
        ..._read(stateId),
        'par': [for (final p in par) p.toJson()],
        'parAtMs': at?.millisecondsSinceEpoch,
      });

  /// Keeps the center's product information sheets as the server sent them [at].
  Future<void> saveSheets(int stateId, List<ProductSheet> sheets, {required DateTime at}) async => _write(stateId, {
        ..._read(stateId),
        'sheets': [for (final s in sheets) s.toJson()],
        'sheetsAtMs': at.millisecondsSinceEpoch,
      });

  /// The columns chosen on this phone for the center's par table; none chosen when nothing (readable) was saved.
  Future<ParColumns> loadParColumns(int stateId) async => ParColumns.fromJson(_read(stateId)['parColumns']);

  Future<void> saveParColumns(int stateId, ParColumns columns) async =>
      _write(stateId, {..._read(stateId), 'parColumns': columns.toJson()});

  Future<void> saveMazamaLicenses(int stateId, List<String> licenses) async =>
      _write(stateId, {..._read(stateId), 'mazamaLicenses': licenses});

  Future<void> saveRows(int stateId, List<StockRow> rows, {required String mgMode, required DateTime at}) async =>
      _write(stateId, {
        ..._read(stateId),
        'rows': [for (final r in rows) r.toJson()],
        'rowsMgMode': mgMode,
        'rowsAtMs': at.millisecondsSinceEpoch,
      });
}
