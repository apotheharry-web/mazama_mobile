// Test helper (not a test file): release files (specs/app-updates AU-R1) signed with the shared vectors' TEST key
// (host_list_signing.dart's; never Mazama's key), so the update tests can verify files the way the app does, with
// that TEST public key injected.
import 'dart:convert';

import 'package:mazama_mobile/app_release.dart';

import 'host_list_signing.dart';

export 'host_list_signing.dart' show otherPublicKey, testPublicKey, testSignature;

/// A build dated [day] (its UTC calendar day), the [n]th of that day: YYMMDDNN.
int buildOn(DateTime day, [int n = 1]) {
  final d = day.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return int.parse('${two(d.year % 100)}${two(d.month)}${two(d.day)}${two(n)}');
}

/// The text of a release file, keys in AU-R1's order; [over] replaces fields (a null value removes the key).
String releaseText({
  String version = '0.2.4',
  required int build,
  String? apk,
  String sha256 = 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12',
  int size = 1000,
  int minSdk = 24,
  Map<String, Object?> over = const {},
}) {
  final fields = <String, Object?>{
    'kind': releaseKind,
    'version': version,
    'build': build,
    'apk': apk ?? '${apkPrefix}v$version%2B$build/mazama-mobile-$version%2B$build.apk',
    'sha256': sha256,
    'size': size,
    'minSdk': minSdk,
  };
  for (final e in over.entries) {
    if (e.value == null) {
      fields.remove(e.key);
    } else {
      fields[e.key] = e.value;
    }
  }
  return '${jsonEncode(fields)}\n';
}

/// A release file signed with the TEST key and verified as the app verifies one (no date bound).
Future<ReleaseFile> signedRelease({
  String version = '0.2.4',
  required int build,
  String sha256 = 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12',
  int size = 1000,
  int minSdk = 24,
}) async {
  final text = releaseText(version: version, build: build, sha256: sha256, size: size, minSdk: minSdk);
  final file = await verifiedReleaseFile(text, await testSignature(text), publicKey: testPublicKey);
  if (file == null) throw StateError('the TEST-signed release file did not verify');
  return file;
}
