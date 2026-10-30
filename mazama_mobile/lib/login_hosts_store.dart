// SL-R18 / SL-D13: the owner's signed sign-in host list, and the hosts every flow on this phone may talk to.
//
// The app's allowlist is the built-in two (flow_spec.dart's defaultAllowedHosts) plus the hosts of the newest list
// that verifies against the bundled public key (signing.dart, assets/signing/signing.pub). A list only ever adds exact
// hosts; it never removes the built-in ones. It reaches the phone from Mazama's server (/p/flows/hosts,
// login_hosts_client.dart) only after a failed sign-in (with the newer sign-in spec, SL-R10), and is kept here, in
// `login_hosts.json` beside login_spec.yaml, only after the sign-in it enabled gave a session (SignInPage). The file
// holds the list's exact text and its signature, and is verified again every time it is read, so a list saved under
// another key (or while the bundled key is `none`) is never used.
//
// The text rule (parseHostList) is held to the shared vectors assets/shared/flows/contracts/host_list_vectors.json,
// which the server's state/login_hosts.py passes too.
//
// [currentAllowedHosts] is what every flow is run with (state_client.dart's reads, the sale, renew, the sign-in and the
// webview's navigation check): MazamaApp sets the saved list in use at start-up ([useLoginHosts]), SignInPage after a
// sign-in a new list enabled. Same dart:io-direct, *Sync pattern as login_spec_store.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle;

import 'flow/flow_spec.dart' show compareSpecVersions, defaultAllowedHosts, isSpecVersion;
import 'session_store.dart' show defaultSessionDataDir;
import 'signing.dart';

/// The longest host list text, in UTF-8 bytes (login_hosts.py's MAX_BYTES; host_list_vectors.json's max_bytes).
const maxHostListBytes = 65536;

/// The most hosts one list may name (login_hosts.py's MAX_HOSTS; host_list_vectors.json's max_hosts).
const maxListedHosts = 10;

final _hostRe = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$');
final _numberLabelRe = RegExp(r'^([0-9]+|0x[0-9a-f]*)$');

/// specs/app-updates AU-R16 (review I2): the hosts the app reads the owner's signed files and its updates from
/// (github_files.dart) are never sign-in hosts, so no signed list may name one (login_hosts.py's GITHUB_HOSTS).
const githubHostsNeverListed = {
  'raw.githubusercontent.com',
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
};

/// One exact host as a list may name it: lower-case ASCII letters, digits and hyphens in two or more dot-separated
/// labels of 1-63 characters, none starting or ending with a hyphen, at most 253 characters, and a last label that is
/// not a number (so no IP address literal). No dot at either end, no `*`, port, scheme or path, and never one of
/// [githubHostsNeverListed] (login_hosts.py's valid_host is the twin).
bool validListedHost(Object? host) {
  if (host is! String || host.length > 253 || !_hostRe.hasMatch(host)) return false;
  if (githubHostsNeverListed.contains(host)) return false;
  final labels = host.split('.');
  if (labels.any((l) => l.length > 63 || l.startsWith('-') || l.endsWith('-'))) return false;
  return !_numberLabelRe.hasMatch(labels.last);
}

/// (version, hosts in the file's order) of a host list's [text]; throws [FormatException], naming no part of the
/// text, when it isn't a valid one: at most 64 KiB of UTF-8 JSON, an object with exactly "version" (a spec_version)
/// and "hosts" (at most 10 different valid hosts). login_hosts.py's parse is the twin.
(String, List<String>) parseHostList(String text) {
  if (utf8.encode(text).length > maxHostListBytes) throw const FormatException('the host list is over the size limit');
  final Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    throw const FormatException('the host list is not JSON');
  }
  if (data is! Map || data.length != 2 || !data.containsKey('version') || !data.containsKey('hosts')) {
    throw const FormatException('the host list is not an object with exactly version and hosts');
  }
  final Object? version = data['version'];
  final Object? hosts = data['hosts'];
  if (version is! String || !isSpecVersion(version)) throw const FormatException("the host list's version is bad");
  if (hosts is! List || hosts.length > maxListedHosts) {
    throw const FormatException('hosts is not a list of at most $maxListedHosts');
  }
  if (!hosts.every(validListedHost)) throw const FormatException('a host is not an exact lower-case host name');
  final listed = hosts.cast<String>().toList(growable: false);
  if (listed.toSet().length != listed.length) throw const FormatException('a host is listed twice');
  return (version, listed);
}

/// A host list whose signature verified: its [version], [hosts] (in the file's order), the signed file's exact
/// [text] and its `.sig` text [signature] (kept together so the list can be verified again when read back).
class HostList {
  final String version;
  final List<String> hosts;
  final String text;
  final String signature;

  /// Private: [verifiedHostList] (which checks the signature and the text) is the only way to make one.
  const HostList._({required this.version, required this.hosts, required this.text, required this.signature});

  /// The hosts this list adds to the built-in ones, sorted (a built-in one listed adds nothing).
  List<String> get extra => ({...hosts}..removeAll(defaultAllowedHosts)).toList()..sort();
}

/// The list in [text] when [signature] (a `.sig` text) is a good signature of exactly its UTF-8 bytes under
/// [publicKey] (a `signing.pub` text; the bundled one, read from [bundle], when null) and the text is a valid list;
/// otherwise null. Never throws.
Future<HostList?> verifiedHostList(String text, String signature, {String? publicKey, AssetBundle? bundle}) async {
  try {
    if (!await verifySigned(utf8.encode(text), signature, publicKey: publicKey, bundle: bundle)) return null;
    final (version, hosts) = parseHostList(text);
    return HostList._(version: version, hosts: hosts, text: text, signature: signature);
  } catch (_) {
    return null;
  }
}

/// The hosts a flow may talk to under [list]: the built-in ones, then the ones it adds (never fewer than the
/// built-in ones; login_hosts.py's allowed_hosts is the twin).
List<String> allowedHostsWith(HostList? list) =>
    List<String>.unmodifiable([...defaultAllowedHosts, ...?list?.extra]);

/// The hosts [list] adds to [before]: what the sign-in page names after a sign-in (or a retry) a new list enabled.
List<String> hostsAddedTo(Iterable<String> before, HostList? list) {
  final had = {for (final h in before) h.toLowerCase()};
  return [for (final h in list?.extra ?? const <String>[]) if (!had.contains(h)) h];
}

/// True when [candidate] should replace [inUse]: it is newer (the same ordering as spec_version; a list is never
/// replaced by one of the same version or older).
bool newerHostList(HostList candidate, HostList? inUse) => compareSpecVersions(candidate.version, inUse?.version) > 0;

/// True when [candidate] is newer than [inUse] ([newerHostList]) and only takes hosts away: the hosts it adds are a
/// strict subset of the ones [inUse] adds. Such a list widens nothing, so SignInPage keeps it and puts it in use at once,
/// with no newer spec or retry needed (a list that adds any host is kept only after a sign-in it enabled).
bool onlyRemovesHosts(HostList candidate, HostList? inUse) {
  if (inUse == null || !newerHostList(candidate, inUse)) return false;
  final had = inUse.extra.toSet();
  final now = candidate.extra.toSet();
  return now.length < had.length && had.containsAll(now);
}

HostList? _inUse;

/// The verified host list in use on this phone, or null (the built-in hosts only).
HostList? get loginHostsInUse => _inUse;

/// Makes [list] the one in use ([currentAllowedHosts]); null goes back to the built-in hosts only. MazamaApp calls it
/// at start-up with the saved list, SignInPage after a sign-in a new list enabled; tests reset it with null.
void useLoginHosts(HostList? list) => _inUse = list;

/// The hosts every flow on this phone may talk to right now: the built-in ones plus the list in use's.
List<String> currentAllowedHosts() => allowedHostsWith(_inUse);

class LoginHostsStore {
  /// Overridable for tests, as LoginSpecStore.dataDir; defaults to the folder session.json is in.
  final Directory Function() dataDir;

  /// The `signing.pub` text a saved list is verified with; null means the bundled one (read from [bundle], the
  /// app's own unless a test passes one). Tests pass the vectors' TEST key.
  final String? publicKey;
  final AssetBundle? bundle;

  const LoginHostsStore({Directory Function()? dataDir, this.publicKey, this.bundle})
      : dataDir = dataDir ?? defaultSessionDataDir;

  File get _file => File('${dataDir().path}/login_hosts.json');
  File get _temp => File('${dataDir().path}/login_hosts.json.tmp');

  /// The saved list when there is one and it still verifies ([verifiedHostList]); null otherwise. Never throws.
  Future<HostList?> load() async {
    try {
      if (!_file.existsSync() || _file.lengthSync() > 4 * maxHostListBytes) return null;
      final Object? saved = jsonDecode(_file.readAsStringSync());
      if (saved is! Map) return null;
      final Object? text = saved['list'];
      final Object? signature = saved['signature'];
      if (text is! String || signature is! String) return null;
      return await verifiedHostList(text, signature, publicKey: publicKey, bundle: bundle);
    } catch (_) {
      return null; // unreadable, not UTF-8 or not JSON: as if nothing were saved
    }
  }

  /// Keeps [list] (its exact text and signature), atomically (a temporary file renamed over the old one, as
  /// LoginSpecStore.save does). Throws when it can't be written.
  Future<void> save(HostList list) async {
    dataDir().createSync(recursive: true);
    _temp.writeAsStringSync(jsonEncode({'list': list.text, 'signature': list.signature}), flush: true);
    _temp.renameSync(_file.path);
  }
}
