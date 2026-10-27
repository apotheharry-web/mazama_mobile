// The worker's own signed-in session against the state system: an access token (short-lived - Azure B2C's own
// expires_in, 3600s in every real response seen so far) plus a refresh token that can mint a new access token
// without the worker typing their password again. Mirrors the real server's own StateSession._ensure_token
// (mazama_sales/src/mazama_sales/state/client.py): same REFRESH_MARGIN, same "renew if close to expiry, give up
// and ask for a real sign-in if that's not possible" shape - so a worker who leaves the app open mid-cart isn't
// surprised by a sudden expired-token failure right when they finally try to use it.
import 'package:http/http.dart' as http;

import 'flow/flow_runner.dart';
import 'flow/flow_spec.dart';
import 'login_hosts_store.dart' show currentAllowedHosts;
import 'login_spec_store.dart' show stateApiHost;

/// Renew this long before the token would actually stop working, not exactly at the deadline, so there's slack
/// for the renew call itself plus whatever request it's protecting. The value in use is login.yaml's
/// `refresh_margin_seconds` (see [refreshMarginOf]), the same var REFRESH_MARGIN in
/// mazama_sales/src/mazama_sales/state/client.py reads (SM-20); this is only the fallback when a spec has none.
const defaultRefreshMargin = Duration(seconds: 120);

/// The token refresh margin [spec] (the login spec) declares as `refresh_margin_seconds`, or
/// [defaultRefreshMargin] when it doesn't. A value that isn't a positive number is a mistake in the spec and
/// throws [FlowSpecError], as a bad `timeout_seconds` does.
Duration refreshMarginOf(FlowSpec spec) {
  final raw = spec.vars['refresh_margin_seconds'];
  if (raw == null) return defaultRefreshMargin;
  final seconds = double.tryParse(raw);
  if (seconds == null || !(seconds > 0)) {
    throw FlowSpecError('refresh_margin_seconds must be a positive number of seconds'); // names no value (claim 6)
  }
  return Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());
}

class Session {
  final String accessToken;
  final String? refreshToken;

  /// The worker's own login email - never returned by anything the state system sends back (see
  /// fromFlowResult below), only ever known because the worker typed it at sign-in. Carried on Session, and
  /// persisted the same way the tokens are, purely so it's still on hand later for sale_log_client.dart's own
  /// use: attributing a sale to whoever actually made it, for mazama_sales' own weekly report (see
  /// cart_page.dart's _sell). Never sent to the state system itself - that already knows who's signed in from
  /// the access token alone.
  final String email;

  /// Epoch milliseconds (UTC) - i.e. the DateTime.now().millisecondsSinceEpoch value at which this access
  /// token stops working, same instant Azure B2C computed when it returned expires_in.
  final int expiresAtMs;

  /// The demo sign-in's session (guest / guest, specs/demo-mode): never saved, never renewed (DM-D6, DM-R4).
  final bool isDemo;

  const Session({required this.accessToken, this.refreshToken, required this.email, required this.expiresAtMs, this.isDemo = false});

  /// The demo session: no real token, no refresh token, an expiry that never comes (9999-12-31).
  const Session.demo()
      : accessToken = 'DEMO-TOKEN',
        refreshToken = null,
        email = 'guest',
        expiresAtMs = 253402300799000,
        isDemo = true;

  /// True once we're [margin] or less from expiry (or already past it) - exactly at the margin is due, as on
  /// the server, which keeps a token only while `now < expires - REFRESH_MARGIN` (SM-20). Pass the login
  /// spec's own margin ([refreshMarginOf]). [now] is overridable for tests, same pattern as selling.dart's
  /// parseSaleDate taking `today` rather than reading the clock itself.
  bool needsRenewal({DateTime Function() now = DateTime.now, Duration margin = defaultRefreshMargin}) =>
      now().millisecondsSinceEpoch >= expiresAtMs - margin.inMilliseconds;

  Map<String, Object?> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'email': email,
        'expires_at_ms': expiresAtMs,
      };

  /// Null for anything that isn't a session this class itself wrote (nothing stored, a corrupt/partial file,
  /// some future or older format - including one saved before `email` existed on this class at all) - the
  /// caller's correct move either way is the same as having no stored session: fall back to a real sign-in,
  /// which is also the only way to learn the email again anyway.
  static Session? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final accessToken = json['access_token'];
    final expiresAtMs = json['expires_at_ms'];
    final email = json['email'];
    if (accessToken is! String || expiresAtMs is! int || email is! String) return null;
    final refreshToken = json['refresh_token'];
    return Session(
      accessToken: accessToken,
      refreshToken: refreshToken is String ? refreshToken : null,
      email: email,
      expiresAtMs: expiresAtMs,
    );
  }

  /// Builds a Session from whatever runFlow('login'|'renew', ...) returned - both flows extract the same three
  /// fields (see shared/flows/login.yaml), so one constructor serves both call sites. Neither flow's result
  /// carries the email (the state never echoes it back), so it's always supplied separately: the one the
  /// worker just typed at sign-in time (SignInPage._submit), or the existing session's own email when this is
  /// a renewal (ensureFreshSession below, which already has it on hand).
  ///
  /// Throws [FlowSpecError] when the result holds no access token, or an empty one: a flow that "succeeds" without
  /// one (a fetched spec missing its token step, say) is not a session (final review C1).
  static Session fromFlowResult(Map<String, Object?> result, {required String email, DateTime Function() now = DateTime.now}) {
    final accessToken = result['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw FlowSpecError('the flow finished without an access token');
    }
    final refreshToken = result['refresh_token'] as String?;
    final expiresIn = (result['expires_in'] as num?)?.toInt() ?? 0;
    return Session(
      accessToken: accessToken,
      refreshToken: refreshToken,
      email: email,
      expiresAtMs: now().millisecondsSinceEpoch + expiresIn * 1000,
    );
  }
}

/// Thrown when a session can no longer be used or renewed automatically - the caller's only real move is to
/// send the worker back to a real sign-in. The message is already safe to show directly: it's either written
/// here with no secret in it, or built from a FlowError's own message, which flow_runner.dart already scrubs of
/// every secret (password, email, access_token, refresh_token) before it ever reaches here.
class SessionExpired implements Exception {
  final String message;
  SessionExpired(this.message);
  @override
  String toString() => message;
}

/// A [SessionExpired] whose cause is the sign-in spec itself, not the state system: running `renew` (or reading the
/// spec's refresh margin, or the flow's result) threw something other than a [FlowError] - a mistake in a spec the
/// checks did not foresee (final review I1). Callers that only know [SessionExpired] treat it as one: a real sign-in.
/// MazamaApp._resolveHome catches it first when the spec in use is one saved from the server, sets that spec aside
/// (LoginSpecStore.quarantine) and decides again with the bundled one, so a bad download can't lock the phone out.
class SessionSpecUnusable extends SessionExpired {
  SessionSpecUnusable(super.message);
}

/// Thrown instead of [SessionExpired] when the `renew` flow failed for a reason that says nothing about
/// whether the refresh token itself is still good - the request never reached the state system at all
/// or no answer came back (a FlowError with stage connect or send), the state answered with a 5xx, or it answered 200 with
/// something flow_runner.dart's own then_require couldn't make sense of. None of those are the state
/// explicitly refusing this token, so none of them should cost the worker a real sign-in: a caller catching
/// this should leave [Session]/SessionStore exactly as they were and simply try again shortly (the existing
/// session may well still be perfectly good once the state system is reachable again). The message is scrubbed
/// the same way SessionExpired's is, so it's already safe to show directly.
class SessionRenewalUnavailable implements Exception {
  final String message;
  SessionRenewalUnavailable(this.message);
  @override
  String toString() => message;
}

/// What a failed-sale report sent to Mazama's server says when the sale was stopped by a session problem: a fixed text
/// for each kind, never the exception's own message. That message carries the `renew` flow's error text, and a renew
/// from a spec fetched from Mazama's server (or saved from one) can capture a token under another name and put it in
/// its error text, which the scrubbing (exact values of the secret keys only) wouldn't catch. What the worker sees on
/// screen keeps the message. Callers add their own `[outcome]` tags.
String sessionFailureReportText(Object e) => switch (e) {
      SessionSpecUnusable() => 'the sign-in spec could not renew the session',
      SessionExpired() => "the state's sign-in session expired",
      SessionRenewalUnavailable() => "the state's sign-in could not be renewed",
      _ => "the state's sign-in failed",
    };

/// True only when [message] (a FlowError's own text) shows the state system itself explicitly rejecting this
/// refresh token with a 4xx - a real invalid_grant, the same shape an actually expired or revoked refresh token
/// takes. False for anything else (no HTTP status at all - unreachable, or an unconfirmed 200 - or a 5xx):
/// those mean the state system couldn't be talked to or didn't answer usably just now, not that the refresh
/// token is dead, and ensureFreshSession below treats the two very differently.
bool _isGenuineRefusal(String message) {
  final m = RegExp(r'HTTP (\d{3})').firstMatch(message);
  if (m == null) return false;
  final status = int.parse(m.group(1)!);
  return status >= 400 && status < 500;
}

/// Returns a session guaranteed fresh for at least the spec's refresh margin longer: [session] itself if it isn't close to
/// expiry yet (no network call at all), otherwise the result of running the `renew` flow (shared/flows/
/// login.yaml's `renew`, the same refresh_token grant the real server's own _renew uses).
///
/// Throws [SessionExpired] only when nothing short of a real sign-in with a password could ever get past it:
/// no refresh token to try at all, or the state system explicitly refusing the one there is with a 4xx (a
/// genuinely expired or revoked refresh token) - or its [SessionSpecUnusable] form when the spec itself fails: with
/// anything but a [FlowError] (I1: never an exception of another type, so no caller is left with an unhandled one), or
/// with a FlowError that involved no request (stage null: an unknown name, a bad regex, ...).
/// Throws [SessionRenewalUnavailable] instead for everything else the `renew` flow can fail with - the state system being unreachable, erroring, or answering with something
/// unusable - since none of those say anything about the refresh token itself still being good, and wrongly
/// treating a momentary outage as a dead session would force every worker caught by it into a real sign-in
/// (and briefly leave their cart draft stranded behind that sign-in) for no reason at all.
///
/// The renew's requests go only to [allowedHosts]: by default the phone's own allowlist (login_hosts_store.dart's
/// currentAllowedHosts, SL-R18).
Future<Session> ensureFreshSession(Session session, FlowSpec spec,
    {required http.Client client, DateTime Function() now = DateTime.now, Iterable<String>? allowedHosts}) async {
  // DM-R4: a demo session is never renewed: there is no real sign-in behind it to ask.
  if (session.isDemo) return session;
  final Duration margin;
  try {
    margin = refreshMarginOf(spec);
  } catch (e) {
    throw SessionSpecUnusable('the sign-in spec cannot renew the session (${e.runtimeType}) - please sign in again.');
  }
  if (!session.needsRenewal(now: now, margin: margin)) return session;
  final refreshToken = session.refreshToken;
  if (refreshToken == null) {
    throw SessionExpired('the session has expired and cannot be renewed automatically - please sign in again.');
  }
  try {
    final result = await runFlow(spec, 'renew', {'refresh_token': refreshToken},
        // SL-D16: renewal runs unattended, so it never sends anything to the state's API (a redirect there isn't followed)
        client: client, allowedHosts: allowedHosts ?? currentAllowedHosts(), neverRequest: const {stateApiHost});
    return Session.fromFlowResult(result, email: session.email, now: now);
  } on FlowError catch (e) {
    if (e.stage == null) {
      // No request was involved: the spec's own mistake (a name nothing set, a regex or `when` it can't use, an
      // unknown step type, its own url off the allowlist), not the state's answer. Retrying won't help; a saved spec
      // gets set aside. A redirect off the allowlist is the state's answer: stage response, so not here.
      throw SessionSpecUnusable('the sign-in spec cannot renew the session ($e) - please sign in again.');
    }
    final message = e.toString();
    if (_isGenuineRefusal(message)) {
      throw SessionExpired('the session could not be renewed ($e) - please sign in again.');
    }
    throw SessionRenewalUnavailable('the state system could not be reached to renew the session ($e) - try again shortly.');
  } catch (e) {
    // Not the state system's answer but the spec (a type the runner didn't expect, a name it never set) or a result
    // with no token: retrying won't help, a real sign-in might, and a saved spec gets set aside (SessionSpecUnusable).
    throw SessionSpecUnusable('the sign-in spec cannot renew the session (${e.runtimeType}) - please sign in again.');
  }
}
