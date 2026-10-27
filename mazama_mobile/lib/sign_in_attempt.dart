// One sign-in attempt with a sign-in spec, and the session it gives: SignInPage's (main.dart) password sign-in and its
// sign-in on the state's own page both run through [attemptSignIn], and so does the debug "Sign-in files" page's "Try"
// (debug_signin_files_page.dart), so a tried copy runs exactly as a real sign-in would. Saves nothing and reports
// nothing: what happens with the session or the failure is the caller's.
import 'package:http/http.dart' as http;

import 'flow/flow_runner.dart';
import 'flow/flow_spec.dart';
import 'login_spec_store.dart' show stateApiHost;
import 'session.dart';

/// A sign-in that failed because of the spec, not the state system: running it threw something other than a
/// [FlowError], or it finished without an access token (final review C1, I1). Reason `structure`, so the worker sees
/// main.dart's stateSigninChangedMessage and Mazama is told, as for any other changed sign-in.
class SignInSpecFailure extends FlowError {
  SignInSpecFailure(super.message, {super.step}) : super(reason: 'structure');
}

/// One sign-in attempt with [spec]'s `login` flow given [inputs], and the session it gives ([email] is the worker's,
/// carried by the session). A [FlowError] from the flow comes through as it is; anything else thrown while running it
/// (a mistake in the spec the checks didn't foresee) or a result with no access token comes back as a
/// [SignInSpecFailure] (reason `structure`), so a failure is always a FlowError (final review C1, I1). [ask] answers an
/// `await_input`, [browse] shows the state's page for an `open_browser` (SL-R13, SL-R16). Every request (and the
/// state's page) is held to [allowedHosts] (SL-R8, SL-R18).
Future<Session> attemptSignIn(FlowSpec spec, Map<String, Object?> inputs, String email, http.Client client,
    {required Iterable<String> allowedHosts,
    Future<String?> Function(String prompt, bool secret)? ask,
    Future<String?> Function(String url, String until)? browse}) async {
  final Map<String, Object?> result;
  try {
    // SL-D16: a sign-in never sends anything to the state's API, whatever spec runs (a redirect there isn't followed)
    result = await runFlow(spec, 'login', inputs,
        client: client, ask: ask, browse: browse, allowedHosts: allowedHosts, neverRequest: const {stateApiHost});
  } on FlowError {
    rethrow;
  } catch (e) {
    throw SignInSpecFailure('the sign-in spec could not be run (${e.runtimeType})');
  }
  try {
    return Session.fromFlowResult(result, email: email);
  } catch (_) {
    throw SignInSpecFailure('the sign-in finished without an access token', step: lastLoginStepId(spec));
  }
}

/// The `id` of [spec]'s last `login` step, when it has one.
String? lastLoginStepId(FlowSpec spec) {
  try {
    final Object? id = spec.flows['login']!.last['id'];
    return id is String ? id : null;
  } catch (_) {
    return null;
  }
}
