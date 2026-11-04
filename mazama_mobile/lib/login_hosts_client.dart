// GET /p/flows/hosts (routes.yaml): the owner's signed sign-in host list as Mazama's server last
// verified it, {"version", "list" (the signed file's exact text), "signature" (its .sig text)}, or all three null when
// there is none. The phone verifies it again with its own bundled public key (login_hosts_store.dart's
// verifiedHostList) before using it: the server is not trusted to have checked. Asked for only after a failed sign-in,
// beside the newer sign-in spec (SignInPage). Contract: ../mazama_modules/api/routes.yaml, example
// assets/shared/api/examples/login_hosts.response.json.
import 'package:flutter/services.dart' show AssetBundle;
import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'login_hosts_store.dart';
import 'server_request.dart';

/// How long the fetch waits for the server's answer.
const loginHostsTimeout = Duration(seconds: 10);

class LoginHostsError implements Exception {
  final String message;

  /// True when no answer came at all (no connection, no reply within the timeout), as opposed to an error reply:
  /// SignInPage then reads the signed list from GitHub.
  final bool unreachable;

  LoginHostsError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}

/// The route's reply as sent: all three null when the server has no verified list, else all three text (unverified here).
class LoginHostsReply {
  final String? version;
  final String? list;
  final String? signature;
  const LoginHostsReply(this.version, this.list, this.signature);
}

/// Asks GET /p/flows/hosts for the host list. Throws [LoginHostsError] on anything but a 200 whose reply has the contract's shape
/// (the server's own wording for a 401 or 429, through describeServerError). Verifies nothing: see [fetchLoginHosts].
Future<LoginHostsReply> requestLoginHosts({
  String baseUrl = apiBaseUrl,
  http.Client? client,
  Duration timeout = loginHostsTimeout,
}) =>
    serverRequest('$baseUrl${loginHostsPath()}', error: _loginHostsError, timeout: timeout, client: client,
        read: (resp) {
      final body = serverJson(resp.bodyBytes, _loginHostsError);
      if (body is! Map) throw LoginHostsError('unexpected response shape');
      final Object? version = body['version'];
      final Object? list = body['list'];
      final Object? signature = body['signature'];
      if (version == null && list == null && signature == null) return const LoginHostsReply(null, null, null);
      if (version is! String || list is! String || signature is! String) {
        throw LoginHostsError('unexpected response shape');
      }
      return LoginHostsReply(version, list, signature);
    });

// A LoginHostsError says only whether no answer came at all: an error reply (a 5xx included) is an answer.
LoginHostsError _loginHostsError(String message, {int? status, bool unreachable = false}) =>
    LoginHostsError(message, unreachable: unreachable && status == null);

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
