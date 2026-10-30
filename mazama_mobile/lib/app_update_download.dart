// specs/app-updates AU-R11, AU-R12, AU-D11: downloading the APK a verified release file names, and checking it before
// Android's installer sees it.
//
// [downloadApk]: only after the worker tapped Install. A GET of the file's `apk` with a client that follows no
// redirect by itself and sends nothing but Dart's default headers (no app key, no Authorization, no cookie); the phone
// follows at most [maxApkRedirects] redirects itself, each target checked by github_files.dart's [apkHopAllowed]
// before it is requested. The body is streamed to a file of its own for this attempt,
// `<cache>/updates/<build>-<random>.apk` (created exclusively, so two attempts never share one), while its SHA-256 is
// computed; the download stops as soon as it passes `size` bytes, fails when no bytes come for [apkHopTimeout] (a
// stall) or the worker cancels (at once, even during a stall), and fails unless it is exactly `size` bytes with the
// signed SHA-256. On any failure the file is deleted. Android's side then hashes the bytes again as they are copied
// into the installer session and abandons the session unless they are the signed size and SHA-256 (AppInstaller.kt),
// so the bytes installed are the bytes checked.
//
// The server's copy (AU-R21, AU-D14): when GitHub's download fails for any reason but the worker's cancel, the same
// build from Mazama's server (C22, through the server link, with the app key, no redirect followed), held to the same
// signed size and SHA-256 and then the same inspection: whoever serves the bytes, only the signed file says they are
// right. An APK refused by the inspection is not fetched again from the server (its bytes are the signed ones).
//
// [prepareUpdate]: the download, then Android's own reading of the file (app_installer.dart's inspect): the package
// must be the installed app's, its versionCode the file's build, its versionName the file's version, and its signing
// certificates exactly the installed app's. A readable APK whose fields differ is deleted and that build is never
// offered again (app_update_store.dart); a test build signed with the debug key is never offered a release. A file
// Android can't read, or whose signers it can't read, is a failed attempt (deleted, tried again on the next Install),
// never a refusal. Only an APK that passed all of it moves the phone's record (AU-R14). The cancel is looked at again
// after the download and after the inspection.
//
// AU-D11: the APK is a file (tens of megabytes, kept for minutes, handed to another app), the one file this app writes
// outside LocalStore besides the shared reconciliation image (test/local_store_guard_test.dart). It is written only
// under the cache folder's `updates/`, which [clearUpdates] empties at start-up; each attempt deletes its own file after
// the hand-over or a failure.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'app_installer.dart';
import 'app_release.dart';
import 'app_update_store.dart';
import 'github_files.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

/// The most redirects a download follows (each one checked first).
const maxApkRedirects = 3;

/// How long each request of a download may wait for its answer, and the longest wait between two chunks of a body.
const apkHopTimeout = Duration(seconds: 30);

/// How long a whole download may take.
const apkTotalTimeout = Duration(minutes: 15);

/// The card's words for a download that failed (fixed: nothing of an answer is shown).
const downloadFailedWords = 'The update could not be downloaded. Try again later.';

/// The card's words for an APK refused by the checks (AU-R12).
const cantInstallWords = "This update can't be installed on this phone.";

/// The card's words after the worker's cancel.
const downloadCancelledWords = 'The download was cancelled.';

class UpdateDownloadError implements Exception {
  final String message;

  /// The worker cancelled it.
  final bool cancelled;

  /// The APK was refused by the checks: that build is never offered again.
  final bool refused;

  const UpdateDownloadError(this.message, {this.cancelled = false, this.refused = false});
  @override
  String toString() => message;
}

const _failed = UpdateDownloadError(downloadFailedWords);
const _cancelled = UpdateDownloadError(downloadCancelledWords, cancelled: true);

/// The folder downloaded APKs go to.
Directory updatesDir(Directory cacheDir) => Directory('${cacheDir.path}/updates');

/// Empties [updatesDir]. Never throws.
void clearUpdates(Directory cacheDir) {
  try {
    final d = updatesDir(cacheDir);
    if (d.existsSync()) d.deleteSync(recursive: true);
  } catch (_) {}
}

/// Deletes the file at [path], if any. Never throws.
void deleteUpdateFile(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

bool _isRedirect(int status) => status == 301 || status == 302 || status == 303 || status == 307 || status == 308;

/// The cancel, as a flag and as a future (one that never completes when there is no cancel).
class _Cancel {
  _Cancel(Future<void>? cancel) : future = cancel ?? Completer<void>().future {
    unawaited(future.then((_) {
      done = true;
    }));
  }
  final Future<void> future;
  bool done = false;
}

/// [f]'s result, unless the cancel comes first (then [_cancelled]).
Future<T> _orCancel<T>(Future<T> f, _Cancel cancel) =>
    Future.any<T>([f, cancel.future.then<T>((_) => throw _cancelled)]);

/// Streams one 200 answer into [file], checking size and SHA-256 against [f]: a stall of [readTimeout] fails it, and
/// the cancel stops it at once. Throws [UpdateDownloadError].
Future<void> _receive(http.StreamedResponse resp, File file, ReleaseFile f, _Cancel cancel,
    {void Function(int got)? progress, required DateTime deadline, required Duration readTimeout}) async {
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  final out = file.openWrite();
  final done = Completer<void>();
  var got = 0;
  void fail(UpdateDownloadError e) {
    if (!done.isCompleted) done.completeError(e);
  }

  final sub = resp.stream.timeout(readTimeout).listen(
    (chunk) {
      if (done.isCompleted) return;
      if (cancel.done) {
        fail(_cancelled);
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail(_failed);
        return;
      }
      got += chunk.length;
      if (got > f.size) {
        fail(_failed);
        return;
      }
      hasher.add(chunk);
      out.add(chunk);
      progress?.call(got);
    },
    onError: (Object _) => fail(_failed),
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: true,
  );
  unawaited(cancel.future.then((_) => fail(_cancelled)));
  try {
    await done.future;
  } finally {
    await sub.cancel();
    await out.close();
  }
  hasher.close();
  if (got != f.size || digest.value.toString() != f.sha256) throw _failed;
}

class ServerApkError implements Exception {
  final String message;
  ServerApkError(this.message);
  @override
  String toString() => message;
}

/// C22 (`GET /p/app/apk/{build}`, AU-R21): the server's checked copy of [build]'s APK, asked through [client] (the
/// server link in the app) with the app key, following no redirect. Throws [ServerApkError] on anything but a 200 (the
/// server's own wording for a 401 or 429, through describeServerError). The caller checks the bytes.
Future<http.StreamedResponse> requestServerApk(int build,
    {required http.Client client, String baseUrl = apiBaseUrl, Duration timeout = apkHopTimeout}) async {
  final uri = Uri.parse('$baseUrl${appApkPath(build)}');
  final req = http.Request('GET', uri)
    ..followRedirects = false
    ..headers.addAll(appApiKeyHeaders);
  final http.StreamedResponse resp;
  try {
    resp = await client.send(req).timeout(timeout);
  } catch (ex) {
    throw ServerApkError('cannot reach ${uri.host}: ${ex.runtimeType}');
  }
  if (resp.statusCode != 200) {
    final body = await resp.stream.bytesToString().catchError((Object _) => '');
    throw ServerApkError(describeServerError(resp.statusCode, body));
  }
  return resp;
}

/// GitHub's download into [file]: the start address, then at most [maxApkRedirects] hops each checked by
/// [apkHopAllowed] before it is requested. Throws.
Future<void> _fromGithub(ReleaseFile f, File file, http.Client c, _Cancel cancel,
    {void Function(int got)? progress, required DateTime deadline, required Duration readTimeout}) async {
  var uri = Uri.parse(f.apk);
  var hop = 0;
  while (true) {
    if (hop > 0 && !apkHopAllowed(uri)) throw _failed;
    if (cancel.done) throw _cancelled;
    final req = http.Request('GET', uri)..followRedirects = false;
    final resp = await _orCancel(c.send(req).timeout(readTimeout), cancel);
    if (_isRedirect(resp.statusCode)) {
      unawaited(resp.stream.drain<void>().catchError((Object _) {}));
      final location = resp.headers['location'];
      if (location == null || hop >= maxApkRedirects) throw _failed;
      uri = uri.resolve(location);
      hop++;
      continue;
    }
    if (resp.statusCode != 200) {
      unawaited(resp.stream.drain<void>().catchError((Object _) {}));
      throw _failed;
    }
    await _receive(resp, file, f, cancel, progress: progress, deadline: deadline, readTimeout: readTimeout);
    return;
  }
}

/// A file name of this attempt's own: `<build>-<16 random hex digits>.apk`.
String _attemptName(int build) {
  final r = Random.secure();
  final suffix = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  return '$build-$suffix.apk';
}

/// Downloads [f]'s APK into [updatesDir], in a file of this attempt's own, and returns the file; throws
/// [UpdateDownloadError] (fixed words) on any failure, leaving no file. [cancel] completing stops it at once. GitHub
/// first ([client], a plain one by default); with [fromServer], when GitHub's download fails for any reason but the
/// cancel, the server's copy (C22, [serverHttp], the server link by default), held to the same signed size and
/// SHA-256 (AU-R21). [readTimeout] is the longest wait for an answer or between two chunks.
Future<File> downloadApk(
  ReleaseFile f, {
  required Directory cacheDir,
  http.Client? client,
  void Function(int got)? progress,
  Future<void>? cancel,
  bool fromServer = false,
  http.Client? serverHttp,
  Duration readTimeout = apkHopTimeout,
}) async {
  final stop = _Cancel(cancel);
  if (!apkAddressOk(f.apk, f.version, f.build) || !apkStartUrlAllowed(Uri.parse(f.apk))) throw _failed;
  final dir = updatesDir(cacheDir);
  final deadline = DateTime.now().add(apkTotalTimeout);
  final File file;
  try {
    dir.createSync(recursive: true);
    file = File('${dir.path}/${_attemptName(f.build)}');
    file.createSync(exclusive: true); // this attempt's own file: never one another attempt is writing
  } catch (_) {
    throw _failed;
  }
  UpdateDownloadError fail(Object ex) {
    deleteUpdateFile(file.path);
    if (stop.done) return _cancelled;
    return ex is UpdateDownloadError ? ex : _failed;
  }

  final c = client ?? http.Client(); // a plain client: GitHub is not Mazama's server
  try {
    await _fromGithub(f, file, c, stop, progress: progress, deadline: deadline, readTimeout: readTimeout);
    if (stop.done) throw _cancelled;
    return file;
  } catch (ex) {
    final error = fail(ex);
    if (error.cancelled || !fromServer) throw error;
  } finally {
    if (client == null) c.close();
  }
  final s = serverHttp ?? serverClient();
  try {
    file.createSync(exclusive: true);
    final resp = await _orCancel(requestServerApk(f.build, client: s, timeout: readTimeout), stop);
    await _receive(resp, file, f, stop, progress: progress, deadline: deadline, readTimeout: readTimeout);
    if (stop.done) throw _cancelled;
    return file;
  } catch (ex) {
    throw fail(ex);
  } finally {
    if (serverHttp == null) s.close();
  }
}

/// [downloadApk], then Android's reading of the file against [app] (see this file's comment). A readable APK whose
/// fields differ is deleted and its build refused in [store]; an unreadable one is a failed attempt; one that passes
/// moves the phone's record and is returned. The cancel is looked at after each step.
Future<File> prepareUpdate(
  ReleaseFile f, {
  required Directory cacheDir,
  required AppInstaller installer,
  required InstalledApp app,
  required AppUpdateStore store,
  http.Client? client,
  void Function(int got)? progress,
  Future<void>? cancel,
  bool fromServer = false,
  http.Client? serverHttp,
  Duration readTimeout = apkHopTimeout,
}) async {
  final stop = _Cancel(cancel);
  final file = await downloadApk(f,
      cacheDir: cacheDir,
      client: client,
      progress: progress,
      cancel: stop.future,
      fromServer: fromServer,
      serverHttp: serverHttp,
      readTimeout: readTimeout);
  if (stop.done) {
    deleteUpdateFile(file.path);
    throw _cancelled;
  }
  final ApkInfo info;
  try {
    info = await installer.inspect(file.path);
  } catch (_) {
    deleteUpdateFile(file.path);
    throw stop.done ? _cancelled : _failed;
  }
  if (stop.done) {
    deleteUpdateFile(file.path);
    throw _cancelled;
  }
  if (info.package.isEmpty || info.signers.isEmpty || app.signers.isEmpty) {
    deleteUpdateFile(file.path); // Android couldn't read it (or its signers): a failed attempt, never a refusal
    throw _failed;
  }
  final ok = info.package == appPackageName &&
      info.versionCode == f.build &&
      info.versionName == f.version &&
      setEquals(info.signers, app.signers);
  if (!ok) {
    deleteUpdateFile(file.path);
    await store.refuse(f.build);
    throw const UpdateDownloadError(cantInstallWords, refused: true);
  }
  await store.recordVerified(f);
  return file;
}
