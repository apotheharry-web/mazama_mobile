// specs/app-updates AU-R12, AU-R13: the Android side of an update, through the native channel `mazama/app_installer`
// (android/app/src/main/kotlin/com/example/mazama_mobile/AppInstaller.kt).
//
// - installed(): the installed app's version name and code, the phone's Android API level, the SHA-256 of each of the
//   app's signing certificates, and whether "install unknown apps" is on for it (canRequestPackageInstalls);
// - inspect(path): a downloaded APK's package name, version code and name, and signing certificates
//   (PackageManager.getPackageArchiveInfo), read before Android's installer ever sees it;
// - openInstallSettings(): Android's "install unknown apps" setting for this app;
// - stage(path, sha256, size): copies the APK into a new PackageInstaller session; Android's side hashes the bytes as it
//   copies them and abandons the session unless they are exactly the signed size and SHA-256 (so the bytes installed
//   are the bytes checked). Answers `staged:<session id>`, or `refused:<words>`;
// - commit(session): commits it; the session always asks the worker to confirm (USER_ACTION_NOT_REQUIRED is never
//   set). The app calls it only after checking the carts again, since the copy takes a while (review N3). Answers
//   `started`, or `refused:<Android's words>`;
// - abandon(session): drops a staged session (a cart line was added meanwhile);
// - takeStatus(): Android's words for a refusal that came after the hand-over (the session's status), once, or null.
// Inspect and install run off Android's main thread.
//
// Android only (AU-D13): on any other platform, or when the channel isn't there, every call fails with
// [AppInstallerError] in fixed words, and the update check offers nothing.
import 'package:flutter/services.dart';

/// The package the app is installed as (android/app/build.gradle.kts's applicationId).
const appPackageName = 'com.mazamamushrooms.mobile';

/// The channel AppInstaller.kt answers on.
const appInstallerChannel = MethodChannel('mazama/app_installer');

class AppInstallerError implements Exception {
  final String message;
  const AppInstallerError(this.message);
  @override
  String toString() => message;
}

/// The installed app, as Android's package manager reports it.
class InstalledApp {
  final String versionName;
  final int versionCode;
  final int sdkInt;

  /// The SHA-256 (lower-case hex) of each of the app's signing certificates; empty when they couldn't be read.
  final Set<String> signers;

  /// Whether "install unknown apps" is on for the app.
  final bool canInstall;

  const InstalledApp(
      {required this.versionName,
      required this.versionCode,
      required this.sdkInt,
      required this.signers,
      required this.canInstall});
}

/// A downloaded APK, as Android reads it from the file.
class ApkInfo {
  final String package;
  final int versionCode;
  final String versionName;
  final Set<String> signers;

  const ApkInfo({required this.package, required this.versionCode, required this.versionName, required this.signers});
}

Set<String> _signers(Object? raw) => {
      if (raw is List)
        for (final s in raw)
          if (s is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(s)) s,
    };

class AppInstaller {
  AppInstaller({MethodChannel? channel}) : _channel = channel ?? appInstallerChannel;

  final MethodChannel _channel;

  Future<Map<Object?, Object?>> _map(String method, [Object? args]) async {
    final Object? reply;
    try {
      reply = await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException {
      throw const AppInstallerError("Android couldn't answer.");
    } on MissingPluginException {
      throw const AppInstallerError("This phone can't install updates from the app.");
    }
    if (reply is! Map) throw const AppInstallerError("Android couldn't answer.");
    return reply;
  }

  /// The installed app. Throws [AppInstallerError].
  Future<InstalledApp> installed() async {
    final m = await _map('installed');
    final name = m['versionName'];
    final code = m['versionCode'];
    final sdk = m['sdkInt'];
    if (name is! String || code is! int || sdk is! int) throw const AppInstallerError("Android couldn't answer.");
    return InstalledApp(
        versionName: name,
        versionCode: code,
        sdkInt: sdk,
        signers: _signers(m['signers']),
        canInstall: m['canInstall'] == true);
  }

  /// What the APK at [path] says it is. Throws [AppInstallerError] (also when Android can't read it as an APK).
  Future<ApkInfo> inspect(String path) async {
    final m = await _map('inspect', {'path': path});
    final package = m['package'];
    final code = m['versionCode'];
    final name = m['versionName'];
    if (package is! String || code is! int || name is! String) {
      throw const AppInstallerError("This update can't be installed on this phone.");
    }
    return ApkInfo(package: package, versionCode: code, versionName: name, signers: _signers(m['signers']));
  }

  /// Opens Android's "install unknown apps" setting for the app.
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod<Object?>('openInstallSettings');
    } on PlatformException {
      throw const AppInstallerError("Android's setting couldn't be opened.");
    } on MissingPluginException {
      throw const AppInstallerError("This phone can't install updates from the app.");
    }
  }

  Future<String> _text(String method, Map<String, Object?> args, bool Function(String) ok) async {
    final Object? reply;
    try {
      reply = await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException {
      throw const AppInstallerError("Android's installer couldn't be started.");
    } on MissingPluginException {
      throw const AppInstallerError("This phone can't install updates from the app.");
    }
    if (reply is String && (ok(reply) || reply.startsWith('refused:'))) return reply;
    throw const AppInstallerError("Android's installer couldn't be started.");
  }

  /// Copies the APK at [path] into a new installer session, which Android abandons unless the bytes are [size] bytes
  /// with [sha256]: `staged:<session id>`, or `refused:<words>`. Throws [AppInstallerError] when the channel fails.
  Future<String> stage(String path, {required String sha256, required int size}) =>
      _text('stage', {'path': path, 'sha256': sha256, 'size': size}, (r) => RegExp(r'^staged:[0-9]+$').hasMatch(r));

  /// Commits staged [session]: Android's installer asks the worker to confirm. `started`, or `refused:<words>`.
  Future<String> commit(int session) => _text('commit', {'session': session}, (r) => r == 'started');

  /// Drops staged [session]. Never throws.
  Future<void> abandon(int session) async {
    try {
      await _channel.invokeMethod<Object?>('abandon', {'session': session});
    } catch (_) {}
  }

  /// Android's words for a refusal after the hand-over (once), or null. Never throws.
  Future<String?> takeStatus() async {
    try {
      final reply = await _channel.invokeMethod<Object?>('takeStatus');
      return reply is String && reply.isNotEmpty ? reply : null;
    } catch (_) {
      return null;
    }
  }
}
