// SL-R5: reports a sign-in to the state system that failed for any reason other than the worker's own wrong
// email or password, so the owner learns when the state's sign-in page has changed (the server turns repeated
// "structure" reports into a problem on its Status page). The report carries only what the phone knew about the
// failure - the device, the login spec's step, how far the request got, the check's reason word, the login spec
// version and the HTTP status - never an email, password, token or message: the server refuses any other field.
// SignInPage sends it fire-and-forget; nothing here may delay or change what the worker sees.
//
// Only fixed words (postSigninFailureFor): a sign-in spec fetched from Mazama's server, or saved from one, chooses its
// own step ids and reason words, and which step fails; so the step is sent only when it is a step id of one of the
// app's bundled sign-in specs (else "other") and the reason only when it is one of reportedSigninReasons (else null).
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'browser_login_spec.dart' show browserLoginSpecAsset;
import 'flow/flow_runner.dart';
import 'flow/flow_spec.dart';
import 'login_spec_store.dart' show bundledLoginSpecAsset;
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

/// The reason words a sign-in failure report may carry; any other reason is sent as null.
const reportedSigninReasons = {'structure', 'unavailable', 'refused', 'needs_person', 'not_allowed'};

/// [reason] when it is one of [reportedSigninReasons], else null.
String? reportedSigninReason(String? reason) => reportedSigninReasons.contains(reason) ? reason : null;

/// [step] when it is one of [bundledSteps] (bundledSigninStepIds), "other" for any other step, null for none.
String? reportedSigninStep(String? step, Set<String> bundledSteps) =>
    step == null ? null : (bundledSteps.contains(step) ? step : 'other');

/// The step ids of the app's own bundled sign-in specs ([bundledLoginSpecAsset] and [browserLoginSpecAsset]), read
/// with [load] (the app's asset bundle when null; tests read the files). A bundled spec that can't be read adds no
/// ids, so its steps are reported as "other". Never throws.
Future<Set<String>> bundledSigninStepIds({Future<String> Function(String asset)? load}) async {
  final read = load ?? rootBundle.loadString;
  final ids = <String>{};
  for (final asset in const [bundledLoginSpecAsset, browserLoginSpecAsset]) {
    try {
      final spec = FlowSpec.fromYaml(await read(asset));
      for (final steps in spec.flows.values) {
        for (final step in steps) {
          final Object? id = step['id'];
          if (id is String) ids.add(id);
        }
      }
    } catch (_) {
      // an unreadable bundled spec gives no ids: its steps are reported as "other"
    }
  }
  return ids;
}

/// Reports [error] through [postSigninFailure] with only fixed words: its step through [reportedSigninStep] against
/// [bundledSteps], its reason through [reportedSigninReason]; its stage and HTTP status as they are.
Future<void> postSigninFailureFor(
  FlowError error, {
  required String deviceId,
  required Set<String> bundledSteps,
  String? specVersion,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) =>
    postSigninFailure(
      deviceId: deviceId,
      step: reportedSigninStep(error.step, bundledSteps),
      stage: error.stage,
      status: error.status,
      reason: reportedSigninReason(error.reason),
      specVersion: specVersion,
      baseUrl: baseUrl,
      client: client,
    );

class SigninFailureError implements Exception {
  final String message;
  SigninFailureError(this.message);
  @override
  String toString() => message;
}

/// POSTs [apiBaseUrl]/p/signin-failure with [deviceId] and what the failed sign-in's FlowError said ([step],
/// [stage], [status], [reason]) plus the login spec's [specVersion]. Throws SigninFailureError on anything but a
/// clean 2xx.
Future<void> postSigninFailure({
  required String deviceId,
  String? step,
  FlowStage? stage,
  int? status,
  String? reason,
  String? specVersion,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) async {
  final c = client ?? serverClient();   // through the server link, like every /p/ client (sales README R56)
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${signinFailurePath()}');
    http.Response resp;
    try {
      resp = await c.post(
        uri,
        headers: {...appApiKeyHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': deviceId,
          'step': step,
          'stage': stage?.name,
          'reason': reason,
          'specVersion': specVersion,
          'status': status,
        }),
      );
    } catch (ex) {
      throw SigninFailureError('cannot reach ${uri.host}: ${ex.runtimeType}');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SigninFailureError(describeServerError(resp.statusCode, resp.body));
    }
  } finally {
    if (shouldClose) c.close();
  }
}
