// Covers Session's own arithmetic (expiry, renewal threshold, JSON round-trip) and ensureFreshSession's three
// real outcomes: untouched when fresh, renewed via the real `renew` flow when stale, and a clean SessionExpired
// (never a bare FlowError) when renewal isn't possible. Reuses fake_state.dart and assets/flows/login.yaml -
// the same fixtures flow_runner_test.dart already proves the `renew` flow against - rather than faking
// ensureFreshSession's own HTTP layer a second time.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_hosts_store.dart';
import 'package:mazama_mobile/session.dart';

import 'flow/fake_state.dart';
import 'host_list_signing.dart';

late final FlowSpec spec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());

final fixedNow = DateTime.utc(2026, 1, 1, 12, 0, 0);
DateTime _now() => fixedNow;

void main() {
  test('fromFlowResult computes an absolute expiry from expires_in', () {
    final session = Session.fromFlowResult({'access_token': 'A', 'refresh_token': 'R', 'expires_in': 3600}, email: 'worker@example.com', now: _now);
    expect(session.accessToken, 'A');
    expect(session.refreshToken, 'R');
    expect(session.expiresAtMs, fixedNow.millisecondsSinceEpoch + 3600 * 1000);
  });

  test('fromFlowResult treats a missing expires_in as already expired, not a crash', () {
    final session = Session.fromFlowResult({'access_token': 'A', 'refresh_token': 'R'}, email: 'worker@example.com', now: _now);
    expect(session.expiresAtMs, fixedNow.millisecondsSinceEpoch);
  });

  test('needsRenewal is false well before expiry, true once inside the refresh margin', () {
    final session = Session.fromFlowResult({'access_token': 'A', 'refresh_token': 'R', 'expires_in': 3600}, email: 'worker@example.com', now: _now);
    expect(session.needsRenewal(now: () => fixedNow), false);
    // Just under 58 minutes in: a moment more than the 2-minute margin from expiry - not yet due.
    expect(session.needsRenewal(now: () => fixedNow.add(const Duration(minutes: 58, milliseconds: -1))), false);
    // Exactly 58 minutes in: exactly the margin from expiry - due, as on the server (SM-20: StateSession keeps a
    // token only while now < expiry - margin).
    expect(session.needsRenewal(now: () => fixedNow.add(const Duration(minutes: 58))), true);
    // 59 minutes in: only 1 minute from expiry - inside the 2-minute margin, due for renewal.
    expect(session.needsRenewal(now: () => fixedNow.add(const Duration(minutes: 59))), true);
    // Past expiry entirely.
    expect(session.needsRenewal(now: () => fixedNow.add(const Duration(hours: 2))), true);
  });

  // SM-20: the margin is login.yaml's refresh_margin_seconds, the same var the server's REFRESH_MARGIN reads.
  test('the refresh margin comes from the login spec, 120 s, and is the built-in default', () {
    expect(refreshMarginOf(spec), const Duration(seconds: 120));
    expect(defaultRefreshMargin, const Duration(seconds: 120));
    expect(refreshMarginOf(FlowSpec({}, const {})), defaultRefreshMargin);
    expect(refreshMarginOf(FlowSpec({'refresh_margin_seconds': '1.5'}, const {})), const Duration(milliseconds: 1500));
    expect(() => refreshMarginOf(FlowSpec({'refresh_margin_seconds': '-1'}, const {})), throwsA(isA<FlowSpecError>()));
    expect(() => refreshMarginOf(FlowSpec({'refresh_margin_seconds': 'soon'}, const {})), throwsA(isA<FlowSpecError>()));
  });

  test('needsRenewal takes the margin it is given', () {
    final session = Session.fromFlowResult({'access_token': 'A', 'refresh_token': 'R', 'expires_in': 3600}, email: 'worker@example.com', now: _now);
    final at50 = fixedNow.add(const Duration(minutes: 50));
    expect(session.needsRenewal(now: () => at50), false);
    expect(session.needsRenewal(now: () => at50, margin: const Duration(minutes: 10)), true);
  });

  test('toJson/fromJson round-trips exactly, including a null refresh token', () {
    final withRefresh = Session.fromFlowResult({'access_token': 'A', 'refresh_token': 'R', 'expires_in': 3600}, email: 'worker@example.com', now: _now);
    final restored = Session.fromJson(withRefresh.toJson());
    expect(restored, isNotNull);
    expect(restored!.accessToken, withRefresh.accessToken);
    expect(restored.refreshToken, withRefresh.refreshToken);
    expect(restored.expiresAtMs, withRefresh.expiresAtMs);

    const noRefresh = Session(accessToken: 'A', email: 'worker@example.com', expiresAtMs: 123);
    expect(Session.fromJson(noRefresh.toJson())?.refreshToken, isNull);
  });

  test('fromJson rejects anything that is not a session this class itself wrote', () {
    expect(Session.fromJson(null), isNull);
    expect(Session.fromJson(const {}), isNull);
    expect(Session.fromJson(const {'access_token': 'A'}), isNull); // no expires_at_ms
    expect(Session.fromJson(const {'expires_at_ms': 123}), isNull); // no access_token
    expect(Session.fromJson(const {'access_token': 7, 'expires_at_ms': 123}), isNull); // wrong type
  });

  test('a failed-sale report names a session problem in fixed words, never its message', () {
    expect(sessionFailureReportText(SessionExpired('could not be renewed (refused LEAKED) - please sign in again.')),
        "the state's sign-in session expired");
    expect(sessionFailureReportText(SessionSpecUnusable('spec broke on LEAKED')),
        'the sign-in spec could not renew the session');
    expect(sessionFailureReportText(SessionRenewalUnavailable('unreachable LEAKED')),
        "the state's sign-in could not be renewed");
    expect(sessionFailureReportText(StateError('LEAKED')), "the state's sign-in failed");
  });

  group('ensureFreshSession', () {
    test('a session well within its lifetime is returned unchanged, with no network call at all', () async {
      final fresh = Session.fromFlowResult({'access_token': 'A', 'refresh_token': 'R', 'expires_in': 3600}, email: 'worker@example.com', now: _now);
      final client = http_testing.MockClient((req) async => throw StateError('no network call expected: ${req.url}'));
      final result = await ensureFreshSession(fresh, spec, client: client, now: _now);
      expect(result, same(fresh)); // identically the same instance - not just equal fields
    });

    test('a session inside the refresh margin is renewed via the real renew flow', () async {
      final fake = FakeState();
      final login = await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      // Built already-expired relative to `_now`, regardless of what `login` itself set its own expires_in to -
      // this is the renewal path being tested, not fromFlowResult's arithmetic (that's covered above).
      final stale = Session(accessToken: login['access_token'] as String, refreshToken: login['refresh_token'] as String,
          email: 'worker@example.com', expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);

      final renewed = await ensureFreshSession(stale, spec, client: fake.client(), now: _now);

      expect(fake.refreshes, 1);
      expect(renewed.accessToken, isNot(stale.accessToken)); // a genuinely new token, not the stale one echoed back
      expect(renewed.needsRenewal(now: _now), false);
    });

    test("ensureFreshSession renews by the spec's own margin", () async {
      // 5 minutes from expiry: fresh under the 120 s default, due under a spec that says 600 s.
      final session = Session(accessToken: 'A', refreshToken: 'R', email: 'worker@example.com',
          expiresAtMs: fixedNow.millisecondsSinceEpoch + 5 * 60 * 1000);
      final none = http_testing.MockClient((req) async => throw StateError('no network call expected: ${req.url}'));
      expect(await ensureFreshSession(session, spec, client: none, now: _now), same(session));
      final wide = FlowSpec({...spec.vars, 'refresh_margin_seconds': '600'}, spec.flows);
      final fake = FakeState();
      final login = await runFlow(spec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
      final real = Session(accessToken: login['access_token'] as String, refreshToken: login['refresh_token'] as String,
          email: 'worker@example.com', expiresAtMs: session.expiresAtMs);
      await ensureFreshSession(real, wide, client: fake.client(), now: _now);
      expect(fake.refreshes, 1);
    });

    test('a session with no refresh token cannot be renewed automatically', () async {
      final stale = Session(accessToken: 'OLD', email: 'worker@example.com', expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
      final client = http_testing.MockClient((req) async => throw StateError('no network call expected: ${req.url}'));
      await expectLater(ensureFreshSession(stale, spec, client: client, now: _now), throwsA(isA<SessionExpired>()));
    });

    test('a refused refresh (expired/revoked refresh token) is reported as SessionExpired, not a bare FlowError', () async {
      final fake = FakeState()..refreshOk = false; // responds with HTTP 400 - a real invalid_grant shape
      final stale = Session(accessToken: 'OLD', refreshToken: 'stale-refresh', email: 'worker@example.com', expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
      try {
        await ensureFreshSession(stale, spec, client: fake.client(), now: _now);
        fail('expected SessionExpired');
      } on SessionExpired catch (e) {
        expect(e.message, contains('sign in again'));
      }
    });

    test('a renewal that never reaches the state system at all is SessionRenewalUnavailable, not SessionExpired', () async {
      final stale = Session(accessToken: 'OLD', refreshToken: 'stale-refresh', email: 'worker@example.com', expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
      final client = http_testing.MockClient((req) async => throw const SocketException('network unreachable'));
      try {
        await ensureFreshSession(stale, spec, client: client, now: _now);
        fail('expected SessionRenewalUnavailable');
      } on SessionRenewalUnavailable catch (e) {
        expect(e.message, contains('try again shortly'));
      }
    });

    test('a 5xx from the token endpoint during renewal is SessionRenewalUnavailable, not a hard refusal', () async {
      // Unlike refreshOk=false above (a real 400 invalid_grant), a 5xx is the state system's own server-side
      // problem, not the state explicitly rejecting this refresh token - ensureFreshSession must not treat the
      // two the same way.
      final stale = Session(accessToken: 'OLD', refreshToken: 'stale-refresh', email: 'worker@example.com', expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
      final client = http_testing.MockClient((req) async => http.Response('', 503));
      try {
        await ensureFreshSession(stale, spec, client: client, now: _now);
        fail('expected SessionRenewalUnavailable');
      } on SessionRenewalUnavailable catch (e) {
        expect(e.message, contains('try again shortly'));
      }
    });

    // Final review Minor 1: a redirect off the allowlist is the state's answer (stage response, the 3xx), not the
    // spec's mistake, so it neither signs the worker out nor sets a saved spec aside.
    test('SL-D16: renewal never reaches the state API, by its own url or by a redirect', () async {
      Future<int> renewWith(String url, http.Response Function(http.Request) answer) async {
        final renew = <Map<String, Object?>>[
          {
            'id': 'token',
            'type': 'request',
            'method': 'GET',
            'url': url,
            'extract': [
              {'var': 'access_token', 'source': 'body', 'json': 'access_token'},
            ],
          },
        ];
        final stale = Session(accessToken: 'OLD', refreshToken: 'R', email: 'worker@example.com',
            expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
        final sent = <Uri>[];
        final client = http_testing.MockClient((req) async {
          sent.add(req.url);
          return answer(req);
        });
        await expectLater(ensureFreshSession(stale, FlowSpec(spec.vars, {...spec.flows, 'renew': renew}),
            client: client, now: _now), throwsA(anything));
        expect(sent.where((u) => u.host == 'psilocybin.oregon.gov'), isEmpty);
        return sent.length;
      }

      // its own url there: refused before anything is sent
      expect(await renewWith('https://psilocybin.oregon.gov/api/me', (r) => http.Response('{"access_token":"X"}', 200)),
          0);
      // a redirect there: not followed, the 302 is the answer (so no token: the spec can't renew)
      expect(
          await renewWith('https://oregonpsilocybinprodb2c.b2clogin.com/token',
              (r) => http.Response('', 302, headers: {'location': 'https://psilocybin.oregon.gov/api/me'})),
          1);
    });

    test('a renew whose redirect hop is off the allowlist is SessionRenewalUnavailable, not SessionSpecUnusable',
        () async {
      final renew = <Map<String, Object?>>[
        {
          'id': 'token',
          'type': 'request',
          'method': 'GET',
          'url': 'https://oregonpsilocybinprodb2c.b2clogin.com/token',
          'extract': [
            {'var': 'access_token', 'source': 'body', 'json': 'access_token'},
          ],
        },
      ];
      final hopping = FlowSpec(spec.vars, {...spec.flows, 'renew': renew});
      final stale = Session(accessToken: 'OLD', refreshToken: 'R', email: 'worker@example.com',
          expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
      var calls = 0;
      final client = http_testing.MockClient((req) async {
        calls += 1;
        return http.Response('', 302, headers: {'location': 'https://evil.example.com/token'});
      });
      await expectLater(
          ensureFreshSession(stale, hopping, client: client, now: _now),
          throwsA(isA<SessionRenewalUnavailable>()
              .having((e) => e.message, 'message', contains('try again shortly'))));
      expect(calls, 1); // the hop itself was never sent
    });

    // Final review I1: whatever the spec does wrong, the caller gets one of the two Session exceptions.
    test('a spec whose refresh margin is unusable gives SessionSpecUnusable (a SessionExpired), not a FlowSpecError',
        () async {
      final bad = FlowSpec({...spec.vars, 'refresh_margin_seconds': '2m'}, spec.flows);
      final fresh = Session(accessToken: 'A', refreshToken: 'R', email: 'worker@example.com',
          expiresAtMs: fixedNow.millisecondsSinceEpoch + 3600 * 1000);
      final none = http_testing.MockClient((req) async => throw StateError('no network call expected: ${req.url}'));
      await expectLater(ensureFreshSession(fresh, bad, client: none, now: _now),
          throwsA(isA<SessionSpecUnusable>().having((e) => e.message, 'message', contains('sign in again'))));
    });

    test('a renew flow that throws something other than a FlowError gives SessionSpecUnusable', () async {
      final renew = <Map<String, Object?>>[
        {'id': 'token', 'type': 'request', 'method': ['POST'], 'url': 'https://oregonpsilocybinprodb2c.b2clogin.com/token'},
      ];
      final broken = FlowSpec(spec.vars, {...spec.flows, 'renew': renew});
      final stale = Session(accessToken: 'OLD', refreshToken: 'R', email: 'worker@example.com',
          expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
      var calls = 0;
      final client = http_testing.MockClient((req) async {
        calls += 1;
        return http.Response('{}', 200);
      });
      await expectLater(ensureFreshSession(stale, broken, client: client, now: _now), throwsA(isA<SessionSpecUnusable>()));
      expect(calls, 0);
    });

    // Fix round 2: a FlowError that involved no request (stage null) is the spec's own mistake, not the state's answer.
    test('a renew flow that uses a name nothing set gives SessionSpecUnusable and sends nothing', () async {
      final renew = <Map<String, Object?>>[
        {
          'id': 'maybe',
          'type': 'generate',
          'when': {'var': 'never'},
          'make': 'random_hex',
          'into': ['nonce'],
        },
        {
          'id': 'token',
          'type': 'request',
          'method': 'POST',
          'url': 'https://oregonpsilocybinprodb2c.b2clogin.com/token',
          'form': {'nonce': '{{nonce}}'},
        },
      ];
      final broken = FlowSpec(spec.vars, {...spec.flows, 'renew': renew}, format: 2);
      final stale = Session(accessToken: 'OLD', refreshToken: 'R', email: 'worker@example.com',
          expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
      var calls = 0;
      final client = http_testing.MockClient((req) async {
        calls += 1;
        return http.Response('{}', 200);
      });
      await expectLater(ensureFreshSession(stale, broken, client: client, now: _now), throwsA(isA<SessionSpecUnusable>()));
      expect(calls, 0);
    });

    test('a renew flow whose regex is outside the shared syntax gives SessionSpecUnusable', () async {
      final renew = <Map<String, Object?>>[
        {
          'id': 'token',
          'type': 'request',
          'method': 'POST',
          'url': 'https://oregonpsilocybinprodb2c.b2clogin.com/token',
          'extract': [
            {'var': 'access_token', 'source': 'body', 'regex': r'(?i)"access_token":"([^"]+)"'},
          ],
        },
      ];
      final broken = FlowSpec(spec.vars, {...spec.flows, 'renew': renew});
      final stale = Session(accessToken: 'OLD', refreshToken: 'R', email: 'worker@example.com',
          expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
      final client = http_testing.MockClient((req) async => http.Response('{"access_token":"NEW"}', 200));
      await expectLater(ensureFreshSession(stale, broken, client: client, now: _now), throwsA(isA<SessionSpecUnusable>()));
    });

    test('a renew flow that ends without an access token gives SessionSpecUnusable', () async {
      final renew = <Map<String, Object?>>[
        {
          'id': 'token',
          'type': 'request',
          'method': 'POST',
          'url': 'https://oregonpsilocybinprodb2c.b2clogin.com/token',
          'extract': [
            {'var': 'access_token', 'source': 'body', 'json': 'nothing_here'},
          ],
        },
      ];
      final noToken = FlowSpec(spec.vars, {...spec.flows, 'renew': renew});
      final stale = Session(accessToken: 'OLD', refreshToken: 'R', email: 'worker@example.com',
          expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);
      final client = http_testing.MockClient((req) async => http.Response('{"token_type": "Bearer"}', 200));
      await expectLater(ensureFreshSession(stale, noToken, client: client, now: _now), throwsA(isA<SessionSpecUnusable>()));
    });
  });

  group("renew runs under the phone's hosts (SL-R18)", () {
    tearDown(() => useLoginHosts(null));
    // The renew's token request sent to the state's "new address" (the fake answers by path, whatever the host).
    final moved = FlowSpec({...spec.vars, 'b2c': 'https://login.example.gov/oregonpsilocybinprodb2c.onmicrosoft.com'},
        spec.flows);
    Session stale() => Session(
        accessToken: 'A', refreshToken: 'REFRESH-1', email: 'worker@example.com', expiresAtMs: fixedNow.millisecondsSinceEpoch - 1);

    test('a renew at a host no list names is the spec failing, and sends nothing', () async {
      final fake = FakeState();
      await expectLater(
          ensureFreshSession(stale(), moved, client: fake.client(), now: _now), throwsA(isA<SessionSpecUnusable>()));
      expect(fake.log, isEmpty);
    });

    test('with a signed list naming the host in use, the renew goes there', () async {
      useLoginHosts(await signedHostList('2026-11-01.1', ['login.example.gov']));
      final fake = FakeState();
      final renewed = await ensureFreshSession(stale(), moved, client: fake.client(), now: _now);
      expect(fake.refreshes, 1);
      expect(renewed.accessToken, 'ACCESS-1');
    });

    test('hosts given by the caller are the ones used', () async {
      final fake = FakeState();
      final renewed = await ensureFreshSession(stale(), moved,
          client: fake.client(), now: _now, allowedHosts: [...defaultAllowedHosts, 'login.example.gov']);
      expect(renewed.accessToken, 'ACCESS-1');
    });
  });

  test('fromFlowResult refuses a result with no access token, or an empty one (final review C1)', () {
    expect(() => Session.fromFlowResult({'refresh_token': 'R', 'expires_in': 3600}, email: 'w@example.com', now: _now),
        throwsA(isA<FlowSpecError>()));
    expect(() => Session.fromFlowResult({'access_token': '', 'expires_in': 3600}, email: 'w@example.com', now: _now),
        throwsA(isA<FlowSpecError>()));
    expect(() => Session.fromFlowResult({'access_token': 7, 'expires_in': 3600}, email: 'w@example.com', now: _now),
        throwsA(isA<FlowSpecError>()));
  });
}
