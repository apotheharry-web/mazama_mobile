// specs/app-updates AU-R16: the only code on the phone that talks to GitHub, and its own two host sets.
//
// - The signed files: exactly [githubFilesBase] followed by one of [githubFileNames], with or without `.sig` (the
//   owner's signed sign-in files and the release file at the public repository's root, AU-D7, AU-D8). GET only, no
//   redirect followed (a 3xx is a failure), the file at most [githubFileMaxBytes], a `.sig` at most
//   [githubSigMaxBytes], [githubFileTimeout] each ([fetchSignedGithubFile]). Nothing here checks a signature: the
//   callers do (app_update_client.dart, and the sign-in fallback), with the bundled signing.pub.
// - The APK download: a start address passing AU-R1's `apk` rule ([apkStartUrlAllowed]), then redirect hops only to
//   `https` on port 443 at exactly one of [apkRedirectHosts] ([apkHopAllowed]; a query is allowed on hops, which carry
//   GitHub's signed download parameters). The server's APK worker holds the same hosts (app_release.py's APK_HOSTS).
//
// These hosts are never part of currentAllowedHosts() (login_hosts_store.dart), the flow runner's allowlist or the
// sign-in webview's navigation check (browser_sign_in_page.dart), and a signed host list never adds to them: the
// checks below use their own sets. Requests here carry nothing but Dart's default headers: never the app key, a
// token, a cookie or the worker's email, and they never go through the server link (serverClient()).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_release.dart' show apkPrefix;

/// The folder of the public repository's `main` branch the signed files are read from (AU-D8).
const githubFilesBase = 'https://raw.githubusercontent.com/apotheharry-web/mazama_mobile/main/';

/// The signed files the phone may read from GitHub (each with its `.sig`).
const githubFileNames = {'login.yaml', 'login_browser.yaml', 'hosts.json', 'latest.json'};

/// The hosts an APK download may be redirected to (AU-R16), exactly.
const apkRedirectHosts = {'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'};

/// The longest signed file read from GitHub.
const githubFileMaxBytes = 65536;

/// The longest `.sig` read from GitHub.
const githubSigMaxBytes = 1024;

/// How long each GitHub file request may take, in all.
const githubFileTimeout = Duration(seconds: 10);

final _apkStartRe = RegExp(r'^v(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})(\+|%2B)[0-9]{8}/'
    r'([A-Za-z0-9._+-]|%2B){1,100}\.apk$');

/// True for exactly a signed file's address: [githubFilesBase] + one of [githubFileNames], optionally + `.sig`.
bool githubFileUrlAllowed(Uri u) {
  final s = u.toString();
  if (!s.startsWith(githubFilesBase)) return false;
  final name = s.substring(githubFilesBase.length);
  final base = name.endsWith('.sig') ? name.substring(0, name.length - 4) : name;
  return githubFileNames.contains(base);
}

/// True for an APK start address of AU-R1's shape: [apkPrefix] + `v<x.y.z>+<8 digits>/<asset>.apk` (`+` may be
/// `%2B`), nothing else (app_release.dart's [apkAddressOk] also ties the tag to a file's own version and build).
bool apkStartUrlAllowed(Uri u) {
  final s = u.toString();
  if (!s.startsWith(apkPrefix) || s.contains('\\')) return false;
  return _apkStartRe.hasMatch(s.substring(apkPrefix.length));
}

/// True for an APK redirect hop: `https`, port 443, no user info, exactly one of [apkRedirectHosts] (Uri gives the
/// host in lower case; a trailing dot is another host and refused). A query is allowed.
bool apkHopAllowed(Uri u) {
  if (u.scheme != 'https' || u.userInfo.isNotEmpty || u.port != 443) return false;
  if (u.toString().contains('\\')) return false;
  return apkRedirectHosts.contains(u.host);
}

/// Reads [resp]'s body, failing as soon as it passes [cap] bytes.
Future<List<int>> _capped(http.StreamedResponse resp, int cap) async {
  final out = <int>[];
  await for (final chunk in resp.stream) {
    if (out.length + chunk.length > cap) throw const FormatException('over the size limit');
    out.addAll(chunk);
  }
  return out;
}

Future<String> _get(http.Client c, Uri uri, int cap, Duration timeout) async {
  if (!githubFileUrlAllowed(uri)) throw ArgumentError('not a GitHub file address');
  Future<String> run() async {
    final req = http.Request('GET', uri)..followRedirects = false;
    final resp = await c.send(req);
    if (resp.statusCode != 200) throw StateError('HTTP ${resp.statusCode}');
    return utf8.decode(await _capped(resp, cap));
  }

  return run().timeout(timeout);
}

/// The signed file [name] (one of [githubFileNames]) and its `.sig`, as (text, signature), read from GitHub; null on
/// any failure (no answer, a status other than 200, a redirect, a body over its cap, a timeout, text that isn't
/// UTF-8). The `.sig` is asked for only once the file was read. Verifies nothing. Never throws; logs nothing of a body.
Future<(String, String)?> fetchSignedGithubFile(String name,
    {http.Client? client, Duration timeout = githubFileTimeout}) async {
  if (!githubFileNames.contains(name)) return null;
  final c = client ?? http.Client(); // a plain client: GitHub is not Mazama's server (no server link, no app key)
  try {
    final text = await _get(c, Uri.parse('$githubFilesBase$name'), githubFileMaxBytes, timeout);
    final sig = await _get(c, Uri.parse('$githubFilesBase$name.sig'), githubSigMaxBytes, timeout);
    return (text, sig);
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}
