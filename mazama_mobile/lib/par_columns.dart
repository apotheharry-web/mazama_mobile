// The par table's serving-size columns the workers added or deleted on this phone (SP-D14), per center: a choice made
// on this phone, not data read from anywhere, so a document of its own in the data folder's LocalStore
// (`par_columns_<state id>.json`, {"added": [...], "removed": [...]}), not a sync dataset. Builds before specs/phone-sync
// Task 10 kept it inside the stock page's stock_cache_<state id>.json (stock_cache_store.dart, removed); the sync
// migration moves it here on the folder's first use (sync_migration.dart's migrateStockCaches). Synchronous calls, as
// the other stores; anything unreadable counts as nothing chosen.
import 'dart:convert';
import 'dart:io';

import 'local_store.dart';
import 'session_store.dart' show defaultSessionDataDir;
import 'stock_summary.dart';
import 'sync/sync_datasets.dart' show Datasets;

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

/// The document a center's par columns are kept in.
String parColumnsDocument(int stateId) => 'par_columns_$stateId.json';

class ParColumnsStore {
  const ParColumnsStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  /// Overridable for tests, as the other stores.
  final Directory Function() dataDir;

  /// The columns chosen on this phone for the center's par table; none chosen when nothing (readable) was saved.
  Future<ParColumns> load(int stateId) async {
    try {
      Datasets.forDir(dataDir).moveOlderCopies(); // an older build's choice is moved here first (the file comment)
      final text = LocalStore.forDir(dataDir()).read(parColumnsDocument(stateId))?.body;
      return text == null ? const ParColumns() : ParColumns.fromJson(jsonDecode(text));
    } catch (_) {
      return const ParColumns(); // the database can't be opened, or a damaged copy: as if none were chosen
    }
  }

  Future<void> save(int stateId, ParColumns columns) async {
    Datasets.forDir(dataDir).moveOlderCopies(); // so an older build's choice, moved later, can't replace this one
    LocalStore.forDir(dataDir()).write(parColumnsDocument(stateId), jsonEncode(columns.toJson()));
  }
}
