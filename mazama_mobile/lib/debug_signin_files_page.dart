// Debug-only (reached from DebugToolsPage, itself kDebugMode-only): the three sign-in files the owner can fix without a
// release (login.yaml, login_browser.yaml and the signed host list hosts.json, SL-R10, SL-R18, SL-R19), side by side:
// - the copy bundled in the app (the two specs; there is no bundled host list);
// - Mazama's server's copy, through the usual clients and the server link (C17 requestLoginSpec, C19
//   requestBrowserLoginSpec, C18 requestLoginHosts), with the source the server chose ("server": deployed with it,
//   "hosted": the owner's signed copy);
// - the owner's hosted copy, read straight from the address typed on this page (the folder the files and their .sig
//   files are hosted in, e.g. a GitHub raw folder), with a plain GET: debug only, no credentials, no app key, https
//   only, a short timeout and the server's 64 KiB cap.
// Each copy is checked (it parses, its format, its spec_version against the other copies, the hosts and the usable
// sign-in spec rule in its served mode under the hosts in use; the host list rule; the signature with this build's
// key) and the specs can be tried: "Try" runs the copy's `login` exactly as SignInPage does (sign_in_attempt.dart's
// attemptSignIn, the same askSignInValue question and openBrowserSignIn page), under the hosts in use plus a verified
// host list's when "use this host list too" is ticked. A try saves nothing (no session, spec or host list, nothing put
// in use) and reports nothing. The only file this page writes is the typed address, in its own small file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:http/http.dart' as http;

import 'browser_login_spec.dart' show browserLoginSpecAsset;
import 'browser_sign_in_page.dart' show openBrowserSignIn;
import 'flow/flow_runner.dart' show FlowError;
import 'flow/flow_spec.dart';
import 'login_hosts_client.dart';
import 'login_hosts_store.dart';
import 'login_spec_client.dart';
import 'login_spec_store.dart' show ServedAs, bundledLoginSpecAsset, usableLoginSpec;
import 'session_store.dart' show defaultSessionDataDir;
import 'sign_in_attempt.dart';
import 'sign_in_prompt.dart';
import 'signing.dart';

/// How long a hosted file's GET may take.
const debugHostedFetchTimeout = Duration(seconds: 10);

/// The largest hosted file read, in bytes (the server's cap on a hosted file).
const debugHostedMaxBytes = 65536;

/// The three sign-in files, by the name each has in the hosted folder ([hostedName]).
enum SigninFile { login, browser, hosts }

String hostedName(SigninFile file) => switch (file) {
      SigninFile.login => 'login.yaml',
      SigninFile.browser => 'login_browser.yaml',
      SigninFile.hosts => 'hosts.json',
    };

/// The hosted folder typed on the page, as the base the file names are added to: an https address with a host and no
/// user info, query or fragment, ending in `/` (added when missing). Null for anything else.
Uri? hostedBaseUri(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
  return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
}

/// A hosted file's text, or why there is none.
typedef HostedFile = ({String? text, String? error});

/// GETs [url] with [client]: its text when the answer is a 200 of at most [debugHostedMaxBytes] bytes of UTF-8, else
/// the reason (the status, a redirect, the cap, no answer). No redirect is followed (the owner's raw address answers
/// itself; a redirect could leave https). The whole fetch, reading included, is held to [timeout]. Never throws.
Future<HostedFile> fetchHostedFile(http.Client client, Uri url, {Duration timeout = debugHostedFetchTimeout}) async {
  try {
    return await _fetchHostedFile(client, url).timeout(timeout);
  } on TimeoutException {
    return (text: null, error: 'no answer from ${url.host} within ${timeout.inSeconds} s');
  } on FormatException {
    return (text: null, error: 'not UTF-8');
  } catch (e) {
    return (text: null, error: 'cannot reach ${url.host}: ${e.runtimeType}');
  }
}

Future<HostedFile> _fetchHostedFile(http.Client client, Uri url) async {
  final resp = await client.send(http.Request('GET', url)..followRedirects = false);
  if (resp.statusCode >= 300 && resp.statusCode < 400) {
    return (text: null, error: 'HTTP ${resp.statusCode}: redirected (use the raw address, which answers itself)');
  }
  if (resp.statusCode != 200) return (text: null, error: 'HTTP ${resp.statusCode}');
  final bytes = <int>[];
  await for (final chunk in resp.stream) {
    bytes.addAll(chunk);
    if (bytes.length > debugHostedMaxBytes) return (text: null, error: 'over $debugHostedMaxBytes bytes');
  }
  return (text: utf8.decode(bytes), error: null);
}

/// Where the page keeps the typed hosted address: `debug_signin_files.json` in the app's data folder. Never throws.
class DebugSigninAddressStore {
  /// Overridable for tests, as SessionStore.dataDir.
  final Directory Function() dataDir;

  const DebugSigninAddressStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  File get _file => File('${dataDir().path}/debug_signin_files.json');

  /// The address saved, or null (none, or unreadable).
  String? load() {
    try {
      if (!_file.existsSync()) return null;
      final Object? saved = jsonDecode(_file.readAsStringSync());
      final Object? base = saved is Map ? saved['base'] : null;
      return base is String ? base : null;
    } catch (_) {
      return null;
    }
  }

  /// Keeps [base]; false when it can't be written.
  bool save(String base) {
    try {
      dataDir().createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode({'base': base}), flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// One line of a copy's checks: [ok] true (passed), false (failed) or null (for information).
class SigninFileCheck {
  final String label;
  final bool? ok;
  const SigninFileCheck(this.label, this.ok);
}

/// The first line of an error's text, at most 160 characters (an error never shows more of a file than that).
String _firstLine(Object e) {
  final text = (e is FlowSpecError ? e.message : e is FormatException ? e.message : '${e.runtimeType}').split('\n').first;
  return text.length > 160 ? '${text.substring(0, 160)}...' : text;
}

/// The spec_version of a spec [text], or null.
String? _specVersionOf(String text) {
  try {
    return FlowSpec.fromYaml(text, maxFormat: 1 << 20).specVersion;
  } catch (_) {
    return null;
  }
}

/// The version of a host list [text], or null.
String? _listVersionOf(String text) {
  try {
    return parseHostList(text).$1;
  } catch (_) {
    return null;
  }
}

/// How [version] compares with each of [others] (copy name -> its version), one information line each.
List<SigninFileCheck> versionComparisons(String? version, Map<String, String?> others) => [
      for (final MapEntry(key: where, value: other) in others.entries)
        if (other != null) SigninFileCheck('${_relation(compareSpecVersions(version, other))} the $where copy ($other)', null),
    ];

String _relation(int compared) => compared > 0
    ? 'newer than'
    : compared == 0
        ? 'same as'
        : 'older than';

/// The checks of a sign-in spec copy's [text] in the [served] mode: it parses, its format is one this app reads, its
/// spec_version (and how it compares with [others]), its hosts are among [inUse] (the hosts in use), it is a usable
/// sign-in spec as served under [inUse]; and, when not and [withLists] (the hosts in use plus every verified host
/// list's) has more, whether it is under those.
List<SigninFileCheck> specChecks(String text, ServedAs served,
    {required List<String> inUse, required List<String> withLists, Map<String, String?> others = const {}}) {
  final FlowSpec spec;
  try {
    spec = FlowSpec.fromYaml(text, maxFormat: 1 << 20); // the format is its own line below
  } catch (e) {
    return [SigninFileCheck('does not parse: ${_firstLine(e)}', false)];
  }
  final version = spec.specVersion;
  final checks = <SigninFileCheck>[
    const SigninFileCheck('parses', true),
    SigninFileCheck('format ${spec.format} (this app reads up to $supportedFlowFormat)', spec.format <= supportedFlowFormat),
    SigninFileCheck('spec_version ${version ?? '(none)'}', isSpecVersion(version)),
    ...versionComparisons(version, others),
  ];
  final hostsOk = specHostsAllowed(spec, allowed: inUse);
  checks.add(SigninFileCheck(hostsOk ? 'hosts allowed (the hosts in use)' : 'a host is not among the hosts in use', hostsOk));
  final usable = usableLoginSpec(text, allowedHosts: inUse, served: served) != null;
  checks.add(SigninFileCheck(
      usable ? 'usable as served (${served.name})' : 'not a usable sign-in spec as served (${served.name})', usable));
  if (!usable && withLists.length > inUse.length) {
    final usableWith = usableLoginSpec(text, allowedHosts: withLists, served: served) != null;
    checks.add(SigninFileCheck(
        usableWith ? "usable with the verified host lists' hosts too" : "not usable with the verified host lists' hosts either",
        usableWith));
  }
  return checks;
}

/// The checks of a host list copy's [text]: it follows the host list rule (parseHostList), its version (and how it
/// compares with [others]) and its hosts.
List<SigninFileCheck> hostListChecks(String text, {Map<String, String?> others = const {}}) {
  try {
    final (version, hosts) = parseHostList(text);
    return [
      const SigninFileCheck('parses and follows the host list rule', true),
      SigninFileCheck('version $version', null),
      ...versionComparisons(version, others),
      SigninFileCheck('hosts: ${hosts.isEmpty ? '(none)' : hosts.join(', ')}', null),
    ];
  } on FormatException catch (e) {
    return [SigninFileCheck('host list rule: ${_firstLine(e)}', false)];
  }
}

/// The signature check of [text] with [signature] (a `.sig` text; null when there is none, [missing] saying why)
/// under [publicKey] (this build's `signing.pub` text).
Future<SigninFileCheck> signatureCheck(String text, String? signature, String? publicKey, {String? missing}) async {
  if (publicKeyBytes(publicKey) == null) {
    return SigninFileCheck(
        publicKey?.trim() == noSigningKey ? 'signature: no key in this build' : 'signature: no usable key in this build',
        false);
  }
  if (signature == null) return SigninFileCheck('signature: no .sig file (${missing ?? 'missing'})', false);
  final ok = await verifySigned(utf8.encode(text), signature, publicKey: publicKey);
  return SigninFileCheck(
      ok ? "signature: verified with this build's key" : "signature: does not verify with this build's key", ok);
}

/// One copy of one file, as the page shows it.
class _Copy {
  _Copy(this.file, this.id, this.where);

  final SigninFile file;

  /// `bundled`, `server` or `hosted` (keys in tests).
  final String id;

  /// What the page calls it: "Bundled", "Mazama server", "Hosted".
  final String where;

  String? text;
  String? error;
  final notes = <String>[];
  var checks = <SigninFileCheck>[];

  /// A host list copy that verified: what "use this host list too" adds.
  HostList? verified;
  bool useHosts = false;

  bool trying = false;
  String? tryResult;
}

class DebugSigninFilesPage extends StatefulWidget {
  const DebugSigninFilesPage({
    super.key,
    this.addressStore = const DebugSigninAddressStore(),
    this.fetchServerSpec,
    this.fetchServerBrowserSpec,
    this.fetchServerHosts,
    this.hostedClient,
    this.stateClient,
    this.bundle,
    this.publicKey,
    this.ask,
    this.browse,
  });

  /// Where the typed hosted address is kept.
  final DebugSigninAddressStore addressStore;

  /// C17, given the hosts the reply is held to; null means requestLoginSpec (the server link).
  final Future<FetchedSpec> Function(Iterable<String> allowedHosts)? fetchServerSpec;

  /// C19, as [fetchServerSpec]; null means requestBrowserLoginSpec.
  final Future<FetchedSpec> Function(Iterable<String> allowedHosts)? fetchServerBrowserSpec;

  /// C18; null means requestLoginHosts.
  final Future<LoginHostsReply> Function()? fetchServerHosts;

  /// Makes the client the hosted files are read with; null means a plain http.Client().
  final http.Client Function()? hostedClient;

  /// Makes the client a "Try" runs the sign-in with; null means a plain http.Client(), as SignInPage uses.
  final http.Client Function()? stateClient;

  /// Where the bundled specs and signing.pub are read; null means the app's own.
  final AssetBundle? bundle;

  /// The `signing.pub` text the signatures are checked with; null means the bundled one. Tests pass a TEST key.
  final String? publicKey;

  /// Answers a spec's `await_input` question; null means askSignInValue's dialog, as SignInPage.
  final Future<String?> Function(String prompt, bool secret)? ask;

  /// Shows the state's page for an `open_browser`; null means openBrowserSignIn, as SignInPage.
  final Future<String?> Function(String url, String until)? browse;

  @override
  State<DebugSigninFilesPage> createState() => _DebugSigninFilesPageState();
}

class _DebugSigninFilesPageState extends State<DebugSigninFilesPage> {
  late final _baseController = TextEditingController(text: widget.addressStore.load() ?? '');
  bool _fetching = false;
  String? _addressError;
  Map<SigninFile, List<_Copy>> _copies = const {};

  @override
  void dispose() {
    _baseController.dispose();
    super.dispose();
  }

  AssetBundle get _bundle => widget.bundle ?? rootBundle;

  List<_Copy> get _hostCopies => _copies[SigninFile.hosts] ?? const <_Copy>[];

  /// The hosts in use plus the extra hosts of [lists] (each verified).
  static List<String> _hostsWith(Iterable<HostList?> lists) {
    final hosts = [...currentAllowedHosts()];
    for (final list in lists) {
      for (final h in list?.extra ?? const <String>[]) {
        if (!hosts.contains(h)) hosts.add(h);
      }
    }
    return hosts;
  }

  /// The hosts a "Try" runs under: the hosts in use plus each ticked, verified host list's.
  List<String> _tryHosts() => _hostsWith([for (final c in _hostCopies) if (c.useHosts) c.verified]);

  Future<void> _fetch() async {
    final typed = _baseController.text.trim();
    final base = hostedBaseUri(typed);
    setState(() {
      _fetching = true;
      _addressError = typed.isNotEmpty && base == null ? 'The hosted address must be an https address' : null;
    });
    if (base != null) widget.addressStore.save(base.toString());
    final client = widget.hostedClient?.call() ?? http.Client();
    try {
      final key = widget.publicKey ?? await bundledPublicKey(bundle: widget.bundle);
      final serverHosts = await _serverHosts(key);
      final hostedHosts = await _hosted(client, base, SigninFile.hosts, key);
      final withLists = _hostsWith([serverHosts.verified, hostedHosts.verified]);
      final copies = <SigninFile, List<_Copy>>{SigninFile.hosts: [serverHosts, hostedHosts]};
      for (final (file, asset, served) in [
        (SigninFile.login, bundledLoginSpecAsset, ServedAs.login),
        (SigninFile.browser, browserLoginSpecAsset, ServedAs.browser),
      ]) {
        final bundled = await _bundledSpec(file, asset);
        final server = await _serverSpec(file, withLists);
        final hosted = await _hosted(client, base, file, key);
        final all = [bundled, server, hosted];
        for (final c in all) {
          final text = c.text;
          if (text == null) continue;
          final others = {
            for (final o in all)
              if (o != c && o.text != null) o.where.toLowerCase(): _specVersionOf(o.text!),
          };
          c.checks = [
            ...specChecks(text, served, inUse: currentAllowedHosts(), withLists: withLists, others: others),
            ...c.checks, // the signature line, set while fetching
          ];
        }
        copies[file] = all;
      }
      for (final c in [serverHosts, hostedHosts]) {
        final text = c.text;
        if (text == null) continue;
        final others = {
          for (final o in [serverHosts, hostedHosts])
            if (o != c && o.text != null) o.where.toLowerCase(): _listVersionOf(o.text!),
        };
        c.checks = [...hostListChecks(text, others: others), ...c.checks];
      }
      if (mounted) setState(() => _copies = copies);
    } finally {
      client.close();
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<_Copy> _bundledSpec(SigninFile file, String asset) async {
    final c = _Copy(file, 'bundled', 'Bundled');
    try {
      c.text = await _bundle.loadString(asset, cache: false);
      c.notes.add(asset);
      c.checks = [const SigninFileCheck('signature: not needed (shipped inside the app)', null)];
    } catch (e) {
      c.error = 'cannot read $asset (${e.runtimeType})';
    }
    return c;
  }

  Future<_Copy> _serverSpec(SigninFile file, List<String> allowedHosts) async {
    final c = _Copy(file, 'server', 'Mazama server');
    final fetch = file == SigninFile.login
        ? (widget.fetchServerSpec ?? (Iterable<String> hosts) => requestLoginSpec(allowedHosts: hosts))
        : (widget.fetchServerBrowserSpec ?? (Iterable<String> hosts) => requestBrowserLoginSpec(allowedHosts: hosts));
    try {
      final fetched = await fetch(allowedHosts);
      c.text = fetched.yaml;
      final what = fetched.source == 'hosted' ? "the owner's hosted copy" : 'the copy deployed with the server';
      c.notes.add('source: ${fetched.source} ($what), specVersion ${fetched.spec.specVersion ?? '(none)'}');
      c.checks = [
        fetched.source == 'hosted'
            ? const SigninFileCheck('signature: the server verified it', null)
            : const SigninFileCheck("signature: the server's own copy (needs no signature)", null),
      ];
    } on LoginSpecError catch (e) {
      c.error = 'the server did not give one: ${e.message}';
    } catch (e) {
      c.error = 'the server did not give one (${e.runtimeType})';
    }
    return c;
  }

  Future<_Copy> _serverHosts(String? key) async {
    final c = _Copy(SigninFile.hosts, 'server', 'Mazama server');
    try {
      final fetchHosts = widget.fetchServerHosts ?? () => requestLoginHosts();
      final reply = await fetchHosts();
      final list = reply.list;
      if (list == null) {
        c.error = 'the server has no host list';
        return c;
      }
      c.text = list;
      c.notes.add('version in the reply: ${reply.version}');
      c.checks = [
        await signatureCheck(list, reply.signature, key),
        if (_listVersionOf(list) != reply.version) const SigninFileCheck("the reply's version is not the list's own", false),
      ];
      final verified = key == null ? null : await verifiedHostList(list, reply.signature ?? '', publicKey: key);
      c.verified = verified != null && verified.version == reply.version ? verified : null;
    } on LoginHostsError catch (e) {
      c.error = 'the server did not give one: ${e.message}';
    } catch (e) {
      c.error = 'the server did not give one (${e.runtimeType})';
    }
    return c;
  }

  /// The hosted copy of [file] and its .sig; the signature line is the copy's only check so far.
  Future<_Copy> _hosted(http.Client client, Uri? base, SigninFile file, String? key) async {
    final c = _Copy(file, 'hosted', 'Hosted');
    if (base == null) {
      c.error = 'no hosted address typed';
      return c;
    }
    final url = base.resolve(hostedName(file));
    c.notes.add('$url');
    final got = await fetchHostedFile(client, url);
    final text = got.text;
    if (text == null) {
      c.error = 'cannot read it: ${got.error}';
      return c;
    }
    c.text = text;
    final sig = await fetchHostedFile(client, base.resolve('${hostedName(file)}.sig'));
    c.checks = [await signatureCheck(text, sig.text, key, missing: sig.error)];
    final sigText = sig.text;
    if (file == SigninFile.hosts && key != null && sigText != null) {
      c.verified = await verifiedHostList(text, sigText, publicKey: key);
    }
    return c;
  }

  /// SignInPage's question dialog, unless a test gives its own.
  Future<String?> _ask(String prompt, bool secret) async {
    final ask = widget.ask;
    if (ask != null) return ask(prompt, secret);
    if (!mounted) return null;
    final answer = await askSignInValue(context, prompt, secret: secret);
    return mounted ? answer : null;
  }

  /// SignInPage's state page, held to [allowedHosts], unless a test gives its own.
  Future<String?> _browse(String url, String until, Iterable<String> allowedHosts) async {
    final browse = widget.browse;
    if (browse != null) return browse(url, until);
    if (!mounted) return null;
    final ended = await openBrowserSignIn(context, url, until, allowed: allowedHosts);
    return mounted ? ended : null;
  }

  /// Runs [c]'s `login` (a password sign-in for login.yaml after asking for an email and password, the sign-in on the
  /// state's page for login_browser.yaml) under [_tryHosts], and shows how it ended. Nothing is saved or reported.
  Future<void> _try(_Copy c) async {
    final text = c.text;
    if (text == null) return;
    final browser = c.file == SigninFile.browser;
    ({String email, String password})? credentials;
    if (!browser) {
      credentials = await showDialog<({String email, String password})>(
          context: context, builder: (_) => const _CredentialsDialog());
      if (credentials == null || !mounted) return;
    }
    final hosts = _tryHosts();
    final spec = usableLoginSpec(text, allowedHosts: hosts, served: browser ? ServedAs.browser : ServedAs.login);
    if (spec == null) {
      setState(() => c.tryResult = 'Not tried: this copy is not a usable sign-in spec under the hosts of this try.');
      return;
    }
    setState(() {
      c.trying = true;
      c.tryResult = null;
    });
    final client = widget.stateClient?.call() ?? http.Client();
    String result;
    try {
      final session = credentials == null
          ? await attemptSignIn(spec, const <String, Object?>{}, '', client,
              allowedHosts: hosts, browse: (url, until) => _browse(url, until, hosts))
          : await attemptSignIn(spec, {'email': credentials.email, 'password': credentials.password}, credentials.email,
              client,
              allowedHosts: hosts, ask: _ask);
      final minutes = ((session.expiresAtMs - DateTime.now().millisecondsSinceEpoch) / 60000).round();
      result = 'Signed in, token expires in $minutes minutes. Nothing was saved.';
    } on FlowError catch (e) {
      // FlowError messages are already scrubbed of the email, password and tokens (flow_runner.dart).
      result = 'Failed at step ${e.step ?? '(none)'}, reason ${e.reason ?? '(none)'}: ${e.message}';
    } catch (e) {
      result = 'Did not finish (${e.runtimeType}).';
    } finally {
      client.close();
    }
    if (mounted) {
      setState(() {
        c.trying = false;
        c.tryResult = result;
      });
    }
  }

  void _view(_Copy c) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${hostedName(c.file)} (${c.where})'),
        content: SingleChildScrollView(
          child: SelectableText(c.text ?? '', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
      ),
    );
  }

  Widget _check(SigninFileCheck check) {
    final ok = check.ok;
    final icon = ok == null
        ? const Icon(Icons.info_outline, size: 18)
        : ok
            ? const Icon(Icons.check_circle, size: 18, color: Colors.green)
            : const Icon(Icons.cancel, size: 18, color: Colors.red);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        icon,
        const SizedBox(width: 6),
        Expanded(child: Text(ok == false ? 'FAIL: ${check.label}' : check.label)),
      ]),
    );
  }

  Widget _copyCard(_Copy c) {
    final error = c.error;
    final tryResult = c.tryResult;
    final tryLabel = switch (c.file) {
      SigninFile.login => 'Try password sign-in with this copy',
      SigninFile.browser => "Try sign-in on the state's page with this copy",
      SigninFile.hosts => null,
    };
    return Card(
      key: ValueKey('copy-${c.file.name}-${c.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(c.where, style: Theme.of(context).textTheme.titleSmall),
          for (final note in c.notes) Text(note),
          if (error != null) Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          for (final check in c.checks) _check(check),
          if (c.text != null)
            Wrap(spacing: 8, children: [
              OutlinedButton(
                  key: ValueKey('view-${c.file.name}-${c.id}'), onPressed: () => _view(c), child: const Text('View')),
              if (tryLabel != null)
                OutlinedButton(
                  key: ValueKey('try-${c.file.name}-${c.id}'),
                  onPressed: c.trying || _fetching ? null : () => _try(c),
                  child: Text(tryLabel),
                ),
            ]),
          if (c.file == SigninFile.hosts && c.text != null)
            CheckboxListTile(
              key: ValueKey('use-hosts-${c.id}'),
              contentPadding: EdgeInsets.zero,
              title: const Text('use this host list too'),
              subtitle: c.verified == null ? const Text('only a host list that verified can be used') : null,
              value: c.useHosts,
              onChanged: c.verified == null ? null : (v) => setState(() => c.useHosts = v ?? false),
            ),
          if (c.trying) const LinearProgressIndicator(),
          if (tryResult != null) Text(tryResult, key: ValueKey('try-result-${c.file.name}-${c.id}')),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final addressError = _addressError;
    return Scaffold(
      appBar: AppBar(title: const Text('Sign-in files (debug)')),
      // a Column, not a lazy list: every card is built (and findable in tests)
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: const ValueKey('hosted-base'),
            controller: _baseController,
            decoration: InputDecoration(
              labelText: 'Hosted folder (https, e.g. a GitHub raw folder)',
              errorText: addressError,
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('fetch'),
            onPressed: _fetching ? null : _fetch,
            child: _fetching
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Fetch'),
          ),
          Text('Hosts in use: ${currentAllowedHosts().join(', ')}'),
          for (final file in SigninFile.values)
            if (_copies[file] != null) ...[
              const Divider(),
              Text(hostedName(file), style: Theme.of(context).textTheme.titleMedium),
              for (final c in _copies[file]!) _copyCard(c),
            ],
        ]),
      ),
    );
  }
}

/// The email and password a password "Try" signs in with; null when cancelled.
class _CredentialsDialog extends StatefulWidget {
  const _CredentialsDialog();

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

class _CredentialsDialogState extends State<_CredentialsDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Try password sign-in'),
      scrollable: true,
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          key: const ValueKey('try-email'),
          controller: _email,
          decoration: const InputDecoration(labelText: 'Email'),
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
        ),
        TextField(
          key: const ValueKey('try-password'),
          controller: _password,
          decoration: const InputDecoration(labelText: 'Password'),
          obscureText: true,
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('try-go'),
          onPressed: () => Navigator.of(context).pop((email: _email.text.trim(), password: _password.text)),
          child: const Text('Sign in'),
        ),
      ],
    );
  }
}
