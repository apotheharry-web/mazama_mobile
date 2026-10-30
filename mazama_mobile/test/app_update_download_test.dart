// specs/app-updates AU-R11, AU-R12, AU-D11: the APK download (app_update_download.dart): redirects followed by the
// phone itself and only to GitHub's download hosts, no app key or cookie, the signed size and SHA-256, nothing left
// behind on a failure; and Android's reading of the file (a fake installer here) before the installer sees it. The
// "APK" is a few made-up bytes; release files are signed with the TEST key (app_release_signing.dart).
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/app_installer.dart';
import 'package:mazama_mobile/app_release.dart';
import 'package:mazama_mobile/app_update_download.dart';
import 'package:mazama_mobile/app_update_store.dart';

import 'app_release_signing.dart';

const _signer = 'aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11';
const _asset = 'https://release-assets.githubusercontent.com/github-production-release-asset/1/x?sp=r&sig=abc';
final _body = List<int>.generate(70000, (i) => (i * 7) % 256);
const _build = 26103001;

InstalledApp _app({Set<String> signers = const {_signer}}) =>
    InstalledApp(versionName: '0.2.3', versionCode: 26102901, sdkInt: 30, signers: signers, canInstall: true);

class _FakeInstaller extends AppInstaller {
  _FakeInstaller(this.info);
  ApkInfo info;
  final inspected = <String>[];

  @override
  Future<ApkInfo> inspect(String path) async {
    inspected.add(path);
    return info;
  }
}

ApkInfo _info({String package = appPackageName, int code = _build, String name = '0.2.4', Set<String> signers = const {_signer}}) =>
    ApkInfo(package: package, versionCode: code, versionName: name, signers: signers);

void main() {
  late Directory tempDir;
  late Directory cache;
  late ReleaseFile release;
  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mazama_app_update_download_test_');
    cache = Directory('${tempDir.path}/cache')..createSync();
    release = await signedRelease(build: _build, sha256: sha256.convert(_body).toString(), size: _body.length);
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  AppUpdateStore store() => AppUpdateStore(dataDir: () => Directory('${tempDir.path}/data'), publicKey: testPublicKey);

  List<String> left() => updatesDir(cache).existsSync()
      ? [for (final e in updatesDir(cache).listSync()) e.path.split('/').last]
      : const [];

  /// GitHub: the release address redirects to [_asset] (or [answers] says otherwise), which serves [_body].
  MockClient github(List<http.BaseRequest> seen, {Map<String, http.Response Function()>? answers}) =>
      MockClient((req) async {
        seen.add(req);
        final url = req.url.toString();
        final a = answers?[url];
        if (a != null) return a();
        if (url == release.apk) return http.Response('', 302, headers: {'location': _asset});
        if (url == _asset) return http.Response.bytes(_body, 200);
        return http.Response('', 404);
      });

  test('follows a github.com -> release-assets redirect itself, and keeps <build>.apk', () async {
    final seen = <http.BaseRequest>[];
    final file = await downloadApk(release, cacheDir: cache, client: github(seen));
    expect(file.path, startsWith('${updatesDir(cache).path}/$_build-'));
    expect(file.path, endsWith('.apk'));
    expect(file.readAsBytesSync(), _body);
    expect([for (final r in seen) r.url.toString()], [release.apk, _asset]);
    for (final r in seen) {
      expect(r.followRedirects, isFalse);
    }
  });

  test('sends no app key, Authorization or cookie on any hop', () async {
    final seen = <http.BaseRequest>[];
    await downloadApk(release, cacheDir: cache,
        client: github(seen, answers: {
          release.apk: () => http.Response('', 302, headers: {'location': _asset, 'set-cookie': 's=1'}),
        }));
    for (final r in seen) {
      final names = r.headers.keys.map((k) => k.toLowerCase()).toSet();
      expect(names.intersection({'x-app-key', 'authorization', 'cookie'}), isEmpty);
    }
  });

  for (final target in [
    'https://evil.example.com/a.apk',
    'http://release-assets.githubusercontent.com/a',
    'https://release-assets.githubusercontent.com:8443/a',
    'https://user@release-assets.githubusercontent.com/a',
  ]) {
    test('a hop apkHopAllowed refuses is never requested: $target', () async {
      final seen = <http.BaseRequest>[];
      await expectLater(
          downloadApk(release, cacheDir: cache,
              client: github(seen, answers: {
                release.apk: () => http.Response('', 302, headers: {'location': target}),
              })),
          throwsA(isA<UpdateDownloadError>()));
      expect([for (final r in seen) r.url.toString()], [release.apk]);
      expect(left(), isEmpty);
    });
  }

  test('a 4th redirect is refused; 3 are followed', () async {
    final hops = [release.apk, for (var i = 0; i < 4; i++) 'https://objects.githubusercontent.com/$i'];
    Map<String, http.Response Function()> chain(int redirects) => {
          for (var i = 0; i < redirects; i++) hops[i]: () => http.Response('', 302, headers: {'location': hops[i + 1]}),
          hops[redirects]: () => http.Response.bytes(_body, 200),
        };
    final seen = <http.BaseRequest>[];
    await expectLater(downloadApk(release, cacheDir: cache, client: github(seen, answers: chain(4))),
        throwsA(isA<UpdateDownloadError>()));
    expect(seen, hasLength(4));
    expect(left(), isEmpty);
    final ok = await downloadApk(release, cacheDir: cache, client: github([], answers: chain(3)));
    expect(ok.readAsBytesSync(), _body);
  });

  test('stops as soon as the body passes size bytes, and leaves no file', () async {
    var sent = 0;
    final client = MockClient.streaming((req, _) async {
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < 1000; i++) {
          sent += 8192;
          yield List<int>.filled(8192, 1);
        }
      }

      return http.StreamedResponse(chunks(), 200);
    });
    await expectLater(downloadApk(release, cacheDir: cache, client: client), throwsA(isA<UpdateDownloadError>()));
    expect(sent, lessThanOrEqualTo(_body.length + 2 * 8192));
    expect(left(), isEmpty);
  });

  for (final served in ['short', 'changed', 'empty']) {
    test('a $served body fails and leaves no file', () async {
      final bytes = switch (served) {
        'short' => _body.sublist(1),
        'changed' => [..._body]..[5] ^= 1,
        _ => <int>[],
      };
      final client = MockClient((_) async => http.Response.bytes(bytes, 200));
      await expectLater(downloadApk(release, cacheDir: cache, client: client), throwsA(isA<UpdateDownloadError>()));
      expect(left(), isEmpty);
    });
  }

  test('a status other than 200 or a network failure fails', () async {
    for (final client in [
      MockClient((_) async => http.Response('', 500)),
      MockClient((_) async => throw http.ClientException('blocked')),
    ]) {
      await expectLater(downloadApk(release, cacheDir: cache, client: client), throwsA(isA<UpdateDownloadError>()));
    }
    expect(left(), isEmpty);
  });

  test('cancel leaves no file', () async {
    final cancel = Completer<void>();
    final client = MockClient.streaming((req, _) async {
      Stream<List<int>> chunks() async* {
        yield _body.sublist(0, 1000);
        cancel.complete();
        await Future<void>.delayed(Duration.zero);
        yield _body.sublist(1000);
      }

      return http.StreamedResponse(chunks(), 200);
    });
    await expectLater(
        downloadApk(release, cacheDir: cache, client: client, cancel: cancel.future),
        throwsA(isA<UpdateDownloadError>().having((e) => e.cancelled, 'cancelled', isTrue)));
    expect(left(), isEmpty);
  });

  test('progress is told the bytes so far', () async {
    final got = <int>[];
    await downloadApk(release, cacheDir: cache, client: github([]), progress: got.add);
    expect(got.last, _body.length);
  });

  group('prepareUpdate', () {
    Future<Object?> prepare(ApkInfo info, {InstalledApp? app}) async {
      try {
        return await prepareUpdate(release,
            cacheDir: cache, installer: _FakeInstaller(info), app: app ?? _app(), store: store(), client: github([]));
      } on UpdateDownloadError catch (e) {
        return e;
      }
    }

    test('an APK that matches is kept and moves the record', () async {
      final got = await prepare(_info());
      expect(got, isA<File>());
      expect((await store().seen())?.build, _build);
    });

    test('an APK whose signer differs is deleted and refused', () async {
      final got = await prepare(_info(signers: {'bb' * 32}));
      expect(got, isA<UpdateDownloadError>().having((e) => e.refused, 'refused', isTrue));
      expect((got as UpdateDownloadError).message, cantInstallWords);
      expect(left(), isEmpty);
      expect(await store().refused(), {_build});
      expect(await store().seen(), isNull);
    });

    for (final (what, info) in [
      ('another package', _info(package: 'com.example.other')),
      ('another version code', _info(code: _build + 1)),
      ('another version name', _info(name: '0.2.5')),
      ('an extra signer', _info(signers: {_signer, 'bb' * 32})),
    ]) {
      test('$what: deleted and refused', () async {
        final got = await prepare(info);
        expect(got, isA<UpdateDownloadError>().having((e) => e.refused, 'refused', isTrue));
        expect(left(), isEmpty);
        expect(await store().refused(), {_build});
      });
    }

    for (final (what, info) in [
      ('a file Android cannot read', _info(package: '', code: 0, name: '', signers: const {})),
      ('a file whose signers Android cannot read', _info(signers: const {})),
    ]) {
      test('$what is a failed attempt, never a refusal (review I1, M3)', () async {
        final got = await prepare(info);
        expect(got, isA<UpdateDownloadError>().having((e) => e.refused, 'refused', isFalse));
        expect((got as UpdateDownloadError).message, downloadFailedWords);
        expect(left(), isEmpty);
        expect(await store().refused(), isEmpty);
      });
    }

    test('a cancel during the inspection hands nothing on and refuses nothing (review I2)', () async {
      final cancel = Completer<void>();
      final installer = _InspectCancels(_info(signers: {'bb' * 32}), cancel);
      await expectLater(
          prepareUpdate(release,
              cacheDir: cache, installer: installer, app: _app(), store: store(), client: github([]), cancel: cancel.future),
          throwsA(isA<UpdateDownloadError>().having((e) => e.cancelled, 'cancelled', isTrue)));
      expect(left(), isEmpty);
      expect(await store().refused(), isEmpty);
      expect(await store().seen(), isNull);
    });

    test('with the installed signers unreadable nothing is kept', () async {
      final got = await prepare(_info(signers: const {}), app: _app(signers: const {}));
      expect(got, isA<UpdateDownloadError>());
      expect(left(), isEmpty);
    });
  });

  test('clearUpdates empties the folder', () async {
    updatesDir(cache).createSync(recursive: true);
    File('${updatesDir(cache).path}/old.apk').writeAsStringSync('x');
    clearUpdates(cache);
    expect(updatesDir(cache).existsSync(), isFalse);
    clearUpdates(cache); // nothing there is fine
  });

  group("the server's copy (AU-R21)", () {
    String serverUrl() => '$apiBaseUrl${appApkPath(_build)}';

    MockClient server(List<http.BaseRequest> seen, http.Response Function() answer) => MockClient((req) async {
          seen.add(req);
          return answer();
        });

    for (final (why, answers) in [
      ('GitHub answering 500', <String, http.Response Function()>{
        'start': () => http.Response('', 500),
      }),
      ('a refused hop', <String, http.Response Function()>{
        'start': () => http.Response('', 302, headers: {'location': 'https://evil.example.com/a.apk'}),
      }),
      ('a wrong hash from GitHub', <String, http.Response Function()>{
        'start': () => http.Response.bytes([..._body]..[0] ^= 1, 200),
      }),
    ]) {
      test('$why falls back to the server, with the app key', () async {
        final seenServer = <http.BaseRequest>[];
        final file = await downloadApk(release,
            cacheDir: cache,
            client: github([], answers: {release.apk: answers['start']!}),
            fromServer: true,
            serverHttp: server(seenServer, () => http.Response.bytes(_body, 200)));
        expect(file.readAsBytesSync(), _body);
        expect(seenServer.single.url.toString(), serverUrl());
        expect(seenServer.single.followRedirects, isFalse);
        for (final e in appApiKeyHeaders.entries) {
          expect(seenServer.single.headers[e.key], e.value);
        }
      });
    }

    test("the server's copy is held to the same signed hash", () async {
      await expectLater(
          downloadApk(release,
              cacheDir: cache,
              client: MockClient((_) async => http.Response('', 500)),
              fromServer: true,
              serverHttp: server([], () => http.Response.bytes([..._body]..[9] ^= 1, 200))),
          throwsA(isA<UpdateDownloadError>()));
      expect(left(), isEmpty);
    });

    test('the server request follows no redirect', () async {
      final seenServer = <http.BaseRequest>[];
      await expectLater(
          downloadApk(release,
              cacheDir: cache,
              client: MockClient((_) async => http.Response('', 500)),
              fromServer: true,
              serverHttp: server(seenServer, () => http.Response('', 302, headers: {'location': _asset}))),
          throwsA(isA<UpdateDownloadError>()));
      expect(seenServer, hasLength(1));
    });

    test('a GitHub success never asks the server', () async {
      final seenServer = <http.BaseRequest>[];
      await downloadApk(release,
          cacheDir: cache,
          client: github([]),
          fromServer: true,
          serverHttp: server(seenServer, () => http.Response.bytes(_body, 200)));
      expect(seenServer, isEmpty);
    });

    test('a cancel does not fall back', () async {
      final cancel = Completer<void>()..complete();
      final seenServer = <http.BaseRequest>[];
      await expectLater(
          downloadApk(release,
              cacheDir: cache,
              client: github([]),
              cancel: cancel.future,
              fromServer: true,
              serverHttp: server(seenServer, () => http.Response.bytes(_body, 200))),
          throwsA(isA<UpdateDownloadError>().having((e) => e.cancelled, 'cancelled', isTrue)));
      expect(seenServer, isEmpty);
    });

    test('an inspection refusal does not fall back to the server', () async {
      final seenServer = <http.BaseRequest>[];
      await expectLater(
          prepareUpdate(release,
              cacheDir: cache,
              installer: _FakeInstaller(_info(signers: {'bb' * 32})),
              app: _app(),
              store: store(),
              client: github([]),
              fromServer: true,
              serverHttp: server(seenServer, () => http.Response.bytes(_body, 200))),
          throwsA(isA<UpdateDownloadError>().having((e) => e.refused, 'refused', isTrue)));
      expect(seenServer, isEmpty);
    });

    test("GitHub's requests still carry no app key", () async {
      final seen = <http.BaseRequest>[];
      await downloadApk(release,
          cacheDir: cache,
          client: github(seen, answers: {release.apk: () => http.Response('', 500)}),
          fromServer: true,
          serverHttp: server([], () => http.Response.bytes(_body, 200)));
      for (final r in seen) {
        expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-app-key')));
      }
    });
  });

  test('two attempts never share a file (review I1)', () async {
    final a = await downloadApk(release, cacheDir: cache, client: github([]));
    final b = await downloadApk(release, cacheDir: cache, client: github([]));
    expect(a.path, isNot(b.path));
    expect(a.readAsBytesSync(), _body);
    expect(b.readAsBytesSync(), _body);
  });

  test('a body that stalls fails after the read timeout (review M1)', () async {
    final client = MockClient.streaming((req, _) async {
      final stalled = StreamController<List<int>>();
      stalled.add(_body.sublist(0, 100)); // then nothing more
      return http.StreamedResponse(stalled.stream, 200);
    });
    await expectLater(
        downloadApk(release, cacheDir: cache, client: client, readTimeout: const Duration(milliseconds: 50)),
        throwsA(isA<UpdateDownloadError>().having((e) => e.cancelled, 'cancelled', isFalse)));
    expect(left(), isEmpty);
  });

  test('Cancel stops a stalled download at once (review M1)', () async {
    final cancel = Completer<void>();
    final client = MockClient.streaming((req, _) async {
      final stalled = StreamController<List<int>>();
      stalled.add(_body.sublist(0, 100));
      Future<void>.delayed(const Duration(milliseconds: 10), cancel.complete);
      return http.StreamedResponse(stalled.stream, 200);
    });
    final watch = Stopwatch()..start();
    await expectLater(downloadApk(release, cacheDir: cache, client: client, cancel: cancel.future),
        throwsA(isA<UpdateDownloadError>().having((e) => e.cancelled, 'cancelled', isTrue)));
    expect(watch.elapsed, lessThan(apkHopTimeout));
    expect(left(), isEmpty);
  });

  test('Cancel stops a request that has no answer yet', () async {
    final cancel = Completer<void>();
    final client = MockClient((_) {
      Future<void>.delayed(const Duration(milliseconds: 10), cancel.complete);
      return Completer<http.Response>().future;
    });
    await expectLater(downloadApk(release, cacheDir: cache, client: client, cancel: cancel.future),
        throwsA(isA<UpdateDownloadError>().having((e) => e.cancelled, 'cancelled', isTrue)));
    expect(left(), isEmpty);
  });
}

/// Completes the cancel while Android reads the file.
class _InspectCancels extends AppInstaller {
  _InspectCancels(this.info, this.cancel);
  final ApkInfo info;
  final Completer<void> cancel;

  @override
  Future<ApkInfo> inspect(String path) async {
    cancel.complete();
    return info;
  }
}
