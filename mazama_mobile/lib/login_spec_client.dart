// GET /p/flows/login (C17, routes.yaml; SL-R9): the newest sign-in spec Mazama's server knows of (its own or the hosted
// copy), for a phone whose bundled one no longer gets through the state's sign-in. The phone sends the spec format it
// reads; the server answers {"specVersion", "source": "server" | "hosted", "yaml"}. The reply is held to the same rule
// as a saved spec (login_spec_store.dart's usableLoginSpec) before anything uses it, in the login served mode (no
// open_browser). GET /p/flows/login_browser (C19, SL-R19) is the same for the browser sign-in spec (the sign-in on the
// state's own page), in the browser served mode (an open_browser in login). Contract: ../mazama_modules/api/routes.yaml,
// examples assets/shared/api/examples/login_spec.response.json and login_browser_spec.response.json.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'flow/flow_spec.dart';
import 'login_spec_store.dart' show ServedAs, usableLoginSpec;
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

/// How long the fetch waits for the server's answer.
const loginSpecTimeout = Duration(seconds: 10);

class LoginSpecError implements Exception {
  final String message;
  LoginSpecError(this.message);
  @override
  String toString() => message;
}

/// A usable sign-in spec from the server: the parsed [spec], the [yaml] text it came from (what LoginSpecStore.save
/// keeps) and where the server got it ([source]: "server" or "hosted").
class FetchedSpec {
  final FlowSpec spec;
  final String yaml;
  final String source;
  const FetchedSpec(this.spec, this.yaml, this.source);
}

/// Asks C17 for the newest sign-in spec this app's format can read. Throws [LoginSpecError] on anything but a 200
/// whose reply is a usable spec (the server's own wording for a 401 or 429, through describeServerError). Usable under
/// [allowedHosts]: the phone's own allowlist by default; SignInPage passes the built-in hosts plus a host list it
/// fetched with the spec (SL-R18). A spec with an open_browser is refused (SL-R19's login served mode).
Future<FetchedSpec> requestLoginSpec({
  String baseUrl = apiBaseUrl,
  http.Client? client,
  Duration timeout = loginSpecTimeout,
  Iterable<String>? allowedHosts,
}) =>
    _requestSpec(loginSpecPath(), ServedAs.login,
        baseUrl: baseUrl, client: client, timeout: timeout, allowedHosts: allowedHosts);

/// Asks C19 for the newest browser sign-in spec this app's format can read (SL-R19), as [requestLoginSpec] does for
/// the password one; a spec without an open_browser in `login` is refused (the browser served mode).
Future<FetchedSpec> requestBrowserLoginSpec({
  String baseUrl = apiBaseUrl,
  http.Client? client,
  Duration timeout = loginSpecTimeout,
  Iterable<String>? allowedHosts,
}) =>
    _requestSpec(loginBrowserSpecPath(), ServedAs.browser,
        baseUrl: baseUrl, client: client, timeout: timeout, allowedHosts: allowedHosts);

Future<FetchedSpec> _requestSpec(
  String path,
  ServedAs served, {
  required String baseUrl,
  required http.Client? client,
  required Duration timeout,
  required Iterable<String>? allowedHosts,
}) async {
  final c = client ?? serverClient(); // through the server link, like every /p/ client (sales README R56)
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl$path?format=$supportedFlowFormat');
    http.Response resp;
    try {
      resp = await c.get(uri, headers: appApiKeyHeaders).timeout(timeout);
    } catch (ex) {
      throw LoginSpecError('cannot reach ${uri.host}: ${ex.runtimeType}');
    }
    if (resp.statusCode != 200) throw LoginSpecError(describeServerError(resp.statusCode, resp.body));
    Object? body;
    try {
      body = jsonDecode(utf8.decode(resp.bodyBytes));
    } on FormatException {
      throw LoginSpecError('the server did not answer with JSON');
    }
    if (body is! Map) throw LoginSpecError('unexpected response shape');
    final yaml = body['yaml'];
    final source = body['source'];
    final version = body['specVersion'];
    if (yaml is! String || version is! String || (source != 'server' && source != 'hosted')) {
      throw LoginSpecError('unexpected response shape');
    }
    final spec = usableLoginSpec(yaml, allowedHosts: allowedHosts, served: served);
    if (spec == null) throw LoginSpecError('the server sent a sign-in spec this app cannot use');
    if (spec.specVersion != version) throw LoginSpecError("the reply's specVersion is not the spec's own");
    return FetchedSpec(spec, yaml, source as String);
  } finally {
    if (shouldClose) c.close();
  }
}

/// [requestLoginSpec], or null on any failure (no answer, an error reply, a reply that isn't a usable spec, or no
/// answer within [timeout]). Never throws.
Future<FetchedSpec?> fetchLoginSpec({
  String baseUrl = apiBaseUrl,
  http.Client? client,
  Duration timeout = loginSpecTimeout,
  Iterable<String>? allowedHosts,
}) async {
  try {
    return await requestLoginSpec(baseUrl: baseUrl, client: client, timeout: timeout, allowedHosts: allowedHosts);
  } catch (_) {
    return null;
  }
}

/// [requestBrowserLoginSpec], or null on any failure, as [fetchLoginSpec]. Never throws.
Future<FetchedSpec?> fetchBrowserLoginSpec({
  String baseUrl = apiBaseUrl,
  http.Client? client,
  Duration timeout = loginSpecTimeout,
  Iterable<String>? allowedHosts,
}) async {
  try {
    return await requestBrowserLoginSpec(baseUrl: baseUrl, client: client, timeout: timeout, allowedHosts: allowedHosts);
  } catch (_) {
    return null;
  }
}
