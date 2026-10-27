// Parity tests: the Dart interpreter, running ../../assets/flows/login.yaml (synced from ../../../mazama_modules/flows by
// tool/sync_flows.sh - run that first if this can't find the file), reaches the same outcome as the Python
// interpreter's own parity tests in mazama_sales/tests/state/test_flowspec.py, against the same fake state system
// (ported here as fake_state.dart). This is what lets the phone app and the server trust one spec instead of each
// hand-rolling the login flow and hoping they agree.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';

import 'fake_state.dart';

late final FlowSpec spec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());
late final FlowSpec saleSpec = FlowSpec.fromYaml(File('assets/flows/sale.yaml').readAsStringSync());

void main() {
  test('the spec resolves the same constants the server reads from the same file', () {
    expect(spec.vars['client_id'], clientId);
    expect(spec.vars['policy'], policy);
    expect(spec.vars['site'], site);
  });

  test('login proves the PKCE verifier and returns the token the fake issued', () async {
    final fake = FakeState();
    final ctx = await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    expect(ctx['access_token'], 'ACCESS-1');
    expect(ctx['refresh_token'], 'REFRESH-1');
    expect(ctx['expires_in'], 3600);
    expect(fake.logins, 1); // the fake only issues a token if sha256(verifier) matched the challenge
    expect(fake.log.where((e) => e.$1 == 'POST' && e.$2.endsWith('/SelfAsserted')).length, 1);
  });

  test('cookies set during authorize are carried forward to SelfAsserted', () async {
    // FakeState's SelfAsserted branch requires all four cookies set by its authorize branch: one with an
    // Expires attribute containing a comma (the exact shape that trips a naive split on package:http's
    // comma-joined Set-Cookie header), and two with real B2C-shaped names containing `:` and `|` (the exact
    // shape that broke this cookie jar for real, against the actual state system, before the name regex was
    // widened - see flow_runner.dart's _mergeSetCookies/_cookiePairRe for the mechanism and that history).
    // This failing would mean the cookie jar regressed, not that the fake is lenient.
    final fake = FakeState();
    final ctx = await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    expect(ctx['access_token'], 'ACCESS-1');
  });

  test('a wrong password is refused without echoing it', () async {
    final fake = FakeState()..rejectLogin = true;
    try {
      await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fail('expected a FlowError');
    } on FlowError catch (ex) {
      expect(ex.message, contains('the state system refused the login'));
      expect(ex.message, isNot(contains(fakePassword)));
    }
  });

  Future<FlowError> loginError(FakeState fake) async {
    try {
      await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    } on FlowError catch (ex) {
      return ex;
    }
    fail('expected a FlowError');
  }

  test('every login check has a known reason', () {
    const known = {'structure', 'credentials', 'unavailable', 'refused'};
    final text = File('assets/flows/login.yaml').readAsStringSync();
    // Every `- check:` entry in the file must be followed (before the next check) by one of the known reasons.
    final blocks = text.split(RegExp(r'^\s*- check:', multiLine: true)).skip(1).toList();
    expect(blocks, isNotEmpty);
    for (final block in blocks) {
      final m = RegExp(r'^\s*reason:\s*(\w+)', multiLine: true).firstMatch(block);
      expect(m, isNotNull, reason: 'a check has no reason: $block');
      expect(known, contains(m!.group(1)));
    }
  });

  test('a wrong password is credentials with the state\'s words scrubbed', () async {
    final fake = FakeState()..rejectLogin = true;
    final err = await loginError(fake);
    expect((err.step, err.reason), ('self_asserted', 'credentials'));
    expect(err.message, 'the state system refused the login: bad password ***');
  });

  test('a changed page is structure and sends no password', () async {
    final fake = FakeState()..pageHtml = '<html>new page</html>';
    final err = await loginError(fake);
    expect((err.step, err.reason), ('require_page_fields', 'structure'));
    expect(fake.log.where((e) => e.$2.endsWith('/SelfAsserted')), isEmpty);
  });

  test('a page instead of the code redirect is structure', () async {
    final fake = FakeState()..confirmedStatus = 200;
    final err = await loginError(fake);
    expect((err.step, err.reason), ('confirmed', 'structure'));
  });

  test('an unavailable sign-in page is unavailable', () async {
    final fake = FakeState()..pageStatus = 503;
    final err = await loginError(fake);
    expect((err.step, err.reason, err.status), ('authorize', 'unavailable', 503));
    expect(err.message, 'the sign-in page was not available: HTTP 503');
  });

  // B2C busy or down at SelfAsserted is an outage, not a changed page (final review Important 3).
  for (final status in [429, 500, 503]) {
    test('a throttled or failing sign-in form is unavailable ($status)', () async {
      final fake = FakeState()..selfAssertedStatus = status;
      final err = await loginError(fake);
      expect((err.step, err.reason, err.status), ('self_asserted', 'unavailable', status));
      expect(err.message, "the state's sign-in did not answer: HTTP $status");
    });
  }

  test('a refused sign-in form is structure', () async {
    final fake = FakeState()..selfAssertedStatus = 403; // a rejected transaction or csrf: the flow changed
    final err = await loginError(fake);
    expect((err.step, err.reason), ('self_asserted', 'structure'));
    expect(err.message, 'the sign-in form was not accepted: HTTP 403');
  });

  test('a sign-in form answer that is not JSON is structure', () async {
    final fake = FakeState()..selfAssertedHtml = '<html>a new page</html>';
    final err = await loginError(fake);
    expect((err.step, err.reason), ('self_asserted', 'structure'));
    expect(err.message, 'the sign-in form answered with something unexpected');
  });

  test('login captures the page and the refresh lifetime', () async {
    final fake = FakeState()..refreshExpiresIn = 86400;
    final ctx = await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    expect(ctx['signin_page'], contains('SETTINGS'));
    expect(ctx['refresh_token_expires_in'], 86400);
    final renewed = await runFlow(spec, 'renew', {'refresh_token': ctx['refresh_token']}, client: fake.client());
    expect(renewed['refresh_token_expires_in'], 86400);
  });

  test('a refused refresh is refused', () async {
    final fake = FakeState()..refreshOk = false;
    try {
      await runFlow(spec, 'renew', {'refresh_token': 'stale'}, client: fake.client());
      fail('expected a FlowError');
    } on FlowError catch (ex) {
      expect((ex.step, ex.reason), ('token', 'refused'));
    }
  });

  test('the login spec has a spec version', () {
    expect(spec.vars['spec_version'], '2026-10-24.4'); // the one place the literal is written in the tests
  });

  test('renew matches the login flow\'s own token shape', () async {
    final fake = FakeState();
    final login = await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    final ctx = await runFlow(spec, 'renew', {'refresh_token': login['refresh_token']}, client: fake.client());
    expect(ctx['access_token'], 'ACCESS-2');
    expect(fake.refreshes, 1);
  });

  test('a failed refresh is reported the same way the server reports it', () async {
    final fake = FakeState()..refreshOk = false;
    try {
      await runFlow(spec, 'renew', {'refresh_token': 'stale'}, client: fake.client());
      fail('expected a FlowError');
    } on FlowError catch (ex) {
      expect(ex.message, contains('the token refresh was refused: HTTP 400'));
    }
  });

  test('sale sends the given records as a JSON body and returns what the state created', () async {
    // Proves json_var end to end: the records list goes up as a real JSON body (not form-encoded, not
    // templated field by field - json_var looks the whole value up directly), with the bearer token from an
    // earlier login, and whatever the state answers with comes back unchanged as `created`. Also proves the
    // _isTruthy fix: `created` is a List, and this flow's then_require checks it's truthy - the old
    // `.toString().isNotEmpty` check would have passed even on an empty list, so this only really tests
    // anything because the fix is in place.
    final fake = FakeState();
    final login = await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    final sent = [{'id': 0, 'productGuid': 'G-1', 'numberSold': 1, 'productCost': 12.5}];
    final created = [{...sent[0], 'id': 9001, 'saleNumber': 'S-1'}];
    fake.data['CreateSalesRecords/false'] = created;
    final ctx = await runFlow(saleSpec, 'sale', {'access_token': login['access_token'], 'records': sent}, client: fake.client());
    expect(ctx['created'], created);
    final (postedPath, postedBody) = fake.posted.last;
    expect(postedPath, 'CreateSalesRecords/false');
    expect(postedBody, sent);
  });

  test('sale reports a rejected write without echoing the access token', () async {
    final fake = FakeState();
    final login = await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    // No fake.data entry for CreateSalesRecords/false -> the generic ProductTracking branch answers 404.
    try {
      await runFlow(saleSpec, 'sale', {'access_token': login['access_token'], 'records': [{'id': 0}]}, client: fake.client());
      fail('expected a FlowError');
    } on FlowError catch (ex) {
      expect(ex.message, contains('the state system answered the sale with HTTP 404'));
      expect(ex.message, isNot(contains(login['access_token'] as String)));
      expect(ex.stage, FlowStage.response);
      expect(ex.status, 404);
    }
  });

  test('secrets never appear in a FlowError', () async {
    final fake = FakeState()..rejectLogin = true;
    try {
      await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      fail('expected a FlowError');
    } on FlowError catch (ex) {
      expect(ex.message, isNot(contains(fakeEmail)));
      expect(ex.message, isNot(contains(fakePassword)));
    }
  });

  // SM-12: where a request step failed decides whether a write may have reached the state system. The stage and
  // status of every case both apps share are in assets/shared/flows/contracts/write_outcomes.json
  // (../write_outcomes_test.dart); these pin the messages and the failures only dart:io and package:http produce,
  // against a scripted client instead of a fake server, because a fake server can't produce them.
  group('request failures carry the stage they happened at', () {
    final records = [{'id': 0}];

    Future<FlowError> saleError(http.Client client, {Map<String, Object?> extra = const {}}) async {
      try {
        await runFlow(saleSpec, 'sale', {'access_token': 'TOKEN-SM12', 'records': records, ...extra}, client: client);
      } on FlowError catch (ex) {
        return ex;
      }
      fail('expected a FlowError');
    }

    test('a failed host lookup never sent anything', () async {
      final ex = await saleError(_Scripted.throwing(
          const SocketException("Failed host lookup: 'psilocybin.oregon.gov'", osError: OSError('No address associated with hostname', 7))));
      expect(ex.stage, FlowStage.connect);
      expect(ex.status, isNull);
      expect(ex.message, 'cannot reach psilocybin.oregon.gov: SocketException');
    });

    test('package:http\'s own wrapper around a SocketException is read through to the cause', () async {
      // IOClient rethrows a SocketException as a ClientException that also implements SocketException.
      final ex = await saleError(_Scripted.throwing(_WrappedSocketException(
          const SocketException("Failed host lookup: 'psilocybin.oregon.gov'"))));
      expect(ex.stage, FlowStage.connect);
    });

    test('a connection reset after the request went out may have been received', () async {
      final ex = await saleError(_Scripted.throwing(
          const SocketException('Connection reset by peer', osError: OSError('Connection reset by peer', 104))));
      expect(ex.stage, FlowStage.send);
      expect(ex.message, 'no answer from psilocybin.oregon.gov: SocketException');
    });

    test('anything else the client throws is treated as maybe sent, not as never sent', () async {
      final ex = await saleError(_Scripted.throwing(StateError('something odd')));
      expect(ex.stage, FlowStage.send);
    });

    test('no reply within timeout_seconds ends the request instead of waiting forever', () async {
      final never = _Scripted((req) => Completer<http.StreamedResponse>().future);
      final watch = Stopwatch()..start();
      final ex = await saleError(never, extra: {'timeout_seconds': '0.05'});
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(ex.stage, FlowStage.send);
      expect(ex.message, 'no answer from psilocybin.oregon.gov within 0.05 s');
    });

    test('a reply whose body never finishes arriving also times out, as a reply that was received', () async {
      final stalled = _Scripted((req) async => http.StreamedResponse(StreamController<List<int>>().stream, 200, request: req));
      final ex = await saleError(stalled, extra: {'timeout_seconds': '0.05'});
      expect(ex.stage, FlowStage.response);
      expect(ex.status, 200);
    });

    test('a reply cut off part way through its body was received', () async {
      Stream<List<int>> body() async* {
        yield [91]; // '['
        throw http.ClientException('Connection reset by peer');
      }
      final cut = _Scripted((req) async => http.StreamedResponse(body(), 200, request: req));
      final ex = await saleError(cut);
      expect(ex.stage, FlowStage.response);
      expect(ex.status, 200);
      expect(ex.message, 'the answer from psilocybin.oregon.gov was cut off: ClientException');
    });

    test('a 5xx is a response-stage failure carrying its status', () async {
      final ex = await saleError(_Scripted((req) async => http.StreamedResponse(Stream.value([]), 503, request: req)));
      expect((ex.stage, ex.status), (FlowStage.response, 503));
      expect(ex.message, 'the state system answered the sale with HTTP 503');
    });

    test('an assert step that fails has no stage: no request was involved', () async {
      final s = FlowSpec.fromYaml('flows:\n  f:\n    - {id: a, type: assert, require: [{check: truthy, vars: [x], error: no x}]}\n');
      try {
        await runFlow(s, 'f', {}, client: _Scripted.throwing(StateError('unused')));
        fail('expected a FlowError');
      } on FlowError catch (ex) {
        expect((ex.stage, ex.status), (null, null));
      }
    });
  });

  // Mirrors mazama_sales/tests/state/test_flowspec_failures.py case for case: the same inline specs (JSON is YAML,
  // so jsonEncode builds them) and the same expected values.
  group('failure reasons and capture_on_fail', () {
    FlowSpec specOf(List<Map<String, Object?>> steps) => FlowSpec.fromYaml(jsonEncode({
          'vars': {'base': 'https://state.test'},
          'flows': {'t': steps},
        }));

    Map<String, Object?> fetch([Map<String, Object?> over = const {}]) => {
          'id': 'fetch',
          'type': 'request',
          'url': '{{base}}/x',
          'require': [
            {'check': 'status_in', 'values': [200], 'error': 'bad {status}'}
          ],
          ...over,
        };

    MockClient replying(int status, Object? body) =>
        MockClient((req) async => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'}));

    Future<FlowError> fails(FlowSpec s, http.Client client, [Map<String, Object?> inputs = const {}]) async {
      try {
        await runFlow(s, 't', inputs, client: client, allowedHosts: const ['state.test']);
      } on FlowError catch (ex) {
        return ex;
      }
      fail('expected a FlowError');
    }

    Map<String, Object?> refusal([Map<String, Object?> over = const {}]) => fetch({
          'require': [
            {'check': 'json_equals', 'path': 'status', 'value': '200', 'error': 'refused: {{msg}}'}
          ],
          'capture_on_fail': [
            {'var': 'msg', 'source': 'body', 'json': 'message'}
          ],
          ...over,
        });

    test('a failed check carries its reason and step', () async {
      final step = fetch({
        'require': [
          {'check': 'status_in', 'values': [200], 'error': 'bad {status}', 'reason': 'unavailable'}
        ],
      });
      final err = await fails(specOf([step]), replying(503, {}));
      expect((err.step, err.reason, err.stage, err.status), ('fetch', 'unavailable', FlowStage.response, 503));
    });

    test('a check without a reason has none', () async {
      final err = await fails(specOf([fetch()]), replying(503, {}));
      expect(err.reason, isNull);
      expect(err.step, 'fetch');
    });

    test('a transport failure carries the step but no reason', () async {
      final boom = MockClient((req) async => throw const SocketException('Failed host lookup: state.test'));
      final err = await fails(specOf([fetch()]), boom);
      expect((err.step, err.reason, err.stage), ('fetch', null, FlowStage.connect));
    });

    test('an assert step carries its step and reason', () async {
      final step = {
        'id': 'check',
        'type': 'assert',
        'require': [
          {'check': 'truthy', 'vars': ['missing'], 'error': 'no page', 'reason': 'structure'}
        ],
      };
      final err = await fails(specOf([step]), replying(200, {}));
      expect((err.step, err.reason, err.stage), ('check', 'structure', null));
    });

    test('capture_on_fail fills the error template', () async {
      final err = await fails(specOf([refusal()]), replying(200, {'status': '400', 'message': 'nope'}));
      expect(err.message, 'refused: nope');
    });

    test('capture_on_fail uses the default, then empty', () async {
      final step = refusal({
        'require': [
          {'check': 'json_equals', 'path': 'status', 'value': '200', 'error': 'refused: {{msg}}|{{code}}|'}
        ],
        'capture_on_fail': [
          {'var': 'msg', 'source': 'body', 'json': 'message', 'default': 'check it'},
          {'var': 'code', 'source': 'body', 'json': 'code'},
        ],
      });
      final err = await fails(specOf([step]), replying(200, {}));
      expect(err.message, 'refused: check it||');
    });

    test('capture_on_fail also runs for then_require', () async {
      final step = fetch({
        'then_require': [
          {'check': 'json_equals', 'path': 'status', 'value': '200', 'error': 'late: {{msg}}'}
        ],
        'capture_on_fail': [
          {'var': 'msg', 'source': 'body', 'json': 'message'}
        ],
      });
      final err = await fails(specOf([step]), replying(200, {'status': '400', 'message': 'nope'}));
      expect(err.message, 'late: nope');
    });

    test('captured text is scrubbed', () async {
      final err = await fails(
          specOf([refusal()]), replying(200, {'status': '400', 'message': 'bad pw1'}), {'password': 'pw1'});
      expect(err.message, isNot(contains('pw1')));
      expect(err.message, contains('***'));
    });

    test('captured text is scrubbed whatever its case', () async {
      // B2C may echo the email in another case than the one typed; it must still never reach a message.
      final err = await fails(specOf([refusal()]),
          replying(200, {'status': '400', 'message': 'no account for WORKER@EXAMPLE.COM'}), {'email': 'worker@example.com'});
      expect(err.message, 'refused: no account for ***');
    });

    test('capture_on_fail does not run when the checks pass', () async {
      final ctx = await runFlow(specOf([refusal()]), 't', {},
          client: replying(200, {'status': '200', 'message': 'hi'}), allowedHosts: const ['state.test']);
      expect(ctx.containsKey('msg'), isFalse);
    });

    test('default applies to a normal extract', () async {
      final step = fetch({
        'extract': [
          {'var': 'got', 'source': 'body', 'json': 'nothing', 'default': 'fallback'}
        ],
      });
      final ctx = await runFlow(specOf([step]), 't', {}, client: replying(200, {}), allowedHosts: const ['state.test']);
      expect(ctx['got'], 'fallback');
    });
  });

  // Mirrors mazama_sales/tests/state/test_flowspec_allowlist.py case for case (SL-R8): the same inline specs and
  // the same expected values, except where the cookie jar differs (see the chain test).
  group('every request and redirect hop must be https on an allowed host', () {
    FlowSpec specOf(List<Map<String, Object?>> steps) => FlowSpec.fromYaml(jsonEncode({
          'vars': <String, Object?>{},
          'flows': {'t': steps},
        }));

    Map<String, Object?> fetch(String url, [Map<String, Object?> over = const {}]) =>
        {'id': 'fetch', 'type': 'request', 'url': url, ...over};

    // A MockClient that records every request it is asked to send, in order.
    MockClient recording(List<http.Request> calls, Future<http.Response> Function(http.Request) handler) =>
        MockClient((req) {
          calls.add(req);
          return handler(req);
        });

    Future<http.Response> ok(http.Request req) async => http.Response('ok', 200);

    Future<Map<String, Object?>> run(List<Map<String, Object?>> steps, http.Client client,
            {Iterable<String> allowedHosts = defaultAllowedHosts}) =>
        runFlow(specOf(steps), 't', {}, client: client, allowedHosts: allowedHosts);

    Future<FlowError> blocked(List<Map<String, Object?>> steps, http.Client client,
        {Iterable<String> allowedHosts = defaultAllowedHosts}) async {
      try {
        await run(steps, client, allowedHosts: allowedHosts);
      } on FlowError catch (ex) {
        return ex;
      }
      fail('expected a FlowError');
    }

    // The state's own B2C tenant: the only b2clogin.com host (SL-R17).
    const tenantHost = 'oregonpsilocybinprodb2c.b2clogin.com';
    const otherTenants = [
      'https://evil.b2clogin.com/x',
      'https://login.b2clogin.com/x',
      'https://b2clogin.com/x',
      'https://$tenantHost.evil.example/x',
      'https://x$tenantHost/x',
      'https://a.$tenantHost/x',
    ];

    test('SL-D16: a host in neverRequest is never sent to: not by a step url, not by a redirect', () async {
      final calls = <http.Request>[];
      try {
        await runFlow(specOf([fetch('https://psilocybin.oregon.gov/api')]), 't', {},
            client: recording(calls, ok), neverRequest: const {'psilocybin.oregon.gov'});
        fail('expected a FlowError');
      } on FlowError catch (err) {
        expect((err.step, err.reason, err.stage), ('fetch', 'not_allowed', null));
      }
      expect(calls, isEmpty);

      // a redirect there is not followed: the 3xx is the answer, as with follow_redirects: false
      final hops = <http.Request>[];
      final ctx = await runFlow(
          specOf([
            fetch('https://$tenantHost/a', {
              'extract': [
                {'var': 'where', 'source': 'header', 'name': 'location'},
              ],
            }),
          ]),
          't',
          {},
          client: recording(hops, (req) async => http.Response('', 302, headers: {'location': 'https://psilocybin.oregon.gov/#code=C'})),
          neverRequest: const {'psilocybin.oregon.gov'});
      expect([for (final h in hops) h.url.host], [tenantHost]);
      expect(ctx['where'], 'https://psilocybin.oregon.gov/#code=C');
    });

    for (final spelled in ['https://PSILOCYBIN.oregon.gov/api', 'https://psilocybin.oregon.gov./api']) {
      test('SL-D16: neverRequest holds however the host is spelled ($spelled)', () async {
        final calls = <http.Request>[];
        try {
          await runFlow(specOf([fetch(spelled)]), 't', {},
              client: recording(calls, ok), neverRequest: const {'psilocybin.oregon.gov'});
          fail('expected a FlowError');
        } on FlowError catch (err) {
          expect(err.reason, 'not_allowed');
        }
        expect(calls, isEmpty);

        final hops = <http.Request>[];
        await runFlow(specOf([fetch('https://$tenantHost/a')]), 't', {},
            client: recording(hops, (req) async => http.Response('', 302, headers: {'location': spelled})),
            neverRequest: const {'psilocybin.oregon.gov'});
        expect([for (final h in hops) h.url.host], [tenantHost]);
      });
    }

    test('the default allowlist is exactly the state site and its own tenant', () {
      expect(defaultAllowedHosts, ['psilocybin.oregon.gov', tenantHost]);
      expect(defaultAllowedHosts.where((e) => e.startsWith('.')), isEmpty); // no suffix entry by default
    });

    test("the state's own tenant is sent to", () async {
      final calls = <http.Request>[];
      await run([fetch('https://$tenantHost/t/authorize')], recording(calls, ok));
      expect([for (final c in calls) c.url.toString()], ['https://$tenantHost/t/authorize']);
    });

    test('a suffix entry passed in still matches hosts under it', () {
      expect(hostAllowedUrl('https://a.state.test/x', allowed: const ['.state.test']), isTrue);
      expect(hostAllowedUrl('https://state.test/x', allowed: const ['.state.test']), isFalse);
    });

    for (final url in otherTenants) {
      test('a redirect to another tenant is stopped before it is sent ($url)', () async {
        final calls = <http.Request>[];
        final err = await blocked([fetch('https://$tenantHost/a')],
            recording(calls, (req) async => http.Response('', 302, headers: {'location': url})));
        expect((err.step, err.reason, err.stage, err.status), ('fetch', 'not_allowed', FlowStage.response, 302));
        expect(calls.length, 1);
      });
    }

    for (final url in [
      'https://evil.com/x',
      'http://psilocybin.oregon.gov/x',
      'https://psilocybin.oregon.gov@evil.com/x',
      'https://psilocybin.oregon.gov:8443/x',
      ...otherTenants,
    ]) {
      test('a step url off the allowlist is never sent ($url)', () async {
        final calls = <http.Request>[];
        final err = await blocked([fetch(url)], recording(calls, ok));
        expect((err.step, err.reason, err.stage), ('fetch', 'not_allowed', null));
        expect(calls, isEmpty);
      });
    }

    test('the check is on the url after params are added', () async {
      final calls = <http.Request>[];
      await run([
        fetch('https://psilocybin.oregon.gov/x', {
          'params': {'a': 'b'}
        })
      ], recording(calls, ok));
      expect([for (final c in calls) c.url.toString()], ['https://psilocybin.oregon.gov/x?a=b']);
    });

    test('allowed hosts can be passed in', () async {
      final calls = <http.Request>[];
      await run([fetch('https://state.test/x')], recording(calls, ok), allowedHosts: const ['state.test']);
      expect(calls.length, 1);
      final err = await blocked([fetch('https://state.test/x')], recording(<http.Request>[], ok));
      expect(err.reason, 'not_allowed');
    });

    test('a redirect to another host is stopped before it is sent', () async {
      final calls = <http.Request>[];
      final err = await blocked([fetch('https://psilocybin.oregon.gov/x')],
          recording(calls, (req) async => http.Response('', 302, headers: {'location': 'https://evil.com/x'})));
      // The state's own answer sent it there (final review Minor 1): the response stage with the 3xx.
      expect((err.step, err.reason, err.stage, err.status), ('fetch', 'not_allowed', FlowStage.response, 302));
      expect(calls.length, 1);
    });

    test('a redirect downgrading to http is stopped', () async {
      final calls = <http.Request>[];
      final err = await blocked([fetch('https://psilocybin.oregon.gov/x')],
          recording(calls, (req) async => http.Response('', 301, headers: {'location': 'http://psilocybin.oregon.gov/x'})));
      expect(err.reason, 'not_allowed');
      expect(calls.length, 1);
      expect((err.stage, err.status), (FlowStage.response, 301));
    });

    test('a later hop off the allowlist carries the status that sent it there', () async {
      final calls = <http.Request>[];
      final err = await blocked([fetch('https://psilocybin.oregon.gov/a')], recording(calls, (req) async {
        if (req.url.path == '/a') return http.Response('', 302, headers: {'location': '/b'});
        return http.Response('', 307, headers: {'location': 'https://evil.com/c'});
      }));
      expect((err.reason, err.stage, err.status), ('not_allowed', FlowStage.response, 307));
      expect([for (final c in calls) c.url.path], ['/a', '/b']);
    });

    test('a chain between allowed hosts keeps cookies and reports the final url', () async {
      // The one deliberate difference from the Python twin: this runner's cookie jar is not host-scoped (see the
      // file comment in flow_runner.dart), so the first host's cookie IS sent to the second host, and both reach
      // the third. httpx's jar is host-scoped, so there /b sees no cookie and /c sees only sid=one.
      final calls = <http.Request>[];
      String? cookieAtB = 'unset';
      Future<http.Response> handler(http.Request req) async {
        final path = req.url.path;
        if (path == '/a') {
          return http.Response('', 302,
              headers: {'location': 'https://$tenantHost/b', 'set-cookie': 'sid=one; Path=/'});
        }
        if (path == '/b') {
          cookieAtB = req.headers['cookie'];
          return http.Response('', 302,
              headers: {'location': 'https://psilocybin.oregon.gov/c?z=1', 'set-cookie': 'other=two; Path=/'});
        }
        expect(path, '/c');
        return http.Response('cookie=${req.headers['cookie']}', 200);
      }

      final ctx = await run([
        fetch('https://psilocybin.oregon.gov/a', {
          'extract': [
            {'var': 'final', 'source': 'url'},
            {'var': 'seen', 'source': 'body', 'regex': 'cookie=(.*)'},
          ]
        })
      ], recording(calls, handler));
      expect(ctx['final'], 'https://psilocybin.oregon.gov/c?z=1');
      expect(cookieAtB, 'sid=one');
      expect(ctx['seen'], 'sid=one; other=two');
      expect(calls.length, 3);
    });

    test('a relative location is resolved against the current url', () async {
      final calls = <http.Request>[];
      final ctx = await run([
        fetch('https://psilocybin.oregon.gov/a/b', {
          'extract': [
            {'var': 'u', 'source': 'url'}
          ]
        })
      ], recording(calls, (req) async {
        if (req.url.path == '/a/b') return http.Response('', 302, headers: {'location': '../c'});
        return http.Response('ok', 200);
      }));
      expect(ctx['u'], 'https://psilocybin.oregon.gov/c');
    });

    for (final code in [301, 302, 303, 307, 308]) {
      test('a get is followed with the same method ($code)', () async {
        final calls = <http.Request>[];
        await run([fetch('https://psilocybin.oregon.gov/start')], recording(calls, (req) async {
          if (req.url.path == '/start') return http.Response('', code, headers: {'location': '/end'});
          return http.Response('ok', 200);
        }));
        expect([for (final c in calls) (c.method, c.url.path, c.body)], [('GET', '/start', ''), ('GET', '/end', '')]);
      });
    }

    for (final code in [301, 302, 303, 307, 308]) {
      test('a post answered with a redirect comes back as it is ($code)', () async {
        // A POST that was answered reached the state system and may have been recorded: never followed, whatever
        // follow_redirects says, so a later hop's failure can't make it read as "not sent".
        final calls = <http.Request>[];
        final err = await blocked([
          fetch('https://psilocybin.oregon.gov/start', {
            'method': 'POST',
            'form': {'k': 'v'},
            'require': [
              {'check': 'status_in', 'values': [200], 'error': 'bad {status}'}
            ],
          })
        ], recording(calls, (req) async => http.Response('', code, headers: {'location': '/end'})));
        expect((err.step, err.stage, err.status), ('fetch', FlowStage.response, code));
        expect(calls.length, 1);
      });
    }

    test('a post redirect extracts from the 3xx', () async {
      final calls = <http.Request>[];
      final ctx = await run([
        fetch('https://psilocybin.oregon.gov/start', {
          'method': 'POST',
          'form': {'k': 'v'},
          'extract': [
            {'var': 'st', 'source': 'status'},
            {'var': 'u', 'source': 'url'},
          ],
        })
      ], recording(calls, (req) async => http.Response('', 302, headers: {'location': '/end'})));
      expect((ctx['st'], ctx['u'], calls.length), (302, 'https://psilocybin.oregon.gov/start', 1));
    });

    test('a connect error after the first hop is send, not connect', () async {
      final calls = <http.Request>[];
      final err = await blocked([fetch('https://psilocybin.oregon.gov/a')], recording(calls, (req) async {
        if (req.url.path == '/a') return http.Response('', 302, headers: {'location': '/b'});
        throw const SocketException("Failed host lookup: 'psilocybin.oregon.gov'");
      }));
      expect((err.step, err.stage, err.reason), ('fetch', FlowStage.send, null));
      expect(calls.length, 2);
    });

    test('a connect error on the first request is still connect', () async {
      final err = await blocked([fetch('https://psilocybin.oregon.gov/a')], recording(<http.Request>[], (req) async {
        throw const SocketException("Failed host lookup: 'psilocybin.oregon.gov'");
      }));
      expect(err.stage, FlowStage.connect);
    });

    test('more than ten redirects fail', () async {
      final calls = <http.Request>[];
      final err = await blocked([fetch('https://psilocybin.oregon.gov/loop')],
          recording(calls, (req) async => http.Response('', 302, headers: {'location': '/loop'})));
      expect(err.message, contains('too many redirects'));
      expect((err.step, err.reason), ('fetch', 'structure'));
      expect((err.stage, err.status), (FlowStage.response, 302)); // answered: the state's loop, not a spec mistake
      expect(calls.length, 11);
    });

    test('exactly ten redirects are followed', () async {
      final calls = <http.Request>[];
      final ctx = await run([
        fetch('https://psilocybin.oregon.gov/s', {
          'extract': [
            {'var': 'b', 'source': 'body', 'regex': '(done)'}
          ]
        })
      ], recording(calls, (req) async {
        final n = int.parse(req.url.queryParameters['n'] ?? '0');
        if (n < 10) return http.Response('', 302, headers: {'location': '/s?n=${n + 1}'});
        return http.Response('done', 200);
      }));
      expect(ctx['b'], 'done');
      expect(calls.length, 11);
    });

    test('follow_redirects false returns the 3xx', () async {
      final calls = <http.Request>[];
      final ctx = await run([
        fetch('https://psilocybin.oregon.gov/x', {
          'follow_redirects': false,
          'extract': [
            {'var': 'st', 'source': 'status'},
            {'var': 'loc', 'source': 'header', 'name': 'Location'},
          ]
        })
      ], recording(calls, (req) async => http.Response('', 302, headers: {'location': 'https://evil.com/x'})));
      expect((ctx['st'], ctx['loc'], calls.length), (302, 'https://evil.com/x', 1));
    });

    test('every request is sent with followRedirects off: the runner follows redirects itself', () async {
      final calls = <http.Request>[];
      await run([fetch('https://psilocybin.oregon.gov/s')], recording(calls, (req) async {
        return req.url.path == '/s' ? http.Response('', 302, headers: {'location': '/end'}) : http.Response('', 200);
      }));
      expect([for (final c in calls) c.followRedirects], [false, false]);
    });

    test('Authorization is dropped on a hop to another host and kept on the same host', () async {
      final calls = <http.Request>[];
      await run([
        fetch('https://psilocybin.oregon.gov/a', {
          'headers': {'Authorization': 'Bearer T'}
        })
      ], recording(calls, (req) async {
        if (req.url.path == '/a') return http.Response('', 302, headers: {'location': '/b'});
        if (req.url.path == '/b') return http.Response('', 302, headers: {'location': 'https://$tenantHost/c'});
        return http.Response('', 200);
      }));
      expect([for (final c in calls) c.headers['authorization']], ['Bearer T', 'Bearer T', null]);
    });
  });

  group('timeout_seconds', () {
    test('every shipped flow spec sets it to 60 (SM-D1)', () {
      for (final name in ['login', 'sale', 'state_reads']) {
        final s = FlowSpec.fromYaml(File('assets/flows/$name.yaml').readAsStringSync());
        expect(flowRequestTimeout(s.vars), const Duration(seconds: 60), reason: name);
      }
    });

    test('a spec without it still gets 60 s, never no timeout at all', () {
      expect(flowRequestTimeout(const {}), const Duration(seconds: 60));
    });

    test('fractions of a second are kept; nonsense is a spec error, not a silent default', () {
      expect(flowRequestTimeout(const {'timeout_seconds': '0.05'}), const Duration(milliseconds: 50));
      expect(flowRequestTimeout(const {'timeout_seconds': 2}), const Duration(seconds: 2));
      expect(() => flowRequestTimeout(const {'timeout_seconds': 'soon'}), throwsA(isA<FlowError>()));
      expect(() => flowRequestTimeout(const {'timeout_seconds': '0'}), throwsA(isA<FlowError>()));
    });
  });

  // Mirrors mazama_sales/tests/state/test_flowspec_phase3.py case for case (spec format 2, SL-R11-R13): the same
  // inline specs, the same bodies and the same expected values.
  group('format 2: regex fallbacks, conditional steps and asking a person', () {
    FlowSpec specOf(String stepsYaml, {int fmt = 2}) =>
        FlowSpec.fromYaml('format: $fmt\nvars:\n  site: "https://psilocybin.oregon.gov"\nflows:\n  t:\n$stepsYaml');

    Future<Map<String, Object?>> run(FlowSpec s, _Net net,
            {Map<String, Object?> inputs = const {}, Future<String?> Function(String prompt, bool secret)? ask}) =>
        runFlow(s, 't', inputs, client: net.client(), ask: ask);

    Future<FlowError> fails(Future<Object?> running) async {
      try {
        await running;
      } on FlowError catch (ex) {
        return ex;
      }
      fail('expected a FlowError');
    }

    // --- SL-R11: regex fallbacks ---

    const fetchList = r'''
    - id: page
      type: request
      url: "{{site}}/p"
      extract:
        - {var: v, source: body, regex: ['a=(\w+)', 'b=(\w+)']}
''';

    test('a regex list uses the first pattern that matches', () async {
      expect((await run(specOf(fetchList), _Net(['b=two a=one'])))['v'], 'one');
    });

    test('a regex list falls back to the next pattern', () async {
      expect((await run(specOf(fetchList), _Net(['x b=two'])))['v'], 'two');
    });

    test('a regex list that finds nothing uses the default or leaves the var unset', () async {
      expect((await run(specOf(fetchList), _Net(['nothing']))).containsKey('v'), isFalse);
      final withDefault = fetchList.replaceFirst('regex: [', 'default: none, regex: [');
      expect((await run(specOf(withDefault), _Net(['nothing'])))['v'], 'none');
    });

    for (final regex in ['[]', r"['ok=(\w+)', 3]", "'('", "['(']"]) {
      test('a bad regex or regex list is a spec mistake naming the step ($regex)', () async {
        final s = specOf(fetchList.replaceFirst(r"['a=(\w+)', 'b=(\w+)']", regex));
        final err = await fails(run(s, _Net(['ok=1'])));
        expect((err.step, err.stage, err.reason), ('page', null, 'structure'));
      });
    }

    // Regex syntax both sides read (SPEC.md): test_flowspec_phase3.py holds the same two lists.
    const notShared = [
      r'(?P<n>x)', r'(?P=n)', r'(?i)x', r'(?#c)x', r'(?>x)', r'a*+', r'a++', r'a?+', r'a{2}+', r'x}+',
      r'(?(1)a|b)', r'\Ax', r'x\Z', r'[\A]', r'(?<n>x)', r'[a](?<n>x)', r'(?', r'[]a]', r'[^]a]', r'(a)*+',
      r'\(?+', r'\zx', r'\ex', r'(a)\1', r'\0', r'[\z]', '\\',
      // final review Minor 2: malformed hex escapes, \B in a class, {, and look-behinds Python can't read alike
      // (quantified, or of variable width)
      r'\x4', r'\x4g', r'\u12', r'\u{41}', r'[\x4]', r'[\u12]', r'x\x', r'[\B]', r'a{,3}', r'(?<=a)*',
      r'(?<=a)?', r'(?<!a)+', r'(?<=a){2}', r'(?<=a+)x', r'(?<=ab|c)x', r'(?<=a{2})x', r'(?<!a?)x',
      r'(?<=(?:a|b))x', r'(?<=(a)*)x',
    ];
    const shared = [
      r'[(?]x', r'(?:x)', r'(?=x)', r'(?!x)', r'(?<=a)x', r'(?<!a)x', r'a+?', r'a*?', r'a??', r'\(?x', r'\++',
      r'[+]+', r'a{2}', r'\\A', r'(a)+', r'[\]]+', r'"csrf":"([^"]+)"', r'[a-z]+?',
      r'\x41\d\W\s\S\b\B\n\r\t\f\v', r'\u0041', r'[\d\-\]]', r'\.\$\/', r'(\()?x',
      r'\x4a1', r'[\x41-\x5a]+', r'\u00e9', r'[\b]', r'a{2,3}', r'a{1,}', r'a|b', r'(?<=a)x|y', r'(a|b)(?<=b)c',
      r'(?<=[ab])x', r'(?<=\x41\d)x', r'(?<=(a))x', r'((?<=a)b)+', r'(?<=a)(x)+',
    ];
    for (final pattern in notShared) {
      test('regex syntax only one side reads is refused ($pattern)', () {
        expect(sharedRegexSyntax(pattern), isFalse);
        expect(() => regexPatterns(pattern, 'page'),
            throwsA(isA<FlowError>().having((e) => e.step, 'step', 'page')));
      });
    }
    for (final pattern in shared) {
      test('regex syntax both sides read is accepted ($pattern)', () {
        expect(sharedRegexSyntax(pattern), isTrue);
      });
    }

    test('a when matches outside the shared syntax is malformed', () {
      expect(() => checkWhen({'var': 'x', 'matches': '(?i)yes'}, 's'),
          throwsA(isA<FlowError>().having((e) => e.message, 'message', contains('malformed when'))));
    });

    test('a regex without a group finds nothing', () async {
      final s = specOf(fetchList.replaceFirst(r"['a=(\w+)', 'b=(\w+)']", r"['a=\w+', 'b=(\w+)']"));
      expect((await run(s, _Net(['a=one b=two'])))['v'], 'two');
    });

    test('regexGroupCount counts capture groups only', () {
      expect(regexGroupCount(RegExp(r'a(b)(?:c)(d)?')), 2);
      expect(regexGroupCount(RegExp(r'(?<=a)b')), 0);
    });

    // --- SL-R12: conditional steps ---

    const whenSteps = r'''
    - id: first
      type: request
      url: "{{site}}/first"
      extract:
        - {var: flag, source: body, regex: 'flag=(\w*)'}
    - id: maybe
      type: request
      when: WHEN
      url: "{{site}}/maybe"
      extract:
        - {var: got, source: body, regex: '(.+)'}
''';
    FlowSpec whenSpec(String cond) => specOf(whenSteps.replaceFirst('WHEN', cond));

    final whenCases = <(String, String, bool)>[
      ('{var: flag}', 'flag=yes', true),
      ('{var: flag}', 'flag=', false), // set but empty
      ('{var: flag}', 'no flag here', false), // unset
      ('{var: flag, equals: "yes"}', 'flag=yes', true),
      ('{var: flag, equals: "yes"}', 'flag=no', false),
      ('{var: flag, equals: "yes"}', 'no flag here', false),
      ('{var: flag, equals: ""}', 'no flag here', false), // unset is false for every form, even equals ""
      ('{var: flag, matches: "^y"}', 'flag=yes', true),
      ('{var: flag, matches: "e"}', 'flag=yes', true), // a search, not a full match
      ('{var: flag, matches: "^n"}', 'flag=yes', false),
      ('{var: flag, matches: ".*"}', 'no flag here', false),
    ];
    for (final (cond, body, runs) in whenCases) {
      test('when decides whether a step runs ($cond, $body)', () async {
        final net = _Net([body]);
        final ctx = await run(whenSpec(cond), net);
        expect(net.paths, runs ? ['/first', '/maybe'] : ['/first']);
        expect(ctx.containsKey('got'), runs); // a skipped step captures nothing
      });
    }

    test('equals compares the text of the value', () async {
      final s = specOf(r'''
    - id: first
      type: request
      url: "{{site}}/first"
      extract:
        - {var: n, source: body, json: n}
    - id: maybe
      type: request
      when: {var: n, equals: "3"}
      url: "{{site}}/maybe"
''');
      final net = _Net(['{"n": 3}']);
      await run(s, net);
      expect(net.paths, ['/first', '/maybe']);
    });

    // SPEC.md: {var} holds for JSON false too (its text isn't empty); a JSON boolean is tested with matches.
    final boolCases = <(String, String, bool)>[
      ('{var: flag}', '{"flag": true}', true),
      ('{var: flag}', '{"flag": false}', true),
      (r'{var: flag, matches: "^(true|True)$"}', '{"flag": true}', true),
      (r'{var: flag, matches: "^(true|True)$"}', '{"flag": false}', false),
      (r'{var: flag, matches: "^(true|True)$"}', '{}', false),
    ];
    for (final (cond, body, runs) in boolCases) {
      test('a JSON boolean is tested with matches true ($cond, $body)', () async {
        final s = specOf(r'''
    - id: first
      type: request
      url: "{{site}}/first"
      extract:
        - {var: flag, source: body, json: flag}
    - id: maybe
      type: request
      when: WHEN
      url: "{{site}}/maybe"
'''
            .replaceFirst('WHEN', cond));
        final net = _Net([body]);
        await run(s, net);
        expect(net.paths, runs ? ['/first', '/maybe'] : ['/first']);
      });
    }

    test('a skipped step with an extract default still captures nothing', () async {
      final s = specOf(r'''
    - id: maybe
      type: request
      when: {var: absent}
      url: "{{site}}/maybe"
      extract:
        - {var: got, source: body, regex: '(x)', default: d}
''');
      final net = _Net(['x']);
      expect((await run(s, net)).containsKey('got'), isFalse);
      expect(net.paths, isEmpty);
    });

    test('a name only a skipped step sets is a FlowError when used', () async {
      final s = specOf(r'''
    - id: maybe
      type: generate
      when: {var: absent}
      make: random_hex
      into: [x]
    - id: use
      type: request
      url: "{{site}}/{{x}}"
''');
      final net = _Net(['']);
      final err = await fails(run(s, net)); // a FlowError, as in flowspec.py: not the FlowSpecError a spec's vars give
      expect(err, isA<FlowUnknownName>());
      expect(err.message, contains('unknown variable: x'));
      expect((err.reason, err.stage, err.step), ('structure', null, 'use'));
      expect(net.paths, isEmpty);
    });

    for (final cond in [
      '{var: flag, equals: "a", matches: "b"}',
      '{var: flag, contains: "a"}',
      '{equals: "a"}',
      '{var: 3}',
      '{var: flag, equals: 3}',
      '{var: flag, matches: true}',
      'flag',
      '[flag]',
      '{var: flag, matches: "("}',
    ]) {
      test('a malformed when is a spec mistake naming the step and sends nothing more ($cond)', () async {
        final net = _Net(['no flag here']); // the var is unset: the form is checked even when it would be false
        final err = await fails(run(whenSpec(cond), net));
        expect((err.step, err.stage, err.reason), ('maybe', null, 'structure'));
        expect(net.paths, ['/first']);
      });
    }

    // --- SL-R13: asking a person ---

    const askSteps = r'''
    - id: ask
      type: await_input
      into: code
      prompt: "Code for {{who}}?"
      secret: true
    - id: send
      type: request
      method: POST
      url: "{{site}}/code"
      form: {code: "{{code}}"}
      require:
        - check: json_equals
          path: ok
          value: "yes"
          error: "refused: {{why}}"
      capture_on_fail:
        - {var: why, source: body, json: message}
''';

    test('await_input asks with the templated prompt and later steps use the answer', () async {
      final asked = <(String, bool)>[];
      final net = _Net(['{"ok": "yes"}']);
      final ctx = await run(specOf(askSteps), net, inputs: {'who': 'Ann'}, ask: (prompt, secret) async {
        asked.add((prompt, secret));
        return '123456';
      });
      expect(asked, [('Code for Ann?', true)]);
      expect(ctx['code'], '123456');
      expect(net.forms, ['code=123456']);
    });

    test('secret defaults to false', () async {
      final asked = <bool>[];
      await run(specOf(askSteps.replaceFirst('      secret: true\n', '')), _Net(['{"ok": "yes"}']),
          inputs: {'who': 'x'}, ask: (p, s) async {
        asked.add(s);
        return '1';
      });
      expect(asked, [false]);
    });

    test('without a callback the flow needs a person and sends nothing', () async {
      final net = _Net(['{"ok": "yes"}']);
      final err = await fails(run(specOf(askSteps), net, inputs: {'who': 'x'}));
      expect((err.reason, err.stage, err.step, err.status), ('needs_person', null, 'ask', null));
      expect(net.paths, isEmpty);
    });

    for (final answer in <String?>['', null]) {
      test('an empty or missing answer is cancelled and sends nothing ($answer)', () async {
        final net = _Net(['{"ok": "yes"}']);
        final err = await fails(run(specOf(askSteps), net, inputs: {'who': 'x'}, ask: (p, s) async => answer));
        expect((err.reason, err.stage, err.step), ('cancelled', null, 'ask'));
        expect(net.paths, isEmpty);
      });
    }

    test('a secret answer echoed back is scrubbed from the error', () async {
      final net = _Net(['{"ok": "no", "message": "wrong code 987654"}']);
      final err = await fails(run(specOf(askSteps), net, inputs: {'who': 'x'}, ask: (p, s) async => '987654'));
      expect(err.message, isNot(contains('987654')));
      expect(err.message, contains('wrong code ***'));
    });

    test('an answer that is not secret is not scrubbed', () async {
      final net = _Net(['{"ok": "no", "message": "wrong code 987654"}']);
      final err = await fails(run(specOf(askSteps.replaceFirst('secret: true', 'secret: false')), net,
          inputs: {'who': 'x'}, ask: (p, s) async => '987654'));
      expect(err.message, contains('wrong code 987654'));
    });

    test('a skipped await_input does not ask', () async {
      final s = specOf(askSteps
          .replaceFirst('      type: await_input\n', '      type: await_input\n      when: {var: mfa}\n')
          .replaceFirst('      form:', '      when: {var: mfa}\n      form:'));
      final net = _Net(['']);
      final ctx = await run(s, net, inputs: {'who': 'x'}, ask: (prompt, secret) async => fail('asked'));
      expect(ctx.containsKey('code'), isFalse);
      expect(net.paths, isEmpty);
    });

    final malformedAsks = <(String, String)>[
      ('      into: code\n', ''),
      ('      into: code\n', '      into: [code]\n'),
      ('      prompt: "Code for {{who}}?"\n', ''),
      ('      prompt: "Code for {{who}}?"\n', '      prompt: 3\n'),
      ('      secret: true\n', '      secret: "yes"\n'),
    ];
    for (final (from, to) in malformedAsks) {
      test('a malformed await_input is a spec mistake naming the step (${from.trim()} -> ${to.trim()})', () async {
        final err = await fails(
            run(specOf(askSteps.replaceFirst(from, to)), _Net(['']), inputs: {'who': 'x'}, ask: (p, s) async => '1'));
        expect((err.step, err.stage, err.reason), ('ask', null, 'structure'));
      });
    }

    // --- a mistake in the spec itself is reason `structure` (final review Minor 3; test_flowspec_phase3.py) ---

    for (final steps in [
      '    - {id: s, type: generate, when: {var: x, contains: y}, make: random_hex, into: [n]}\n', // malformed when
      r"""    - {id: s, type: request, url: "{{site}}/p", extract: [{var: v, source: body, regex: '(?i)(x)'}]}""" '\n',
      r"""    - {id: s, type: request, url: "{{site}}/p", extract: [{var: v, source: body, regex: '(x'}]}""" '\n',
      r"""    - {id: s, type: request, url: "{{site}}/p", extract: [{var: v, source: body, regex: 3}]}""" '\n',
      '    - {id: s, type: await_input, into: [x], prompt: p}\n',
      '    - {id: s, type: teleport}\n',
      '    - {id: s, make: random_hex, into: [n]}\n', // no type at all
      r"""    - {id: s, type: request, url: "{{site}}/p", extract: [{var: v, source: cookie}]}""" '\n',
      '    - {id: s, type: assert, require: [{check: is_nice, vars: [site]}]}\n',
      '    - {id: s, type: generate, make: uuid, into: [n]}\n',
    ]) {
      test('a mistake in the spec itself is reason structure with no stage (${steps.trim()})', () async {
        final err = await fails(run(specOf(steps), _Net(['x']), ask: (p, s) async => '1'));
        expect((err.step, err.stage, err.reason), ('s', null, 'structure'));
      });
    }

    // --- format ---

    test('this interpreter reads format 2', () {
      // format 3 and the refusal of format 4: the 'format 3' group below
      expect(FlowSpec.fromYaml('format: 2\nflows: {}\n').format, 2);
    });

    // --- parked phase 2 follow-up: an explicit tag on a value it can't read ---

    for (final text in [
      'vars: {a: !!int abc}\n',
      'vars: {a: !!float abc}\n',
      'vars: {a: !!bool abc}\n',
      'vars: {a: !!int 0xzz}\n',
      'vars: {a: !!timestamp abc}\n',
    ]) {
      test('a tagged value that cannot be read is a FlowSpecError that does not quote it (${text.trim()})', () {
        try {
          FlowSpec.fromYaml(text);
          fail('expected a FlowSpecError');
        } on FlowSpecError catch (ex) {
          expect(ex.message, isNot(contains('abc')));
          expect(ex.message, isNot(contains('zz')));
        }
      });
    }

    // --- end to end: an MFA round on the state fake ---

    String mfaSpecText() {
      var text = File('assets/flows/login.yaml').readAsStringSync();
      expect(text, contains('format: 1\n'));
      expect(text, contains('    - id: confirmed\n'));
      text = text.replaceFirst('format: 1\n', 'format: 2\n');
      text = text.replaceFirst('        - {var: b2c_status, source: body, json: status}\n',
          '        - {var: b2c_status, source: body, json: status}\n        - {var: mfa, source: body, json: mfa}\n');
      return text.replaceFirst('    - id: confirmed\n', '$_mfaSteps    - id: confirmed\n');
    }

    const creds = {'email': fakeEmail, 'password': fakePassword};

    test('an MFA spec signs in with the code a person gives', () async {
      final fake = FakeState(mfaCode: '123456');
      final asked = <(String, bool)>[];
      final ctx = await runFlow(FlowSpec.fromYaml(mfaSpecText()), 'login', creds, client: fake.client(),
          ask: (p, s) async {
        asked.add((p, s));
        return '123456';
      });
      expect(ctx['access_token'], 'ACCESS-1');
      expect(fake.logins, 1);
      expect(asked, [('Enter the most recent code the state sent you', true)]);
    });

    test('an MFA spec with a wrong code is refused without echoing it', () async {
      final fake = FakeState(mfaCode: '123456');
      final err = await fails(runFlow(FlowSpec.fromYaml(mfaSpecText()), 'login', creds,
          client: fake.client(), ask: (p, s) async => '654321'));
      expect((err.reason, err.step), ('credentials', 'send_code'));
      expect(err.message, isNot(contains('654321')));
      expect(err.message, contains('wrong code ***'));
      expect(fake.logins, 0);
    });

    test('an MFA spec signs in without asking when the state wants no code', () async {
      final fake = FakeState();
      final ctx = await runFlow(FlowSpec.fromYaml(mfaSpecText()), 'login', creds,
          client: fake.client(), ask: (p, s) async => fail('asked'));
      expect(ctx['access_token'], 'ACCESS-1');
    });

    test('the shipped spec against an MFA state fails without a token', () async {
      await expectLater(runFlow(spec, 'login', creds, client: FakeState(mfaCode: '123456').client()),
          throwsA(isA<FlowError>()));
    });

    test('an MFA spec run without a callback needs a person', () async {
      final fake = FakeState(mfaCode: '123456');
      final err = await fails(runFlow(FlowSpec.fromYaml(mfaSpecText()), 'login', creds, client: fake.client()));
      expect((err.reason, err.step), ('needs_person', 'ask_code'));
    });
  });

  // test_flowspec_phase4.py holds the same cases.
  group('format 3: open_browser, vars_equal and callback errors', () {
    const site = 'https://psilocybin.oregon.gov';
    FlowSpec specOf(String stepsYaml) =>
        FlowSpec.fromYaml('format: 3\nvars:\n  site: "$site"\nflows:\n  t:\n$stepsYaml');

    Future<Map<String, Object?>> run(FlowSpec s,
            {_Net? net,
            Map<String, Object?> inputs = const {},
            Set<String> secretKeys = defaultSecretKeys,
            Future<String?> Function(String prompt, bool secret)? ask,
            Future<String?> Function(String url, String until)? browse}) =>
        runFlow(s, 't', inputs,
            client: (net ?? _Net([''])).client(), secretKeys: secretKeys, ask: ask, browse: browse);

    Future<FlowError> fails(Future<Object?> running) async {
      try {
        await running;
      } on FlowError catch (ex) {
        return ex;
      }
      fail('expected a FlowError');
    }

    const browseSteps = r'''
    - id: page
      type: open_browser
      url: "{{site}}/authorize"
      params: {state: "{{st}}", p: B2C_1A_signin}
      until: "{{site}}/"
      extract:
        - {var: code, source: url_fragment, name: code}
        - {var: returned_state, source: url_fragment, name: state}
        - {var: q, source: url_query, name: q}
        - {var: missing, source: url_fragment, name: nothing, default: none}
        - {var: unset, source: url_query, name: nothing}
''';

    // A browse callback answering [answer] that records what it was given.
    final calls = <(String, String)>[];
    setUp(calls.clear);
    Future<String?> Function(String, String) browser(String? answer) => (url, until) async {
          calls.add((url, until));
          return answer;
        };

    // --- open_browser ---

    test("browse gets the start URL with params and until, and the returned URL's parts land in the context",
        () async {
      final net = _Net(['']);
      final ctx = await run(specOf(browseSteps),
          net: net, inputs: {'st': 'abc'}, browse: browser('$site/?q=1#code=CODE1&state=abc'));
      expect(calls, [('$site/authorize?state=abc&p=B2C_1A_signin', '$site/')]);
      expect((ctx['code'], ctx['returned_state'], ctx['q'], ctx['missing']), ('CODE1', 'abc', '1', 'none'));
      expect(ctx.containsKey('unset'), isFalse);
      expect(net.paths, isEmpty); // the interpreter sends nothing itself
    });

    test("the returned URL's values are decoded and a blank or bare key is an empty value", () async {
      final ctx =
          await run(specOf(browseSteps), inputs: {'st': 'x'}, browse: browser('$site/?q=a+b%2Bc#state=&code'));
      expect((ctx['q'], ctx['returned_state'], ctx['code']), ('a b+c', '', ''));
    });

    test('the first of a repeated key wins', () async {
      final ctx = await run(specOf(browseSteps), inputs: {'st': 'x'}, browse: browser('$site/#code=one&code=two'));
      expect(ctx['code'], 'one');
    });

    test('the fragment is everything after the first hash and the query stops at it', () async {
      final ctx = await run(specOf(browseSteps), inputs: {'st': 'x'}, browse: browser('$site/#code=a?q=2#b'));
      expect(ctx['code'], 'a?q=2#b');
      expect(ctx.containsKey('q'), isFalse);
    });

    test('urlValue decodes as a form value and leaves a stray percent alone', () {
      expect(urlValue('https://x/#a=%C3%A9%zz+%2', 'url_fragment', 'a'), 'é%zz %2');
      expect(urlValue('https://x/?a=1', 'url_fragment', 'a'), isNull);
      expect(urlValue('https://x/#a=1', 'url_query', 'a'), isNull);
    });

    test('without a browse callback the flow needs a person', () async {
      final err = await fails(run(specOf(browseSteps), inputs: {'st': 'x'}));
      expect((err.reason, err.stage, err.step, err.status), ('needs_person', null, 'page', null));
    });

    test('a closed page is cancelled', () async {
      final err = await fails(run(specOf(browseSteps), inputs: {'st': 'x'}, browse: browser(null)));
      expect((err.reason, err.stage, err.step), ('cancelled', null, 'page'));
    });

    for (final answer in ['https://evil.example.com/#code=1', site, '', '${site.toUpperCase()}/#code=1']) {
      test('a returned URL that does not start with until is structure and is not quoted ($answer)', () async {
        final err = await fails(run(specOf(browseSteps), inputs: {'st': 'x'}, browse: browser(answer)));
        expect((err.reason, err.stage, err.step), ('structure', null, 'page'));
        expect(err.message, isNot(contains('code=1')));
        expect(err.message, isNot(contains('evil')));
      });
    }

    final offList = <(String, String)>[
      ('url: "{{site}}/authorize"', 'url: "https://evil.example.com/authorize"'),
      ('url: "{{site}}/authorize"', 'url: "http://psilocybin.oregon.gov/authorize"'),
      ('url: "{{site}}/authorize"', 'url: "{{st}}/authorize"'),
      ('until: "{{site}}/"', 'until: "https://evil.example.com/"'),
      ('until: "{{site}}/"', 'until: "http://psilocybin.oregon.gov/"'),
      // another B2C tenant (SL-R17)
      ('url: "{{site}}/authorize"', 'url: "https://evil.b2clogin.com/authorize"'),
      ('url: "{{site}}/authorize"', 'url: "https://oregonpsilocybinprodb2c.b2clogin.com.evil.example/authorize"'),
      ('until: "{{site}}/"', 'until: "https://evil.b2clogin.com/"'),
      ('until: "{{site}}/"', 'until: "https://xoregonpsilocybinprodb2c.b2clogin.com/"'),
    ];
    for (final (from, to) in offList) {
      test('a start URL or until off the allowlist is not allowed and browse is never called ($to)', () async {
        final err = await fails(run(specOf(browseSteps.replaceFirst(from, to)),
            inputs: {'st': 'https://evil.example.com'}, browse: browser('$site/#code=1')));
        expect((err.reason, err.stage, err.step), ('not_allowed', null, 'page'));
        expect(calls, isEmpty);
      });
    }

    test('a start URL off the allowlist is not allowed even with no callback', () async {
      final err = await fails(run(
          specOf(browseSteps.replaceFirst('url: "{{site}}/authorize"', 'url: "https://evil.example.com/a"')),
          inputs: {'st': 'x'}));
      expect(err.reason, 'not_allowed');
    });

    final malformed = <(String, String)>[
      ('      url: "{{site}}/authorize"\n', ''),
      ('      url: "{{site}}/authorize"\n', '      url: [x]\n'),
      ('      until: "{{site}}/"\n', ''),
      ('      until: "{{site}}/"\n', '      until: 3\n'),
      ('      params: {state: "{{st}}", p: B2C_1A_signin}\n', '      params: [a]\n'),
      ('source: url_fragment, name: code}', 'source: url_fragment}'),
      ('source: url_fragment, name: code}', 'source: url_fragment, name: 3}'),
      ('source: url_fragment, name: code}', "source: body, regex: '(x)'}"),
      ('source: url_fragment, name: code}', 'source: url, name: code}'),
      ('{var: code, source', '{var: [code], source'),
      ('      extract:\n', '      extract: {a: b}\n      x:\n'),
    ];
    for (final (from, to) in malformed) {
      test('a malformed open_browser is a spec mistake naming the step (${from.trim()} -> ${to.trim()})', () async {
        final err = await fails(
            run(specOf(browseSteps.replaceFirst(from, to)), inputs: {'st': 'x'}, browse: browser('$site/#code=1')));
        expect((err.reason, err.stage, err.step), ('structure', null, 'page'));
        expect(calls, isEmpty);
      });
    }

    test('a url_fragment extract in a request step is an unknown source', () async {
      final s = specOf(
          r'''    - {id: s, type: request, url: "{{site}}/p", extract: [{var: v, source: url_fragment, name: v}]}''' '\n');
      final err = await fails(run(s, net: _Net(['x'])));
      expect((err.reason, err.stage, err.step), ('structure', null, 's'));
    });

    test('the returned URL is never in an error and a secret extract is scrubbed', () async {
      const checkStep = r'''
    - id: check
      type: assert
      require:
        - {check: truthy, vars: [absent], error: "no luck with {{code}}", reason: structure}
''';
      final s = specOf('$browseSteps$checkStep');
      final err = await fails(run(s,
          inputs: {'st': 'x'},
          secretKeys: {...defaultSecretKeys, 'code'},
          browse: browser('$site/#code=TOPSECRET')));
      expect(err.message, isNot(contains('TOPSECRET')));
      expect(err.message, contains('no luck with ***'));
    });

    test('a skipped open_browser does not browse', () async {
      final s = specOf(browseSteps.replaceFirst(
          '      type: open_browser\n', '      type: open_browser\n      when: {var: absent}\n'));
      final ctx = await run(s, inputs: {'st': 'x'}, browse: browser('$site/#code=1'));
      expect(ctx.containsKey('code'), isFalse);
      expect(calls, isEmpty);
    });

    // --- callback errors pass through ---

    const askSteps = r'''
    - id: ask
      type: await_input
      into: code
      prompt: "Code?"
''';

    Future<Map<String, Object?>> runRaising(String which, Object error) => which == 'ask'
        ? run(specOf(askSteps), inputs: {'st': 'x'}, ask: (p, s) async => throw error)
        : run(specOf(browseSteps), inputs: {'st': 'x'}, browse: (u, t) async => throw error);

    for (final (which, step) in [('ask', 'ask'), ('browse', 'page')]) {
      test('a FlowError from the $which callback passes through with its step filled in', () async {
        final err = await fails(
            runRaising(which, FlowError('nobody answered the sign-in prompt in time', reason: 'needs_person')));
        expect((err.reason, err.step, err.message, err.stage),
            ('needs_person', step, 'nobody answered the sign-in prompt in time', null));
      });

      test('a FlowError from the $which callback that names a step is the same error', () async {
        final raised = FlowError('db down', reason: 'unavailable', step: 'elsewhere');
        final err = await fails(runRaising(which, raised));
        expect(identical(err, raised), isTrue);
      });

      test('any other exception from the $which callback is structure without its message', () async {
        final err = await fails(runRaising(which, StateError('Hunter2 leaked')));
        expect((err.reason, err.stage, err.step), ('structure', null, step));
        expect(err.message, isNot(contains('Hunter2')));
      });
    }

    test('the prompt never carries a secret value', () async {
      // The prompt can be stored, shown and sent on (SL-R14), so a secret templated into it reaches ask scrubbed.
      final asked = <String>[];
      await run(specOf(askSteps.replaceFirst('"Code?"', '"Code for {{password}}?"')),
          inputs: {'password': 'Hunter2'}, ask: (prompt, secret) async {
        asked.add(prompt);
        return '1';
      });
      expect(asked, ['Code for ***?']);
    });

    // --- vars_equal ---

    FlowSpec eqSpec([String vars = '[a, b]']) => specOf('''
    - id: same
      type: assert
      require:
        - {check: vars_equal, vars: $vars, reason: structure, error: "state mismatch for {{a}}"}
''');

    final eqCases = <(Map<String, Object?>, bool)>[
      ({'a': 'x', 'b': 'x'}, true),
      ({'a': 'x', 'b': 'y'}, false),
      ({'a': 'x'}, false),
      ({'b': 'x'}, false),
      ({}, false),
      ({'a': '', 'b': ''}, true),
      ({'a': '3', 'b': 3}, true), // compared as text
      ({'a': null, 'b': null}, false), // unset (null) on both sides is not equal
    ];
    for (final (inputs, ok) in eqCases) {
      test('vars_equal needs both set and equal as text ($inputs)', () async {
        if (ok) {
          await run(eqSpec(), inputs: inputs);
          return;
        }
        final err = await fails(run(eqSpec(), inputs: inputs));
        expect((err.reason, err.stage, err.step), ('structure', null, 'same'));
      });
    }

    test("vars_equal fails with the check's error and reason", () async {
      final s = specOf(r'''
    - id: same
      type: assert
      require:
        - {check: vars_equal, vars: [a, b], reason: credentials, error: "a was {{a}}"}
''');
      final err = await fails(run(s, inputs: {'a': 'x', 'b': 'y'}));
      expect((err.reason, err.message), ('credentials', 'a was x'));
    });

    for (final vars in ['[a]', '[a, b, c]', 'a', '[a, 3]', '{a: b}']) {
      test('a malformed vars_equal is a spec mistake ($vars)', () async {
        final err = await fails(run(eqSpec(vars), inputs: {'a': 'x', 'b': 'x', 'c': 'x'}));
        expect((err.reason, err.stage, err.step), ('structure', null, 'same'));
      });
    }

    // --- review fix round 1 (test_flowspec_phase4.py holds the same cases) ---

    final roundOne = <(String, String, Map<String, Object?>)>[
      ('url: "{{site}}/authorize"', 'url: "{{site}}/authorize?p=X"', {}), // I1: a query belongs in params
      ('url: "{{site}}/authorize"', 'url: "{{site}}/authorize{{qs}}"', {'qs': '?p=X'}),
      ('until: "{{site}}/"', 'until: "{{site}}"', {}), // M1: until needs a path
      ('until: "{{site}}/"', 'until: "https://psilocybin.oregon.gov"', {}),
      ('      extract:\n', '      require: [{check: truthy, vars: [st]}]\n      extract:\n', {}), // I2
      ('      extract:\n', '      capture_on_fail: [{var: why, source: url_query, name: why}]\n      extract:\n', {}),
      ('      extract:\n', '      then_require: {check: truthy}\n      extract:\n', {}),
    ];
    for (final (from, to, extra) in roundOne) {
      test('a query in url, a bare until, or require/capture_on_fail on open_browser is structure (${to.trim()})',
          () async {
        final err = await fails(run(specOf(browseSteps.replaceFirst(from, to)),
            inputs: {'st': 'x', ...extra}, browse: browser('$site/#code=1')));
        expect((err.reason, err.stage, err.step), ('structure', null, 'page'));
        expect(calls, isEmpty);
      });
    }

    const stateCheck = '''
      then_require:
        - {check: vars_equal, vars: [st, returned_state], reason: structure, error: "the state did not match"}
''';

    test('a then_require on open_browser runs after its extracts', () async {
      final spec = specOf('$browseSteps$stateCheck');
      final ctx = await run(spec, inputs: {'st': 'abc'}, browse: browser('$site/#code=1&state=abc'));
      expect(ctx['code'], '1');
      final err = await fails(run(spec, inputs: {'st': 'abc'}, browse: browser('$site/#code=1&state=evil')));
      expect((err.reason, err.stage, err.step, err.message), ('structure', null, 'page', 'the state did not match'));
    });

    test('a FlowError subclass from a callback is the same object, its step filled in', () async {
      final raised = FlowUnknownName('a subclass');
      final err = await fails(run(specOf(browseSteps), inputs: {'st': 'x'}, browse: (u, t) async => throw raised));
      expect(identical(err, raised), isTrue);
      expect((err.step, err.reason), ('page', 'structure'));
    });

    // --- format ---

    test('this interpreter reads format 3 and refuses format 4', () {
      expect(supportedFlowFormat, 3);
      expect(FlowSpec.fromYaml('format: 3\nflows: {}\n').format, 3);
      expect(() => FlowSpec.fromYaml('format: 4\nflows: {}\n'),
          throwsA(isA<FlowSpecError>().having((e) => e.message, 'message', contains('format 4'))));
    });

    test('specHostsAllowed checks open_browser url and until', () {
      expect(specHostsAllowed(specOf(browseSteps)), isTrue);
      expect(
          specHostsAllowed(
              specOf(browseSteps.replaceFirst('url: "{{site}}/authorize"', 'url: "https://e.example/"'))),
          isFalse);
      expect(specHostsAllowed(specOf(browseSteps.replaceFirst('until: "{{site}}/"', 'until: "https://e.example/"'))),
          isFalse);
      expect(specHostsAllowed(specOf(browseSteps.replaceFirst('until: "{{site}}/"', 'until: "{{st}}/"'))), isFalse);
    });
  });
}

/// The MFA round SPEC.md shows (mazama_sales/tests/state/mfa_spec.py's MFA_STEPS), inserted before `confirmed`.
const _mfaSteps = r'''
    - id: ask_code
      type: await_input
      when: {var: mfa, matches: "^(true|True)$"}
      into: mfa_code
      prompt: "Enter the most recent code the state sent you"
      secret: true

    - id: send_code
      type: request
      when: {var: mfa, matches: "^(true|True)$"}
      method: POST
      url: "{{b2c}}/{{pol}}/SelfAsserted"
      params: {tx: "{{trans}}", p: "{{pol}}"}
      headers:
        X-CSRF-TOKEN: "{{csrf}}"
        X-Requested-With: XMLHttpRequest
        Origin: "{{b2c_host}}"
        Referer: "{{page_url}}"
      form:
        request_type: RESPONSE
        code: "{{mfa_code}}"
      require:
        - check: status_in
          values: [200]
          reason: unavailable
          error: "the code form did not answer: HTTP {status}"
        - check: json_equals
          path: status
          value: "200"
          reason: credentials
          error: "the code was refused: {{mfa_message}}"
      capture_on_fail:
        - {var: mfa_message, source: body, json: message, default: "wrong code"}

''';

/// Answers every request with the next of its bodies (the last one from then on) and records the path and body of
/// each request it is sent (test_flowspec_phase3.py's Net).
class _Net {
  final List<String> _bodies;
  final List<String> paths = [];
  final List<String> forms = [];
  _Net(List<String> bodies) : _bodies = [...bodies];

  http.Client client() => MockClient((req) async {
        paths.add(req.url.path);
        forms.add(req.body);
        final body = _bodies.length > 1 ? _bodies.removeAt(0) : _bodies[0];
        return http.Response(body, 200);
      });
}

/// A client whose send() does whatever the test says - throw a transport error, never answer, or answer with
/// a body stream that misbehaves.
class _Scripted extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) _send;
  _Scripted(this._send);
  _Scripted.throwing(Object error) : _send = ((_) => Future.error(error));
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _send(request);
}

/// The shape of package:http's private _ClientSocketException: a ClientException that implements
/// SocketException and forwards osError/address/port to the SocketException it wraps.
class _WrappedSocketException extends http.ClientException implements SocketException {
  final SocketException cause;
  _WrappedSocketException(this.cause) : super(cause.message);
  @override
  InternetAddress? get address => cause.address;
  @override
  OSError? get osError => cause.osError;
  @override
  int? get port => cause.port;
}
