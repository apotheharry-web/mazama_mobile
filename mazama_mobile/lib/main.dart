// The real first screen: sign in against the Oregon state system using the shared login flow spec
// (assets/flows/login.yaml, a copy of ../mazama_modules/flows/login.yaml kept in sync by tool/sync_flows.sh) through
// lib/flow/flow_runner.dart - the same interpreter proven equivalent to the server's StateSession._login/_renew in
// test/flow/flow_runner_test.dart, now wired up to a real network client instead of the test fake. On success,
// hands off to SelectCenterPage (select_center_page.dart), which asks the real state system which service
// center(s) this account can act for and lands on CartPage for whichever one the worker opens.
//
// On every launch, MazamaApp itself checks for a session saved by a previous run (session_store.dart) before
// ever showing this sign-in form - see its own _resolveHome for exactly what that does and doesn't cover.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'browser_login_spec.dart';
import 'browser_sign_in_page.dart';
import 'cart_timer_widget.dart';

import 'demo/demo_backend.dart';
import 'demo/demo_banner.dart';
import 'device_id.dart';
import 'flow/flow_runner.dart';
import 'flow/flow_spec.dart';
import 'login_hosts_client.dart';
import 'login_hosts_store.dart';
import 'login_spec_client.dart';
import 'login_spec_store.dart';
import 'open_source_link.dart';
import 'resilience_options.dart';
import 'select_center_page.dart';
import 'server_link.dart';
import 'session.dart';
import 'session_store.dart';
import 'sign_in_attempt.dart';
import 'sign_in_prompt.dart';
import 'signin_failure_client.dart';

Future<void> main() async {
  // Must resolve before anything else touches SessionStore/CartStore/DeviceIdStore - see initAppDataDir's own
  // comment in session_store.dart for why (path_provider is the only portable way to find this app's real,
  // sandboxed storage directory on Android/iOS; without this, those stores fall back to an unreliable guess).
  WidgetsFlutterBinding.ensureInitialized();
  await initAppDataDir();
  // Where a build-specific offline-resilience tweak goes (resilience_options.dart's own file comment) - e.g.
  // `const MazamaApp(resilienceOptions: ResilienceOptions(cacheMaxAge: Duration(days: 1)))` for a build that
  // wants a tighter cache window. Left at the default here, same as every call site before this existed.
  runApp(const MazamaApp());
}

/// Sends the worker back to a fresh sign-in, clearing whatever session was stored - the one path both
/// SelectCenterPage and CartPage use when ensureFreshSession gives up (no refresh token, or the state system
/// refused the one there was). Pulling this all the way out to the top means neither page has to duplicate the
/// "clear storage, replace the whole nav stack" sequence or risk leaving it half-done.
/// DM-D2: the demo sign-in is user `guest` (trimmed, any case) with password `guest` exactly.
bool isDemoSignIn(String email, String password) => email.trim().toLowerCase() == 'guest' && password == 'guest';

Future<void> goToSignIn(BuildContext context,
    {required FlowSpec spec, required SessionStore sessionStore, String? message}) async {
  await sessionStore.clear();
  // A signed-out phone shows no center's carts on its home screen (MC-D15), however it came to be signed out.
  unawaited(const CartTimerWidget().clear());
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => SignInPage(spec: spec, sessionStore: sessionStore, message: message)),
    (route) => false,
  );
}

class MazamaApp extends StatefulWidget {
  final SessionStore sessionStore;

  /// The one place this app's offline-resilience behavior is actually configured - constructed here, before
  /// this widget (or anything under it) exists, and threaded down through every SignInPage/SelectCenterPage/
  /// CartPage this app ever opens. See resilience_options.dart's own file comment for what it controls.
  /// Defaults to `const ResilienceOptions()` - today's behavior - so a build that doesn't need to change it
  /// doesn't have to know this field exists.
  final ResilienceOptions resilienceOptions;

  /// The app's one link to Mazama's server (server_link.dart, README R56): the server tracker behind the banner above
  /// every page, the outbox and the catch-up work. Null (the app) builds the real one in [sessionStore]'s folder;
  /// tests pass their own.
  final ServerLink? serverLink;

  const MazamaApp(
      {super.key, this.sessionStore = const SessionStore(), this.resilienceOptions = const ResilienceOptions(), this.serverLink});

  @override
  State<MazamaApp> createState() => _MazamaAppState();
}

class _MazamaAppState extends State<MazamaApp> with WidgetsBindingObserver {
  late final Future<Widget> _homeFuture = _resolveHome();

  /// The app's server link, made the app-wide one ([useServerLink]) before any page can call a /p/ route.
  late final ServerLink _link;

  @override
  void initState() {
    super.initState();
    _link = widget.serverLink ?? ServerLink.standard(dataDir: widget.sessionStore.dataDir, sessionStore: widget.sessionStore);
    useServerLink(_link);
    WidgetsBinding.instance.addObserver(this);
    _link.wake(); // anything a previous run left waiting, if the server answers
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _link.onForeground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    releaseServerLink(_link);
    if (widget.serverLink == null) _link.dispose();
    super.dispose();
  }

  /// Decides what the worker sees first: if a previous run's session is on disk AND is either still fresh or
  /// renewable, skip straight to SelectCenterPage with it - that's the whole point of session_store.dart. Any
  /// other case (nothing stored, or ensureFreshSession gives up) falls back to a real sign-in, after clearing
  /// whatever unusable session was on disk so the next launch doesn't repeat the same failed renew attempt.
  ///
  /// Final review I1: never throws (a throw would leave the FutureBuilder's spinner up for good). When the spec in use
  /// is one saved from the server and deciding with it fails any other way than the two Session exceptions (or with
  /// SessionSpecUnusable, the spec's own failure), that spec is set aside (LoginSpecStore.quarantine) and the decision
  /// made again with the bundled one; whatever else goes wrong lands on the sign-in page.
  Future<Widget> _resolveHome() async {
    final specStore = LoginSpecStore(dataDir: widget.sessionStore.dataDir);
    final String bundledYaml;
    final ({FlowSpec spec, bool saved}) choice;
    try {
      // SL-R18: the saved signed host list (verified again; none, the built-in hosts only, when there is none or it no
      // longer verifies) is put in use before any spec is checked or flow run: the saved spec, renew, every read.
      useLoginHosts(await LoginHostsStore(dataDir: widget.sessionStore.dataDir).load());
      // SL-R9: the newer valid one of the bundled spec and one saved from the server (login_spec_store.dart).
      bundledYaml = await rootBundle.loadString(bundledLoginSpecAsset);
      choice = await specStore.choose(bundledYaml);
    } catch (e) {
      return _specLoadFailed(e);
    }
    if (choice.saved) {
      try {
        return await _homeWith(choice.spec, savedSpec: true);
      } catch (_) {
        specStore.quarantine();
        final FlowSpec bundled;
        try {
          bundled = FlowSpec.fromYaml(bundledYaml);
        } catch (e) {
          return _specLoadFailed(e);
        }
        return _homeOrSignIn(bundled);
      }
    }
    return _homeOrSignIn(choice.spec);
  }

  Widget _specLoadFailed(Object e) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load the sign-in flow: $e'),
          ),
        ),
      );

  SignInPage _signInPage(FlowSpec spec) =>
      SignInPage(spec: spec, sessionStore: widget.sessionStore, resilienceOptions: widget.resilienceOptions);

  /// [_homeWith] for a spec that is not a saved one: anything it throws lands on the sign-in page, not a spinner.
  Future<Widget> _homeOrSignIn(FlowSpec spec) async {
    try {
      return await _homeWith(spec, savedSpec: false);
    } catch (_) {
      return _signInPage(spec);
    }
  }

  /// The first page for [spec]: SelectCenterPage with the stored session when it is fresh or can't be renewed just
  /// now, else the sign-in page. With [savedSpec], a SessionSpecUnusable is thrown on to [_resolveHome] (which sets
  /// the saved spec aside) instead of clearing the session: the session may be fine, the spec is what failed.
  Future<Widget> _homeWith(FlowSpec spec, {required bool savedSpec}) async {
    final stored = Session.fromJson(await widget.sessionStore.load());
    if (stored != null) {
      final client = http.Client();
      try {
        final fresh = await ensureFreshSession(stored, spec, client: client);
        await widget.sessionStore.save(fresh.toJson());
        return SelectCenterPage(
          session: fresh,
          spec: spec,
          sessionStore: widget.sessionStore,
          resilienceOptions: widget.resilienceOptions,
        );
      } on SessionSpecUnusable {
        if (savedSpec) rethrow;
        await widget.sessionStore.clear();
      } on SessionExpired {
        await widget.sessionStore.clear();
      } on SessionRenewalUnavailable {
        // The state system just can't be reached right now - the stored session on disk is still good, so
        // don't throw it away or force a real sign-in over what might be a momentary outage or bad wifi at
        // launch. Hand the worker straight to SelectCenterPage with what's on disk; its own
        // _ensureFreshThenFetch runs this exact same renewal check again and surfaces a plain, retryable error
        // there if the state is still unreachable, the same way any other fetch failure on that page already
        // does - never by clearing the session or bouncing back here.
        return SelectCenterPage(
          session: stored,
          spec: spec,
          sessionStore: widget.sessionStore,
          resilienceOptions: widget.resilienceOptions,
        );
      } finally {
        client.close();
      }
    }
    return _signInPage(spec);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mazama',
      // DM-R5: "Demo: nothing here is real" above every page while the demo is open; under it, while Mazama's server
      // can't be reached (and never in the demo), the server link's banner (README R56).
      builder: (context, child) => demoBannerBuilder(context, ServerLinkBanner(link: _link, child: child ?? const SizedBox.shrink())),
      home: FutureBuilder<Widget>(
        future: _homeFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData) return snapshot.data!;
          // "Still loading". _resolveHome never throws (every failure inside it becomes a page: final review I1).
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        },
      ),
    );
  }
}

/// SL-R5: what the sign-in page shows when the state's sign-in page no longer looks the way login.yaml expects
/// (a check with reason `structure` failed), instead of the check's own technical message.
const stateSigninChangedMessage = "The state's sign-in has changed. Mazama has been told.";

/// SL-R13: what the sign-in page shows when the worker cancelled (or left empty) a question the sign-in spec asked
/// (reason `cancelled`). Not reported, and no newer spec is looked for: nothing went wrong.
const signInCancelledMessage = 'Sign-in cancelled.';

/// SL-R16: what the sign-in page shows when the sign-in on the state's own page didn't end with a session for a
/// reason that isn't the worker's or the state page's own refusal (the page answered another sign-in, returned no
/// code, the token request gave no token). Not reported; a newer browser spec is looked for first (SL-R19).
const browserSigninUnfinishedMessage = "The state's page didn't finish signing in. Try again, or tell Mazama.";

/// SL-R16: added under the message when a password sign-in failed because the state's sign-in has changed
/// (`structure`) or needs a person (`needs_person`), the cases the sign-in on the state's own page is for.
const browserSigninSuggestion = "You can sign in on the state's page instead.";

/// The Email field's message when it is left empty: for the password sign-in, and for "Sign in on the state's page",
/// where the app still needs the worker's email (the state's page doesn't say who signed in) for their notifications
/// and to put their name on their sales.
const emailRequiredMessage = 'Enter your email';
const browserEmailRequiredMessage = 'Enter an email address to receive notifications';

/// SL-R18: the note over the next page after a sign-in that a signed host list just fetched from Mazama's server
/// enabled: the list is kept, and the hosts it adds to the app's own are allowed from now on, so a host the owner
/// didn't sign is seen (SL-D13's mitigation). Worded as what is allowed, not what was used: the retry may not have
/// needed every host the list adds.
String newSigninHostsMessage(List<String> hosts) => "Sign-in now also allows: ${hosts.join(', ')}";

/// SL-R18: shown under a failed retry that ran with the hosts a newly fetched list adds (nothing was kept).
String retrySigninHostsMessage(List<String> hosts) => "The retry also allowed: ${hosts.join(', ')}";

/// SL-R5: told about every failed sign-in except a wrong email or password (reason `credentials`), with the login
/// spec's `spec_version`. SignInPage calls it fire-and-forget: whatever it does, returns or throws never delays or
/// changes what the page shows.
typedef SigninFailureReporter = Future<void> Function(FlowError error, String? specVersion);

/// The reporter SignInPage uses when none is given: this install's device id and the failure's step, stage,
/// status and reason, posted to /p/signin-failure (signin_failure_client.dart). Never an email, password or token,
/// and only fixed words: the step only when it is a step id of the app's bundled sign-in specs (else "other"), the
/// reason only when it is one of reportedSigninReasons (else null), whatever spec ran (postSigninFailureFor).
Future<void> defaultSigninFailureReporter(FlowError error, String? specVersion) async {
  final deviceId = await const DeviceIdStore().idOrCreate();
  await postSigninFailureFor(
    error,
    deviceId: deviceId,
    bundledSteps: await bundledSigninStepIds(),
    specVersion: specVersion,
  );
}

class SignInPage extends StatefulWidget {
  final FlowSpec spec;
  final SessionStore sessionStore;

  /// A one-time message to show above the form - used when something upstream (ensureFreshSession, mid-cart
  /// renewal) sent the worker back here rather than them choosing to sign out themselves, so they understand
  /// why they're looking at this screen again instead of the cart they were just in.
  final String? message;

  /// Forwarded straight through to the SelectCenterPage _submit() opens on a successful sign-in - same
  /// reasoning as CartPage's own field by this name. Defaults to `const ResilienceOptions()`, same as every
  /// other call site.
  final ResilienceOptions resilienceOptions;

  /// SL-R5: told about failed sign-ins (see SigninFailureReporter); null means defaultSigninFailureReporter.
  /// Injected by tests so nothing is posted or written to disk.
  final SigninFailureReporter? reportSigninFailure;

  /// SL-R10: asks for the newest sign-in spec after a failed sign-in (not `credentials`); null means fetchLoginSpec
  /// (Mazama's server, through the server link). Answers null when there is none to be had.
  final Future<FetchedSpec?> Function()? fetchSpec;

  /// SL-R10: where a newer spec that just signed in is kept; null means a LoginSpecStore in the session store's
  /// folder, the one MazamaApp._resolveHome reads at start-up.
  final LoginSpecStore? specStore;

  /// SL-R18: asks for the owner's signed host list, alongside [fetchSpec], and answers it only when it verifies
  /// against the bundled key; null means fetchLoginHosts (Mazama's server, through the server link). Answers null
  /// when there is none to be had.
  final Future<HostList?> Function()? fetchHosts;

  /// SL-R18: where a host list that just enabled a sign-in is kept; null means a LoginHostsStore in the session
  /// store's folder, the one MazamaApp._resolveHome reads at start-up.
  final LoginHostsStore? hostsStore;

  /// SL-R13: answers a sign-in spec's `await_input` question (prompt, secret) - an MFA code, say - or null when the
  /// worker cancelled; null means askSignInValue's dialog. Handed to runFlow on the first attempt and on the SL-D11
  /// retry, never to renew (nobody is there to ask).
  final Future<String?> Function(String prompt, bool secret)? ask;

  /// SL-R16: shows the state's own sign-in page at a URL and answers the URL it ended at (starting with `until`), or
  /// null when the worker closed it; null means openBrowserSignIn (the webview page). Injected by tests.
  final Future<String?> Function(String url, String until)? browse;

  /// SL-R16: the browser sign-in spec; null means loadBrowserLoginSpec (the newer of the bundled assets/flows_phone/
  /// copy and one kept in [browserSpecStore], SL-R19).
  final Future<FlowSpec> Function()? browserSpec;

  /// SL-R19: asks for the newest browser sign-in spec after a failed browser sign-in (not `cancelled`/`credentials`);
  /// null means fetchBrowserLoginSpec (Mazama's server, through the server link). Answers null when there is none.
  final Future<FetchedSpec?> Function()? fetchBrowserSpec;

  /// SL-R19: where a newer browser spec that just signed in is kept; null means a LoginSpecStore.browser in the
  /// session store's folder (login_browser_spec.yaml, apart from login_spec.yaml).
  final LoginSpecStore? browserSpecStore;

  /// PA-R6: opens the link to this app's published source; null means the phone's browser. Injected by tests.
  final Future<bool> Function(Uri uri)? openLink;

  const SignInPage({
    super.key,
    required this.spec,
    required this.sessionStore,
    this.message,
    this.resilienceOptions = const ResilienceOptions(),
    this.reportSigninFailure,
    this.fetchSpec,
    this.specStore,
    this.fetchHosts,
    this.hostsStore,
    this.ask,
    this.browse,
    this.browserSpec,
    this.fetchBrowserSpec,
    this.browserSpecStore,
    this.openLink,
  });

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _emailFieldKey = GlobalKey<FormFieldState<String>>();

  bool _submitting = false;
  String? _error;

  /// SL-R16: [browserSigninSuggestion] is shown under [_error] (set with it by [_showFailure]).
  bool _suggestBrowser = false;

  /// Set while "Sign in on the state's page" checks the Email field, so an empty one asks with
  /// [browserEmailRequiredMessage]; the password sign-in asks with [emailRequiredMessage].
  bool _emailForBrowser = false;

  /// SL-R18: the hosts a newly fetched list added that the failed retry used; named under [_error].
  List<String> _newHosts = const [];

  @override
  void initState() {
    super.initState();
    setDemoMode(false); // the sign-in page is never part of the demo (signing out of it lands here)
  }

  /// DM-R3: guest / guest opens the demo center built into the app; nothing is saved (DM-D6) or sent (DM-D1).
  Future<void> _openDemo() async {
    try {
      final demo = await DemoBackend.load(rootBundle);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SelectCenterPage.demo(
            demo: demo,
            spec: widget.spec,
            sessionStore: widget.sessionStore,
            resilienceOptions: widget.resilienceOptions,
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'The demo did not open: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Fire-and-forget: started, never awaited, every error dropped - including a reporter that throws before it
  /// returns a Future (Future.sync turns that into a failed Future, which catchError then drops).
  /// [spec] is the spec that failed: its `spec_version` goes with the report.
  void _reportFailure(FlowError e, FlowSpec spec) {
    final report = widget.reportSigninFailure ?? defaultSigninFailureReporter;
    final specVersion = spec.specVersion;
    unawaited(Future<void>.sync(() => report(e, specVersion)).catchError((Object _) {}));
  }

  /// SL-R10: the newest sign-in spec to be had, or null - a fetch that fails or throws (even before returning a
  /// Future) counts as none. The default fetch holds the reply to [allowedHosts] (the hosts of this attempt).
  Future<FetchedSpec?> _fetchSpec(Iterable<String> allowedHosts) async {
    final Future<FetchedSpec?> Function() fetch =
        widget.fetchSpec ?? () => fetchLoginSpec(allowedHosts: allowedHosts);
    try {
      return await Future<FetchedSpec?>.sync(fetch);
    } catch (_) {
      return null;
    }
  }

  /// SL-R19: the newest browser sign-in spec to be had, or null, as [_fetchSpec]; the default fetch holds the reply to
  /// [allowedHosts] and to the browser served mode.
  Future<FetchedSpec?> _fetchBrowserSpec(Iterable<String> allowedHosts) async {
    final Future<FetchedSpec?> Function() fetch =
        widget.fetchBrowserSpec ?? () => fetchBrowserLoginSpec(allowedHosts: allowedHosts);
    try {
      return await Future<FetchedSpec?>.sync(fetch);
    } catch (_) {
      return null;
    }
  }

  LoginSpecStore get _browserSpecStore =>
      widget.browserSpecStore ?? LoginSpecStore.browser(dataDir: widget.sessionStore.dataDir);

  /// SL-R18: the signed host list fetched after a failure, when it is newer than the one in use and adds a host: the
  /// candidate for the retry, kept only after a sign-in it enabled. One that only removes hosts ([onlyRemovesHosts]) is
  /// kept and put in use at once instead (it widens nothing), and null is returned. Null too when there is none newer.
  Future<HostList?> _newerHostList() async {
    final fetched = await _fetchHosts();
    final inUse = loginHostsInUse;
    if (fetched == null || !newerHostList(fetched, inUse)) return null;
    if (onlyRemovesHosts(fetched, inUse)) {
      try {
        await (widget.hostsStore ?? LoginHostsStore(dataDir: widget.sessionStore.dataDir)).save(fetched);
      } catch (_) {
        // Not saved: in use until the app stops; the next failed sign-in fetches it again.
      }
      useLoginHosts(fetched);
      return null;
    }
    return fetched;
  }

  /// SL-R18: the signed host list to be had (verified), or null - a fetch that fails or throws counts as none.
  Future<HostList?> _fetchHosts() async {
    final Future<HostList?> Function() fetch = widget.fetchHosts ?? fetchLoginHosts;
    try {
      return await Future<HostList?>.sync(fetch);
    } catch (_) {
      return null;
    }
  }

  /// FlowError's own message is already scrubbed of email/password/tokens (see flow_runner.dart's defaultSecretKeys)
  /// before it ever reaches here, so it's safe to show directly - except when the state's sign-in page itself has
  /// changed, where the worker gets a plain sentence instead of the failed check (SL-R5), and a question the worker
  /// cancelled (SL-R13).
  /// SL-R16: a `structure` or `needs_person` failure also suggests the sign-in on the state's own page.
  void _showFailure(FlowError e) {
    if (!mounted) return;
    setState(() {
      _error = switch (e.reason) {
        'structure' => stateSigninChangedMessage,
        'cancelled' => signInCancelledMessage,
        _ => e.toString(),
      };
      _suggestBrowser = e.reason == 'structure' || e.reason == 'needs_person';
    });
  }

  /// SL-R16: how a failed sign-in on the state's own page is shown. B2C's own refusal (`credentials`) and anything
  /// else show the FlowError's (scrubbed) message; never reported (SL-R19's one retry with a fetched spec comes first).
  void _showBrowserFailure(FlowError e) {
    if (!mounted) return;
    setState(() {
      _error = switch (e.reason) {
        'cancelled' => signInCancelledMessage,
        'structure' => browserSigninUnfinishedMessage,
        _ => e.toString(),
      };
      _suggestBrowser = false;
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    _emailForBrowser = false;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
      _suggestBrowser = false;
      _newHosts = const [];
    });
    if (isDemoSignIn(_emailController.text, _passwordController.text)) {
      await _openDemo();
      return;
    }

    final client = http.Client();
    try {
      final email = _emailController.text.trim();
      final inputs = <String, Object?>{'email': email, 'password': _passwordController.text};
      var spec = widget.spec;
      // SL-R18: the hosts this attempt may use. The first try uses the phone's own (built-in plus the saved list's).
      final before = currentAllowedHosts();
      var hosts = before;
      String? newerYaml; // set when signed in with a newer spec than widget.spec (SL-R10)
      HostList? newerHosts; // set when that sign-in used a host list fetched just now (SL-R18)
      Session session;
      try {
        session = await _attempt(spec, inputs, email, client, allowedHosts: hosts);
      } on FlowError catch (e) {
        // SL-R5, SL-D7: a wrong email or password is the worker's to fix, and a question they cancelled (SL-R13) is
        // their choice: no report, no newer spec looked for.
        if (e.reason == 'credentials' || e.reason == 'cancelled') {
          _showFailure(e);
          return;
        }
        // SL-R5: everything else is reported, transport failures (no reason) included, fire-and-forget.
        _reportFailure(e, spec);
        // SL-R18: the owner's signed host list, verified with the bundled key. One newer than the list in use gives
        // the hosts of this attempt: the built-in ones plus its own (the newer list wins, as on the server).
        final candidate = await _newerHostList();
        final retryHosts = allowedHostsWith(candidate ?? loginHostsInUse);
        // SL-R10 / SL-D11: one more try, only with a spec newer than the one that just failed; never a second fetch.
        // Held here too, whatever the fetcher did (as the browser path is): its text (what is saved after a session)
        // a usable sign-in spec under the attempt's hosts, served as login.yaml, so never one that opens the state's
        // page (SL-R19's served mode); and the spec it runs on those hosts.
        final fetched = await _fetchSpec(retryHosts);
        if (fetched == null ||
            compareSpecVersions(fetched.spec.specVersion, spec.specVersion) <= 0 ||
            !specHostsAllowed(fetched.spec, allowed: retryHosts) ||
            usableLoginSpec(fetched.yaml, allowedHosts: retryHosts, served: ServedAs.login) == null) {
          _showFailure(e);
          return;
        }
        spec = fetched.spec;
        hosts = retryHosts;
        final retryAdded = hostsAddedTo(before, candidate);
        try {
          session = await _attempt(spec, inputs, email, client, allowedHosts: hosts);
        } on FlowError catch (retryError) {
          // Reported with the newer spec's version unless it's the worker's password or a question they cancelled
          // (SL-R13). The worker sees the retry's own failure, except when the newer spec itself couldn't be run, used a
          // name nothing set (FlowUnknownName, reason `structure`) or gave no token (C1, I1): then the original. Nothing
          // is saved (spec or host list); widget.spec and the hosts in use stay as they were. The hosts a new list
          // added are named under the failure (SL-R18).
          if (retryError.reason != 'credentials' && retryError.reason != 'cancelled') _reportFailure(retryError, spec);
          _showFailure(retryError is SignInSpecFailure || retryError is FlowUnknownName ? e : retryError);
          if (mounted && retryAdded.isNotEmpty) setState(() => _newHosts = retryAdded);
          return;
        }
        newerYaml = fetched.yaml;
        newerHosts = candidate;
      }
      await _keepNewer(
          before: before,
          newerHosts: newerHosts,
          newerSpec: newerYaml == null ? null : spec,
          newerYaml: newerYaml,
          specStore: widget.specStore ?? LoginSpecStore(dataDir: widget.sessionStore.dataDir));
      await _signedIn(session, spec);
    } catch (e) {
      // I1: whatever else went wrong (the session couldn't be stored, say), the worker is told; never a silent stop.
      if (mounted) setState(() => _error = 'Signing in did not finish (${e.runtimeType}). Please try again.');
    } finally {
      client.close();
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// SL-R10/R18/R19: what a sign-in that gave a session keeps, and only then. [newerHosts], a host list fetched for the
  /// retry, is saved and put in use from now on (reads, the sale, renew, the webview), even when it can't be written
  /// (the next start-up then goes back to the saved one). [newerYaml] (parsed: [newerSpec]), the fetched spec the retry
  /// signed in with, is saved in [specStore], checked under the hosts now in use; but not when the host list it needs
  /// couldn't be saved (it isn't usable under [before], the hosts of the saved list): the next start-up would ignore it.
  /// A save that fails still lets this sign-in through. The hosts the list adds to [before] are named over the next
  /// page.
  Future<void> _keepNewer({
    required List<String> before,
    required HostList? newerHosts,
    required FlowSpec? newerSpec,
    required String? newerYaml,
    required LoginSpecStore specStore,
  }) async {
    var hostsSaved = true;
    if (newerHosts != null) {
      try {
        await (widget.hostsStore ?? LoginHostsStore(dataDir: widget.sessionStore.dataDir)).save(newerHosts);
      } catch (_) {
        hostsSaved = false; // the next failed sign-in fetches it again
      }
      useLoginHosts(newerHosts);
    }
    if (newerYaml != null && newerSpec != null && (hostsSaved || specHostsAllowed(newerSpec, allowed: before))) {
      try {
        await specStore.save(newerYaml);
      } catch (_) {
        // Not saved: the next start-up uses the older spec again and, if it fails, finds this one again.
      }
    }
    final added = hostsAddedTo(before, newerHosts);
    if (added.isNotEmpty) _announceNewHosts(added);
  }

  /// SL-R18: names the hosts a new list added over the next page (the app's messenger outlives this page's route).
  void _announceNewHosts(List<String> added) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(newSigninHostsMessage(added)), duration: const Duration(seconds: 10)));
  }

  /// What every sign-in that gave a [session] does next, whichever way it signed in: the session is saved and the
  /// worker goes on to pick a center. [spec] is the sign-in spec the app renews with and signs in with from now on.
  Future<void> _signedIn(Session session, FlowSpec spec) async {
    await widget.sessionStore.save(session.toJson());
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => SelectCenterPage(
          session: session,
          spec: spec,
          sessionStore: widget.sessionStore,
          resilienceOptions: widget.resilienceOptions,
        ),
      ),
    );
  }

  /// SL-R16: the sign-in on the state's own page. The worker types their email and password into the state's page
  /// (the app never sees the password); the email field is still needed here, because nothing the state sends back
  /// names the worker and the session carries the email for Mazama's own records (Session.email, sale logs), as a
  /// password sign-in's does. Runs the browser spec's `login` with [_browse], no question asked; a session goes the
  /// same way as a password sign-in's ([_signedIn]), renewing with [SignInPage.spec] (whose `renew` the browser spec's
  /// is a copy of). Failures are shown ([_showBrowserFailure]) and never reported.
  ///
  /// SL-R19: after any failure, `cancelled` and `credentials` included (a stuck page the worker closed, or B2C's own
  /// error, are how a moved host or a changed policy shows on this path), the signed host list and the newest browser
  /// spec are fetched, as after a failed password sign-in (SL-R10, SL-R18), and the sign-in is tried once more (the
  /// state's page opens again) only when that spec is newer than the one that failed and usable as a browser spec under
  /// the hosts of the retry; otherwise the original failure is shown as it is. Spec and list are kept only after a
  /// session.
  Future<void> _signInOnStatePage() async {
    _emailForBrowser = true;
    if (!(_emailFieldKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _error = null;
      _suggestBrowser = false;
      _newHosts = const [];
    });
    final client = http.Client();
    try {
      final email = _emailController.text.trim();
      final Future<FlowSpec> Function() load =
          widget.browserSpec ?? () => loadBrowserLoginSpec(store: _browserSpecStore);
      final FlowSpec spec;
      try {
        spec = await Future<FlowSpec>.sync(load);
      } catch (_) {
        if (mounted) setState(() => _error = browserSigninUnfinishedMessage);
        return;
      }
      Session session;
      // The state's page and the flow are held to the phone's own hosts (built-in plus the saved list's, SL-R18).
      final before = currentAllowedHosts();
      String? newerYaml; // set when signed in with a newer browser spec than the one loaded (SL-R19)
      FlowSpec? newerSpec;
      HostList? newerHosts; // set when that sign-in used a host list fetched just now (SL-R18)
      try {
        session = await _attempt(spec, const <String, Object?>{}, email, client,
            allowedHosts: before, browse: (url, until) => _browse(url, until, before));
      } on FlowError catch (e) {
        // Whatever the ending, `cancelled` (a stuck page the worker closed) and `credentials` (B2C's own error, such as
        // invalid_scope) included: those are how a moved host or a changed policy shows here. With nothing newer to be
        // had, the original message is shown as it would have been.
        final candidate = await _newerHostList();
        final retryHosts = allowedHostsWith(candidate ?? loginHostsInUse);
        final fetched = await _fetchBrowserSpec(retryHosts);
        // Held here too, whatever the fetcher did: newer than the spec that failed, and a usable browser spec under the
        // retry's hosts (an open_browser in login, its url and until on those hosts).
        final retrySpec = fetched == null || compareSpecVersions(fetched.spec.specVersion, spec.specVersion) <= 0
            ? null
            : usableLoginSpec(fetched.yaml, allowedHosts: retryHosts, served: ServedAs.browser);
        if (fetched == null || retrySpec == null) {
          _showBrowserFailure(e);
          return;
        }
        final retryAdded = hostsAddedTo(before, candidate);
        try {
          session = await _attempt(retrySpec, const <String, Object?>{}, email, client,
              allowedHosts: retryHosts, browse: (url, until) => _browse(url, until, retryHosts));
        } on FlowError catch (retryError) {
          // The retry's own failure, except when the newer spec itself couldn't be run: then the original. Nothing kept.
          _showBrowserFailure(retryError is SignInSpecFailure || retryError is FlowUnknownName ? e : retryError);
          if (mounted && retryAdded.isNotEmpty) setState(() => _newHosts = retryAdded);
          return;
        }
        newerYaml = fetched.yaml;
        newerSpec = retrySpec;
        newerHosts = candidate;
      }
      await _keepNewer(
          before: before,
          newerHosts: newerHosts,
          newerSpec: newerSpec,
          newerYaml: newerYaml,
          specStore: _browserSpecStore);
      await _signedIn(session, widget.spec);
    } catch (e) {
      // I1, as for a password sign-in.
      if (mounted) setState(() => _error = 'Signing in did not finish (${e.runtimeType}). Please try again.');
    } finally {
      client.close();
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// SL-R16: the state's page for the browser spec's `open_browser` step: [SignInPage.browse] when given, else the
  /// webview page, its navigations held to [allowedHosts] (the flow's own, SL-R18). Null (so reason `cancelled`) if
  /// this page has gone away meanwhile.
  Future<String?> _browse(String url, String until, Iterable<String> allowedHosts) async {
    final browse = widget.browse;
    if (browse != null) return browse(url, until);
    if (!mounted) return null;
    final ended = await openBrowserSignIn(context, url, until, allowed: allowedHosts);
    return mounted ? ended : null;
  }

  /// One sign-in attempt with [spec] (sign_in_attempt.dart's [attemptSignIn]): a failure is always a FlowError,
  /// reported, shown, and never saved (final review C1, I1). With [browse] (the sign-in on the state's own page, SL-R16)
  /// the flow gets that and no [_ask]. Every request (and the state's page) is held to [allowedHosts] (SL-R8, SL-R18).
  Future<Session> _attempt(FlowSpec spec, Map<String, Object?> inputs, String email, http.Client client,
          {required Iterable<String> allowedHosts, Future<String?> Function(String url, String until)? browse}) =>
      attemptSignIn(spec, inputs, email, client,
          allowedHosts: allowedHosts, ask: browse == null ? _ask : null, browse: browse);

  /// SL-R13: the worker's answer to a sign-in spec's question: [SignInPage.ask] when given, else the dialog. Null (so
  /// reason `cancelled`) if the page has gone away meanwhile, so nothing is shown on a context that is no longer here.
  Future<String?> _ask(String prompt, bool secret) async {
    final ask = widget.ask;
    if (ask != null) return ask(prompt, secret);
    if (!mounted) return null;
    final answer = await askSignInValue(context, prompt, secret: secret);
    return mounted ? answer : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mazama sign-in')),
      // The other way in, kept apart from the form at the bottom of the screen so it isn't mistaken for part of the
      // password sign-in.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _submitting ? null : _signInOnStatePage,
                    child: const Text(signInOnStatePageLabel),
                  ),
                  OpenSourceLink(open: widget.openLink),
                  PrivacyPolicyLink(open: widget.openLink),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          // Scrolls when the form, its message and both buttons don't fit (a small phone with the keyboard up).
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.message != null) ...[
                      Text(widget.message!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                    ],
                    TextFormField(
                      key: _emailFieldKey,
                      controller: _emailController,
                      decoration: const InputDecoration(labelText: 'Email'),
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      enabled: !_submitting,
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? (_emailForBrowser ? browserEmailRequiredMessage : emailRequiredMessage)
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      enabled: !_submitting,
                      validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 20),
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: 12),
                    ],
                    if (_error != null && _newHosts.isNotEmpty) ...[
                      Text(retrySigninHostsMessage(_newHosts)),
                      const SizedBox(height: 12),
                    ],
                    if (_error != null && _suggestBrowser) ...[
                      const Text(browserSigninSuggestion),
                      const SizedBox(height: 12),
                    ],
                    FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign in'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
