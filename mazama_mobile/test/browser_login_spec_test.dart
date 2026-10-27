// SL-R16: assets/flows_phone/login_browser.yaml (synced from ../mazama_modules/flows/phone by tool/sync_flows.sh - run
// that first if this can't find the file), run by the Dart interpreter against fake_state.dart's B2C, with a fake
// `browse` standing in for the webview page.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/browser_login_spec.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_spec_store.dart';

import 'flow/fake_state.dart';

final String yaml = File(browserLoginSpecAsset).readAsStringSync();
late final FlowSpec spec = FlowSpec.fromYaml(yaml);

/// An asset bundle holding [files] (asset key -> text).
class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) throw StateError('no asset $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

/// A browse callback for [fake]: checks the start URL and `until`, registers the code the page would hand out
/// against the challenge the start URL carries (as fake_state.dart's `confirmed` does), and answers [answer] given
/// the start URL's `state`.
Future<String?> Function(String, String) page(FakeState fake, String? Function(String state) answer,
    {List<(String, String)>? calls}) {
  return (url, until) async {
    calls?.add((url, until));
    final u = Uri.parse(url);
    expect(url, startsWith('$b2cHost/$tenant.onmicrosoft.com/$policy/oauth2/v2.0/authorize?'));
    expect(until, site);
    expect(u.queryParameters['client_id'], clientId);
    expect(u.queryParameters['redirect_uri'], site);
    expect(u.queryParameters['response_mode'], 'fragment');
    expect(u.queryParameters['code_challenge_method'], 'S256');
    final state = u.queryParameters['state']!;
    expect(state, isNotEmpty);
    expect(url, contains('state=$state'));
    fake.codes['CODE1'] = u.queryParameters['code_challenge']!;
    return answer(state);
  };
}

Future<FlowError> fails(Future<Object?> running) async {
  try {
    await running;
  } on FlowError catch (ex) {
    return ex;
  }
  fail('expected a FlowError');
}

void main() {
  test('it is a usable sign-in spec for this app, of format 3, served only as the browser one (SL-R19)', () {
    expect(usableLoginSpec(yaml), isNotNull);
    expect(usableLoginSpec(yaml, served: ServedAs.browser), isNotNull);
    expect(usableLoginSpec(yaml, served: ServedAs.login), isNull);
    expect(spec.format, 3);
    expect(isSpecVersion(spec.specVersion), isTrue);
  });

  test('an app that reads only format 2 cannot use it', () {
    expect(usableLoginSpec(yaml, maxFormat: 2), isNull);
  });

  test('every url and until it uses is on an allowed host', () {
    expect(specHostsAllowed(spec), isTrue);
  });

  test('its B2C ids are login.yaml\'s (kept in step by hand)', () {
    final login = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
    for (final name in ['tenant', 'policy', 'b2c', 'client_id', 'scope', 'site', 'site_origin', 'redirect_uri',
        'refresh_margin_seconds', 'timeout_seconds']) {
      expect(spec.vars[name], login.vars[name], reason: name);
    }
  });

  group("kept in step with login.yaml (a drift guard: both are edited by hand)", () {
    final login = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
    Map<String, Object?> step(FlowSpec s, String flow, String id) => s.flows[flow]!.singleWhere((st) => st['id'] == id);

    test("the page it opens is login.yaml's authorize request: same url, same params", () {
      final browser = step(spec, 'login', 'browser');
      final authorize = step(login, 'login', 'authorize');
      expect(browser['type'], 'open_browser');
      expect(browser['url'], authorize['url']);
      expect(browser['params'], isA<Map<Object?, Object?>>());
      expect(browser['params'], equals(authorize['params']));
    });

    test("its token step is login.yaml's", () {
      expect(step(spec, 'login', 'token'), equals(step(login, 'login', 'token')));
    });

    test("its renew flow is login.yaml's", () {
      expect(spec.flows['renew'], equals(login.flows['renew']));
    });
  });

  test('login shows the authorize page and trades the code it returns for a token', () async {
    final fake = FakeState();
    final calls = <(String, String)>[];
    final ctx = await runFlow(spec, 'login', const {},
        client: fake.client(), browse: page(fake, (st) => '$site#code=CODE1&state=$st', calls: calls));
    expect(calls, hasLength(1));
    expect(ctx['access_token'], 'ACCESS-1');
    expect(ctx['refresh_token'], 'REFRESH-1');
    expect(ctx['expires_in'], 3600);
    expect(fake.logins, 1); // the fake issues a token only when sha256(verifier) matches the page's challenge
    expect(fake.log, [('POST', '/$tenant.onmicrosoft.com/$policy/oauth2/v2.0/token')]);
  });

  test('a returned state that is not the one sent is structure, and no token is asked for', () async {
    final fake = FakeState();
    final err = await fails(runFlow(spec, 'login', const {},
        client: fake.client(), browse: page(fake, (st) => '$site#code=CODE1&state=${st}x')));
    expect(err.reason, 'structure');
    expect(err.step, 'browser');
    expect(err.message, isNot(contains('CODE1')));
    expect(fake.log, isEmpty);
  });

  test('a returned address without a code is structure, and no token is asked for', () async {
    final fake = FakeState();
    final err = await fails(
        runFlow(spec, 'login', const {}, client: fake.client(), browse: page(fake, (st) => '$site#state=$st')));
    expect(err.reason, 'structure');
    expect(err.step, 'require_code');
    expect(fake.log, isEmpty);
  });

  test("B2C's own error in the fragment is credentials, with its description, and no token is asked for", () async {
    final fake = FakeState();
    final err = await fails(runFlow(spec, 'login', const {},
        client: fake.client(),
        browse: page(fake, (st) => '$site#error=access_denied&error_description=AADB2C90118%3A+forgot&state=$st')));
    expect(err.reason, 'credentials');
    expect(err.step, 'page_refused');
    expect(err.message, contains('AADB2C90118: forgot'));
    expect(fake.log, isEmpty);
  });

  test('closing the page is cancelled', () async {
    final fake = FakeState();
    final err = await fails(runFlow(spec, 'login', const {}, client: fake.client(), browse: page(fake, (st) => null)));
    expect(err.reason, 'cancelled');
    expect(fake.log, isEmpty);
  });

  test('without a browse callback login needs a person', () async {
    final fake = FakeState();
    final err = await fails(runFlow(spec, 'login', const {}, client: fake.client()));
    expect(err.reason, 'needs_person');
    expect(fake.log, isEmpty);
  });

  test("renew works as login.yaml's", () async {
    final fake = FakeState();
    final ctx = await runFlow(spec, 'renew', {'refresh_token': 'REFRESH-0'}, client: fake.client());
    expect(ctx['access_token'], 'ACCESS-1');
    expect(fake.refreshes, 1);
    fake.refreshOk = false;
    final err = await fails(runFlow(spec, 'renew', {'refresh_token': 'REFRESH-1'}, client: fake.client()));
    expect(err.reason, 'refused');
  });

  group('loadBrowserLoginSpec', () {
    test('reads the bundled asset and holds it to the sign-in spec rule', () async {
      final loaded = await loadBrowserLoginSpec(bundle: _Bundle({browserLoginSpecAsset: yaml}));
      expect(loaded.specVersion, spec.specVersion);
      expect(loaded.flows.keys, containsAll(['login', 'renew']));
    });

    test('a bundled copy that is not usable throws instead of being run', () async {
      final evil = yaml.replaceFirst('site: "https://psilocybin.oregon.gov/"', 'site: "https://evil.example.com/"');
      expect(evil, isNot(yaml));
      await expectLater(loadBrowserLoginSpec(bundle: _Bundle({browserLoginSpecAsset: evil})),
          throwsA(isA<FlowSpecError>()));
    });

    group('with a saved copy (SL-R19)', () {
      late Directory dir;
      setUp(() => dir = Directory.systemTemp.createTempSync('browser_login_spec_test_'));
      tearDown(() => dir.deleteSync(recursive: true));

      String at(String version) {
        final out = yaml.replaceFirst('spec_version: "${spec.specVersion}"', 'spec_version: "$version"');
        expect(out, isNot(yaml));
        return out;
      }

      test('a saved copy newer than the bundled one is used', () async {
        final store = LoginSpecStore.browser(dataDir: () => dir);
        await store.save(at('2999-01-01.1'));
        final loaded = await loadBrowserLoginSpec(bundle: _Bundle({browserLoginSpecAsset: yaml}), store: store);
        expect(loaded.specVersion, '2999-01-01.1');
      });

      test('an older saved copy, or one on a tie, loses to the bundled one', () async {
        final store = LoginSpecStore.browser(dataDir: () => dir);
        for (final version in ['2000-01-01.1', spec.specVersion!]) {
          // On a tie the saved copy is the bundled text itself (at() insists on a changed version).
          await store.save(version == spec.specVersion ? yaml : at(version));
          final loaded = await loadBrowserLoginSpec(bundle: _Bundle({browserLoginSpecAsset: yaml}), store: store);
          expect(loaded.specVersion, spec.specVersion);
        }
      });

      test('a saved copy is used when the bundled one is not usable', () async {
        final store = LoginSpecStore.browser(dataDir: () => dir);
        await store.save(at('2000-01-01.1'));
        final evil = yaml.replaceFirst('site: "https://psilocybin.oregon.gov/"', 'site: "https://evil.example.com/"');
        final loaded = await loadBrowserLoginSpec(bundle: _Bundle({browserLoginSpecAsset: evil}), store: store);
        expect(loaded.specVersion, '2000-01-01.1');
      });

      test('a saved file that is not a browser spec is ignored', () async {
        final login = File('assets/flows/login.yaml').readAsStringSync();
        File('${dir.path}/login_browser_spec.yaml').writeAsStringSync(login.replaceFirst(
            RegExp(r'spec_version: "[^"]+"'), 'spec_version: "2999-01-01.1"'));
        final loaded = await loadBrowserLoginSpec(
            bundle: _Bundle({browserLoginSpecAsset: yaml}), store: LoginSpecStore.browser(dataDir: () => dir));
        expect(loaded.specVersion, spec.specVersion);
      });
    });

    testWidgets('the app bundles it (pubspec.yaml lists assets/flows_phone/)', (tester) async {
      final loaded = await tester.runAsync(loadBrowserLoginSpec);
      expect(loaded!.specVersion, spec.specVersion);
    });
  });
}
