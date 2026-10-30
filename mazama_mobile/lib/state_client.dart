// Shared generic client both licenses_client.dart and state_packages_client.dart now run through for every
// authenticated JSON GET against the state system - the Dart half of "mazama_app and mazama_sales share the
// same codebase for their interactions with the state." Runs the one shared `get_json` flow from
// ../../mazama_modules/flows/state_reads.yaml (vendored at assets/flows/state_reads.yaml by
// tool/sync_flows.sh - see ../../mazama_modules/README.md and ../../mazama_modules/SPEC.md), the same spec
// mazama_sales' state/client.py now runs
// via StateSession.get(). Mirrors that method closely: inspects the plain `status` the flow captures (added to
// the DSL specifically for this - see state_reads.yaml's own file comment and SPEC.md's "what stays out of the
// spec") rather than letting the flow raise on 401, and distinguishes "the state system said no" from "the
// body wasn't JSON" by checking for `result`'s *presence* in the returned context, never its truthiness - an
// empty, successful response (a service center with no current inventory, say) is `[]`, falsy but perfectly
// valid.
//
// One deliberate difference from StateSession.get(): this does NOT retry a 401 itself. The app's session
// renewal is proactive (SelectCenterPage/CartPage renew the access token on a timer before it expires, not
// reactively on a failed call), so by the time a call here sees a 401 the caller's own renewal has already
// failed elsewhere and there's nothing a retry here would fix. This just reports it plainly, the exact "sign
// in again" message licenses_client.dart/state_packages_client.dart already threw before this refactor, so
// neither caller's own error handling needed to change.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'flow/flow_runner.dart';
import 'flow/flow_spec.dart';
import 'login_hosts_store.dart' show currentAllowedHosts;

class StateReadError implements Exception {
  final String message;

  /// The state system couldn't be reached: no connection, or no answer in time (the flow failed connecting or sending).
  final bool unreachable;
  StateReadError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}

Future<FlowSpec>? _specFuture;

/// Loads+parses assets/flows/state_reads.yaml once and caches the parsed [FlowSpec] for the process's
/// lifetime - one level above rootBundle's own Future-by-asset-key cache (see widget_test.dart's comment on
/// it), so FlowSpec.fromYaml's own parsing isn't repeated on every call either. A test that needs a specific
/// spec (a fake one, or a freshly-edited real one) passes it directly via fetchStateJson's own [spec]
/// parameter instead of relying on this cache.
Future<FlowSpec> stateReadsSpec() {
  return _specFuture ??= rootBundle.loadString('assets/flows/state_reads.yaml').then(FlowSpec.fromYaml);
}

/// Forgets the cached spec, for a test that loaded it inside a widget test: the Future belongs to that test's fake
/// async zone, and a later test awaiting it (in CI's bundle, one in another file) would wait forever. Such a file
/// calls this, and `rootBundle.clear()`, in its tearDown.
@visibleForTesting
void resetStateReadsSpec() => _specFuture = null;

/// Runs the shared `get_json` flow for one authenticated state-system JSON GET at [path] (e.g.
/// `'GetSalesRecords/225'`) and returns the parsed body - the Dart twin of StateSession.get() in
/// mazama_sales/src/mazama_sales/state/client.py. Endpoints with a named flow of their own
/// (`packaged_products`, `packaged_product_info`, `applicable_licenses`) go through [fetchStateFlow] instead.
Future<Object?> fetchStateJson(String path, {required String accessToken, http.Client? client, FlowSpec? spec}) =>
    fetchStateFlow('get_json', {'path': path}, accessToken: accessToken, client: client, spec: spec);

/// Runs one read flow from state_reads.yaml ([flow] with its own [inputs]; SM-20) and returns the parsed body - the
/// Dart twin of StateSession._read in mazama_sales/src/mazama_sales/state/client.py. [client] defaults to a
/// plain `http.Client()`, closed when this call created it; pass one in (a `MockClient`, say) to reuse or
/// fake it. [spec] overrides the cached assets/flows/state_reads.yaml parse, mainly for tests.
///
/// Throws [StateReadError] on: a 401 ("the state system no longer accepts this session - sign in again"); any
/// other non-200 status, surfaced by the flow's own `require` as a [FlowError] and rethrown here with the same
/// message (`"GET {path} failed: HTTP {status}"`, scrubbed of secrets - the same wording mazama_sales' own
/// StateSession raises, from the same shared spec); or a 200 whose body wasn't valid JSON.
///
/// Requests go only to [allowedHosts]: by default the phone's own allowlist (login_hosts_store.dart's
/// currentAllowedHosts: the built-in hosts plus a saved signed list's, SL-R18).
Future<Object?> fetchStateFlow(String flow, Map<String, Object?> inputs,
    {required String accessToken, http.Client? client, FlowSpec? spec, Iterable<String>? allowedHosts}) async {
  final c = client ?? http.Client();
  final shouldClose = client == null;
  try {
    final s = spec ?? await stateReadsSpec();
    Map<String, Object?> ctx;
    try {
      ctx = await runFlow(s, flow, {...inputs, 'access_token': accessToken},
          client: c, allowedHosts: allowedHosts ?? currentAllowedHosts());
    } on FlowError catch (ex) {
      throw StateReadError(ex.message, unreachable: ex.stage == FlowStage.connect || ex.stage == FlowStage.send);
    }
    if (ctx['status'] == 401) {
      throw StateReadError('the state system no longer accepts this session - sign in again');
    }
    if (!ctx.containsKey('result')) {
      throw StateReadError('the state system did not answer with JSON');
    }
    return ctx['result'];
  } finally {
    if (shouldClose) c.close();
  }
}
