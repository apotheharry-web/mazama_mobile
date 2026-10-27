// The Dart twin of mazama_sales/src/mazama_sales/state/flowspec.py: a small, generic interpreter for the steps in a
// FlowSpec. It knows nothing about Azure B2C or the state system specifically - see ../../../mazama_modules/SPEC.md for
// what a step can say. Keeping this file structurally close to flowspec.py (same step names, same two-phase
// require/extract/then_require order) is deliberate: a reviewer fixing one should be able to find the matching spot
// in the other without translating much.
//
// One real difference from flowspec.py, not a mirroring gap: flowspec.py's run_flow makes one httpx.Client for
// the whole flow, and httpx.Client persists cookies across requests automatically - exactly what a flow like
// login (authorize -> self_asserted -> confirmed -> token) needs, since B2C sets session cookies during
// `authorize` that later steps are expected to send back. Dart's package:http does nothing of the kind, so this
// file carries its own small cookie jar (see _mergeSetCookies/_cookieHeader below), scoped to one runFlow call,
// to match that behavior rather than silently dropping it. Unlike httpx's, this jar is not scoped by host: every
// cookie it holds is sent on every request and redirect hop of the run (all of them on allowed hosts, SL-R8).
//
// Redirects (SL-R8): every request is sent with followRedirects off and the runner follows redirects itself, so
// each hop's URL is checked against the host allowlist before it is sent and each hop's Set-Cookie lands in the
// jar. Only GET and HEAD are followed; the rules are redirectRules below, the twin of flowspec.py's _redirect_rules.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'flow_spec.dart';

const defaultSecretKeys = {'password', 'email', 'access_token', 'refresh_token'};

/// Where a request step failed (SM-12) - what a caller needs to tell "nothing was sent" from "it may have been",
/// without reading the message. The same three values as flowspec.py's FlowError.stage.
enum FlowStage {
  /// The connection never opened (host lookup failed, connection refused, network unreachable, TLS handshake
  /// failed): nothing reached the server.
  connect,

  /// Any other failure before an answer's status arrived - a reset after the request went out, the connection
  /// closed before the reply, no answer within the timeout, anything unrecognised: the request may have been
  /// received.
  send,

  /// An answer came back ([FlowError.status] is set), but its body couldn't be read in full, or a
  /// `require`/`then_require` check rejected it, or it was a redirect to an address off the allowlist (reason
  /// `not_allowed`, [FlowError.status] the 3xx).
  response,
}

class FlowError implements Exception {
  final String message;

  /// Null for a failure that involved no request (an `assert` step, a mistake in the spec, a step url off the
  /// allowlist).
  final FlowStage? stage;

  /// The answer's HTTP status, when one arrived.
  final int? status;

  /// The failing step's `id` (null if it has none or the failure belongs to no step). Not final: a FlowError a caller's
  /// callback throws without one gets the step it was thrown in (flowspec.py sets it the same way).
  String? step;

  /// The failing check's `reason` (null when the check names none, and always null for a transport failure). A mistake
  /// in the spec itself found while it runs (a malformed `when`, `await_input`, `open_browser` or `vars_equal`, a regex
  /// that doesn't compile or leaves the shared syntax, an unknown step type, extract source, check or generator, a step
  /// with no `type`, a name nothing set) has reason `structure` and stage null (SPEC.md "Failures"; flowspec.py's
  /// FlowError).
  final String? reason;

  FlowError(this.message, {this.stage, this.status, this.step, this.reason});
  @override
  String toString() => message;
}

/// SM-D1: used when a spec has no `timeout_seconds` var - never "no timeout".
const defaultRequestTimeout = Duration(seconds: 60);

/// The per-request timeout: [ctx]'s `timeout_seconds` (spec var or input; fractions allowed), else
/// [defaultRequestTimeout]. Anything that isn't a positive number is a mistake in the spec and throws, rather
/// than quietly becoming the default. The twin of flowspec.py's request_timeout.
Duration flowRequestTimeout(Map<String, Object?> ctx) {
  final raw = ctx['timeout_seconds'];
  if (raw == null) return defaultRequestTimeout;
  final seconds = raw is num ? raw.toDouble() : double.tryParse(raw.toString());
  if (seconds == null || !(seconds > 0) || seconds.isInfinite) {
    // names no value: whatever was set there (a spec could read a token into it) stays out of the message (claim 6)
    throw FlowError('timeout_seconds must be a positive number of seconds');
  }
  return Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());
}

/// The exception's public kind for a message: package:http's own wrapper is a private class (its runtimeType
/// reads `_ClientSocketException`), so the interface it implements is named instead.
String _kind(Object ex) => ex is SocketException
    ? 'SocketException'
    : ex is http.ClientException
        ? 'ClientException'
        : '${ex.runtimeType}';

String _secondsText(Duration d) => d.inMicroseconds % Duration.microsecondsPerSecond == 0
    ? '${d.inSeconds}'
    : '${d.inMicroseconds / Duration.microsecondsPerSecond}';

// errno values for "the connection never opened", per platform: ECONNREFUSED, ENETUNREACH, EHOSTUNREACH.
const _linuxConnectErrnos = {111, 101, 113}; // Linux, Android
const _darwinConnectErrnos = {61, 51, 65}; // iOS, macOS
const _windowsConnectErrnos = {10061, 10051, 10065};

/// True only when [ex] proves the request never left the device. Deliberately narrow: anything not recognised
/// here counts as "may have been sent", the safer mistake for a write (a reset after sending, errno 104/54, is
/// a SocketException too, and must not land here). package:http's IOClient rethrows a SocketException as a
/// ClientException that still implements SocketException, so `is SocketException` sees through it.
bool _neverConnected(Object ex) {
  if (ex is HandshakeException) return true; // TLS failed before any of the request was written
  if (ex is! SocketException) return false;
  if (ex.message.startsWith('Failed host lookup')) return true;
  final errno = ex.osError?.errorCode;
  if (errno == null) return false;
  final codes = Platform.isIOS || Platform.isMacOS
      ? _darwinConnectErrnos
      : Platform.isWindows
          ? _windowsConnectErrnos
          : _linuxConnectErrnos;
  return codes.contains(errno);
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

(String, String) _pkce() {
  final verifier = _b64url(List<int>.generate(48, (_) => Random.secure().nextInt(256)));
  final challenge = _b64url(sha256.convert(utf8.encode(verifier)).bytes);
  return (verifier, challenge);
}

String _randomHex(int bytes) {
  final rnd = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

// Replaces every secret value in [message] with ***, whatever its case: a message can quote the state's own words
// (capture_on_fail), and B2C may echo an email in another case than the one typed (flowspec.py's _scrub).
String _scrub(String message, Map<String, Object?> ctx, Set<String> secretKeys) {
  for (final key in secretKeys) {
    final v = ctx[key];
    if (v != null && v.toString().isNotEmpty) {
      message = message.replaceAll(RegExp(RegExp.escape(v.toString()), caseSensitive: false), '***');
    }
  }
  return message;
}

// Matches Python's own truthiness (used by `truthy` checks against a captured variable of any JSON-decoded
// type, not just the strings every check against this ever saw before `sale`'s `created` list): null, false,
// 0, '', [] and {} are falsy, everything else is truthy. Before this, the Dart side used
// `ctx[v].toString().isNotEmpty`, which was fine for the plain strings every existing flow ever checked (csrf,
// code, access_token) but is wrong for a captured list or map - `[].toString()` is `'[]'`, a non-empty string,
// so an empty list would have read as truthy here while Python's `all(ctx.get(v) for v in vars)` correctly
// treats an empty list as falsy. `sale.yaml`'s `created` is the first flow to check truthy against a
// non-string value, which is what surfaced this.
bool _isTruthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

Object? _jsonPath(Object? data, String path) {
  if (path.isEmpty) return data; // the whole parsed body, e.g. a sale write's list of created records
  for (final part in path.split('.')) {
    if (data is! Map || !data.containsKey(part)) return null;
    data = data[part];
  }
  return data;
}

/// A {{name}} nothing has set at run time (a name only a skipped step sets, say): the spec's own mistake, reason
/// `structure`, stage null, [step] the step it happened in (flowspec.py's UnknownName). A [FlowError], not the
/// [FlowSpecError] a spec's own `vars` give while it loads.
class FlowUnknownName extends FlowError {
  FlowUnknownName(super.message, {super.step}) : super(reason: 'structure');
}

/// [templateString] at run time: an unknown name is a [FlowUnknownName] (runFlow fills in the step).
String _template(String s, Map<String, Object?> ctx) {
  try {
    return templateString(s, ctx);
  } on FlowSpecError catch (e) {
    throw FlowUnknownName(e.message);
  }
}

FlowError _fail(String? error, Map<String, Object?> ctx, Set<String> secretKeys,
    {int? status, FlowStage? stage, String? step, String? reason}) {
  var msg = error ?? 'the flow failed';
  if (status != null) msg = msg.replaceAll('{status}', status.toString());
  if (RegExp(r'\{\{\w+\}\}').hasMatch(msg)) msg = _template(msg, ctx);
  // A check that runs against a response (status set) is always the response stage; an `assert` step has neither.
  return FlowError(_scrub(msg, ctx, secretKeys),
      stage: stage ?? (status != null ? FlowStage.response : null), status: status, step: step, reason: reason);
}

/// Runs the checks in order; the first that fails throws a [FlowError] carrying [step] and the check's `reason`.
/// [beforeFail] runs just before that throw (the request step's `capture_on_fail`).
void _runRequire(List<Map<String, Object?>>? checks, Map<String, Object?> ctx, Set<String> secretKeys,
    {int? status, Object? bodyJson, String? step, void Function()? beforeFail}) {
  for (final chk in checks ?? const <Map<String, Object?>>[]) {
    final check = chk['check'] as String;
    final bool failed;
    switch (check) {
      case 'status_in':
        final values = (chk['values'] as List).cast<int>();
        failed = !values.contains(status);
        break;
      case 'truthy':
        final vars = (chk['vars'] as List).cast<String>();
        failed = !vars.every((v) => _isTruthy(ctx[v]));
        break;
      case 'json_equals':
        final got = _jsonPath(bodyJson, chk['path'] as String);
        final want = _template(chk['value'].toString(), ctx);
        failed = got.toString() != want;
        break;
      case 'vars_equal':
        final (a, b) = varsEqualNames(chk, step);
        final va = ctx[a];
        final vb = ctx[b];
        failed = va == null || vb == null || va.toString() != vb.toString();
        break;
      default:
        throw FlowError('unknown require check: $check', step: step, reason: 'structure');
    }
    if (failed) {
      if (beforeFail != null) beforeFail();
      throw _fail(chk['error'] as String?, ctx, secretKeys,
          status: status, step: step, reason: chk['reason'] as String?);
    }
  }
}

/// A `vars_equal` check's two var names (format 3): `vars` is a list of exactly two texts, else a spec mistake
/// (flowspec.py's vars_equal_names).
(String, String) varsEqualNames(Map<Object?, Object?> chk, [String? step]) {
  final Object? names = chk['vars'];
  if (names is List && names.length == 2) {
    final Object? a = names[0];
    final Object? b = names[1];
    if (a is String && b is String) return (a, b);
  }
  throw FlowError('step ${_idText(step)} has a malformed vars_equal (vars is a list of two names)',
      step: step, reason: 'structure');
}

// Attribute names that can appear inside a Set-Cookie value looking like `name=value` but aren't cookies
// themselves - excluded defensively, though in practice the regex below already can't match most of these
// (they're `;`-separated from the cookie name, not `,`-separated, and the boundary this regex requires is a
// comma or string start).
const _cookieAttributeNames = {
  'expires', 'path', 'domain', 'secure', 'httponly', 'samesite', 'max-age', 'version',
};

// package:http's IOClient joins multiple Set-Cookie response headers into one string with a bare comma (see
// package:http's io_client.dart) - ambiguous with the comma inside a cookie's own `Expires=Wed, 21 Oct 2026...`
// attribute value. This splits only at a boundary that looks like the start of a new `name=value` cookie pair
// (string start, or right after ", "), which the date-with-comma case doesn't match (the token right after that
// comma is a bare day number followed by a space, never `name=`), so it holds up without needing a full RFC
// 6265 Set-Cookie parser.
//
// The name group is deliberately NOT restricted to `\w` - a real capture against the actual state system (see
// the HAR comparison that found this) showed B2C setting cookies named
// `x-ms-cpim-sso:oregonpsilocybinprodb2c.onmicrosoft.com_0` and `x-ms-cpim-cache|be7xvbawu0spqk0ivbh1fq_0`:
// real cookie names here contain `:` and `|`, which a strict RFC 6265 token grammar would exclude but B2C (and
// browsers) tolerate anyway. An earlier version of this regex used `[\w-]+` for the name, which silently failed
// to capture either of those two cookies - B2C needs all four of what `authorize` sets to recognize the
// session, and dropping two of them is exactly what made the real `SelfAsserted` call bounce back to a login
// HTML page (B2C error AADB2C90046, "We are having trouble signing you in... start your session over") instead
// of the JSON response fake_state.dart and state_fake.py had only ever modeled with two simple cookie names.
// Widening the name class to "anything but the characters that actually delimit a cookie pair" fixes this
// without reopening the date-comma ambiguity above: that disambiguation works because the token right after
// the date's embedded comma is a bare number followed by a *space*, and `=` still can't follow it immediately
// regardless of how broad the name class is.
final _cookiePairRe = RegExp(r'(?:^|,\s*)([^\s=,;]+)=([^;,]*)');

void _mergeSetCookies(http.Response resp, Map<String, String> cookies) {
  final raw = resp.headers['set-cookie'];
  if (raw == null || raw.isEmpty) return;
  for (final m in _cookiePairRe.allMatches(raw)) {
    final name = m.group(1)!;
    if (_cookieAttributeNames.contains(name.toLowerCase())) continue;
    cookies[name] = m.group(2)!;
  }
}

String? _cookieHeader(Map<String, String> cookies) {
  if (cookies.isEmpty) return null;
  return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

Object? _bodyJson(http.Response resp) {
  try {
    return jsonDecode(resp.body);
  } on FormatException {
    return null;
  }
}

const _nothing = Object();

/// The step types this interpreter runs (flowspec.py's STEP_TYPES).
const flowStepTypes = {'generate', 'assert', 'request', 'await_input', 'open_browser'};

/// The extract sources an `open_browser` step reads its returned URL with (flowspec.py's URL_SOURCES).
const flowUrlSources = {'url_fragment', 'url_query'};

String _idText(String? step) => step ?? '(no id)';

const _groupOpeners = [':', '=', '!', '<=', '<!'];

const _escapableLetters = 'dDwWsSbBnrtfvxu';
const _hexDigits = '0123456789abcdefABCDEF';
final _asciiAlnum = RegExp(r'^[A-Za-z0-9]$');

/// Whether a backslash may escape [c] in the shared syntax: a non-alphanumeric character (ASCII letters and digits are
/// what the two languages read differently), or one of the letter escapes both read alike (flowspec.py's
/// _escape_shared).
bool _escapeShared(String c) {
  if (c.isEmpty) return false;
  if (_asciiAlnum.hasMatch(c)) return _escapableLetters.contains(c);
  return true;
}

/// The character after index [at] in [s], or '' at the end.
String _charAfter(String s, int at) => at + 1 < s.length ? s[at + 1] : '';

/// How many code units the escape starting at [at] (a backslash) takes in the shared syntax, or 0 when it is refused:
/// `\x` needs exactly two hex digits and `\u` exactly four (`\x4`, `\u12`, `\u{41}` are plain text here and an error
/// in Python), `\B` is refused inside a class (a plain B here, an error in Python), and anything else is
/// [_escapeShared]'s call (flowspec.py's _escape_length is the twin).
int _escapeLength(String pattern, int at, {required bool inClass}) {
  final c = _charAfter(pattern, at);
  if (c == 'x' || c == 'u') {
    final width = c == 'x' ? 2 : 4;
    final start = at + 2;
    if (start + width > pattern.length) return 0;
    for (var k = start; k < start + width; k++) {
      if (!_hexDigits.contains(pattern[k])) return 0;
    }
    return 2 + width;
  }
  if (inClass && c == 'B') return 0;
  return _escapeShared(c) ? 2 : 0;
}

/// Whether [pattern] keeps to the regex syntax Dart's `RegExp` and Python's `re` read the same way (SPEC.md "Regex
/// syntax both sides read"); flowspec.py's shared_regex_syntax is the twin, scanning the same way. Outside a
/// character class, every unescaped `(?` is followed by `:`, `=`, `!`, `<=` or `<!` (no named groups, inline flags,
/// comments, atomic groups or conditionals); no unescaped `*`, `+`, `?` or `}` is followed by `+` (possessive); no
/// unescaped `{` is followed by `,` (`{,3}`); no quantifier (`*`, `+`, `?`, `{`) comes straight after the `)` that
/// closes a look-behind; and inside a look-behind (`(?<=`, `(?<!`, nested groups included) there is no quantifier and
/// no `|`, so it has one fixed width. A backslash may escape only a non-alphanumeric character or one of
/// `d D w W s S b B n r t f v x u`, inside a class or out (but no `\B` in a class): no `\A`, `\Z`, `\z`, other letters,
/// and no digits (backreferences, `\0`); `\x` takes exactly two hex digits and `\u` exactly four. A class that starts
/// with `]` (`[]...]`, `[^]...]`: an empty class here, a literal `]` in Python) is refused. `[` opens a class unless
/// escaped, and `]` closes it.
bool sharedRegexSyntax(String pattern) {
  final n = pattern.length;
  final groups = <bool>[]; // one entry per open group: whether it is a look-behind
  var i = 0;
  var quantified = false;
  var afterLookbehind = false; // the previous token was the `)` that closes a look-behind
  while (i < n) {
    final c = pattern[i];
    if (c == '\\') {
      final width = _escapeLength(pattern, i, inClass: false);
      if (width == 0) return false;
      i += width;
      quantified = false;
      afterLookbehind = false;
      continue;
    }
    if (c == '[') {
      var j = i + 1 < n && pattern[i + 1] == '^' ? i + 2 : i + 1;
      if (j < n && pattern[j] == ']') return false;
      while (j < n && pattern[j] != ']') {
        if (pattern[j] == '\\') {
          final width = _escapeLength(pattern, j, inClass: true);
          if (width == 0) return false;
          j += width;
        } else {
          j++;
        }
      }
      i = j + 1;
      quantified = false;
      afterLookbehind = false;
      continue;
    }
    if (c == '(') {
      if (pattern.startsWith('(?', i)) {
        final at = i + 2;
        final opener = _groupOpeners.where((o) => pattern.startsWith(o, at)).firstOrNull;
        if (opener == null) return false;
        groups.add(opener == '<=' || opener == '<!');
        i = at + opener.length;
      } else {
        groups.add(false);
        i++;
      }
      quantified = false;
      afterLookbehind = false;
      continue;
    }
    if (c == ')') {
      afterLookbehind = groups.isNotEmpty && groups.removeLast();
      quantified = false;
      i++;
      continue;
    }
    if ('*+?{'.contains(c) && afterLookbehind) return false;
    if ('*+?{|'.contains(c) && groups.contains(true)) return false;
    if (c == '+' && quantified) return false;
    if (c == '{' && _charAfter(pattern, i) == ',') return false;
    quantified = '*+?}'.contains(c);
    afterLookbehind = false;
    i++;
  }
  return true;
}

RegExp _compile(String pattern, String? step) {
  if (!sharedRegexSyntax(pattern)) {
    throw FlowError("step ${_idText(step)} has a regex that uses syntax Python and Dart don't read alike",
        step: step, reason: 'structure');
  }
  try {
    return RegExp(pattern);
  } on FormatException {
    throw FlowError('step ${_idText(step)} has a regex that does not compile', step: step, reason: 'structure');
  }
}

/// How many capture groups [re] has (a match of `(?:re)|` against '' always exists and carries them all).
int regexGroupCount(RegExp re) => RegExp('(?:${re.pattern})|').firstMatch('')!.groupCount;

/// The step's `id` when it is text, else null (a usable spec's ids are text; this never throws on one that isn't).
String? _stepId(Map<Object?, Object?> step) {
  final Object? id = step['id'];
  return id is String ? id : null;
}

/// An extract rule's `regex`: one pattern, or (format 2, SL-R11) a non-empty list of them tried in order. Anything
/// else, or a pattern that doesn't compile or leaves the shared syntax ([sharedRegexSyntax]), is a spec mistake: a
/// [FlowError] naming the step (flowspec.py's regex_patterns).
List<RegExp> regexPatterns(Object? value, [String? step]) {
  if (value is String) return [_compile(value, step)];
  if (value is List && value.isNotEmpty && value.every((Object? p) => p is String)) {
    return [for (final Object? p in value) _compile(p as String, step)];
  }
  throw FlowError('step ${_idText(step)} has a regex that is not text or a non-empty list of text',
      step: step, reason: 'structure');
}

/// A `when` (SL-R12) as its parts: exactly {var}, {var, equals} or {var, matches}, all text, and a `matches` that
/// compiles. Anything else is a spec mistake (a [FlowError] naming the step), even when the var is unset
/// (flowspec.py's _when_form).
({String name, String? equals, RegExp? matches}) _whenForm(Object? when, String? step) {
  FlowError bad() => FlowError('step ${_idText(step)} has a malformed when', step: step, reason: 'structure');
  if (when is! Map) throw bad();
  final Object? name = when['var'];
  if (name is! String) throw bad();
  final keys = {for (final Object? k in when.keys) if (k != 'var') k};
  if (keys.isEmpty) return (name: name, equals: null, matches: null);
  if (keys.length == 1 && keys.contains('equals')) {
    final Object? equals = when['equals'];
    if (equals is String) return (name: name, equals: equals, matches: null);
  }
  if (keys.length == 1 && keys.contains('matches')) {
    final Object? matches = when['matches'];
    if (matches is String) {
      try {
        return (name: name, equals: null, matches: _compile(matches, step));
      } on FlowError {
        throw bad();
      }
    }
  }
  throw bad();
}

/// Throws [FlowError] when [when] is not one of the three forms (usableLoginSpec uses this; flowspec.py's
/// check_when).
void checkWhen(Object? when, [String? step]) => _whenForm(when, step);

/// Whether a step with this `when` runs. An unset var (absent or null) is false for every form; `{var}` needs a
/// non-empty text; `equals` compares the text of the value; `matches` is a regex search on that text (flowspec.py's
/// when_holds). The text of a JSON true/false differs from Python's (`true` here, `True` there): SPEC.md says to
/// test one with `matches: "^(true|True)$"`.
bool whenHolds(Object? when, Map<String, Object?> ctx, [String? step]) {
  final form = _whenForm(when, step);
  final value = ctx[form.name];
  if (value == null) return false;
  final text = value.toString();
  final equals = form.equals;
  if (equals != null) return text == equals;
  final matches = form.matches;
  if (matches != null) return matches.hasMatch(text);
  return text.isNotEmpty;
}

/// An `await_input` step (SL-R13) has text `into` and `prompt`, and `secret` true/false or absent; otherwise throws a
/// [FlowError] naming the step (flowspec.py's check_await_input).
void checkAwaitInput(Map<Object?, Object?> step) {
  final sid = _stepId(step);
  final Object? secret = step.containsKey('secret') ? step['secret'] : false;
  if (step['into'] is! String || step['prompt'] is! String || secret is! bool) {
    throw FlowError('step ${_idText(sid)} is a malformed await_input (into and prompt are text, secret true/false)',
        step: sid, reason: 'structure');
  }
}

/// An `open_browser` step (SL-R16) has text `url` (with no `?`: a query goes in `params`) and `until`, `params` a
/// mapping or absent, `then_require` a list or absent, no `require` or `capture_on_fail` (nothing answers them), and
/// `extract` absent or a list of rules each with a text `var`, a `source` of url_fragment or url_query, and a text
/// `name`; otherwise throws a [FlowError] naming the step (flowspec.py's check_open_browser).
void checkOpenBrowser(Map<Object?, Object?> step) {
  final sid = _stepId(step);
  final Object? url = step['url'];
  final Object? params = step['params'];
  final Object? rules = step['extract'];
  final Object? thenRequire = step['then_require'];
  final ok = url is String &&
      !url.contains('?') &&
      step['until'] is String &&
      (params == null || params is Map) &&
      (thenRequire == null || thenRequire is List) &&
      !step.containsKey('require') &&
      !step.containsKey('capture_on_fail') &&
      (rules == null ||
          (rules is List &&
              rules.every((Object? r) =>
                  r is Map && r['var'] is String && flowUrlSources.contains(r['source']) && r['name'] is String)));
  if (!ok) {
    throw FlowError(
        'step ${_idText(sid)} is a malformed open_browser (url and until are text, no query in url, '
        'params a mapping, no require or capture_on_fail, extract rules url_fragment or url_query with a name)',
        step: sid,
        reason: 'structure');
  }
}

bool _isHexDigit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66);

/// A form value decoded as Python's parse_qsl decodes it: `+` is a space, each `%XX` (two hex digits) a byte, the bytes
/// read as UTF-8 (a malformed sequence is U+FFFD), and a `%` not followed by two hex digits left as it is.
String _decodeFormValue(String s) {
  final text = s.replaceAll('+', ' ');
  final out = StringBuffer();
  final bytes = <int>[];
  void flush() {
    if (bytes.isNotEmpty) {
      out.write(utf8.decode(bytes, allowMalformed: true));
      bytes.clear();
    }
  }

  var i = 0;
  while (i < text.length) {
    if (text.codeUnitAt(i) == 0x25 &&
        i + 2 < text.length &&
        _isHexDigit(text.codeUnitAt(i + 1)) &&
        _isHexDigit(text.codeUnitAt(i + 2))) {
      bytes.add(int.parse(text.substring(i + 1, i + 3), radix: 16));
      i += 3;
    } else {
      flush();
      out.write(text[i]);
      i++;
    }
  }
  flush();
  return out.toString();
}

/// [name]'s value in the fragment (everything after the first `#`) or the query (between the first `?` and the first
/// `#`) of [url], decoded as a form value (`+` is a space); a blank value or a bare key is ''; the first of a repeated
/// key wins; null when it isn't there (flowspec.py's url_value is the twin).
String? urlValue(String url, String source, String name) {
  final hash = url.indexOf('#');
  final head = hash >= 0 ? url.substring(0, hash) : url;
  final String text;
  if (source == 'url_fragment') {
    text = hash >= 0 ? url.substring(hash + 1) : '';
  } else {
    final q = head.indexOf('?');
    text = q >= 0 ? head.substring(q + 1) : '';
  }
  for (final part in text.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final key = _decodeFormValue(eq >= 0 ? part.substring(0, eq) : part);
    if (key == name) return _decodeFormValue(eq >= 0 ? part.substring(eq + 1) : '');
  }
  return null;
}

/// Applies extract rules. A rule that finds nothing uses its own `default`, else [fallback] (capture_on_fail passes
/// ''), else leaves the variable unset. A `regex` list is tried in order; the first pattern that matches wins. A
/// pattern with no group finds nothing (flowspec.py does the same; the usable-spec rule refuses one).
void _extract(List<Map<String, Object?>>? rules, Map<String, Object?> ctx, http.Response resp, Uri finalUrl,
    {Object? fallback = _nothing, String? step}) {
  for (final rule in rules ?? const <Map<String, Object?>>[]) {
    final varName = rule['var'] as String;
    final source = rule['source'] as String;
    Object? found = _nothing;
    if (source == 'body' && rule.containsKey('regex')) {
      for (final pattern in regexPatterns(rule['regex'], step)) {
        final m = pattern.firstMatch(resp.body);
        if (m != null && m.groupCount >= 1) {
          found = m.group(1);
          break;
        }
      }
    } else if (source == 'body' && rule.containsKey('json')) {
      final v = _jsonPath(_bodyJson(resp), rule['json'] as String);
      if (v != null) found = v;
    } else if (source == 'status') {
      // The plain HTTP status code as an integer - mirrors flowspec.py's own `status` extract source, added
      // for ../../../mazama_modules/flows/state_reads.yaml's get_json flow so a caller (state_client.dart's
      // fetchStateJson) can implement its own policy for a status it wants a chance to react to (a 401, say)
      // instead of the flow raising. See ../../../mazama_modules/SPEC.md's `extract.source` list for the full
      // rationale.
      found = resp.statusCode;
    } else if (source == 'header') {
      final h = resp.headers[(rule['name'] as String).toLowerCase()] ?? '';
      if (rule.containsKey('fragment')) {
        final frag = Uri.splitQueryString(Uri.parse(h).fragment);
        final v = frag[rule['fragment'] as String];
        if (v != null) found = v;
      } else if (h.isNotEmpty) {
        found = h;
      }
    } else if (source == 'url') {
      found = finalUrl.toString();
    } else {
      throw FlowError('unknown extract source: $source', step: step, reason: 'structure');
    }
    if (identical(found, _nothing)) found = rule.containsKey('default') ? rule['default'] : fallback;
    if (!identical(found, _nothing)) ctx[varName] = found;
  }
}

/// Runs one named flow to completion against [client] and returns the final context (inputs + every captured
/// variable). Throws [FlowError], with any value named in [secretKeys] scrubbed from the message, on the first
/// failed check. Every request is sent with followRedirects off; a step's own `follow_redirects` (default true)
/// decides whether the runner follows a 3xx itself, so a plain `http.Client()` (or a fake standing in for the state
/// system in tests) is all [client] needs to be. Every request and every redirect hop must pass
/// [hostAllowedUrl] against [allowedHosts] before it is sent (SL-R8); one that doesn't is never sent and fails
/// with reason `not_allowed`.
///
/// A step whose `when` doesn't hold is skipped (SL-R12). An `await_input` step (SL-R13) calls [ask] with its
/// templated prompt and whether the answer is secret: without [ask] the flow fails with reason `needs_person`, and a
/// null or empty answer with reason `cancelled`, both before anything more is sent; a `secret` answer is scrubbed
/// from every later error like a password; the prompt [ask] gets has every secret value scrubbed.
///
/// An `open_browser` step (SL-R16) calls [browse] with the start URL and `until` once both pass the allowlist:
/// without [browse] the flow fails with `needs_person`, a null answer with `cancelled`, and an answer that doesn't
/// start with `until` with `structure`. A [FlowError] thrown by [ask] or [browse] passes through (its step filled in
/// when it names none); anything else they throw is reason `structure`.
Future<Map<String, Object?>> runFlow(FlowSpec spec, String flowName, Map<String, Object?> inputs,
    {required http.Client client,
    Set<String> secretKeys = defaultSecretKeys,
    Iterable<String> allowedHosts = defaultAllowedHosts,
    Set<String> neverRequest = const {},
    Future<String?> Function(String prompt, bool secret)? ask,
    Future<String?> Function(String url, String until)? browse}) async {
  // [neverRequest]: allowed hosts this run must not send anything to (SL-D16: a sign-in or renewal run never reaches
  // the state's API). A step's own url there is refused like one off the allowlist; a redirect there is not followed
  // (the 3xx comes back as the answer, as with `follow_redirects: false`). An open_browser's `until` may still name
  // one: it is matched, never requested.
  final steps = spec.flows[flowName];
  if (steps == null) throw FlowError('no such flow: $flowName');
  final ctx = <String, Object?>{...spec.vars, ...inputs};
  final keys = <String>{...secretKeys}; // grows by a secret await_input's `into`
  // Scoped to this one runFlow call, same lifetime as flowspec.py's own httpx.Client(transport=transport) - see
  // the file-level comment above for why this exists at all.
  final cookies = <String, String>{};
  for (final step in steps) {
    final Object? kind = step['type'];
    final sid = _stepId(step);
    try {
      if (step.containsKey('when') && !whenHolds(step['when'], ctx, sid)) continue;
      if (kind == 'generate') {
        _runGenerate(step, ctx, sid);
      } else if (kind == 'assert') {
        _runRequire((step['require'] as List?)?.cast<Map<String, Object?>>(), ctx, keys, step: sid);
      } else if (kind == 'request') {
        await _runRequest(step, ctx, client, keys, cookies, allowedHosts, neverRequest);
      } else if (kind == 'await_input') {
        if (await _runAwaitInput(step, ctx, keys, ask)) keys.add(step['into'] as String);
      } else if (kind == 'open_browser') {
        await _runOpenBrowser(step, ctx, keys, allowedHosts, browse);
      } else {
        throw FlowError('unknown step type: $kind', step: sid, reason: 'structure');
      }
    } on FlowUnknownName catch (e) {
      if (e.step != null) rethrow;
      throw FlowUnknownName(e.message, step: sid);
    }
  }
  return ctx;
}

/// Runs a caller's callback ([ask], [browse]): a [FlowError] it throws passes through unchanged, with its step filled
/// in when it names none; anything else it throws is a [FlowError] with reason `structure` that names only its kind
/// (its message could hold anything). flowspec.py's _call_back is the twin.
Future<T> _callBack<T>(Future<T> Function() callback, String? sid, String what) async {
  try {
    return await callback();
  } on FlowError catch (e) {
    e.step ??= sid; // the same object, whatever its subclass
    rethrow;
  } catch (e) {
    throw FlowError('the $what callback failed: ${_kind(e)}', step: sid, reason: 'structure');
  }
}

/// Asks a person and stores the answer in `into`; returns whether the answer is secret (flowspec.py's
/// _run_await_input).
Future<bool> _runAwaitInput(Map<String, Object?> step, Map<String, Object?> ctx, Set<String> secretKeys,
    Future<String?> Function(String prompt, bool secret)? ask) async {
  checkAwaitInput(step);
  final sid = _stepId(step);
  final secret = (step['secret'] as bool?) ?? false;
  if (ask == null) {
    throw FlowError('the flow needs a person to answer a question, and nobody is there to ask',
        step: sid, reason: 'needs_person');
  }
  // The prompt leaves the interpreter (the server stores, audits, shows and alerts it), so no secret goes with it.
  final prompt = _scrub(_template(step['prompt'] as String, ctx), ctx, secretKeys);
  final answer = await _callBack(() => ask(prompt, secret), sid, 'ask');
  if (answer == null || answer.isEmpty) {
    throw FlowError('the question was not answered', step: sid, reason: 'cancelled');
  }
  ctx[step['into'] as String] = answer;
  return secret;
}

/// Hands the sign-in page to a person (SL-R16): the start URL is built from `url` and `params` as a request step's is,
/// and it and `until` must pass the allowlist before [browse] sees either. The URL [browse] returns is read by the
/// step's url_fragment/url_query extracts and is never put in an error (it can carry the authorization code); its
/// `then_require` checks (the returned state, say) run after them. flowspec.py's _run_open_browser is the twin.
Future<void> _runOpenBrowser(Map<String, Object?> step, Map<String, Object?> ctx, Set<String> secretKeys,
    Iterable<String> allowedHosts, Future<String?> Function(String url, String until)? browse) async {
  checkOpenBrowser(step);
  final sid = _stepId(step);
  final url = _template(step['url'] as String, ctx);
  final params = _templateMap(step['params'] as Map?, ctx);
  final until = _template(step['until'] as String, ctx);
  if (!openBrowserUrlsOk(url, until)) {
    throw FlowError('step ${_idText(sid)} has a query in its url or an until with no path',
        step: sid, reason: 'structure');
  }
  if (!hostAllowedUrl(url, allowed: allowedHosts)) throw _blocked(url, ctx, secretKeys, sid);
  Uri uri;
  try {
    uri = Uri.parse(url); // as _runRequest builds its request
  } on FormatException {
    throw _blocked(url, ctx, secretKeys, sid);
  }
  if (params.isNotEmpty) uri = uri.replace(queryParameters: params);
  final start = uri.toString();
  if (!hostAllowedUrl(start, allowed: allowedHosts)) throw _blocked(start, ctx, secretKeys, sid);
  if (!hostAllowedUrl(until, allowed: allowedHosts)) throw _blocked(until, ctx, secretKeys, sid);
  if (browse == null) {
    throw FlowError("the flow needs a person to sign in on the state's page, and nobody is there",
        step: sid, reason: 'needs_person');
  }
  final finalUrl = await _callBack(() => browse(start, until), sid, 'browse');
  if (finalUrl == null) throw FlowError('the sign-in page was closed', step: sid, reason: 'cancelled');
  if (!finalUrl.startsWith(until)) {
    throw FlowError('the sign-in page ended somewhere other than the address the flow waits for',
        step: sid, reason: 'structure');
  }
  for (final Object? r in (step['extract'] as List?) ?? const <Object?>[]) {
    final rule = r as Map; // checkOpenBrowser has made sure of every field read here
    Object? found = urlValue(finalUrl, rule['source'] as String, rule['name'] as String);
    if (found == null && rule.containsKey('default')) found = rule['default'];
    if (found != null) ctx[rule['var'] as String] = found;
  }
  _runRequire((step['then_require'] as List?)?.cast<Map<String, Object?>>(), ctx, secretKeys, step: sid);
}

void _runGenerate(Map<String, Object?> step, Map<String, Object?> ctx, String? sid) {
  final make = step['make'] as String;
  final into = (step['into'] as List).cast<String>();
  if (make == 'pkce') {
    final (verifier, challenge) = _pkce();
    ctx[into[0]] = verifier;
    ctx[into[1]] = challenge;
  } else if (make == 'random_hex') {
    for (final name in into) {
      ctx[name] = _randomHex(16);
    }
  } else {
    throw FlowError('unknown generator: $make', step: sid, reason: 'structure');
  }
}

/// At most this many redirect hops are followed for one request step (flowspec.py's MAX_REDIRECTS).
const maxRedirects = 10;

const _redirectStatuses = {301, 302, 303, 307, 308};
const _followedMethods = {'GET', 'HEAD'};

/// [uri]'s host as the allowlist compares it: lower case, one trailing dot removed (`psilocybin.oregon.gov.` is the
/// same host), so neverRequest can't be passed by spelling the host another way (fifth public-app audit).
String _comparedHost(Uri uri) {
  final host = uri.host.toLowerCase();
  return host.endsWith('.') ? host.substring(0, host.length - 1) : host;
}

/// The redirect rules, in one place (flowspec.py's _redirect_rules is the twin): true when an answer is a redirect to
/// follow. Only a GET or HEAD answered 301/302/303/307/308 is followed, with the same method and no body; at most
/// [maxRedirects] hops. Any other method's 3xx comes back as it is, whatever `follow_redirects` says: a POST that was
/// answered has reached the state system and may have been recorded (a sale, say), and following it would let a
/// later hop's failure (a connect error, a 4xx) read as "not sent" to classifySaleFailure (SL-R8 review ruling).
bool redirectRules(int status, String method) =>
    _followedMethods.contains(method.toUpperCase()) && _redirectStatuses.contains(status);

/// Reason `not_allowed`. A step's own url off the list is the spec's mistake (stage null: nothing was sent); a
/// redirect hop off the list is the state's answer, so [status] is the 3xx that sent it there and the stage is
/// `response` (final review Minor 1; flowspec.py's _blocked is the twin).
FlowError _blocked(String url, Map<String, Object?> ctx, Set<String> secretKeys, String? sid, {int? status}) =>
    _fail('the flow tried to reach ${url.split('?')[0].split('#')[0]}, which is not an allowed https address', ctx,
        secretKeys, status: status, step: sid, reason: 'not_allowed');

final _schemeRe = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');

/// Where a redirect's [location] leads from [current] (resolved as a browser would), or null when that is not
/// allowed. An absolute or scheme-relative location is also checked as written, before Uri's normalisation, the
/// way a step's own url is; one Uri can't read is not allowed either.
Uri? _nextHop(Uri current, String location, Iterable<String> allowed) {
  if (_schemeRe.hasMatch(location) && !hostAllowedUrl(location, allowed: allowed)) return null;
  if (location.startsWith('//') && !hostAllowedUrl('${current.scheme}:$location', allowed: allowed)) return null;
  final next = _resolve(current, location);
  return next != null && hostAllowedUrl(next.toString(), allowed: allowed) ? next : null;
}

Uri? _resolve(Uri current, String location) {
  try {
    return current.resolve(location);
  } on FormatException {
    return null;
  }
}

const _hopDroppedHeaders = {'host', 'cookie', 'content-length', 'content-type', 'content-encoding'};

/// The request for the next hop, rebuilt from [prev] the way flowspec.py rebuilds it: the same method (only GET and
/// HEAD are followed) and no body; no Host, Cookie, Content-Length or Content-Type/-Encoding carried over (the cookie
/// header is the jar's, as it now stands); no Authorization when the hop goes to another host.
http.Request _hopRequest(http.Request prev, Uri next, Map<String, String> cookies) {
  final req = http.Request(prev.method, next)..followRedirects = false;
  final crossHost = next.authority != prev.url.authority;
  prev.headers.forEach((name, value) {
    final n = name.toLowerCase();
    if (_hopDroppedHeaders.contains(n)) return;
    if (crossHost && n == 'authorization') return;
    req.headers[name] = value;
  });
  final cookieHeader = _cookieHeader(cookies);
  if (cookieHeader != null) req.headers['cookie'] = cookieHeader;
  return req;
}

/// Sends one request (one hop) and reads its answer in full. SM-12: one deadline for the whole hop - sending it,
/// waiting for the answer, and reading the body - and the failure says which of those it got to (FlowStage),
/// because that decides whether a write may have reached the server. The two phases are awaited separately for
/// exactly that reason: client.send completes once the answer's status and headers are in, so anything after it is
/// a response that really arrived. On a hop after the first ([afterRedirect]) a failure to connect is still `send`,
/// never `connect`: an earlier request in the chain was answered, so something did reach the server.
Future<http.Response> _sendHop(http.Request req, http.Client client, Duration timeout, Map<String, Object?> ctx,
    Set<String> secretKeys, String? sid, {required bool afterRedirect}) async {
  final host = req.url.host;
  final started = Stopwatch()..start();
  http.StreamedResponse streamed;
  try {
    streamed = await client.send(req).timeout(timeout);
  } on TimeoutException {
    throw _fail('no answer from $host within ${_secondsText(timeout)} s', ctx, secretKeys,
        stage: FlowStage.send, step: sid);
  } catch (ex) {
    if (!afterRedirect && _neverConnected(ex)) {
      throw _fail('cannot reach $host: ${_kind(ex)}', ctx, secretKeys, stage: FlowStage.connect, step: sid);
    }
    throw _fail('no answer from $host: ${_kind(ex)}', ctx, secretKeys, stage: FlowStage.send, step: sid);
  }
  final left = timeout - started.elapsed;
  try {
    return await http.Response.fromStream(streamed).timeout(left.isNegative ? Duration.zero : left);
  } on TimeoutException {
    throw _fail('the answer from $host did not finish arriving within ${_secondsText(timeout)} s', ctx, secretKeys,
        stage: FlowStage.response, status: streamed.statusCode, step: sid);
  } catch (ex) {
    throw _fail('the answer from $host was cut off: ${_kind(ex)}', ctx, secretKeys,
        stage: FlowStage.response, status: streamed.statusCode, step: sid);
  }
}

Future<void> _runRequest(Map<String, Object?> step, Map<String, Object?> ctx, http.Client client,
    Set<String> secretKeys, Map<String, String> cookies, Iterable<String> allowedHosts,
    [Set<String> neverRequest = const {}]) async {
  final sid = _stepId(step);
  final method = (step['method'] as String?) ?? 'GET';
  final url = _template(step['url'] as String, ctx);
  final params = _templateMap(step['params'] as Map?, ctx);
  final headers = _templateMap(step['headers'] as Map?, ctx);
  final form = step.containsKey('form') ? _templateMap(step['form'] as Map?, ctx) : null;
  // json_var names a context variable directly (NOT {{...}} templated - the value is a whole object/list, a
  // sale record list say, not a string to substitute into) and sends it as the JSON request body. Built by the
  // caller's own business logic before runFlow is invoked, passed in the same way email/password are login's
  // inputs. A step has at most one of form/json_var.
  final jsonVarName = step['json_var'] as String?;
  final jsonBody = jsonVarName != null ? ctx[jsonVarName] : null;
  final followRedirects = (step['follow_redirects'] as bool?) ?? true;
  // SL-R8: the url as written is checked before Uri.parse can throw on it or normalise it, and the built url
  // (params added) again below; nothing is sent to a host off the list.
  if (!hostAllowedUrl(url, allowed: allowedHosts)) throw _blocked(url, ctx, secretKeys, sid);
  var uri = Uri.parse(url);
  if (params.isNotEmpty) uri = uri.replace(queryParameters: params);
  if (!hostAllowedUrl(uri.toString(), allowed: allowedHosts)) throw _blocked(uri.toString(), ctx, secretKeys, sid);
  if (neverRequest.contains(_comparedHost(uri))) throw _blocked(uri.toString(), ctx, secretKeys, sid);

  var req = http.Request(method, uri)..followRedirects = false;
  // Set from the jar first so a step's own explicit `headers: {Cookie: ...}` (none currently do) can still
  // override it - same precedence as everything else a step can say about its own headers.
  final cookieHeader = _cookieHeader(cookies);
  if (cookieHeader != null) req.headers['cookie'] = cookieHeader;
  req.headers.addAll(headers);
  if (form != null) {
    req.bodyFields = form; // sets content-type: application/x-www-form-urlencoded, same as httpx's data=
  } else if (jsonVarName != null) {
    req.headers['content-type'] = 'application/json';
    req.body = jsonEncode(jsonBody);
  }

  // The timeout (SM-12) applies to each hop on its own, as httpx's does to each request it sends.
  final timeout = flowRequestTimeout(ctx);
  var hops = 0;
  http.Response resp;
  while (true) {
    resp = await _sendHop(req, client, timeout, ctx, secretKeys, sid, afterRedirect: hops > 0);
    // Merged from every hop regardless of status code - a redirect response can set cookies too, and the next
    // hop or step needs them the same way a browser or httpx.Client would carry them forward.
    _mergeSetCookies(resp, cookies);
    final location = resp.headers['location'];
    if (!followRedirects || !redirectRules(resp.statusCode, req.method) || location == null || location.isEmpty) break;
    hops++;
    if (hops > maxRedirects) {
      // Answered (a redirect loop on the state's side), not a spec mistake: the response stage, with the last status.
      throw _fail('too many redirects (more than $maxRedirects)', ctx, secretKeys,
          status: resp.statusCode, step: sid, reason: 'structure');
    }
    final next = _nextHop(req.url, location, allowedHosts);
    if (next == null) {
      // The state's answer sent it there: the response stage, with the 3xx.
      throw _blocked((_resolve(req.url, location) ?? location).toString(), ctx, secretKeys, sid,
          status: resp.statusCode);
    }
    if (neverRequest.contains(_comparedHost(next))) break; // SL-D16: not followed; the 3xx is the answer
    req = _hopRequest(req, next, cookies);
  }

  final finalUrl = req.url; // the last hop's url: what `extract source: url` reports
  // capture_on_fail: text from the failing response for the error template; '' if absent.
  void capture() => _extract((step['capture_on_fail'] as List?)?.cast<Map<String, Object?>>(), ctx, resp, finalUrl,
      fallback: '', step: sid);

  _runRequire((step['require'] as List?)?.cast<Map<String, Object?>>(), ctx, secretKeys,
      status: resp.statusCode, bodyJson: _bodyJson(resp), step: sid, beforeFail: capture);
  _extract((step['extract'] as List?)?.cast<Map<String, Object?>>(), ctx, resp, finalUrl, step: sid);
  _runRequire((step['then_require'] as List?)?.cast<Map<String, Object?>>(), ctx, secretKeys,
      status: resp.statusCode, bodyJson: _bodyJson(resp), step: sid, beforeFail: capture);
}

Map<String, String> _templateMap(Map? d, Map<String, Object?> ctx) {
  if (d == null) return const {};
  return {for (final e in d.entries) e.key as String: _template(e.value.toString(), ctx)};
}
