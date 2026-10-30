// specs/app-updates AU-R5, AU-R9, AU-D9: the phone asks C21 for the newest signed release file through the server
// link and, only when the server can't answer, reads it from GitHub; either way it verifies it itself. Release files
// are signed with the TEST key (app_release_signing.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/app_update_client.dart';
import 'package:mazama_mobile/github_files.dart';
import 'package:mazama_mobile/server_link_client.dart' show ServerOfflineException;

import 'app_release_signing.dart';

final _today = DateTime.utc(2026, 10, 30, 12);

Map<String, Object?> _reply(String text, String sig, int build) => {'build': build, 'manifest': text, 'signature': sig};

void main() {
  test('the example reply parses', () async {
    final example = jsonDecode(File('assets/shared/api/examples/app_latest.response.json').readAsStringSync()) as Map;
    final reply = await requestAppLatest(client: MockClient((_) async => http.Response(jsonEncode(example), 200)));
    expect(reply.build, example['build']);
    expect(reply.manifest, example['manifest']);
    expect(reply.signature, example['signature']);
  });

  test('asks appLatestPath() through the given server client, with the app key headers', () async {
    final seen = <http.BaseRequest>[];
    final client = MockClient((req) async {
      seen.add(req);
      return http.Response(jsonEncode({'build': null, 'manifest': null, 'signature': null}), 200);
    });
    expect(await fetchLatestRelease(serverHttp: client, serverOffline: () => false, now: () => _today, publicKey: testPublicKey), isNull);
    expect(seen.single.url.toString(), '$apiBaseUrl${appLatestPath()}');
    for (final e in appApiKeyHeaders.entries) {
      expect(seen.single.headers[e.key], e.value);
    }
  });

  test('a verified reply is the file; a reply whose signature fails is nothing, whatever its build', () async {
    final text = releaseText(build: 26103001);
    final sig = await testSignature(text);
    final good = MockClient((_) async => http.Response(jsonEncode(_reply(text, sig, 26103001)), 200));
    final file = await fetchLatestRelease(serverHttp: good, now: () => _today, publicKey: testPublicKey);
    expect(file?.build, 26103001);
    final badSig = MockClient((_) async => http.Response(jsonEncode(_reply(text, await testSignature('other'), 26103001)), 200));
    expect(await fetchLatestRelease(serverHttp: badSig, now: () => _today, publicKey: testPublicKey), isNull);
    final otherBuild = MockClient((_) async => http.Response(jsonEncode(_reply(text, sig, 26103002)), 200));
    expect(await fetchLatestRelease(serverHttp: otherBuild, now: () => _today, publicKey: testPublicKey), isNull);
    expect(await fetchLatestRelease(serverHttp: good, now: () => _today, publicKey: otherPublicKey), isNull);
  });

  test('when the server cannot answer, latest.json is read from GitHub and verified', () async {
    final text = releaseText(build: 26103001);
    final sig = await testSignature(text);
    final asked = <String>[];
    final github = MockClient((req) async {
      asked.add(req.url.toString());
      return http.Response(req.url.path.endsWith('.sig') ? sig : text, 200);
    });
    final offline = MockClient((req) async => throw ServerOfflineException(req.url));
    final file = await fetchLatestRelease(
        serverHttp: offline, githubHttp: github, serverOffline: () => true, now: () => _today, publicKey: testPublicKey);
    expect(file?.build, 26103001);
    expect(asked, ['${githubFilesBase}latest.json', '${githubFilesBase}latest.json.sig']);
  });

  test('a GitHub file with a bad .sig is nothing', () async {
    final text = releaseText(build: 26103001);
    final github = MockClient((req) async =>
        http.Response(req.url.path.endsWith('.sig') ? await testSignature('other') : text, 200));
    final offline = MockClient((req) async => throw ServerOfflineException(req.url));
    expect(
        await fetchLatestRelease(
            serverHttp: offline, githubHttp: github, serverOffline: () => true, now: () => _today, publicKey: testPublicKey),
        isNull);
  });

  test('when the server answers (any status), GitHub is not asked', () async {
    var githubAsked = 0;
    final github = MockClient((_) async {
      githubAsked++;
      return http.Response('x', 200);
    });
    for (final status in [200, 401, 429, 500, 503]) {
      final server = MockClient((_) async => http.Response(
          status == 200 ? jsonEncode({'build': null, 'manifest': null, 'signature': null}) : '{"detail": "no"}', status));
      expect(
          await fetchLatestRelease(serverHttp: server, githubHttp: github, serverOffline: () => true, now: () => _today, publicKey: testPublicKey),
          isNull);
    }
    expect(githubAsked, 0);
  });

  test('a failed request while the link still counts the server online does not ask GitHub', () async {
    var githubAsked = 0;
    final github = MockClient((_) async {
      githubAsked++;
      return http.Response('x', 200);
    });
    final failing = MockClient((req) async => throw http.ClientException('reset', req.url));
    expect(
        await fetchLatestRelease(serverHttp: failing, githubHttp: github, serverOffline: () => false, now: () => _today, publicKey: testPublicKey),
        isNull);
    expect(githubAsked, 0);
  });

  test('C21 carries the installed build and the install id (AU-R22)', () async {
    final seen = <http.BaseRequest>[];
    final client = MockClient((req) async {
      seen.add(req);
      return http.Response(jsonEncode({'build': null, 'manifest': null, 'signature': null}), 200);
    });
    const id = '0123456789abcdef0123456789abcdef';
    await fetchLatestRelease(serverHttp: client, installedBuild: 26102901, deviceId: id, now: () => _today, publicKey: testPublicKey);
    expect(seen.single.url.queryParameters, {'build': '26102901', 'device': id});
    expect(seen.single.url.path, appLatestPath());
  });

  test('an install id of another shape is not sent, nor the build without it', () async {
    final seen = <http.BaseRequest>[];
    final client = MockClient((req) async {
      seen.add(req);
      return http.Response(jsonEncode({'build': null, 'manifest': null, 'signature': null}), 200);
    });
    for (final id in [null, '7f3c2a9e-4b1d-4e8a-9c55-0d2f6b8e1a34', 'ABCDEF0123456789ABCDEF0123456789', '']) {
      await fetchLatestRelease(serverHttp: client, installedBuild: 26102901, deviceId: id, now: () => _today, publicKey: testPublicKey);
    }
    for (final r in seen) {
      expect(r.url.hasQuery, isFalse, reason: r.url.toString());
    }
  });

  test("GitHub's latest.json request carries neither the build nor the id", () async {
    final text = releaseText(build: 26103001);
    final sig = await testSignature(text);
    final seen = <http.BaseRequest>[];
    final github = MockClient((req) async {
      seen.add(req);
      return http.Response(req.url.path.endsWith('.sig') ? sig : text, 200);
    });
    final offline = MockClient((req) async => throw ServerOfflineException(req.url));
    await fetchLatestRelease(
        serverHttp: offline,
        githubHttp: github,
        serverOffline: () => true,
        installedBuild: 26102901,
        deviceId: '0123456789abcdef0123456789abcdef',
        now: () => _today,
        publicKey: testPublicKey);
    expect(seen, hasLength(2));
    for (final r in seen) {
      expect(r.url.hasQuery, isFalse);
      expect(r.headers.keys.map((k) => k.toLowerCase()).toSet().intersection({'x-app-key', 'authorization', 'cookie'}),
          isEmpty);
    }
  });

  test('while signing.pub holds no key nothing is asked for (AU-R2)', () async {
    var asked = 0;
    final client = MockClient((_) async {
      asked++;
      return http.Response('{}', 200);
    });
    expect(
        await fetchLatestRelease(
            serverHttp: client, githubHttp: client, serverOffline: () => true, now: () => _today, publicKey: 'none'),
        isNull);
    expect(asked, 0);
  });

  test('a C21 reply over 16 KiB is refused (review M5)', () async {
    final text = releaseText(build: 26103001);
    final sig = await testSignature(text);
    final big = jsonEncode({..._reply(text, sig, 26103001), 'pad': 'x' * appLatestMaxBytes});
    final client = MockClient((_) async => http.Response(big, 200));
    expect(await fetchLatestRelease(serverHttp: client, now: () => _today, publicKey: testPublicKey), isNull);
    await expectLater(requestAppLatest(client: client), throwsA(isA<AppLatestError>()));
  });

  test('a C21 body that stalls after the headers counts as no answer: GitHub is asked (review N4)', () async {
    final text = releaseText(build: 26103001);
    final sig = await testSignature(text);
    final stalled = StreamController<List<int>>();
    final server = MockClient.streaming((req, _) async {
      stalled.add(utf8.encode('{"build": 26103001, '));
      return http.StreamedResponse(stalled.stream, 200);
    });
    final github = MockClient((req) async => http.Response(req.url.path.endsWith('.sig') ? sig : text, 200));
    final file = await fetchLatestRelease(
        serverHttp: server,
        githubHttp: github,
        serverOffline: () => false, // the link saw the headers
        timeout: const Duration(milliseconds: 50),
        now: () => _today,
        publicKey: testPublicKey);
    expect(file?.build, 26103001);
    expect(stalled.hasListener, isFalse); // the stalled reply was let go
  });
}
