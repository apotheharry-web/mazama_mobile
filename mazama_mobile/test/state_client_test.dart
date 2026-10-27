// Parity tests: the Dart interpreter, running assets/flows/state_reads.yaml (vendored from
// ../mazama_modules/flows/state_reads.yaml by tool/sync_flows.sh - run that first if this can't find the file)
// through fetchStateJson, reaches the same outcome mazama_sales' own parity tests
// (tests/state/test_state_reads_flowspec.py) expect from StateSession.get() against the same shared spec, via
// the same fake state system shape (fake_state.dart is the Dart twin of tests/state_fake.py's FakeState).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_hosts_store.dart';
import 'package:mazama_mobile/state_client.dart';

import 'flow/fake_state.dart';
import 'host_list_signing.dart';

const _sourcePath = '../mazama_modules/flows/state_reads.yaml';
const _vendoredPath = 'assets/flows/state_reads.yaml';

late final FlowSpec spec = FlowSpec.fromYaml(File(_vendoredPath).readAsStringSync());

void main() {
  test('the vendored copy this app actually runs matches the shared source exactly', () {
    final sourceFile = File(_sourcePath);
    if (!sourceFile.existsSync()) {
      // The shared mazama repo isn't checked out next to this one in every environment (CI, say) - the
      // guard only runs where it can actually compare, same reasoning test_state_reads_flowspec.py's own
      // guard would have for the Python side if mazama_sales were ever packaged standalone.
      return;
    }
    expect(File(_vendoredPath).readAsStringSync(), sourceFile.readAsStringSync());
  });

  test('a successful read captures the whole body, including an empty list', () async {
    final fake = FakeState();
    fake.tokens.add('TEST-TOKEN');
    fake.data['GetSalesRecords/225'] = [];
    final result = await fetchStateJson('GetSalesRecords/225', accessToken: 'TEST-TOKEN', client: fake.client(), spec: spec);
    expect(result, []); // present (not absent) even though it's falsy - see state_reads.yaml's own comment
  });

  test('a successful read of a populated list', () async {
    final fake = FakeState();
    fake.tokens.add('TEST-TOKEN');
    fake.data['GetPackagedProducts/225/ServiceCenter'] = [
      {'id': 1},
      {'id': 2},
    ];
    final result = await fetchStateJson('GetPackagedProducts/225/ServiceCenter', accessToken: 'TEST-TOKEN', client: fake.client(), spec: spec);
    expect(result, [
      {'id': 1},
      {'id': 2},
    ]);
  });

  test('a 401 is reported as "sign in again", not retried and not a generic HTTP error', () async {
    final fake = FakeState(); // no token seeded, so the fake's own bearer check 401s
    await expectLater(
      fetchStateJson('GetSalesRecords/225', accessToken: 'NOT-A-REAL-TOKEN', client: fake.client(), spec: spec),
      throwsA(isA<StateReadError>().having((e) => e.message, 'message', contains('sign in again'))),
    );
  });

  test('a 404 raises with the exact message mazama_sales\' own StateSession.get() raises from the same spec', () async {
    final fake = FakeState();
    fake.tokens.add('TEST-TOKEN');
    await expectLater(
      fetchStateJson('GetSalesRecords/1', accessToken: 'TEST-TOKEN', client: fake.client(), spec: spec),
      throwsA(isA<StateReadError>().having((e) => e.message, 'message', 'GET GetSalesRecords/1 failed: HTTP 404')),
    );
  });

  // SM-20: one named flow per endpoint both apps read, each with get_json's headers (User-Agent included).
  group('named reads', () {
    final cases = <(String, Map<String, Object?>, String)>[
      ('packaged_products', {'state_id': 225, 'holder': 'ServiceCenter'}, 'GetPackagedProducts/225/ServiceCenter'),
      ('packaged_product_info', {'package_id': 7}, 'GetPackagedProductInfo/7'),
      ('applicable_licenses', {}, 'GetApplicableLicenses'),
      ('get_json', {'path': 'GetSalesRecords/225'}, 'GetSalesRecords/225'),
    ];
    for (final (flow, inputs, path) in cases) {
      test('$flow GETs $path with the shared headers', () async {
        final seen = <http.BaseRequest>[];
        final client = http_testing.MockClient((req) async {
          seen.add(req);
          return http.Response('[{"id":1}]', 200);
        });
        final result = await fetchStateFlow(flow, inputs, accessToken: 'TEST-TOKEN', client: client, spec: spec);
        expect(result, [
          {'id': 1}
        ]);
        expect(seen, hasLength(1));
        final req = seen.single;
        expect(req.method, 'GET');
        expect(req.url.toString(), '${spec.vars['api']}$path');
        expect(req.headers['Authorization'], 'Bearer TEST-TOKEN');
        expect(req.headers['Accept'], 'application/json');
        expect(req.headers['Referer'], spec.vars['site']);
        expect(req.headers['Origin'], spec.vars['site_origin']);
        expect(req.headers['User-Agent'], spec.vars['user_agent']);
      });

      test('$flow names $path when it fails, and reports a 401 as a session problem', () async {
        final notFound = http_testing.MockClient((req) async => http.Response('', 404));
        // A token that can't occur in the message: the runner scrubs secrets out of error text.
        await expectLater(fetchStateFlow(flow, inputs, accessToken: 'TEST-TOKEN', client: notFound, spec: spec),
            throwsA(isA<StateReadError>().having((e) => e.message, 'message', 'GET $path failed: HTTP 404')));
        final expired = http_testing.MockClient((req) async => http.Response('', 401));
        await expectLater(fetchStateFlow(flow, inputs, accessToken: 'TEST-TOKEN', client: expired, spec: spec),
            throwsA(isA<StateReadError>().having((e) => e.message, 'message', contains('sign in again'))));
      });
    }
  });

  group("reads run under the phone's hosts (SL-R18)", () {
    tearDown(() => useLoginHosts(null));
    // The reads sent to the state's "new address".
    final moved = FlowSpec({...spec.vars, 'api': 'https://api.example.gov/api/private/ProductTracking/'}, spec.flows);
    http.Client answering(List<http.Request> seen) => http_testing.MockClient((req) async {
          seen.add(req);
          return http.Response('[]', 200);
        });

    test('a read at a host no list names is refused before it is sent', () async {
      final seen = <http.Request>[];
      await expectLater(fetchStateJson('GetSalesRecords/225', accessToken: 'TEST-TOKEN', client: answering(seen), spec: moved),
          throwsA(isA<StateReadError>().having((e) => e.message, 'message', contains('not an allowed https address'))));
      expect(seen, isEmpty);
    });

    test('with a signed list naming the host in use, the read goes there', () async {
      useLoginHosts(await signedHostList('2026-11-01.1', ['api.example.gov']));
      final seen = <http.Request>[];
      final result =
          await fetchStateJson('GetSalesRecords/225', accessToken: 'TEST-TOKEN', client: answering(seen), spec: moved);
      expect(result, []);
      expect(seen.single.url.host, 'api.example.gov');
    });

    test('hosts given by the caller are the ones used', () async {
      useLoginHosts(await signedHostList('2026-11-01.1', ['api.example.gov']));
      final seen = <http.Request>[];
      await expectLater(
          fetchStateFlow('get_json', {'path': 'x'},
              accessToken: 'TEST-TOKEN', client: answering(seen), spec: moved, allowedHosts: defaultAllowedHosts),
          throwsA(isA<StateReadError>()));
      expect(seen, isEmpty);
    });
  });
}
