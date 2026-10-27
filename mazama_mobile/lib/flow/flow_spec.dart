// Parses a shared flow spec (see ../../../mazama_modules/SPEC.md) out of YAML text. Mirrors
// mazama_sales/src/mazama_sales/state/flowspec.py's load_spec: `vars` is resolved once, in file order, so a later
// var can reference an earlier one with {{name}}; `flows` is left as plain step maps for FlowRunner to execute.
import 'dart:convert' show utf8;

import 'package:yaml/yaml.dart';
// The scanner is not part of package:yaml's public API, but it is the only way to see anchors and aliases before the
// loader builds anything: the loader shares an aliased node, and its duplicate-key check hashes a key deeply, so a few
// hundred bytes of nested aliases used as a key would run for minutes inside loadYaml itself. pubspec.yaml holds yaml
// to 3.1.x (>=3.1.4) for that reason.
// ignore: implementation_imports
import 'package:yaml/src/scanner.dart' show Scanner;
// ignore: implementation_imports
import 'package:yaml/src/token.dart' show TokenType;

final _templateRe = RegExp(r'\{\{(\w+)\}\}');

String templateString(String s, Map<String, Object?> ctx) {
  return s.replaceAllMapped(_templateRe, (m) {
    final name = m.group(1)!;
    if (!ctx.containsKey(name)) {
      throw FlowSpecError('the flow spec used an unknown variable: $name');
    }
    return ctx[name].toString();
  });
}

class FlowSpecError implements Exception {
  final String message;
  FlowSpecError(this.message);
  @override
  String toString() => message;
}

/// Recursively turns YamlMap/YamlList (read-only, lazy views) into plain Map/List so the rest of the app can treat
/// a parsed spec like ordinary JSON-shaped data.
Object? _plain(Object? node) {
  if (node is YamlMap) {
    return {for (final e in node.entries) e.key.toString(): _plain(e.value)};
  }
  if (node is YamlList) {
    return node.map(_plain).toList();
  }
  return node;
}

/// The longest flow spec text read, in UTF-8 bytes (flowspec.py's MAX_SPEC_BYTES).
const maxFlowSpecBytes = 65536;

/// Refuses YAML anchors and aliases by scanning the tokens only, before anything is loaded (flowspec.py's
/// _NoAliasLoader is the twin). Text that does not even scan is refused too.
void _refuseAnchorsAndAliases(String text) {
  final scanner = Scanner(text);
  while (true) {
    final type = scanner.scan().type;
    if (type == TokenType.anchor || type == TokenType.alias) {
      throw FlowSpecError('a flow spec may not use YAML anchors or aliases');
    }
    if (type == TokenType.streamEnd) return;
  }
}

/// The spec `format` this interpreter reads (SL-R7); a spec without one is format 1. Format 2 (SL-R11-R13) adds regex
/// fallbacks (`extract.regex` as a list), conditional steps (`when`) and asking a person (`await_input`). Format 3
/// (SL-R16) adds handing the sign-in page to a person (`open_browser`, its `url_fragment`/`url_query` extracts) and the
/// `vars_equal` check. flowspec.py's SUPPORTED_FORMAT is the twin.
const supportedFlowFormat = 3;

/// Where a spec may send a request: an entry is a host, or '.suffix' for any host ending in it. The allowlist is code,
/// not spec (flowspec.py's DEFAULT_ALLOWED_HOSTS is the twin). The defaults are two exact hosts, the state's site and
/// its own B2C tenant (SL-R17): any *.b2clogin.com would let a spec send the worker's email and password to a tenant
/// anyone can create. No default entry is a suffix; the suffix rule stays for callers that pass one.
const defaultAllowedHosts = <String>['psilocybin.oregon.gov', 'oregonpsilocybinprodb2c.b2clogin.com'];

final _urlRe = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)');
final _hostRe = RegExp(r'^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$');

/// True when [url] is https, its host is allowed and nothing about the URL is ambiguous. One strict grammar read from
/// the text itself, never from Uri.parse (which throws on some of these and normalises others): no backslash anywhere
/// and no '@' in the authority; the port, if written, is exactly 443; the host, minus one trailing dot, is ASCII
/// letters, digits and hyphens in non-empty dot-separated labels (so no '%', Unicode, '..' or IPv6 literal),
/// compared in lower case. flowspec.py's host_allowed is the twin; the vectors are flows/contracts/spec_versions.json.
bool hostAllowedUrl(String url, {Iterable<String> allowed = defaultAllowedHosts}) {
  if (url.contains('\\')) return false;
  final m = _urlRe.firstMatch(url);
  if (m == null || m.group(1)!.toLowerCase() != 'https') return false;
  final authority = m.group(2)!;
  if (authority.contains('@')) return false;
  final colon = authority.indexOf(':');
  if (colon >= 0 && authority.substring(colon + 1) != '443') return false;
  var host = colon >= 0 ? authority.substring(0, colon) : authority;
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (!_hostRe.hasMatch(host)) return false;
  host = host.toLowerCase();
  for (final raw in allowed) {
    final entry = raw.toLowerCase();
    if (entry.startsWith('.')) {
      if (host.endsWith(entry) && host.length > entry.length) return true;
    } else if (host == entry) {
      return true;
    }
  }
  return false;
}

/// [hostAllowedUrl] for a parsed Uri (its text form).
bool hostAllowed(Uri url, {Iterable<String> allowed = defaultAllowedHosts}) =>
    hostAllowedUrl(url.toString(), allowed: allowed);

final _versionRe = RegExp(r'^([0-9]{4}-[0-9]{2}-[0-9]{2})\.([0-9]+)$');

/// (date, whole-number part without leading zeros), or null when [v] is missing or malformed.
(String, String)? _versionKey(String? v) {
  final m = v == null ? null : _versionRe.firstMatch(v);
  if (m == null) return null;
  final n = m.group(2)!.replaceFirst(RegExp(r'^0+'), '');
  return (m.group(1)!, n);
}

/// True when [v] is a well-formed spec_version, YYYY-MM-DD.N (flowspec.py's is_spec_version).
bool isSpecVersion(String? v) => _versionKey(v) != null;

/// -1, 0 or 1: [a] older than, equal to, or newer than [b]. YYYY-MM-DD.N, by date then by N as a whole number; a
/// missing or malformed one sorts below every valid one (flowspec.py's compare_spec_versions; the vectors are
/// flows/contracts/spec_versions.json).
int compareSpecVersions(String? a, String? b) {
  final ka = _versionKey(a);
  final kb = _versionKey(b);
  if (ka == null || kb == null) {
    if (ka == null && kb == null) return 0;
    return ka == null ? -1 : 1;
  }
  final byDate = ka.$1.compareTo(kb.$1);
  if (byDate != 0) return byDate.sign;
  if (ka.$2.length != kb.$2.length) return ka.$2.length < kb.$2.length ? -1 : 1;
  return ka.$2.compareTo(kb.$2).sign;
}

/// True when every request step's url, and every open_browser step's url and until, templated with the spec's `vars`
/// only, has an allowed https host; a host that still holds `{{` is not allowed (flowspec.py's spec_hosts_allowed).
bool specHostsAllowed(FlowSpec spec, {Iterable<String> allowed = defaultAllowedHosts}) {
  String fill(String s) => s.replaceAllMapped(_templateRe, (m) => spec.vars[m.group(1)] ?? m.group(0)!);
  bool hostOk(Object? url) => hostAllowedUrl(fill((url ?? '').toString()), allowed: allowed);
  bool ok(Object? node) {
    if (node is Map) {
      final Object? type = node['type'];
      if (type == 'request' && !hostOk(node['url'])) return false;
      if (type == 'open_browser' && !(hostOk(node['url']) && hostOk(node['until']))) return false;
      return node.values.every(ok);
    }
    if (node is List) return node.every(ok);
    return true;
  }

  return ok(spec.flows);
}

final _withPathRe = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*/');

/// An open_browser's templated `url` has no `?` (httpx drops a url's own query when it adds `params`, Dart keeps it: a
/// query goes in `params`), and its templated `until` has a path (a `/` after the authority), so `https://host` can't
/// also match `https://host.evil.example` (flowspec.py's open_browser_urls_ok is the twin).
bool openBrowserUrlsOk(String url, String until) => !url.contains('?') && _withPathRe.hasMatch(until);

/// True when every request and open_browser step's url, templated with the spec's `vars` only, has no `?`, and every
/// open_browser's until has a path ([openBrowserUrlsOk]). The usable sign-in spec rule uses this (flowspec.py's
/// spec_urls_shaped is the twin).
bool specUrlsShaped(FlowSpec spec) {
  String fill(Object? s) =>
      (s ?? '').toString().replaceAllMapped(_templateRe, (m) => spec.vars[m.group(1)] ?? m.group(0)!);
  bool ok(Object? node) {
    if (node is Map) {
      final Object? type = node['type'];
      if (type == 'request' && fill(node['url']).contains('?')) return false;
      if (type == 'open_browser' && !openBrowserUrlsOk(fill(node['url']), fill(node['until']))) return false;
      return node.values.every(ok);
    }
    if (node is List) return node.every(ok);
    return true;
  }

  return ok(spec.flows);
}

class FlowSpec {
  final Map<String, String> vars;
  final Map<String, List<Map<String, Object?>>> flows;
  final int format;

  FlowSpec(this.vars, this.flows, {this.format = 1});

  /// The spec's own `spec_version` var (login.yaml), or null.
  String? get specVersion => vars['spec_version'];

  /// Parses [yamlText]. Throws [FlowSpecError] when the text is over [maxFlowSpecBytes], is not valid YAML, uses a
  /// YAML anchor or alias, is not a mapping, names a `format` above [maxFormat] (this app's, unless a test asks for an
  /// older reader's), or has `vars` that aren't a mapping of plain values (text, numbers, true/false or null) -
  /// flowspec.py's load_spec_text is the twin.
  factory FlowSpec.fromYaml(String yamlText, {int maxFormat = supportedFlowFormat}) {
    if (utf8.encode(yamlText).length > maxFlowSpecBytes) {
      throw FlowSpecError('the flow spec is over $maxFlowSpecBytes bytes');
    }
    final Object? loaded;
    try {
      _refuseAnchorsAndAliases(yamlText);
      loaded = _plain(loadYaml(yamlText));
    } on FormatException catch (e) {
      // YamlException, and the scanner's own StringScannerException, are both FormatExceptions
      throw FlowSpecError('the flow spec is not valid YAML: ${e.message}');
    }
    if (loaded is! Map) throw FlowSpecError('the flow spec is not a mapping');
    final raw = loaded;
    final fmt = raw.containsKey('format') ? raw['format'] : 1;
    if (fmt is! int || fmt < 1) {
      throw FlowSpecError("the flow spec's format must be a positive whole number, not $fmt");
    }
    if (fmt > maxFormat) {
      throw FlowSpecError('the flow spec is format $fmt; this app reads up to format $maxFormat');
    }
    final resolved = <String, String>{};
    final rawVars = raw['vars'] ?? const <String, Object?>{};
    if (rawVars is! Map) throw FlowSpecError("the flow spec's vars must be a mapping");
    for (final entry in rawVars.entries) {
      final value = entry.value;
      if (value != null && value is! String && value is! num && value is! bool) {
        throw FlowSpecError("the flow spec's var ${entry.key} must be a plain value");
      }
      resolved[entry.key as String] = templateString(value.toString(), resolved);
    }
    final rawFlows = (raw['flows'] as Map?) ?? const {};
    final flows = <String, List<Map<String, Object?>>>{};
    for (final entry in rawFlows.entries) {
      flows[entry.key as String] = (entry.value as List).cast<Map<String, Object?>>();
    }
    return FlowSpec(resolved, flows, format: fmt);
  }
}
