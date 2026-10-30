// specs/app-updates AU-R17, AU-D6: the owner's signed sign-in files read from GitHub, when Mazama's server can't answer
// after a failed sign-in.
//
// The same files the server serves (login.yaml, login_browser.yaml, hosts.json), read with their `.sig` from the
// public repository's root through github_files.dart (exact addresses, no redirect, size caps, Dart's default headers
// only). Unlike a copy through the server (SL-D2), a copy from GitHub counts only when its signature verifies here,
// against the bundled signing.pub; while that is `none` nothing is fetched. A spec must then be a usable sign-in spec
// in its served mode under the attempt's hosts (login_spec_store.dart's usableLoginSpec); a host list must be a valid
// one (login_hosts_store.dart's verifiedHostList). Everything after that is SignInPage's, unchanged: the spec version
// strictly newer than the one that failed, one retry, saved only after a session, a host list newer than the one in use.
//
// raw.githubusercontent.com is never a sign-in host: it is not in currentAllowedHosts() and no flow runs against it.
import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle;
import 'package:http/http.dart' as http;

import 'github_files.dart';
import 'login_hosts_store.dart';
import 'login_spec_client.dart' show FetchedSpec;
import 'login_spec_store.dart' show ServedAs, usableLoginSpec;
import 'signing.dart';

/// The `source` of a spec read from GitHub.
const githubSpecSource = 'github';

Future<bool> _hasKey(String? publicKey, AssetBundle? bundle) async =>
    publicKeyBytes(publicKey ?? await bundledPublicKey(bundle: bundle)) != null;

/// The sign-in spec served as [served] (`login.yaml` for the password sign-in, `login_browser.yaml` for the browser
/// one) read from GitHub, when its signature verifies against [publicKey] (the bundled signing.pub when null) and it is
/// a usable sign-in spec in that served mode under [allowedHosts] (the phone's own when null); else null. Never throws.
Future<FetchedSpec?> githubLoginSpec({
  required ServedAs served,
  Iterable<String>? allowedHosts,
  http.Client? client,
  String? publicKey,
  AssetBundle? bundle,
}) async {
  try {
    if (!await _hasKey(publicKey, bundle)) return null;
    final files = await fetchSignedGithubFile(served == ServedAs.login ? 'login.yaml' : 'login_browser.yaml',
        client: client);
    if (files == null) return null;
    final (text, signature) = files;
    if (!await verifySigned(utf8.encode(text), signature, publicKey: publicKey, bundle: bundle)) return null;
    final spec = usableLoginSpec(text, allowedHosts: allowedHosts ?? currentAllowedHosts(), served: served);
    if (spec == null) return null;
    return FetchedSpec(spec, text, githubSpecSource);
  } catch (_) {
    return null;
  }
}

/// The owner's signed host list read from GitHub, when it verifies against [publicKey] (the bundled signing.pub when
/// null) and is a valid list; else null. Never throws.
Future<HostList?> githubHostList({http.Client? client, String? publicKey, AssetBundle? bundle}) async {
  try {
    if (!await _hasKey(publicKey, bundle)) return null;
    final files = await fetchSignedGithubFile('hosts.json', client: client);
    if (files == null) return null;
    return await verifiedHostList(files.$1, files.$2, publicKey: publicKey, bundle: bundle);
  } catch (_) {
    return null;
  }
}
