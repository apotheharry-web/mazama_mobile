// specs/app-updates AU-R8, AU-R9, AU-R14, AU-R15: what the phone offers (app_update_check.dart's offerFor) and when
// it looks (AppUpdateChecker). Release files are signed with the TEST key (app_release_signing.dart); the installed app
// is a fake (no Android here).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mazama_mobile/app_installer.dart';
import 'package:mazama_mobile/app_release.dart';
import 'package:mazama_mobile/app_update_check.dart';
import 'package:mazama_mobile/app_update_client.dart';
import 'package:mazama_mobile/app_update_store.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_link_client.dart';

import 'app_release_signing.dart';
import 'fake_timers.dart';

const _signer = 'aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11';

InstalledApp _app({int code = 26102901, int sdk = 30, Set<String> signers = const {_signer}}) =>
    InstalledApp(versionName: '0.2.3', versionCode: code, sdkInt: sdk, signers: signers, canInstall: true);

class _FakeInstaller extends AppInstaller {
  _FakeInstaller(this.app);
  InstalledApp app;
  int asked = 0;

  @override
  Future<InstalledApp> installed() async {
    asked++;
    return app;
  }
}

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_app_update_check_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  AppUpdateStore store() => AppUpdateStore(dataDir: () => Directory('${tempDir.path}/data'), publicKey: testPublicKey);

  group('offerFor', () {
    test('a newer build is offered', () async {
      final f = await signedRelease(build: 26103001);
      expect(offerFor(file: f, app: _app(), seen: null, refused: const {})?.build, 26103001);
    });

    test('nothing without a file', () {
      expect(offerFor(file: null, app: _app(), seen: null, refused: const {}), isNull);
    });

    test('a build at or below the installed one is not offered', () async {
      final f = await signedRelease(build: 26102901);
      expect(offerFor(file: f, app: _app(code: 26102901), seen: null, refused: const {}), isNull);
      expect(offerFor(file: f, app: _app(code: 26103001), seen: null, refused: const {}), isNull);
    });

    test('a build below the record is not offered; at the record it is', () async {
      final f = await signedRelease(build: 26103001);
      expect(offerFor(file: f, app: _app(), seen: await signedRelease(build: 26103002), refused: const {}), isNull);
      expect(offerFor(file: f, app: _app(), seen: await signedRelease(build: 26103001), refused: const {}), isNotNull);
    });

    test('a refused build is not offered', () async {
      final f = await signedRelease(build: 26103001);
      expect(offerFor(file: f, app: _app(), seen: null, refused: const {26103001}), isNull);
    });

    test('a minSdk above the phone is not offered', () async {
      final f = await signedRelease(build: 26103001, minSdk: 31);
      expect(offerFor(file: f, app: _app(sdk: 30), seen: null, refused: const {}), isNull);
      expect(offerFor(file: f, app: _app(sdk: 31), seen: null, refused: const {}), isNotNull);
    });

    test('nothing when the installed signers could not be read', () async {
      final f = await signedRelease(build: 26103001);
      expect(offerFor(file: f, app: _app(signers: const {}), seen: null, refused: const {}), isNull);
    });
  });

  group('AppUpdateChecker', () {
    late _FakeInstaller installer;
    late DateTime clock;
    late int fetched;
    setUp(() {
      installer = _FakeInstaller(_app());
      clock = DateTime.utc(2026, 10, 30, 9);
      fetched = 0;
    });

    AppUpdateChecker checker({bool android = true, bool demo = false, bool feature = true, int build = 26103001}) =>
        AppUpdateChecker(
          store: store(),
          installer: installer,
          fetchLatest: (_) async {
            fetched++;
            return signedRelease(build: build);
          },
          now: () => clock,
          isAndroid: android,
          isDemo: () => demo,
          featureOn: () => feature,
        );

    test('a check finds the offer', () async {
      final c = checker();
      var told = 0;
      c.addListener(() => told++);
      await c.check();
      expect(c.offer?.build, 26103001);
      expect(told, 1);
    });

    test('no check on iOS, in demo mode, or with the feature off', () async {
      for (final c in [checker(android: false), checker(demo: true), checker(feature: false)]) {
        await c.check();
        expect(c.offer, isNull);
      }
      expect(fetched, 0);
      expect(installer.asked, 0);
    });

    test('at most once every 6 hours; again after 6 hours', () async {
      final c = checker();
      await c.check();
      clock = clock.add(const Duration(hours: 5, minutes: 59));
      await c.check();
      expect(fetched, 1);
      clock = clock.add(const Duration(minutes: 1));
      await c.check();
      expect(fetched, 2);
      await c.check(force: true);
      expect(fetched, 3);
    });

    test('later() hides the offer until a check finds a higher build', () async {
      var build = 26103001;
      final c = AppUpdateChecker(
          store: store(),
          installer: installer,
          fetchLatest: (_) => signedRelease(build: build),
          now: () => clock,
          isAndroid: true,
          featureOn: () => true);
      await c.check();
      c.later();
      expect(c.offer, isNull);
      await c.check(force: true);
      expect(c.offer, isNull);
      build = 26103002;
      await c.check(force: true);
      expect(c.offer?.build, 26103002);
    });

    test('a refused build is not offered again', () async {
      final c = checker();
      await c.check();
      await c.refused(26103001);
      expect(c.offer, isNull);
      await c.check(force: true);
      expect(c.offer, isNull);
    });

    test('a failing check shows nothing and never throws', () async {
      final c = AppUpdateChecker(
          store: store(),
          installer: installer,
          fetchLatest: (_) async => throw StateError('anything'),
          now: () => clock,
          isAndroid: true,
          featureOn: () => true);
      await c.check();
      expect(c.offer, isNull);
    });

    test('a GitHub failure changes nothing on screen or in ServerHealth', () async {
      final timers = FakeTimers();
      final health = ServerHealth(
          probe: () async => false, startTimer: timers.start, rememberedOfflineSince: DateTime.utc(2026, 10, 30, 8));
      expect(health.offline, isTrue);
      var healthTold = 0;
      health.addListener(() => healthTold++);
      final server = ServerLinkClient(MockClient((_) async => http.Response('{}', 200)), health: health);
      final github = MockClient((_) async => http.Response('blocked', 500));
      final c = AppUpdateChecker(
          store: store(),
          installer: installer,
          fetchLatest: (_) => fetchLatestRelease(
              serverHttp: server, githubHttp: github, serverOffline: () => health.offline, now: () => clock,
              publicKey: testPublicKey),
          now: () => clock,
          isAndroid: true,
          featureOn: () => true);
      var told = 0;
      c.addListener(() => told++);
      await c.check();
      expect(c.offer, isNull);
      expect(told, 0);
      expect(health.offline, isTrue);
      expect(healthTold, 0);
      health.dispose();
    });
  });

  test('invariant: only a verified, newer, unrefused file is offered', () async {
    final today = DateTime.utc(2026, 10, 30, 12);
    const base = 26103001;
    final good = releaseText(build: base);
    final goodSig = await testSignature(good);

    // Every single-field mutation (re-signed, so only the rule decides), every one-byte change of the text (under the
    // old signature) and of the signature.
    final candidates = <(String, String)>[(good, goodSig)];
    final fieldValues = <String, List<Object?>>{
      'kind': [null, 'mazama-mobile-hosts', 1],
      'version': [null, '01.2.3', '1.2', 1, '0.2.5'],
      'build': [null, 2610300, 261030011, '26103001', true, 26103001.5, 26023001, 26110101, 26103002],
      'apk': [null, 'http://github.com/a.apk', '${apkPrefix}v0.2.5+26103001/a.apk', '${apkPrefix}v0.2.4+26103001/a.zip'],
      'sha256': [null, 'AB' * 32, 'ab' * 31],
      'size': [null, 0, maxApkBytes + 1, 1.5],
      'minSdk': [null, 20, 100],
      'extra': ['x'],
    };
    for (final e in fieldValues.entries) {
      for (final v in e.value) {
        final fields = jsonDecode(good) as Map<String, Object?>;
        if (v == null) {
          fields.remove(e.key);
        } else {
          fields[e.key] = v;
        }
        final t = '${jsonEncode(fields)}\n';
        candidates.add((t, await testSignature(t)));
      }
    }
    final bytes = utf8.encode(good);
    for (var i = 0; i < bytes.length; i++) {
      candidates.add((utf8.decode([...bytes]..[i] ^= 0x01, allowMalformed: true), goodSig));
    }
    for (var i = 0; i < goodSig.length; i++) {
      candidates.add((good, String.fromCharCodes(goodSig.codeUnits.toList()..[i] ^= 0x01)));
    }

    final records = <ReleaseFile?>[null, for (final b in [base - 1, base, base + 1]) await signedRelease(build: b)];
    var offered = 0;
    for (final (text, sig) in candidates) {
      final file = await verifiedReleaseFile(text, sig, today: today, publicKey: testPublicKey);
      for (final installed in [base - 1, base, base + 1]) {
        for (final seen in records) {
          for (final refused in [<int>{}, {base}]) {
            final offer = offerFor(file: file, app: _app(code: installed), seen: seen, refused: refused);
            if (offer == null) continue;
            offered++;
            expect(await _verifies(text, sig), isTrue);
            expect(() => parseReleaseFile(text, today: today), returnsNormally);
            expect(offer.build, greaterThan(installed));
            if (seen != null) expect(offer.build, greaterThanOrEqualTo(seen.build));
            expect(refused.contains(offer.build), isFalse);
          }
        }
      }
    }
    expect(offered, greaterThan(0));
  });
}

Future<bool> _verifies(String text, String sig) async =>
    await verifiedReleaseFile(text, sig, publicKey: testPublicKey) != null;
