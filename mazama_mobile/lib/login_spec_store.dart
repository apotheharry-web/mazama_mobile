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

import 'flow/flow_runner.dart'
    show
        checkAwaitInput,
        checkOpenBrowser,
        checkWhen,
        flowStepTypes,
        flowUrlSources,
        regexGroupCount,
        regexPatterns,
        varsEqualNames;
import 'flow/flow_spec.dart';
import 'login_hosts_store.dart' show currentAllowedHosts;
import 'session_store.dart' show defaultSessionDataDir;

/// The sign-in spec the app ships (SL-R9): the one used when no newer usable one is saved.
const bundledLoginSpecAsset = 'assets/flows/login.yaml';

/// What each sign-in flow is given at run time: SignInPage passes email and password to `login`, ensureFreshSession
/// passes refresh_token to `renew` (login_spec_source.py's FLOW_INPUTS is the twin).
const loginFlowInputs = <String, List<String>>{
  'login': ['email', 'password'],
  'renew': ['refresh_token'],
};

/// The longest per-request `timeout_seconds` a sign-in spec may set (login_spec_source.py's MAX_TIMEOUT_SECONDS).
const maxLoginSpecTimeoutSeconds = 120.0;

final _secondsRe = RegExp(r'^[0-9]+(\.[0-9]+)?$');
final _nameRe = RegExp(r'\{\{(\w+)\}\}');
const _requestFields = ['url', 'params', 'headers', 'form'];

/// A name a step sets (generate `into`, extract/capture_on_fail `var`, await_input `into`; and vars_equal's two names):
/// the {{name}} word syntax, in ASCII so Dart and Python read it alike (login_spec_source.py's _TARGET_RE is the twin).
final _nameTargetRe = RegExp(r'^[A-Za-z0-9_]+$');

bool _isTarget(Object? name) => name is String && _nameTargetRe.hasMatch(name);

/// Where a sign-in spec is served from, and so how it is run (SL-R19, the usable rule's served mode;
/// login_spec_source.py's SERVED_MODES): [login] at /p/flows/login, the password sign-in, run with no `browse`
/// callback, so it has no open_browser; [browser] at /p/flows/login_browser, the sign-in on the state's own page, so it
/// has an open_browser in `login`.
enum ServedAs { login, browser }

/// The spec in [yaml] when the phone may use it as its sign-in spec, else null. The twin of the server's
/// login_spec_source.py `_valid_version`, both held to assets/shared/flows/contracts/login_spec_validity.json; the
/// saved file and a fetched reply are both held to it:
/// - [FlowSpec.fromYaml] reads it (size, YAML, no anchors/aliases, no repeated key, format, plain vars);
/// - every flow is a list of step mappings, `login` and `renew` among them and not empty;
/// - every request step has a text url, to an allowed https host (an open_browser's url and until too: [allowedHosts],
///   by default the phone's own, currentAllowedHosts, the built-in hosts plus a saved signed list's, SL-R18), with no `?`
///   (a query goes in `params`; an open_browser's until has a path: [specUrlsShaped]), and its `spec_version` is well
///   formed;
/// - every step's fields have the right kinds ([_stepsOk]); a spec using a format 2 or 3 feature declares it;
/// - `refresh_margin_seconds` and `timeout_seconds`, when set, are positive numbers, the timeout at most 120;
/// - `login` and `renew` each have an `extract` rule for `access_token` (a flow that ends without one is no session);
/// - every {{name}} a step uses is a var, an input of its flow ([loginFlowInputs]) or captured before it is needed;
/// - `{{password}}` is only ever the entire value of a form field of a POST to a host other than psilocybin.oregon.gov,
///   no when or json_var names password, email or refresh_token, no check's `vars` names password; every await_input
///   answer follows the same rule as the password; no var is named email, password or refresh_token ([_secretsPlaced]);
/// - every params/headers/form value is text and no key of theirs has `{{` ([_plainMapsOk]); no step sets a var or an
///   input of its flow, except renew's request extract of refresh_token ([_setNamesOk]);
/// - no request goes to the state's API host ([_noStateApiRequests], SL-D16);
/// - with [served] (SL-R19): [ServedAs.login] has no open_browser step in any flow, [ServedAs.browser] has one in
///   `login` (whatever its `when` says). Without it, neither is asked (the shared vectors' cases with no "served").
///
/// [maxFormat] is the reader's format: this app's, unless a test asks about an older reader. SignInPage passes
/// [allowedHosts] for a retry with a newly fetched host list.
FlowSpec? usableLoginSpec(String yaml,
    {int maxFormat = supportedFlowFormat, Iterable<String>? allowedHosts, ServedAs? served}) {
  try {
    final spec = FlowSpec.fromYaml(yaml, maxFormat: maxFormat);
    // Read as Object?: FlowSpec.flows holds lazily cast views, so a step that isn't a mapping throws here (caught).
    for (final Object? steps in spec.flows.values) {
      if (steps is! List || !steps.every((Object? s) => s is Map)) return null;
    }
    for (final name in loginFlowInputs.keys) {
      final Object? steps = spec.flows[name];
      if (steps is! List || steps.isEmpty) return null;
    }
    if (!_requestsHaveUrls(spec.flows)) return null;
    if (!_stepsOk(spec.flows, spec.format)) return null;
    if (!isSpecVersion(spec.specVersion)) return null;
    if (!specHostsAllowed(spec, allowed: allowedHosts ?? currentAllowedHosts())) return null;
    if (!specUrlsShaped(spec)) return null;
    if (!_noStateApiRequests(spec.flows, spec.vars)) return null;
    if (!_plainMapsOk(spec.flows)) return null;
    if (!_secretsPlaced(spec.flows, spec.vars)) return null;
    if (!_setNamesOk(spec.flows, spec.vars)) return null;
    if (!_secondsOk(spec.vars['refresh_margin_seconds'], null)) return null;
    if (!_secondsOk(spec.vars['timeout_seconds'], maxLoginSpecTimeoutSeconds)) return null;
    for (final MapEntry(key: name, value: inputs) in loginFlowInputs.entries) {
      if (!_namesSetAndTokenExtracted(spec.flows[name]!, {...spec.vars.keys, ...inputs})) return null;
    }
    if (served != null && !_servedOk(spec.flows, served)) return null;
    return spec;
  } catch (_) {
    return null;
  }
}

/// The inputs a sign-in is given that no `when` or `json_var` may name (login_spec_source.py's SECRET_INPUTS).
const loginSecretInputs = ['email', 'password', 'refresh_token'];

/// The state's API: writes and readable records live there, so the password is never sent to it
/// (login_spec_source.py's STATE_API_HOST).
const stateApiHost = 'psilocybin.oregon.gov';

/// The host of [url] as the password rule compares it: the text between `://` and the first `/`, `?` or `#`, minus a
/// `:port`, minus one trailing dot, in lower case ('' with no `://`). Only asked of a url [specHostsAllowed] has
/// already accepted (login_spec_source.py's url_host is the twin).
String urlHostForSecrets(String url) {
  final at = url.indexOf('://');
  if (at < 0) return '';
  final rest = url.substring(at + 3);
  final end = rest.indexOf(RegExp(r'[/?#]'));
  final authority = end < 0 ? rest : rest.substring(0, end);
  final colon = authority.indexOf(':');
  var host = colon < 0 ? authority : authority.substring(0, colon);
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  return host.toLowerCase();
}

/// The names the worker types: `password`, and every await_input's `into` (an answer such as an MFA code), in any
/// flow. Each follows the password rule ([_secretsPlaced]; login_spec_source.py's typed_names).
Set<String> typedNames(Map<String, List<Map<String, Object?>>> flows) {
  final names = {'password'};
  for (final steps in flows.values) {
    for (final step in steps) {
      final Object? into = step['into'];
      if (step['type'] == 'await_input' && into is String) names.add(into);
    }
  }
  return names;
}

/// The `form` fields of [step] allowed to be exactly [template] (`{{password}}`, `{{<an answer>}}`): every such field,
/// when [step] is a `request` whose `method` is exactly `POST` and whose url host, filled in with the spec's [vars], is
/// not [stateApiHost]; else none (login_spec_source.py's _typed_form_fields).
Set<Object?> _typedFormFields(Map<String, Object?> step, Map<String, String> vars, String template) {
  final Object? form = step['form'];
  if (step['type'] != 'request' || step['method'] != 'POST' || form is! Map) return <Object?>{};
  final url = (step['url'] ?? '').toString().replaceAllMapped(_nameRe, (m) => vars[m.group(1)] ?? m.group(0)!);
  if (urlHostForSecrets(url) == stateApiHost) return <Object?>{};
  return {
    for (final MapEntry(:key, :value) in form.entries)
      if (value == template) key,
  };
}

/// SL-D16: no `request` or `open_browser` step, at any depth, has a url whose host, filled in with the spec's [vars], is [stateApiHost].
/// A sign-in spec talks only to the sign-in host(s); the state's API, where writes and records are, is the sale and read
/// specs' alone, and those are never fetched. So a fetched or saved sign-in spec, which renews the session with nobody
/// watching, can't use the worker's tokens there (login_spec_source.py's _check_no_state_api).
bool _noStateApiRequests(Object? node, Map<String, String> vars) {
  if (node is Map) {
    if (node['type'] == 'request' || node['type'] == 'open_browser') { // an open_browser's until is matched, not loaded
      final url = (node['url'] ?? '').toString().replaceAllMapped(_nameRe, (m) => vars[m.group(1)] ?? m.group(0)!);
      if (urlHostForSecrets(url) == stateApiHost) return false;
    }
    return node.values.every((Object? v) => _noStateApiRequests(v, vars));
  }
  if (node is List) return node.every((Object? v) => _noStateApiRequests(v, vars));
  return true;
}

/// [text] in any text under [node], keys and values, at any depth (login_spec_source.py's _has_text).
bool _hasText(Object? node, String text) {
  if (node is String) return node.contains(text);
  if (node is Map) return node.entries.any((e) => _hasText('${e.key}', text) || _hasText(e.value, text));
  if (node is List) return node.any((v) => _hasText(v, text));
  return false;
}

/// What the worker types goes only where it is meant to (SPEC.md "A usable sign-in spec"). For the password and every
/// await_input answer ([typedNames]): its `{{name}}` appears only as the entire value of a `form` field of a `request`
/// with `method: POST` to a host other than psilocybin.oregon.gov ([_typedFormFields]), the scan covering every key and
/// value of `vars`, the flow names and every step (with [_plainMapsOk], no other place is left); no require/
/// then_require check's `vars` and no `when` or `json_var` names it. No `when` or `json_var` names email or
/// refresh_token either. So which step runs can't depend on any of them, and whether a step fails can't depend on what
/// the worker typed (a check may still compare the email or refresh token: it only compares; a `when` can match a
/// regex). No var is named email, password or refresh_token: the flow's input would override it at run time.
/// login_spec_source.py's _check_secrets is the twin.
bool _secretsPlaced(Map<String, List<Map<String, Object?>>> flows, Map<String, String> vars) {
  if (vars.keys.any(loginSecretInputs.contains)) return false;
  final typed = typedNames(flows);
  for (final name in typed) {
    final template = '{{$name}}';
    if (_hasText(vars, template) || flows.keys.any((f) => _hasText(f, template))) return false;
    for (final steps in flows.values) {
      for (final step in steps) {
        final allowed = _typedFormFields(step, vars, template);
        for (final MapEntry(:key, :value) in step.entries) {
          if (_hasText(key, template)) return false;
          if (key == 'form' && value is Map) {
            for (final MapEntry(key: field, value: text) in value.entries) {
              if (!allowed.contains(field) && _hasText(text, template)) return false;
            }
          } else if (_hasText(value, template)) {
            return false;
          }
        }
      }
    }
  }
  final untestable = {...typed, ...loginSecretInputs};
  for (final steps in flows.values) {
    for (final step in steps) {
      final Object? when = step['when'];
      if (when is Map && untestable.contains(when['var'])) return false;
      if (untestable.contains(step['json_var'])) return false;
      for (final checksKey in const ['require', 'then_require']) {
        final Object? checks = step[checksKey];
        if (checks is! List) continue;
        for (final Object? chk in checks) {
          final Object? names = chk is Map ? chk['vars'] : null;
          if (names is List && names.any(typed.contains)) return false;
        }
      }
    }
  }
  return true;
}

const _plainMaps = ['params', 'headers', 'form'];

/// Every `params`, `headers` and `form` a step has is a mapping whose every value is text (a YAML string) and none of
/// whose keys contains `{{`: the interpreters stringify any other value and fill templates inside it, and never fill
/// keys (login_spec_source.py's _check_plain_maps is the twin).
bool _plainMapsOk(Map<String, List<Map<String, Object?>>> flows) {
  for (final steps in flows.values) {
    for (final step in steps) {
      for (final field in _plainMaps) {
        if (!step.containsKey(field)) continue;
        final Object? value = step[field];
        if (value is! Map) return false;
        for (final MapEntry(key: k, value: v) in value.entries) {
          if (v is! String || '$k'.contains('{{')) return false;
        }
      }
    }
  }
  return true;
}

/// (how, name) for every name [step] sets: "extract" / "capture_on_fail" rule vars, a generate's `into` items, an
/// await_input's `into` (login_spec_source.py's _set_names).
List<(String, Object?)> _setNames(Map<String, Object?> step) {
  final out = <(String, Object?)>[];
  for (final how in const ['extract', 'capture_on_fail']) {
    final Object? rules = step[how];
    if (rules is! List) continue;
    for (final Object? rule in rules) {
      if (rule is Map) out.add((how, rule['var']));
    }
  }
  final Object? into = step['into'];
  if (step['type'] == 'generate' && into is List) out.addAll(into.map((n) => ('generate', n)));
  if (step['type'] == 'await_input') out.add(('await_input', into));
  return out;
}

/// No step sets a name that is a var of the spec (the host check fills urls with the vars, so a capture into one could
/// move a host at run time) or an input of its flow ([loginFlowInputs]: login's email and password, renew's
/// refresh_token), except that a `renew` request's `extract` may set `refresh_token`: the state's rotated token
/// (login_spec_source.py's _check_set_names is the twin).
bool _setNamesOk(Map<String, List<Map<String, Object?>>> flows, Map<String, String> vars) {
  for (final MapEntry(key: flow, value: steps) in flows.entries) {
    final taken = {...vars.keys, ...?loginFlowInputs[flow]};
    for (final step in steps) {
      for (final (how, name) in _setNames(step)) {
        if (!taken.contains(name)) continue;
        if (flow == 'renew' && how == 'extract' && name == 'refresh_token' && step['type'] == 'request') continue;
        return false;
      }
    }
  }
  return true;
}

/// SL-R19's served mode ([usableLoginSpec]; login_spec_source.py's _check_served).
bool _servedOk(Map<String, List<Map<String, Object?>>> flows, ServedAs served) {
  bool opensBrowser(Map<String, Object?> step) => step['type'] == 'open_browser';
  return switch (served) {
    ServedAs.login => !flows.values.any((steps) => steps.any(opensBrowser)),
    ServedAs.browser => flows['login']!.any(opensBrowser),
  };
}

/// Every request step, at any depth, has a text url (login_spec_source.py's _check_urls).
bool _requestsHaveUrls(Object? node) {
  if (node is Map) {
    if (node['type'] == 'request' && node['url'] is! String) return false;
    return node.values.every(_requestsHaveUrls);
  }
  if (node is List) return node.every(_requestsHaveUrls);
  return true;
}

/// Every step of every flow: an `id`, when present, text; a known `type`; `method`, when present, text;
/// `follow_redirects`, when present, true/false; a well-formed `when`; a well-formed `await_input` or `open_browser`,
/// only in `login` (any other flow, `renew` among them, may run with nobody there to answer); `url_fragment`/
/// `url_query` extracts only in an `open_browser`; every `vars_equal` check's `vars` two names; every name a step sets
/// (generate `into` items, extract/capture_on_fail `var`, await_input `into`) in the {{name}} word syntax; every
/// extract/capture_on_fail `regex` text or a non-empty list of text, each compiling in the shared syntax
/// ([regexPatterns]) and with a group to take ([regexGroupCount]). A regex list, a `when` or an `await_input`
/// (SL-R11-R13) needs `format: 2` or later declared, an `open_browser` or a `vars_equal` (SL-R16) `format: 3`, so the
/// server never serves it to an older app. False, or a throw (caught by [usableLoginSpec]), when not
/// (login_spec_source.py's _check_steps).
bool _stepsOk(Map<String, List<Map<String, Object?>>> flows, int declared) {
  var needs = 1;
  for (final MapEntry(key: name, value: steps) in flows.entries) {
    for (final step in steps) {
      final Object? id = step['id'];
      if (step.containsKey('id') && id is! String) return false;
      final sid = id is String ? id : null;
      final Object? kind = step['type'];
      if (!flowStepTypes.contains(kind)) return false;
      if (step.containsKey('method') && step['method'] is! String) return false;
      if (step.containsKey('follow_redirects') && step['follow_redirects'] is! bool) return false;
      if (step.containsKey('when')) {
        if (needs < 2) needs = 2;
        checkWhen(step['when'], sid);
      }
      if (kind == 'open_browser') {
        needs = 3;
        if (name != 'login') return false;
        checkOpenBrowser(step);
      }
      for (final key in const ['require', 'then_require']) {
        final Object? checks = step[key];
        if (checks is! List) continue;
        for (final Object? chk in checks) {
          if (chk is Map && chk['check'] == 'vars_equal') {
            needs = 3;
            final (a, b) = varsEqualNames(chk, sid);
            if (!_isTarget(a) || !_isTarget(b)) return false;
          }
        }
      }
      if (kind == 'await_input') {
        if (needs < 2) needs = 2;
        if (name != 'login') return false;
        checkAwaitInput(step);
        if (!_isTarget(step['into'])) return false;
      }
      if (kind == 'generate') {
        final Object? into = step['into'];
        if (into is! List || !into.every(_isTarget)) return false;
      }
      for (final key in const ['extract', 'capture_on_fail']) {
        final Object? rules = step[key];
        if (rules is! List) continue;
        for (final Object? rule in rules) {
          if (rule is! Map || !_isTarget(rule['var'])) return false;
          if (flowUrlSources.contains(rule['source']) && kind != 'open_browser') return false;
          if (rule.containsKey('regex')) {
            final Object? regex = rule['regex'];
            if (regex is List && needs < 2) needs = 2;
            if (regexPatterns(regex, sid).any((re) => regexGroupCount(re) < 1)) return false;
          }
        }
      }
    }
  }
  return needs <= declared;
}

/// Unset, or a positive number of seconds (digits, optionally a fraction) no more than [most].
bool _secondsOk(String? raw, double? most) {
  if (raw == null) return true;
  if (!_secondsRe.hasMatch(raw)) return false;
  final seconds = double.parse(raw);
  return seconds > 0 && (most == null || seconds <= most);
}

/// The var names a list of extract rules sets; throws (caught by [usableLoginSpec]) when [rules] isn't a list.
Set<String> _captures(Object? rules) {
  if (rules == null) return <String>{};
  if (rules is! List) throw const FormatException('an extract or capture_on_fail is not a list of rules');
  return {
    for (final Object? r in rules)
      if (r is Map && r['var'] is String) r['var'] as String,
  };
}

/// Every {{name}} in the text values under [node].
Set<String> _names(Object? node) {
  if (node is String) return {for (final m in _nameRe.allMatches(node)) m.group(1)!};
  if (node is Map) return {for (final Object? v in node.values) ..._names(v)};
  if (node is List) return {for (final Object? v in node) ..._names(v)};
  return <String>{};
}

/// [steps] extract access_token, and each {{name}} is set before it is used: a request (or an await_input's prompt, or
/// an open_browser's url, params and until) is built from what is known before the step (an open_browser's extract
/// targets count for the steps after it); its `require` errors may also use its own capture_on_fail (run just
/// before a check fails), and its `then_require` its own extract too. Every name an earlier step can set counts,
/// whether or not its `when` lets it run (login_spec_source.py's _check_names; SPEC.md "A usable sign-in spec").
bool _namesSetAndTokenExtracted(List<Map<String, Object?>> steps, Set<String> known) {
  final have = {...known};
  var hasToken = false;
  for (final step in steps) {
    final extract = _captures(step['extract']);
    final onFail = _captures(step['capture_on_fail']);
    if (extract.contains('access_token')) hasToken = true;
    final built = _names([for (final k in _requestFields) step[k], step['prompt'], step['until']]);
    if (!have.containsAll(built)) return false;
    if (!{...have, ...onFail}.containsAll(_names(step['require']))) return false;
    if (!{...have, ...onFail, ...extract}.containsAll(_names(step['then_require']))) return false;
    if (step['type'] == 'generate') {
      final Object? into = step['into'];
      if (into is! List) return false;
      have.addAll(into.whereType<String>());
    }
    if (step['type'] == 'await_input') have.add(step['into'] as String); // _stepsOk has made sure it is text
    have.addAll(extract);
  }
  return hasToken;
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
