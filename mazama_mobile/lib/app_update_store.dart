// specs/app-updates AU-R12, AU-R14: what the phone keeps about updates, in its LocalStore (local_store.dart).
//
// - `app_release_seen`: the newest release file (exact text and .sig) whose APK passed the download's checks and
//   Android's inspection (app_update_download.dart). Written only from a verified APK, so a signed file naming a build
//   that was never built can't block later ones. Verified again (signature and rule, without the date bound) when
//   read; a record that doesn't verify, or can't be read, counts as none (the installed build still bounds the offer).
// - `app_release_refused`: the builds whose APK was refused (another package, version or signer): never offered again.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle;

import 'app_release.dart';
import 'local_store.dart';
import 'session_store.dart' show defaultSessionDataDir;

class AppUpdateStore {
  /// Overridable for tests, as every store's; defaults to the folder session.json is in.
  final Directory Function() dataDir;

  /// The `signing.pub` text a kept record is verified with (tests: the TEST key); the bundled one when null.
  final String? publicKey;
  final AssetBundle? bundle;

  const AppUpdateStore({Directory Function()? dataDir, this.publicKey, this.bundle})
      : dataDir = dataDir ?? defaultSessionDataDir;

  static const _seen = 'app_release_seen';
  static const _refused = 'app_release_refused';

  LocalStore get _store => LocalStore.forDir(dataDir());

  /// The newest release file whose APK was verified on this phone, verified again now; null when there is none or it
  /// doesn't verify.
  Future<ReleaseFile?> seen() async {
    try {
      final body = _store.read(_seen)?.body;
      if (body == null) return null;
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final text = decoded['text'];
      final signature = decoded['signature'];
      if (text is! String || signature is! String) return null;
      return await verifiedReleaseFile(text, signature, publicKey: publicKey, bundle: bundle);
    } catch (_) {
      return null;
    }
  }

  /// Keeps [file] as the newest verified one, unless the record already holds a higher build. Call it only once
  /// [file]'s APK has passed every check (AU-R14).
  Future<void> recordVerified(ReleaseFile file) async {
    final current = await seen();
    if (current != null && current.build >= file.build) return;
    _store.write(_seen, jsonEncode({'text': file.text, 'signature': file.signature}));
  }

  /// The builds whose APK was refused on this phone.
  Future<Set<int>> refused() async {
    try {
      final body = _store.read(_refused)?.body;
      if (body == null) return <int>{};
      final decoded = jsonDecode(body);
      if (decoded is! List) return <int>{};
      return {for (final b in decoded) if (b is int) b};
    } catch (_) {
      return <int>{};
    }
  }

  /// Never offers [build] again.
  Future<void> refuse(int build) async {
    final builds = (await refused())..add(build);
    _store.write(_refused, jsonEncode(builds.toList()..sort()));
  }
}
