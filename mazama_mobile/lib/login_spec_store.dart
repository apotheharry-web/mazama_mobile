// SL-R9: the sign-in spec the phone uses. The app ships one (assets/flows/login.yaml); when the state's sign-in page
// changes, the phone can fetch a newer one from Mazama's server (login_spec_client.dart) and keep it here, in a plain
// text file `login_spec.yaml` beside session.json. On every launch the newer valid one of the two is used, so an app
// update that ships a newer spec than the saved one wins at once, and a saved file that is corrupt, of a later format,
// or names a host the app won't talk to is ignored (the bundled one is used). The hosts are the app's own allowlist:
// the built-in two plus a saved signed host list's (login_hosts_store.dart, SL-R18), which MazamaApp puts in use first.
// The browser sign-in spec (SL-R19, browser_login_spec.dart) is kept the same way under its own name,
// `login_browser_spec.yaml` ([LoginSpecStore.browser]), held to the browser served mode.
// Same dart:io-direct, *Sync pattern as session_store.dart / device_id.dart (see cart_store.dart for why *Sync).
import 'dart:io';

import 'flow/flow_spec.dart';
import 'login_hosts_store.dart' show currentAllowedHosts;
import 'mazama_core.dart' show MazamaCore;
import 'session_store.dart' show defaultSessionDataDir;

/// The sign-in spec the app ships (SL-R9): the one used when no newer usable one is saved.
const bundledLoginSpecAsset = 'assets/flows/login.yaml';

/// The state's API: writes and readable records live there, so the password is never sent to it, and a sign-in never
/// requests it (sign_in_attempt.dart, session.dart pass it as `neverRequest`). The usable rule holds a spec to the same
/// (the core's `flows.usable_login_spec`, SL-D16).
const stateApiHost = 'psilocybin.oregon.gov';

/// Where a sign-in spec is served from, and so how it is run (SL-R19, the usable rule's served mode): [login] at
/// /p/flows/login, the password sign-in, run with no `browse` callback, so it has no open_browser; [browser] at
/// /p/flows/login_browser, the sign-in on the state's own page, so it has an open_browser in `login`.
enum ServedAs { login, browser }

/// The spec in [yaml] when the phone may use it as its sign-in spec, else null. The usable rule is the shared core's
/// (`flows.usable_login_spec`, specs/core row 13: SPEC.md "A usable sign-in spec"), the same function the server's
/// login_spec_source.py asks, both held to assets/shared/flows/contracts/login_spec_validity.json; the saved file and a
/// fetched reply are both held to it. The core does not read YAML: [FlowSpec.fromYaml] reads it here (size, YAML, no
/// anchors/aliases, no repeated key, format, plain vars) and the tree the interpreter will run - exactly that tree - is
/// what the core checks:
/// - every flow is a list of step mappings, `login` and `renew` among them and not empty;
/// - every request step has a text url, to an allowed https host (an open_browser's url and until too: [allowedHosts],
///   by default the phone's own, currentAllowedHosts, the built-in hosts plus a saved signed list's, SL-R18), with no `?`
///   (a query goes in `params`; an open_browser's until has a path), never the state's API, and its `spec_version` is
///   well formed;
/// - every step's fields have the right kinds; a spec using a format 2 or 3 feature declares it;
/// - `refresh_margin_seconds` and `timeout_seconds`, when set, are positive numbers, the timeout at most 120;
/// - `login` and `renew` each have an `extract` rule for `access_token` (a flow that ends without one is no session);
/// - every {{name}} a step uses is a var, an input of its flow or captured before it is needed;
/// - `{{password}}` is only ever the entire value of a form field of a POST to a host other than psilocybin.oregon.gov,
///   no when or json_var names password, email or refresh_token, no check's `vars` names password; every await_input
///   answer follows the same rule as the password; no var is named email, password or refresh_token;
/// - every params/headers/form value is text and no key of theirs has `{{`; no step sets a var or an input of its flow,
///   except renew's request extract of refresh_token;
/// - with [served] (SL-R19): [ServedAs.login] has no open_browser step in any flow, [ServedAs.browser] has one in
///   `login` (whatever its `when` says). Without it, neither is asked (the shared vectors' cases with no "served").
///
/// A tree JSON cannot carry exactly (a key that is not text, a number that is not finite) is not usable. [maxFormat] is
/// the reader's format: this app's, unless a test asks about an older reader. SignInPage passes [allowedHosts] for a
/// retry with a newly fetched host list.
FlowSpec? usableLoginSpec(String yaml,
    {int maxFormat = supportedFlowFormat, Iterable<String>? allowedHosts, ServedAs? served}) {
  try {
    final spec = FlowSpec.fromYaml(yaml, maxFormat: maxFormat);
    final answer = MazamaCore.instance.flowsUsableLoginSpec({
      'format': spec.format,
      'reader_format': maxFormat,
      'vars': spec.vars,
      'flows': spec.flows,
      'allowed_hosts': (allowedHosts ?? currentAllowedHosts()).toList(),
      'served': served?.name,
    });
    return answer['usable'] == true ? spec : null;
  } catch (_) {
    return null;
  }
}

/// The file the password sign-in spec is kept in ([LoginSpecStore]).
const loginSpecFileName = 'login_spec.yaml';

/// The file the browser sign-in spec is kept in ([LoginSpecStore.browser], SL-R19), apart from [loginSpecFileName].
const browserLoginSpecFileName = 'login_browser_spec.yaml';

class LoginSpecStore {
  /// Overridable for tests, so a test never reads or writes the real app-data directory - same pattern as
  /// SessionStore.dataDir / DeviceIdStore.dataDir. Defaults to the same directory those use.
  final Directory Function() dataDir;

  /// The file's name in [dataDir]: [loginSpecFileName], or [browserLoginSpecFileName] for [LoginSpecStore.browser].
  final String fileName;

  /// The served mode the saved spec is held to, reading and saving (SL-R19).
  final ServedAs served;

  /// The password sign-in spec's store: `login_spec.yaml`, no open_browser.
  const LoginSpecStore({Directory Function()? dataDir})
      : dataDir = dataDir ?? defaultSessionDataDir,
        fileName = loginSpecFileName,
        served = ServedAs.login;

  /// The browser sign-in spec's store (SL-R19): `login_browser_spec.yaml`, an open_browser in `login`.
  const LoginSpecStore.browser({Directory Function()? dataDir})
      : dataDir = dataDir ?? defaultSessionDataDir,
        fileName = browserLoginSpecFileName,
        served = ServedAs.browser;

  File get _file => File('${dataDir().path}/$fileName');
  File get _temp => File('${dataDir().path}/$fileName.tmp');
  File get _quarantined => File('${dataDir().path}/$fileName.bad');

  /// The saved spec, when there is one and it is usable ([usableLoginSpec], in this store's served mode); null
  /// otherwise. Never throws.
  FlowSpec? savedSpec() => _saved();

  FlowSpec? _saved() {
    try {
      if (!_file.existsSync() || _file.lengthSync() > maxFlowSpecBytes) return null;
      return usableLoginSpec(_file.readAsStringSync(), served: served);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null; // not UTF-8
    }
  }

  /// The spec to sign in with: the saved one when it is usable and its spec_version is newer than [bundledYaml]'s
  /// (compareSpecVersions), otherwise the bundled one (a tie goes to the bundled one, as on the server). If the
  /// bundled text itself can't be read, a usable saved spec is used; with neither, the bundled error is thrown.
  Future<FlowSpec> current(String bundledYaml) async => (await choose(bundledYaml)).spec;

  /// [current], and whether the spec chosen is the saved one (MazamaApp._resolveHome sets a saved spec aside when
  /// it fails in a way the checks didn't foresee: [quarantine]).
  Future<({FlowSpec spec, bool saved})> choose(String bundledYaml) async {
    final saved = _saved();
    final FlowSpec bundled;
    try {
      bundled = FlowSpec.fromYaml(bundledYaml);
    } catch (_) {
      if (saved != null) return (spec: saved, saved: true);
      rethrow;
    }
    if (saved != null && compareSpecVersions(saved.specVersion, bundled.specVersion) > 0) {
      return (spec: saved, saved: true);
    }
    return (spec: bundled, saved: false);
  }

  /// Sets the saved spec aside (renamed to login_spec.yaml.bad, replacing an earlier one, so it can still be looked
  /// at), so the next [choose] gives the bundled one; a later failed sign-in fetches a newer spec again. Never throws.
  void quarantine() {
    try {
      if (_file.existsSync()) _file.renameSync(_quarantined.path);
    } catch (_) {
      try {
        if (_file.existsSync()) _file.deleteSync();
      } catch (_) {
        // Nothing more to do: the next start tries the saved spec again and lands here again.
      }
    }
  }

  /// Replaces the saved spec with [yaml], atomically (written to a temporary file in the same directory, then renamed
  /// over the old one, so a crash mid-write leaves the old file or the new one, never half of either). Throws
  /// [FlowSpecError], saving nothing, when [yaml] is not a usable sign-in spec.
  Future<void> save(String yaml) async {
    if (usableLoginSpec(yaml, served: served) == null) throw FlowSpecError('not a usable sign-in spec; nothing saved');
    dataDir().createSync(recursive: true);
    _temp.writeAsStringSync(yaml, flush: true);
    _temp.renameSync(_file.path);
  }
}
