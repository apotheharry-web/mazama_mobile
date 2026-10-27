// SL-R5: the sign-in failure report. Mirrors sale_failure_client_test.dart's structure; the example request it is
// held to is ../mazama_modules/api/examples/signin_failure.request.json, vendored at assets/shared/api/examples/.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/app_api_key.dart';
import 'package:mazama_mobile/browser_login_spec.dart' show browserLoginSpecAsset;
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_spec_store.dart' show bundledLoginSpecAsset;
import 'package:mazama_mobile/signin_failure_client.dart';

Map<String, Object?> _example() =>
    jsonDecode(File('assets/shared/api/examples/signin_failure.request.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  test("posts exactly the example request's fields as JSON, with the app key, to /p/signin-failure", () async {
    final example = _example();
    final client = http_testing.MockClient((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/p/signin-failure');
      expect(req.headers['content-type'], 'application/json');
      for (final h in appApiKeyHeaders.entries) {
        expect(req.headers[h.key.toLowerCase()], h.value);
      }
      expect(jsonDecode(req.body), example);
      return http.Response('{"ok": true}', 201);
    });
    await postSigninFailure(
      deviceId: example['deviceId'] as String,
      step: example['step'] as String,
      stage: FlowStage.values.byName(example['stage'] as String),
      status: example['status'] as int,
      reason: example['reason'] as String,
      specVersion: example['specVersion'] as String,
      client: client,
    );
  });

  test('a transport failure sends nulls for what is not known, and never any other field', () async {
    late Map<String, Object?> body;
    final client = http_testing.MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, Object?>;
      return http.Response('{"ok": true}', 201);
    });
    await postSigninFailure(deviceId: 'DEVICE-1', step: 'authorize', stage: FlowStage.connect, client: client);
    expect(body, {
      'deviceId': 'DEVICE-1',
      'step': 'authorize',
      'stage': 'connect',
      'reason': null,
      'specVersion': null,
      'status': null,
    });
    expect(body.keys.toSet(), _example().keys.toSet());
  });

  // Audit A: a fetched or saved sign-in spec chooses its own step ids and reason words, and which step fails; so a
  // report carries only words the app itself ships: a step id of a bundled sign-in spec (else "other") and one of the
  // fixed reasons (else null).
  group('only fixed words reach the server', () {
    Future<Map<String, Object?>> sent(FlowError error, Set<String> bundledSteps) async {
      late Map<String, Object?> body;
      final client = http_testing.MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, Object?>;
        return http.Response('{"ok": true}', 201);
      });
      await postSigninFailureFor(error,
          deviceId: 'DEVICE-1', specVersion: '2026-10-24.3', bundledSteps: bundledSteps, client: client);
      return body;
    }

    test('a bundled step id and a fixed reason are sent as they are', () async {
      final body = await sent(
          FlowError('m', step: 'self_asserted', reason: 'structure', stage: FlowStage.response, status: 200),
          {'self_asserted', 'token'});
      expect(body, {
        'deviceId': 'DEVICE-1',
        'step': 'self_asserted',
        'stage': 'response',
        'reason': 'structure',
        'specVersion': '2026-10-24.3',
        'status': 200,
      });
    });

    test('a step id the bundled specs do not have is sent as other', () async {
      final body = await sent(FlowError('m', step: 'pw_starts_with_a', reason: 'structure'), {'self_asserted'});
      expect(body['step'], 'other');
    });

    test('a reason that is not one of the fixed words is sent as null', () async {
      final body = await sent(FlowError('m', step: 'token', reason: 'a1b2c3'), {'token'});
      expect((body['step'], body['reason']), ('token', null));
    });

    test('no step stays no step', () async {
      final body = await sent(FlowError('m', stage: FlowStage.connect), {'token'});
      expect((body['step'], body['reason'], body['stage']), (null, null, 'connect'));
    });

    test('the fixed reasons are exactly these', () {
      expect(reportedSigninReasons, {'structure', 'unavailable', 'refused', 'needs_person', 'not_allowed'});
      for (final r in reportedSigninReasons) {
        expect(reportedSigninReason(r), r);
      }
      for (final r in [null, 'credentials', 'cancelled', 'Structure', '']) {
        expect(reportedSigninReason(r), isNull, reason: '$r');
      }
    });

    test('reportedSigninStep keeps a bundled id and names anything else other', () {
      expect(reportedSigninStep('token', {'token'}), 'token');
      expect(reportedSigninStep('Token', {'token'}), 'other');
      expect(reportedSigninStep('anything', const {}), 'other');
      expect(reportedSigninStep(null, {'token'}), isNull);
    });

    test("the bundled step ids are those of the app's own login.yaml and login_browser.yaml", () async {
      final asked = <String>[];
      final ids = await bundledSigninStepIds(load: (asset) async {
        asked.add(asset);
        return File(asset).readAsString();
      });
      expect(asked, [bundledLoginSpecAsset, browserLoginSpecAsset]);
      final expected = <String>{};
      for (final asset in asked) {
        for (final steps in FlowSpec.fromYaml(File(asset).readAsStringSync()).flows.values) {
          expected.addAll(steps.map((s) => s['id']).whereType<String>());
        }
      }
      expect(ids, expected);
      expect(ids, containsAll(<String>['self_asserted', 'require_page_fields', 'browser', 'token']));
    });

    test('a bundled spec that cannot be read gives no ids, so every step is other', () async {
      final ids = await bundledSigninStepIds(load: (asset) async => throw const FileSystemException('missing'));
      expect(ids, isEmpty);
    });
  });

  test('a plain 200 is also treated as success', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 200));
    await postSigninFailure(deviceId: 'DEVICE-1', client: client);
  });

  test('a non-2xx response is reported as a SigninFailureError naming the status code', () async {
    final client = http_testing.MockClient((req) async => http.Response('', 500));
    await expectLater(
      postSigninFailure(deviceId: 'DEVICE-1', reason: 'structure', client: client),
      throwsA(isA<SigninFailureError>().having((e) => e.message, 'message', contains('500'))),
    );
  });

  test('a network failure is reported clearly, not as an opaque exception', () async {
    final client = http_testing.MockClient((req) async => throw Exception('boom'));
    await expectLater(
      postSigninFailure(deviceId: 'DEVICE-1', client: client),
      throwsA(isA<SigninFailureError>()),
    );
  });
}
