// specs/app-updates AU-R16: the GitHub file addresses and the APK hosts (github_files.dart), held apart from the
// sign-in allowlist (currentAllowedHosts, the flow runner, the sign-in webview's navigation check).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mazama_mobile/browser_sign_in_page.dart' show BrowserNav, decideBrowserNavigation;
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/github_files.dart';
import 'package:mazama_mobile/login_hosts_store.dart';

import 'host_list_signing.dart';

const _githubHosts = ['raw.githubusercontent.com', 'github.com', 'release-assets.githubusercontent.com',
  'objects.githubusercontent.com'];

void main() {
  tearDown(() => useLoginHosts(null));

  group('file addresses', () {
    test('each of the four names and its .sig is allowed', () {
      for (final name in githubFileNames) {
        expect(githubFileUrlAllowed(Uri.parse('$githubFilesBase$name')), isTrue, reason: name);
        expect(githubFileUrlAllowed(Uri.parse('$githubFilesBase$name.sig')), isTrue, reason: name);
      }
      expect(githubFileNames, {'login.yaml', 'login_browser.yaml', 'hosts.json', 'latest.json'});
    });

    for (final url in [
      '${githubFilesBase}sale.yaml',
      '${githubFilesBase}latest.json.sig.sig',
      '${githubFilesBase}sub/latest.json',
      '${githubFilesBase}latest.json?x=1',
      '${githubFilesBase}latest.json#f',
      'https://raw.githubusercontent.com/someone-else/mazama_mobile/main/latest.json',
      'https://raw.githubusercontent.com/apotheharry-web/other/main/latest.json',
      'https://raw.githubusercontent.com/apotheharry-web/mazama_mobile/dev/latest.json',
      'http://raw.githubusercontent.com/apotheharry-web/mazama_mobile/main/latest.json',
      'https://raw.githubusercontent.com:444/apotheharry-web/mazama_mobile/main/latest.json',
      'https://user@raw.githubusercontent.com/apotheharry-web/mazama_mobile/main/latest.json',
      'https://raw.githubusercontent.com.evil.com/apotheharry-web/mazama_mobile/main/latest.json',
      'https://github.com/apotheharry-web/mazama_mobile/raw/main/latest.json',
    ]) {
      test('refused: $url', () => expect(githubFileUrlAllowed(Uri.parse(url)), isFalse));
    }
  });

  group('fetchSignedGithubFile', () {
    test('returns the text and the signature, the .sig asked for second', () async {
      final asked = <String>[];
      final client = MockClient((req) async {
        asked.add(req.url.toString());
        return http.Response(req.url.path.endsWith('.sig') ? 'c2ln\n' : '{"a": 1}\n', 200);
      });
      expect(await fetchSignedGithubFile('latest.json', client: client), ('{"a": 1}\n', 'c2ln\n'));
      expect(asked, ['${githubFilesBase}latest.json', '${githubFilesBase}latest.json.sig']);
    });

    test('a 3xx is a failure and nothing is followed', () async {
      final asked = <String>[];
      final client = MockClient((req) async {
        asked.add(req.url.toString());
        return http.Response('', 302, headers: {'location': 'https://evil.example.com/latest.json'});
      });
      expect(await fetchSignedGithubFile('latest.json', client: client), isNull);
      expect(asked, ['${githubFilesBase}latest.json']);
    });

    test('the requests ask the client not to follow redirects', () async {
      final seen = <http.BaseRequest>[];
      final client = MockClient((req) async {
        seen.add(req);
        return http.Response('x', 200);
      });
      await fetchSignedGithubFile('hosts.json', client: client);
      expect(seen, hasLength(2));
      for (final r in seen) {
        expect(r.followRedirects, isFalse);
        expect(r.method, 'GET');
      }
    });

    test('a file over 64 KiB or a .sig over 1 KiB fails', () async {
      Future<(String, String)?> serve(int file, int sig) => fetchSignedGithubFile('latest.json',
          client: MockClient((req) async =>
              http.Response('x' * (req.url.path.endsWith('.sig') ? sig : file), 200)));
      expect(await serve(githubFileMaxBytes, githubSigMaxBytes), isNotNull);
      expect(await serve(githubFileMaxBytes + 1, 10), isNull);
      expect(await serve(10, githubSigMaxBytes + 1), isNull);
    });

    test('a status other than 200, an error or a timeout fails', () async {
      expect(await fetchSignedGithubFile('latest.json', client: MockClient((_) async => http.Response('x', 500))),
          isNull);
      expect(await fetchSignedGithubFile('latest.json',
          client: MockClient((_) async => throw http.ClientException('blocked'))), isNull);
      expect(await fetchSignedGithubFile('latest.json',
          client: MockClient((_) => Completer<http.Response>().future), timeout: const Duration(milliseconds: 20)),
          isNull);
    });

    test('text that is not UTF-8 fails', () async {
      final client = MockClient((_) async => http.Response.bytes([0xff, 0xfe, 0x00], 200));
      expect(await fetchSignedGithubFile('latest.json', client: client), isNull);
    });

    test('only the four names are fetched', () async {
      var asked = 0;
      final client = MockClient((_) async {
        asked++;
        return http.Response('x', 200);
      });
      expect(await fetchSignedGithubFile('sale.yaml', client: client), isNull);
      expect(await fetchSignedGithubFile('../latest.json', client: client), isNull);
      expect(asked, 0);
    });

    test('the requests carry no app key, Authorization or Cookie header', () async {
      final seen = <http.BaseRequest>[];
      final client = MockClient((req) async {
        seen.add(req);
        return http.Response('x', 200);
      });
      await fetchSignedGithubFile('login.yaml', client: client);
      for (final r in seen) {
        final names = r.headers.keys.map((k) => k.toLowerCase()).toSet();
        expect(names.intersection({'x-app-key', 'authorization', 'cookie'}), isEmpty);
      }
    });
  });

  group('APK hops', () {
    test('apkStartUrlAllowed takes the pinned release path', () {
      for (final url in [
        'https://github.com/apotheharry-web/mazama_mobile/releases/download/v0.2.4+26103001/app-release.apk',
        'https://github.com/apotheharry-web/mazama_mobile/releases/download/v0.2.4%2B26103001/mazama-0.2.4%2B26103001.apk',
      ]) {
        expect(apkStartUrlAllowed(Uri.parse(url)), isTrue, reason: url);
      }
      for (final url in [
        'http://github.com/apotheharry-web/mazama_mobile/releases/download/v0.2.4+26103001/a.apk',
        'https://github.com/someone/mazama_mobile/releases/download/v0.2.4+26103001/a.apk',
        'https://github.com/apotheharry-web/mazama_mobile/releases/latest/download/a.apk',
        'https://github.com/apotheharry-web/mazama_mobile/releases/download/v0.2.4+26103001/a.zip',
        'https://github.com/apotheharry-web/mazama_mobile/releases/download/v0.2.4+26103001/a.apk?x=1',
        'https://github.com/apotheharry-web/mazama_mobile/releases/download/v0.2.4+26103001/../a.apk',
        'https://github.com/apotheharry-web/mazama_mobile/releases/download/0.2.4+26103001/a.apk',
        'https://github.com/apotheharry-web/mazama_mobile/releases/download/v0.2.4+2610300/a.apk',
      ]) {
        expect(apkStartUrlAllowed(Uri.parse(url)), isFalse, reason: url);
      }
    });

    test('apkHopAllowed takes the three hosts, with a query', () {
      for (final url in [
        'https://github.com/apotheharry-web/mazama_mobile/releases/download/v1/a.apk',
        'https://release-assets.githubusercontent.com/x/y?sp=r&sig=abc',
        'https://objects.githubusercontent.com/github-production-release-asset/1?X-Amz-Signature=1',
        'https://objects.githubusercontent.com:443/x',
      ]) {
        expect(apkHopAllowed(Uri.parse(url)), isTrue, reason: url);
      }
    });

    test('apkHopAllowed refuses any other host, http, port 8443 or user info', () {
      for (final url in [
        'https://evil.example.com/a.apk',
        'http://github.com/a.apk',
        'https://github.com:8443/a.apk',
        'https://user@github.com/a.apk',
        'https://github.com./a.apk',
        'https://raw.githubusercontent.com/a/b/main/x.apk',
        'https://evil.githubusercontent.com/a',
        'https://objects.githubusercontent.com.evil.com/a',
        'ftp://github.com/a',
      ]) {
        expect(apkHopAllowed(Uri.parse(url)), isFalse, reason: url);
      }
    });
  });

  group('never the sign-in allowlist', () {
    test('currentAllowedHosts holds none of the GitHub hosts, also with a host list in use', () async {
      for (final h in _githubHosts) {
        expect(currentAllowedHosts(), isNot(contains(h)));
      }
      useLoginHosts(await signedHostList('2026-11-01.1', ['login.example.gov']));
      expect(currentAllowedHosts(), contains('login.example.gov'));
      for (final h in _githubHosts) {
        expect(currentAllowedHosts(), isNot(contains(h)));
        expect(hostAllowedUrl('https://$h/x', allowed: currentAllowedHosts()), isFalse, reason: h);
      }
    });

    test('runFlow refuses a step at raw.githubusercontent.com and sends nothing', () async {
      final spec = FlowSpec.fromYaml('format: 2\nvars:\n  site: "https://raw.githubusercontent.com"\nflows:\n  t:\n'
          '    - id: page\n      type: request\n      url: "{{site}}/apotheharry-web/mazama_mobile/main/login.yaml"\n');
      var sent = 0;
      final client = MockClient((_) async {
        sent++;
        return http.Response(jsonEncode({}), 200);
      });
      await expectLater(runFlow(spec, 't', const {}, client: client, allowedHosts: currentAllowedHosts()),
          throwsA(isA<FlowError>()));
      expect(sent, 0);
    });

    test('the sign-in webview refuses github.com and the raw host', () {
      for (final h in _githubHosts) {
        expect(decideBrowserNavigation('https://$h/apotheharry-web', until: '', isMainFrame: true), BrowserNav.prevent,
            reason: h);
      }
    });
  });
}
