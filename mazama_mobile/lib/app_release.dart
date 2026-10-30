// specs/app-updates AU-R1, AU-R2: the signed Android release file `latest.json` on the phone.
//
// The owner signs latest.json with the sign-in files' key (AU-D3) and publishes it, with its .sig, at the public
// repository's root (AU-D7). The phone reads it from Mazama's server (C21, app_update_client.dart) or, when the server
// can't answer, from GitHub (github_files.dart), and counts it only when its signature verifies against the bundled
// signing.pub (signing.dart) and its text passes the rule below. The server is not trusted to have checked.
//
// The rule is written twice, here and in the server's mazama_sales/app_release.py, and both are held to the shared
// vectors assets/shared/flows/contracts/app_release_vectors.json (vendored from ../mazama_modules/flows/contracts/):
// at most 4096 bytes of UTF-8 JSON, one object with exactly
//   kind     "mazama-mobile-release";
//   version  x.y.z, each part a number of at most 3 digits with no leading zero;
//   build    an integer of exactly 8 digits YYMMDDNN whose YYMMDD is a real date, not after the checker's date + 1 day;
//   apk      exactly [apkPrefix] + "v<version>+<build>/<asset>", `+` written as `+` or `%2B`, the asset
//            [A-Za-z0-9._+-]{1,100} ending ".apk" (`+` may be `%2B`), no other escape, query, fragment, user or port;
//   sha256   64 lower-case hex digits;
//   size     an integer from 1 to [maxApkBytes];
//   minSdk   an integer from 21 to 99.
// Booleans and doubles are not integers (a JSON 26103001.0 decodes to a double). A repeated key keeps its last value (as the server's reader does). A refusal
// names no part of the text.
import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle;

import 'signing.dart';

/// The release file's `kind`, so no other signed file passes as one.
const releaseKind = 'mazama-mobile-release';

/// The longest release file, in UTF-8 bytes (app_release.py's MAX_BYTES; the vectors' max_bytes).
const maxReleaseFileBytes = 4096;

/// The largest APK a release file may name (300 MiB).
const maxApkBytes = 314572800;

/// Where every APK a release file names lives: the public repository's GitHub releases (AU-R1).
const apkPrefix = 'https://github.com/apotheharry-web/mazama_mobile/releases/download/';

const _keys = {'kind', 'version', 'build', 'apk', 'sha256', 'size', 'minSdk'};
final _versionRe = RegExp(r'^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$');
final _assetRe = RegExp(r'^[A-Za-z0-9._+-]{1,100}$');
final _shaRe = RegExp(r'^[0-9a-f]{64}$');

/// A release file whose signature verified: its fields, the signed file's exact [text] and its `.sig` text
/// [signature] (kept together so it can be verified again when read back, app_update_store.dart).
class ReleaseFile {
  final String version;
  final int build;
  final String apk;
  final String sha256;
  final int size;
  final int minSdk;
  final String text;
  final String signature;

  /// Private: [verifiedReleaseFile] (which checks the signature and the text) is the only way to make one.
  const ReleaseFile._({
    required this.version,
    required this.build,
    required this.apk,
    required this.sha256,
    required this.size,
    required this.minSdk,
    required this.text,
    required this.signature,
  });

  @override
  String toString() => 'ReleaseFile($version, $build)';
}

/// The date a build's YYMMDD names (20YY, UTC), or null when it isn't a real date.
DateTime? buildDate(int build) {
  final digits = build.toString().padLeft(8, '0');
  final y = 2000 + int.parse(digits.substring(0, 2));
  final m = int.parse(digits.substring(2, 4));
  final d = int.parse(digits.substring(4, 6));
  final date = DateTime.utc(y, m, d);
  if (date.year != y || date.month != m || date.day != d) return null;
  return date;
}

/// True when [apk] is exactly the pinned release address for [version] and [build] (AU-R1's `apk` rule).
bool apkAddressOk(String apk, String version, int build) {
  if (!apk.startsWith(apkPrefix)) return false;
  final rest = apk.substring(apkPrefix.length).split('/');
  if (rest.length != 2) return false;
  final tag = rest[0].replaceAll('%2B', '+');
  final asset = rest[1].replaceAll('%2B', '+');
  if (tag.contains('%') || asset.contains('%')) return false;
  return tag == 'v$version+$build' && _assetRe.hasMatch(asset) && asset.endsWith('.apk');
}

/// (version, build, apk, sha256, size, minSdk) of a release file's [text]; throws [FormatException], naming no part of
/// the text, when it breaks AU-R1. [today] is the checker's date for the build's date bound (its UTC calendar day);
/// null skips that bound (a file read back from the phone's record). app_release.py's parse is the twin.
(String, int, String, String, int, int) parseReleaseFile(String text, {DateTime? today}) {
  if (utf8.encode(text).length > maxReleaseFileBytes) throw const FormatException('over the size limit');
  final Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    throw const FormatException('not UTF-8 JSON');
  }
  if (data is! Map || data.length != _keys.length || !_keys.every(data.containsKey)) {
    throw const FormatException('not an object with exactly the expected keys');
  }
  if (data['kind'] != releaseKind) throw const FormatException('bad kind');
  final Object? version = data['version'];
  final Object? build = data['build'];
  if (version is! String || !_versionRe.hasMatch(version)) throw const FormatException('bad version');
  if (build is! int || build < 10000000 || build > 99999999) throw const FormatException('bad build');
  final made = buildDate(build);
  if (made == null) throw const FormatException('bad build date');
  if (today != null) {
    final t = today.toUtc();
    final latest = DateTime.utc(t.year, t.month, t.day + 1);
    if (made.isAfter(latest)) throw const FormatException('build dated after tomorrow');
  }
  final Object? apk = data['apk'];
  if (apk is! String || !apkAddressOk(apk, version, build)) throw const FormatException('bad apk');
  final Object? sha = data['sha256'];
  if (sha is! String || !_shaRe.hasMatch(sha)) throw const FormatException('bad sha256');
  final Object? size = data['size'];
  if (size is! int || size < 1 || size > maxApkBytes) throw const FormatException('bad size');
  final Object? minSdk = data['minSdk'];
  if (minSdk is! int || minSdk < 21 || minSdk > 99) throw const FormatException('bad minSdk');
  return (version, build, apk, sha, size, minSdk);
}

/// The release file in [text] when [signature] (a `.sig` text) is a good signature of exactly its UTF-8 bytes under
/// [publicKey] (a `signing.pub` text; the bundled one, read from [bundle], when null) and the text passes AU-R1 with
/// [today]'s date bound (none when null); otherwise null. Never throws.
Future<ReleaseFile?> verifiedReleaseFile(String text, String signature,
    {DateTime? today, String? publicKey, AssetBundle? bundle}) async {
  try {
    if (!await verifySigned(utf8.encode(text), signature, publicKey: publicKey, bundle: bundle)) return null;
    final (version, build, apk, sha, size, minSdk) = parseReleaseFile(text, today: today);
    return ReleaseFile._(
        version: version,
        build: build,
        apk: apk,
        sha256: sha,
        size: size,
        minSdk: minSdk,
        text: text,
        signature: signature);
  } catch (_) {
    return null;
  }
}
