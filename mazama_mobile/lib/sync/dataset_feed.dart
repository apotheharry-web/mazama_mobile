// One dataset as a page reads it through the sync engine instead of its own
// fetch on open. The page shows the stored copy ([watch]: at once, then after every refresh), with its age; on open it
// joins the refresh under way (the center home asks for its datasets' refreshes as it opens, center_home_page.dart),
// asking one itself only when none runs, so opening the home reads each dataset once ([read]). Retry reads the same
// way. A page reading through a feed has no health listener of its own: the engine refreshes what is watched when the
// server answers again and every five minutes in the foreground.
//
// What a page shows of it ([DatasetFeed.shows]): the stored copy, with no notice of its own while the server can't be
// reached (the app-wide banner says so); when the newest refresh had the server's own answer (a 4xx: a key
// rotated, 401; too many requests, 429), the copy still, with that answer as a note beside it, since the engine refreshes
// by itself (every five minutes, the server answering again) and must never take away what the worker is looking at
// (an error shown in its place would take it away at every refresh); the error, in the page's
// own words, only when nothing is stored.
import 'dart:convert';

import '../mazama_inventory_client.dart' show MazamaInventory;
import '../server_error.dart' show isServerUnreachable;
import '../sheets_client.dart' show ProductSheet;
import 'sync_datasets.dart';
import 'sync_engine.dart';
import 'sync_tables.dart' show DatasetRow;

/// What a page shows of its dataset: the copy ([value], read at [at]; null when no time is known) with, when the newest
/// refresh had the server's own answer, that answer as a [note]; or, with no copy, the [error]. [fromCache]: the copy
/// shows because the server couldn't be reached (a page reloads what it reads for itself once it answers again).
typedef FeedShown<T> = ({T? value, DateTime? at, Object? error, Object? note, bool fromCache});

class DatasetFeed<T> {
  DatasetFeed({
    required this.watch,
    required this.running,
    required this.refresh,
    required this.lastError,
    required T Function(Object? json) decode,
  }) : _decode = decode;

  /// [d]'s copy for [key] in [engine].
  factory DatasetFeed.of(SyncEngine engine, Dataset d, String key, {required T Function(Object? json) decode}) =>
      DatasetFeed<T>(
        watch: () => engine.watch(d, key),
        running: () => engine.refreshing(d, key),
        refresh: () => engine.refresh(d, key),
        lastError: () => engine.refreshError(d, key),
        decode: decode,
      );

  /// The stored copy now, then after every write or failed refresh of it (SyncEngine.watch: watched while listened to).
  final Stream<DatasetRow?> Function() watch;

  /// The refresh under way, else null (SyncEngine.refreshing).
  final Future<void>? Function() running;

  /// Asks a refresh (SyncEngine.refresh; never throws).
  final Future<void> Function() refresh;

  /// Why the newest refresh failed; null when it worked, or none ran (SyncEngine.refreshError).
  final Object? Function() lastError;

  final T Function(Object? json) _decode;

  /// Joins the refresh under way, else asks one, and answers with its error (null when it worked). Never two reads for
  /// one open: a refresh asked while one runs would run once more after it.
  Future<Object?> read() async {
    await (running() ?? refresh());
    return lastError();
  }

  /// [row]'s body read back; null when it can't be (an older or damaged copy counts as none).
  T? decode(DatasetRow row) {
    try {
      return _decode(jsonDecode(row.body));
    } catch (_) {
      return null;
    }
  }

  /// What a page shows for [row] once a read has ended with [error] (the file comment; [error] is the newest refresh's). Before the first read on open
  /// has ended, pass [settled] false: the copy stored shows (or the spinner), whatever an earlier run's refresh said.
  FeedShown<T> shows(DatasetRow? row, Object? error, {bool settled = true}) {
    final value = row == null ? null : decode(row);
    final at = row == null || row.fetchedAt.millisecondsSinceEpoch == 0 ? null : row.fetchedAt; // stored without a time
    if (!settled) return (value: value, at: value == null ? null : at, error: null, note: null, fromCache: false);
    if (value != null) {
      final unreachable = error != null && isServerUnreachable(error);
      return (value: value, at: at, error: null, note: unreachable ? null : error, fromCache: unreachable);
    }
    if (error != null) return (value: null, at: null, error: error, note: null, fromCache: false);
    return (
      value: null,
      at: null,
      error: row != null ? "the copy kept on this phone can't be read" : null,
      note: null,
      fromCache: false,
    );
  }
}

/// Mazama's stock (GET /p/mazama-inventory), the Mazama tab's dataset.
DatasetFeed<MazamaInventory> mazamaInventoryFeed(SyncEngine engine) =>
    DatasetFeed.of(engine, Dataset.mazamaInventory, '', decode: mazamaInventoryFromJson);

/// A center's product information sheets (GET /p/sheets/{state_id}), the stock page's lot table.
DatasetFeed<List<ProductSheet>> sheetsFeed(SyncEngine engine, int stateId) =>
    DatasetFeed.of(engine, Dataset.sheets, '$stateId', decode: sheetsFromJson);
