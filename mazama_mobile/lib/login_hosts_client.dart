// GET /p/flows/hosts (C18, routes.yaml; SL-R18): the owner's signed sign-in host list as Mazama's server last
// verified it, {"version", "list" (the signed file's exact text), "signature" (its .sig text)}, or all three null when
// there is none. The phone verifies it again with its own bundled public key (login_hosts_store.dart's
// verifiedHostList) before using it: the server is not trusted to have checked. Asked for only after a failed sign-in,
// beside the newer sign-in spec (SignInPage, SL-R10). Contract: ../mazama_modules/api/routes.yaml, example
// assets/shared/api/examples/login_hosts.response.json.
import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle;
import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'login_hosts_store.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

/// How long the fetch waits for the server's answer.
const loginHostsTimeout = Duration(seconds: 10);

class LoginHostsError implements Exception {
  final String message;

  /// True when no answer came at all (no connection, no reply within the timeout), as opposed to an error reply:
  /// SignInPage then reads the signed list from GitHub (specs/app-updates AU-R17).
  final bool unreachable;

  LoginHostsError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}

/// C18's reply as sent: all three null when the server has no verified list, else all three text (unverified here).
class LoginHostsReply {
  final String? version;
  final String? list;
  final String? signature;
  const LoginHostsReply(this.version, this.list, this.signature);
}

/// Asks C18 for the host list. Throws [LoginHostsError] on anything but a 200 whose reply has the contract's shape
/// (the server's own wording for a 401 or 429, through describeServerError). Verifies nothing: see [fetchLoginHosts].
Future<LoginHostsReply> requestLoginHosts({
  String baseUrl = apiBaseUrl,
  http.Client? client,
  Duration timeout = loginHostsTimeout,
}) async {
  final c = client ?? serverClient(); // through the server link, like every /p/ client (sales README R56)
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${loginHostsPath()}');
    http.Response resp;
    try {
      resp = await c.get(uri, headers: appApiKeyHeaders).timeout(timeout);
    } catch (ex) {
      throw LoginHostsError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode != 200) throw LoginHostsError(describeServerError(resp.statusCode, resp.body));
    Object? body;
    try {
      body = jsonDecode(utf8.decode(resp.bodyBytes));
    } on FormatException {
      throw LoginHostsError('the server did not answer with JSON');
    }
    if (body is! Map) throw LoginHostsError('unexpected response shape');
    final Object? version = body['version'];
    final Object? list = body['list'];
    final Object? signature = body['signature'];
    if (version == null && list == null && signature == null) return const LoginHostsReply(null, null, null);
    if (version is! String || list is! String || signature is! String) {
      throw LoginHostsError('unexpected response shape');
    }
    return LoginHostsReply(version, list, signature);
  } finally {
    if (shouldClose) c.close();
  }
}

/// The server's host list when it verifies against [publicKey] (a `signing.pub` text; the bundled one, from [bundle],
/// when null), is a valid list, and its version is the reply's own; null on anything else (no list, no answer, an
/// error reply, a list that doesn't verify). Never throws.
Future<HostList?> fetchLoginHosts({
  String baseUrl = apiBaseUrl,
  http.Client? client,
  Duration timeout = loginHostsTimeout,
  String? publicKey,
  AssetBundle? bundle,
}) async {
  try {
    return await verifiedLoginHostsReply(await requestLoginHosts(baseUrl: baseUrl, client: client, timeout: timeout),
        publicKey: publicKey, bundle: bundle);
  } catch (_) {
    return null;
  }
}

/// [reply]'s host list when it verifies against [publicKey] (the bundled key, from [bundle], when null), is a valid
/// list, and its version is the reply's own; else null. Never throws.
Future<HostList?> verifiedLoginHostsReply(LoginHostsReply reply, {String? publicKey, AssetBundle? bundle}) async {
  final list = reply.list;
  final signature = reply.signature;
  if (list == null || signature == null) return null;
  final verified = await verifiedHostList(list, signature, publicKey: publicKey, bundle: bundle);
  if (verified == null || verified.version != reply.version) return null;
  return verified;
}
