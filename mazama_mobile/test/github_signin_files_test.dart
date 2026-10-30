// specs/app-updates AU-R17: the signed sign-in files read from GitHub (github_signin_files.dart). Files are signed with
// the shared vectors' TEST key (host_list_signing.dart), injected as the key; GitHub is a MockClient.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mazama_mobile/browser_login_spec.dart' show browserLoginSpecAsset;
import 'package:mazama_mobile/github_files.dart';
import 'package:mazama_mobile/github_signin_files.dart';
import 'package:mazama_mobile/login_hosts_store.dart';
import 'package:mazama_mobile/login_spec_store.dart' show ServedAs;
import 'package:mazama_mobile/signing.dart' show noSigningKey;

import 'app_release_signing.dart';
import 'host_list_signing.dart' show hostListText;

final String _loginYaml = File('assets/flows/login.yaml').readAsStringSync();
final String _browserYaml = File(browserLoginSpecAsset).readAsStringSync();

/// GitHub answering [files] (name -> text) and their TEST signatures (or [sigs] given), recording what was asked.
Future<(MockClient, List<String>)> _github(Map<String, String> files, {Map<String, String>? sigs}) async {
  final signed = <String, String>{
    for (final e in files.entries) e.key: e.value,
    for (final e in files.entries) '${e.key}.sig': sigs?[e.key] ?? await testSignature(e.value),
  };
  final asked = <String>[];
  final client = MockClient((req) async {
    asked.add(req.url.toString());
    final name = req.url.toString().substring(githubFilesBase.length);
    final body = signed[name];
    return body == null ? http.Response('', 404) : http.Response(body, 200);
  });
  return (client, asked);
}

void main() {
  tearDown(() => useLoginHosts(null));

  test('a TEST-key-signed login.yaml is returned as a usable spec, from GitHub', () async {
    final (client, asked) = await _github({'login.yaml': _loginYaml});
    final got = await githubLoginSpec(served: ServedAs.login, client: client, publicKey: testPublicKey);
    expect(got, isNotNull);
    expect(got!.yaml, _loginYaml);
    expect(got.source, githubSpecSource);
    expect(asked, ['${githubFilesBase}login.yaml', '${githubFilesBase}login.yaml.sig']);
  });

  test('the browser sign-in reads login_browser.yaml, in its own served mode', () async {
    final (client, asked) = await _github({'login_browser.yaml': _browserYaml, 'login.yaml': _loginYaml});
    expect(await githubLoginSpec(served: ServedAs.browser, client: client, publicKey: testPublicKey), isNotNull);
    expect(asked.first, '${githubFilesBase}login_browser.yaml');
  });

  test('a bad .sig, another key, or no key at all: nothing', () async {
    final (bad, _) = await _github({'login.yaml': _loginYaml}, sigs: {'login.yaml': await testSignature('other')});
    expect(await githubLoginSpec(served: ServedAs.login, client: bad, publicKey: testPublicKey), isNull);
    final (good, asked) = await _github({'login.yaml': _loginYaml});
    expect(await githubLoginSpec(served: ServedAs.login, client: good, publicKey: otherPublicKey), isNull);
    asked.clear();
    expect(await githubLoginSpec(served: ServedAs.login, client: good, publicKey: noSigningKey), isNull);
    expect(asked, isEmpty); // nothing is fetched while signing.pub holds no key
  });

  test('a signed spec unusable in its served mode is nothing', () async {
    final (client, _) = await _github({'login.yaml': _browserYaml, 'login_browser.yaml': _loginYaml});
    expect(await githubLoginSpec(served: ServedAs.login, client: client, publicKey: testPublicKey), isNull);
    expect(await githubLoginSpec(served: ServedAs.browser, client: client, publicKey: testPublicKey), isNull);
  });

  test("a signed spec whose requests go to a host outside the attempt's allowlist is nothing", () async {
    // The sign-in's requests all go to {{b2c}} (the state's B2C tenant); move that to a host no list allows. (The
    // state's own site, psilocybin.oregon.gov, appears in login.yaml only as the redirect_uri and Origin values,
    // which are never requested.)
    const from = 'b2c: "https://{{tenant}}.b2clogin.com/{{tenant}}.onmicrosoft.com"';
    expect(from.allMatches(_loginYaml), hasLength(1));
    final moved = _loginYaml.replaceFirst(from, 'b2c: "https://login.example.org/{{tenant}}.onmicrosoft.com"');
    final (client, _) = await _github({'login.yaml': moved});
    expect(await githubLoginSpec(served: ServedAs.login, client: client, publicKey: testPublicKey), isNull);
    // the same signed file under an attempt whose hosts include that one (a signed host list added it): usable, so
    // the refusal above is the host check's
    expect(
        await githubLoginSpec(
            served: ServedAs.login,
            client: client,
            publicKey: testPublicKey,
            allowedHosts: [...currentAllowedHosts(), 'login.example.org']),
        isNotNull);
  });

  test('a signed release file is not a sign-in spec', () async {
    final release = releaseText(build: 26103001);
    final (client, _) = await _github({'login.yaml': release, 'login_browser.yaml': release});
    expect(await githubLoginSpec(served: ServedAs.login, client: client, publicKey: testPublicKey), isNull);
    expect(await githubLoginSpec(served: ServedAs.browser, client: client, publicKey: testPublicKey), isNull);
  });

  test('a signed host list verifies as verifiedHostList says', () async {
    final text = hostListText('2026-11-01.1', ['login.example.gov']);
    final (client, _) = await _github({'hosts.json': text});
    final got = await githubHostList(client: client, publicKey: testPublicKey);
    expect(got?.version, '2026-11-01.1');
    expect(got?.hosts, ['login.example.gov']);
    final (bad, _) = await _github({'hosts.json': text}, sigs: {'hosts.json': await testSignature('x')});
    expect(await githubHostList(client: bad, publicKey: testPublicKey), isNull);
    final (release, _) = await _github({'hosts.json': releaseText(build: 26103001)});
    expect(await githubHostList(client: release, publicKey: testPublicKey), isNull);
  });

  test('raw.githubusercontent.com is not a sign-in host', () {
    expect(currentAllowedHosts(), isNot(contains('raw.githubusercontent.com')));
  });

  test('the GitHub hosts can never be listed as sign-in hosts (review I2)', () {
    expect(githubHostsNeverListed, containsAll({...apkRedirectHosts, Uri.parse(githubFilesBase).host}));
    for (final h in githubHostsNeverListed) {
      expect(validListedHost(h), isFalse, reason: h);
      expect(() => parseHostList(hostListText('2026-11-01.1', [h])), throwsFormatException, reason: h);
    }
  });

  test('a signed spec is not a host list, and a signed host list is not a spec (review M1)', () async {
    final (asHosts, _) = await _github({'hosts.json': _loginYaml});
    expect(await githubHostList(client: asHosts, publicKey: testPublicKey), isNull);
    final list = hostListText('2026-11-01.1', ['login.example.gov']);
    final (asSpec, _) = await _github({'login.yaml': list, 'login_browser.yaml': list});
    expect(await githubLoginSpec(served: ServedAs.login, client: asSpec, publicKey: testPublicKey), isNull);
    expect(await githubLoginSpec(served: ServedAs.browser, client: asSpec, publicKey: testPublicKey), isNull);
  });
}
