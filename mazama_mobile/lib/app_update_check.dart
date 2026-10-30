// specs/app-updates AU-R8, AU-R9, AU-R14, AU-R15: whether a newer release is offered on this phone.
//
// [offerFor] is the rule, pure: a release file (already verified: a ReleaseFile is only ever made by
// app_release.dart's verifiedReleaseFile) is offered only when its build is above the installed versionCode, not below
// the phone's record (app_update_store.dart), not refused before, its minSdk is at most the phone's API level, and the
// installed app's signing certificates could be read.
//
// [AppUpdateChecker] runs it: on Android only, never in demo mode (DM-D1), only while `app_updates` is on
// (features.g.dart), at start-up and when the app returns to the foreground, at most once every [checkInterval],
// unawaited by its callers (MazamaApp). Every failure is quiet (AU-R15): nothing on screen, no banner, no report; only
// the kind of failure is logged. GitHub's requests don't go through the server link, so the server's health is never
// touched by them.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'app_installer.dart';
import 'app_release.dart';
import 'app_update_client.dart';
import 'app_update_store.dart';
import 'demo/demo_banner.dart' show demoModeOn;
import 'device_id.dart';
import 'features.g.dart';

/// The least time between two checks.
const checkInterval = Duration(hours: 6);

/// The app's fetch: C21 (then GitHub), reporting the installed build and the install id (AU-R22).
Future<ReleaseFile?> _defaultFetch(InstalledApp app) async {
  String? id;
  try {
    id = await const DeviceIdStore().idOrCreate();
  } catch (_) {}
  return fetchLatestRelease(installedBuild: app.versionCode, deviceId: id);
}

/// A release the phone may install now.
class UpdateOffer {
  final ReleaseFile file;
  const UpdateOffer(this.file);

  String get version => file.version;
  int get build => file.build;
}

/// The offer [file] makes on this phone, or null (see this file's comment).
UpdateOffer? offerFor(
    {required ReleaseFile? file, required InstalledApp app, required ReleaseFile? seen, required Set<int> refused}) {
  if (file == null) return null;
  if (file.build <= app.versionCode) return null;
  if (seen != null && file.build < seen.build) return null;
  if (refused.contains(file.build)) return null;
  if (file.minSdk > app.sdkInt) return null;
  if (app.signers.isEmpty) return null;
  return UpdateOffer(file);
}

class AppUpdateChecker extends ChangeNotifier {
  AppUpdateChecker({
    AppUpdateStore? store,
    AppInstaller? installer,
    Future<ReleaseFile?> Function(InstalledApp app)? fetchLatest,
    DateTime Function()? now,
    bool Function()? isDemo,
    bool? isAndroid,
    bool Function()? featureOn,
  })  : store = store ?? const AppUpdateStore(),
        installer = installer ?? AppInstaller(),
        _fetchLatest = fetchLatest ?? _defaultFetch,
        now = now ?? DateTime.now,
        _isDemo = isDemo ?? (() => demoModeOn.value),
        _isAndroid = isAndroid ?? Platform.isAndroid,
        _featureOn = featureOn ?? (() => featureOnForLicense('app_updates', 'ServiceCenter'));

  final AppUpdateStore store;
  final AppInstaller installer;
  final Future<ReleaseFile?> Function(InstalledApp app) _fetchLatest;
  final DateTime Function() now;
  final bool Function() _isDemo;
  final bool _isAndroid;
  final bool Function() _featureOn;

  DateTime? _lastCheck;
  bool _checking = false;
  UpdateOffer? _offer;
  InstalledApp? _app;
  int? _laterBuild;
  bool _disposed = false;

  /// The offer to show now, or null (none, or hidden by [later] until a higher build).
  UpdateOffer? get offer {
    final o = _offer;
    if (o == null) return null;
    final hidden = _laterBuild;
    if (hidden != null && o.build <= hidden) return null;
    return o;
  }

  /// The installed app as the last check read it (the card needs its signers and "install unknown apps").
  InstalledApp? get installedApp => _app;

  /// Whether checks run at all here: Android, not the demo, the feature on.
  bool get enabled => _isAndroid && !_isDemo() && _featureOn();

  /// Looks for a newer release, unless one was looked for in the last [checkInterval] (or [force]). Never throws.
  Future<void> check({bool force = false}) async {
    if (!enabled || _checking) return;
    final t = now();
    final last = _lastCheck;
    if (!force && last != null && t.difference(last) < checkInterval) return;
    _lastCheck = t;
    _checking = true;
    try {
      final app = await installer.installed();
      final file = await _fetchLatest(app);
      final next = offerFor(file: file, app: app, seen: await store.seen(), refused: await store.refused());
      _app = app;
      _setOffer(next);
    } catch (ex) {
      debugPrint('app update check failed: ${ex.runtimeType}');
    } finally {
      _checking = false;
    }
  }

  /// The worker tapped Later: the card hides until the app restarts or a check finds a higher build.
  void later() {
    final o = _offer;
    if (o == null) return;
    _laterBuild = o.build;
    _notify();
  }

  /// [build]'s APK was refused (AU-R12): it is not offered again.
  Future<void> refused(int build) async {
    await store.refuse(build);
    if (_offer?.build == build) _setOffer(null);
  }

  void _setOffer(UpdateOffer? next) {
    if (next?.build == _offer?.build) {
      _offer = next;
      return;
    }
    _offer = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

AppUpdateChecker? _appChecker;

/// The app's checker (MazamaApp makes it), or null (tests, before the app starts).
AppUpdateChecker? get appUpdateChecker => _appChecker;

/// Makes [checker] the app's (MazamaApp).
void useAppUpdateChecker(AppUpdateChecker checker) => _appChecker = checker;

/// [checker] is going away (MazamaApp disposed).
void releaseAppUpdateChecker(AppUpdateChecker checker) {
  if (identical(_appChecker, checker)) _appChecker = null;
}
