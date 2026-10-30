// GET /p/app/latest (C21, routes.yaml; specs/app-updates AU-R5, AU-R9): the newest signed release file as Mazama's
// server recorded it, {"build", "manifest" (the signed latest.json's exact text), "signature" (its .sig text)}, or all
// three null when there is none. The phone verifies it again with its own bundled key and by its own clock
// (app_release.dart's verifiedReleaseFile) before anything is offered: the server is not trusted to have checked.
//
// When the server can't answer (the request through the server link failed and the link now counts the server
// offline, server_health.dart), the same file is read from GitHub (github_files.dart, AU-D9) and held to the same
// checks. When the server answers, even with an error, GitHub is not asked.
//
// AU-R22: C21 carries the installed build and the install id (lib/device_id.dart), so the owner's App users page shows
// which build each phone runs (phones left behind by a key rotation can be found). The id is sent only in the shape the
// app makes (32 lower-case hex digits, the only one the server takes); GitHub's request carries neither. Contract: ../mazama_modules/api/routes.yaml,
// example assets/shared/api/examples/app_latest.response.json.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle;
import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'app_release.dart';
import 'github_files.dart';
import 'server_error.dart';
import 'signing.dart' show bundledPublicKey, publicKeyBytes;
import 'server_link.dart' show serverLink;
import 'server_link_client.dart' show serverClient;

/// The install id's shape (lib/device_id.dart makes 16 random bytes as hex), the only one C21 takes.
final installIdShape = RegExp(r'^[0-9a-f]{32}$');

/// The largest C21 reply read (the release file is at most 4 KiB; review M5).
const appLatestMaxBytes = 16384;

/// How long C21 may take.
const appLatestTimeout = Duration(seconds: 10);

class AppLatestError implements Exception {
  final String message;

  /// True when no answer came at all (as opposed to an error reply or a malformed one).
  final bool unreachable;

  /// True when the headers came but the body stalled: no answer either, though the server link saw one (review N4).
  final bool stalled;

  AppLatestError(this.message, {this.unreachable = false, this.stalled = false});
  @override
  String toString() => message;
}

/// C21's reply as sent: all three null when the server has nothing recorded, else all three set (unverified here).
class AppLatestReply {
  final int? build;
  final String? manifest;
  final String? signature;
  const AppLatestReply(this.build, this.manifest, this.signature);
}

/// [stream]'s bytes, failing with a [FormatException] as soon as they pass [cap], and with a [TimeoutException] when
/// they haven't all come within [timeout]; either way the stream is cancelled (review N4).
Future<List<int>> _capped(Stream<List<int>> stream, int cap, Duration timeout) {
  final out = <int>[];
  final done = Completer<List<int>>();
  late final StreamSubscription<List<int>> sub;
  void fail(Object e) {
    if (done.isCompleted) return;
    done.completeError(e);
    unawaited(sub.cancel());
  }

  final timer = Timer(timeout, () => fail(TimeoutException('the reply did not arrive', timeout)));
  sub = stream.listen(
    (chunk) {
      if (out.length + chunk.length > cap) return fail(const FormatException('over the size limit'));
      out.addAll(chunk);
    },
    onError: (Object e) => fail(e),
    onDone: () {
      if (!done.isCompleted) done.complete(out);
    },
    cancelOnError: true,
  );
  return done.future.whenComplete(timer.cancel);
}

/// Asks C21. Throws [AppLatestError] on anything but a 200 whose reply has the contract's shape (the server's own
/// wording for a 401 or 429, through describeServerError). Verifies nothing: see [fetchLatestRelease]. With
/// [installedBuild] and [deviceId], both are sent as C21's `build` and `device` (AU-R22).
Future<AppLatestReply> requestAppLatest({
  String baseUrl = apiBaseUrl,
  http.Client? client,
  Duration timeout = appLatestTimeout,
  int? installedBuild,
  String? deviceId,
}) async {
  final c = client ?? serverClient(); // through the server link, like every /p/ client (sales README R56)
  final shouldClose = client == null;
  try {
    var uri = Uri.parse('$baseUrl${appLatestPath()}');
    if (installedBuild != null &&
        installedBuild >= 0 &&
        installedBuild <= 99999999 &&
        deviceId != null &&
        installIdShape.hasMatch(deviceId)) {
      uri = uri.replace(queryParameters: {'build': '$installedBuild', 'device': deviceId});
    }
    final http.StreamedResponse resp;
    try {
      resp = await c.send(http.Request('GET', uri)..headers.addAll(appApiKeyHeaders)).timeout(timeout);
    } catch (ex) {
      throw AppLatestError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    final List<int> bytes;
    try {
      bytes = await _capped(resp.stream, appLatestMaxBytes, timeout);
    } on TimeoutException {
      // a body that stalls after the headers is no answer: GitHub may be asked (review N4)
      throw AppLatestError('the reply from ${uri.host} did not arrive', unreachable: true, stalled: true);
    } catch (_) {
      throw AppLatestError('the reply was too large or broken');
    }
    if (resp.statusCode != 200) {
      throw AppLatestError(describeServerError(resp.statusCode, utf8.decode(bytes, allowMalformed: true)));
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw AppLatestError('the server did not answer with JSON');
    }
    if (body is! Map) throw AppLatestError('unexpected response shape');
    final Object? build = body['build'];
    final Object? manifest = body['manifest'];
    final Object? signature = body['signature'];
    if (build == null && manifest == null && signature == null) return const AppLatestReply(null, null, null);
    if (build is! int || manifest is! String || signature is! String) throw AppLatestError('unexpected response shape');
    return AppLatestReply(build, manifest, signature);
  } finally {
    if (shouldClose) c.close();
  }
}

/// The newest release file that verifies against [publicKey] (a `signing.pub` text; the bundled one, from [bundle],
/// when null) and passes AU-R1 by [now]'s date: from C21, or from GitHub when the server can't answer
/// ([serverOffline], the app's server link by default, says so after the request failed). Null on anything else.
/// Never throws.
Future<ReleaseFile?> fetchLatestRelease({
  String baseUrl = apiBaseUrl,
  http.Client? serverHttp,
  http.Client? githubHttp,
  bool Function()? serverOffline,
  DateTime Function() now = DateTime.now,
  Duration timeout = appLatestTimeout,
  String? publicKey,
  AssetBundle? bundle,
  int? installedBuild,
  String? deviceId,
}) async {
  try {
    // AU-R2 / review M7: while signing.pub holds no key nothing could verify, so nothing is asked for
    if (publicKeyBytes(publicKey ?? await bundledPublicKey(bundle: bundle)) == null) return null;
    final AppLatestReply reply;
    try {
      reply = await requestAppLatest(
          baseUrl: baseUrl, client: serverHttp, timeout: timeout, installedBuild: installedBuild, deviceId: deviceId);
    } on AppLatestError catch (e) {
      if (!e.unreachable) return null; // the server answered (an error is still an answer)
      if (!e.stalled && !(serverOffline ?? () => serverLink.health.offline)()) return null;
      final files = await fetchSignedGithubFile('latest.json', client: githubHttp);
      if (files == null) return null;
      return await verifiedReleaseFile(files.$1, files.$2, today: now(), publicKey: publicKey, bundle: bundle);
    }
    final manifest = reply.manifest;
    final signature = reply.signature;
    if (manifest == null || signature == null) return null;
    final file = await verifiedReleaseFile(manifest, signature, today: now(), publicKey: publicKey, bundle: bundle);
    if (file == null || file.build != reply.build) return null;
    return file;
  } catch (_) {
    return null;
  }
}
