// The move from the files the stores used to write to LocalStore's documents (specs/foundations LS-R5). Run by
// LocalStore.forDir on every fresh open of a folder's database, before it returns, so no store ever reads before its
// old file is in: a phone updated mid-cart opens on the same draft, timer and outbox.
//
// Each file is imported in its own transaction, under its own name as the document's name, with its text exactly as
// it is (a corrupt file stays corrupt, and the store's own parser refuses it, as it did the file). Only after that
// commits is the file renamed `<name>.migrated`, so a failed import (a full disk, an exception) leaves it in place for
// the next open. A document of the same name always wins over a file: it is newer than any file left behind. Each
// import is also recorded (LocalStore's imported_files) in the same transaction, so a file whose rename failed is never
// imported again, even after its document was deleted (a sold or discarded cart must not come back).
// Bytes that are not UTF-8 were unreadable to the store too: nothing is imported and the file is renamed.
//
// session.json is not here: it holds the session's tokens, which move to secure storage (secret_store.dart), and
// the sign-in spec and host list stay files (plan P-D4).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'cart_slots.dart' show isCartId;
import 'local_store.dart';

/// The files imported, exactly. `<id>` is a cart id ([isCartId]), `<n>` digits (a state id), `<any>` any file name
/// in that folder.
const legacyDocumentPatterns = <String>[
  'cart.json',
  'cart_<id>.json',
  'carts.json',
  'session_timer.json',
  'session_timer_<id>.json',
  'session_dose.json',
  'session_dose_<id>.json',
  'device_id.txt',
  'inventory_cache.json',
  'enrichment.json',
  'stock_cache_<n>.json',
  'mazama_inventory_cache.json',
  'server_outbox.json',
  'server_catch_up.json',
  'coa_sent.json',
  'server_health.json',
  'server_replies/<any>.json',
];

/// The folder of [legacyDocumentPatterns] that has files of its own.
const _repliesFolder = 'server_replies';

final List<RegExp> _matchers = [for (final p in legacyDocumentPatterns) _regExpFor(p)];

RegExp _regExpFor(String pattern) {
  final body = pattern.splitMapJoin(
    RegExp('<id>|<n>|<any>'),
    onMatch: (m) => switch (m[0]) {
      '<id>' => '(?<id>[^/]+)',
      '<n>' => '[0-9]+',
      _ => '[^/]+',
    },
    onNonMatch: RegExp.escape,
  );
  return RegExp('^$body\$');
}

/// Whether [name] (relative to the data folder, `/`-separated) is one of [legacyDocumentPatterns].
bool isLegacyDocumentName(String name) {
  for (final m in _matchers) {
    final match = m.firstMatch(name);
    if (match == null) continue;
    final id = match.groupNames.contains('id') ? match.namedGroup('id') : null;
    if (id == null || isCartId(id)) return true;
  }
  return false;
}

/// Called inside each import's transaction, before its write, with the document's name: a test throws here to
/// make an import fail.
@visibleForTesting
void Function(String name)? debugBeforeLegacyImportWrite;

/// Renames a legacy file once its import committed; a test throws here to make the rename fail.
@visibleForTesting
void Function(File file, String to)? debugRenameLegacyFile;

/// Imports every legacy file still in [dir] into [store] (see the file comment). Never throws.
void importLegacyFiles(LocalStore store, Directory dir) {
  for (final (file, name) in _legacyFiles(dir)) {
    _importOne(store, file, name);
  }
}

List<(File, String)> _legacyFiles(Directory dir) {
  final found = <(File, String)>[];
  void scan(Directory folder, String prefix) {
    try {
      for (final entity in folder.listSync()) {
        if (entity is! File) continue;
        final name = '$prefix${entity.uri.pathSegments.last}';
        if (isLegacyDocumentName(name)) found.add((entity, name));
      }
    } on FileSystemException {
      // No such folder (no replies were ever kept), or unreadable: nothing to import from it.
    }
  }

  scan(dir, '');
  scan(Directory('${dir.path}/$_repliesFolder'), '$_repliesFolder/');
  return found;
}

void _importOne(LocalStore store, File file, String name) {
  try {
    final bytes = file.readAsBytesSync();
    String? text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = null; // unreadable to the store as well: nothing to keep
    }
    if (text != null) {
      final body = text;
      final at = file.lastModifiedSync();
      store.transaction(() {
        if (store.legacyFileImported(name)) return; // imported before; its rename failed then
        debugBeforeLegacyImportWrite?.call(name);
        if (store.read(name) == null) store.write(name, body, at: at);
        store.recordLegacyFileImported(name);
      });
    }
  } catch (_) {
    return; // the file stays; the next open tries again
  }
  try {
    final to = '${file.path}.migrated';
    final rename = debugRenameLegacyFile;
    rename == null ? file.renameSync(to) : rename(file, to);
  } catch (_) {
    // Imported, but the file stays: the next open finds it recorded as imported and only renames it then.
  }
}
