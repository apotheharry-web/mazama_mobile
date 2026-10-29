// SL-R16 / SL-D5: the sign-in on the state's own page. The browser sign-in spec (assets/flows_phone/login_browser.yaml,
// browser_login_spec.dart) has an `open_browser` step; runFlow hands its start URL and `until` prefix to a `browse`
// callback, and openBrowserSignIn below is that callback: a full-screen webview (webview_flutter) on the state's real
// B2C page, where the worker types their own email and password (the app never sees them). The page ends when B2C
// sends the browser to `until` (the redirect_uri, with the code or B2C's own error in the fragment): that navigation
// is stopped, never loaded, and its URL handed back to the flow, which checks `state` and asks for the token itself.
// Closing the page hands back null (reason `cancelled`).
//
// What may load (decideBrowserNavigation, the pure rule every navigation is put through):
//   - a URL starting with `until` ends the page (checked first, so the code redirect is never loaded);
//   - a main-frame URL on the shared allowlist (flow_spec.dart's hostAllowedUrl: https, port 443,
//     psilocybin.oregon.gov or the state's own tenant oregonpsilocybinprodb2c.b2clogin.com, never another B2C
//     tenant, SL-R17, plus the hosts of a signed host list, SL-R18; the same list the flow that opened the page runs
//     with, SL-R8: login_hosts_store.dart's currentAllowedHosts unless SignInPage passes the list of its attempt)
//     loads;
//   - any other main-frame URL is refused and the page stays where it was: other hosts, http, other ports,
//     javascript:, data:, intent:, mailto: and about:blank too (webview_flutter starts the page with loadRequest on
//     the B2C URL, so nothing needs a blank main frame first);
//   - frames inside the page load (except one heading for `until`, refused: B2C returns the code in the main frame).
// What webview_flutter's NavigationDelegate.onNavigationRequest covers: navigations the page starts (links, script-set
// locations, server redirects; form posts on iOS only: Android's WebView never asks about a POST navigation, so there a
// form on the state's page posts wherever the page says), never sub-resources (scripts, styles, images, XHR/fetch), so the scripts
// and styles the B2C page loads are not filtered here. On Android (webview_flutter_android) it is called for the main
// frame only: frame navigations load without asking, so the frame branch of decideBrowserNavigation runs only on iOS
// (WKWebView asks for every frame). On Android the first loadRequest is not routed through it either; that URL has
// already passed the allowlist in runFlow before browse is called. onPageStarted and onUrlChange are a backstop for
// the end of the sign-in (see _BrowserSignInPageState.initState).
//
// The page closes once (SignInPageCloser): the close button, the system back gesture and the end of the sign-in can
// race, and a second pop would take SignInPage away with it.
//
// Cookies and site data are cleared before the page loads, every time, so a previous worker's B2C session can't sign
// this one in; a clearing call that fails is ignored and the page still opens. Clearing again when the page closes is
// best effort (the webview may already be gone).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'flow/flow_spec.dart' show hostAllowedUrl;
import 'login_hosts_store.dart' show currentAllowedHosts;

/// The button under the sign-in form, and the title of the page it opens.
const signInOnStatePageLabel = "Sign in on the state's page";

/// What the page shows when the state's page could not be loaded (no URL or page text, which could carry a code).
const browserPageLoadFailedMessage = "The state's page didn't load. Check the connection and try again.";

/// The three answers [decideBrowserNavigation] gives.
enum BrowserNavKind { navigate, prevent, finish }

/// One navigation's verdict: load it, refuse it (the page stays), or end the sign-in with [url].
class BrowserNav {
  final BrowserNavKind kind;

  /// The URL the sign-in ended at, fragment included; only for [BrowserNavKind.finish].
  final String? url;

  const BrowserNav._(this.kind) : url = null;
  const BrowserNav.finish(String this.url) : kind = BrowserNavKind.finish;

  static const navigate = BrowserNav._(BrowserNavKind.navigate);
  static const prevent = BrowserNav._(BrowserNavKind.prevent);

  @override
  bool operator ==(Object other) => other is BrowserNav && other.kind == kind && other.url == url;

  @override
  int get hashCode => Object.hash(kind, url);

  @override
  String toString() => url == null ? 'BrowserNav.${kind.name}' : 'BrowserNav.finish(...)';
}

/// The rule every navigation on the sign-in page is put through (see this file's comment): `until` first, then the
/// host allowlist for the main frame ([allowed]: the phone's own, currentAllowedHosts, unless given); frames load.
BrowserNav decideBrowserNavigation(String url,
    {required String until, required bool isMainFrame, Iterable<String>? allowed}) {
  if (until.isNotEmpty && url.startsWith(until)) return isMainFrame ? BrowserNav.finish(url) : BrowserNav.prevent;
  if (!isMainFrame) return BrowserNav.navigate;
  return hostAllowedUrl(url, allowed: allowed ?? currentAllowedHosts()) ? BrowserNav.navigate : BrowserNav.prevent;
}

/// Runs every one of [clearers] in turn, whatever any of them does: a Future that fails or a call that throws before
/// returning one is dropped. Never throws.
Future<void> clearSignInBrowserData(List<FutureOr<void> Function()> clearers) async {
  for (final clear in clearers) {
    try {
      await clear();
    } catch (_) {
      // Best effort: the next sign-in clears again before it loads.
    }
  }
}

/// Closes the sign-in page once. Every way the page ends goes through it ([finish], [close]) or tells it ([markDone],
/// from [scope]'s PopScope on the system back gesture), and only the first pops: the redirect seen twice, or close or
/// back racing the redirect, must not pop again and take the page under it (SignInPage) away.
class SignInPageCloser {
  bool _done = false;

  /// True once the page has been closed, or is closing, by any route.
  bool get done => _done;

  /// The page is closing some other way (the system back gesture): nothing pops after this.
  void markDone() => _done = true;

  /// Ends the sign-in with [url], unless the page is already closing. True if it popped.
  bool finish(BuildContext context, String url) => _popOnce(context, url);

  /// Closes the page with no answer (reason `cancelled`), unless it is already closing. True if it popped.
  bool close(BuildContext context) => _popOnce(context, null);

  /// Marks the page done first, then pops only while [context] is mounted and its route is the current one (not
  /// already popping, nothing pushed over it).
  bool _popOnce(BuildContext context, String? result) {
    if (_done) return false;
    _done = true;
    if (!context.mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    Navigator.of(context).pop(result);
    return true;
  }

  /// Wraps the page so that a pop from anywhere else (the system back gesture) marks [closer] done.
  static Widget scope({required SignInPageCloser closer, required Widget child}) => PopScope<Object?>(
        onPopInvokedWithResult: (didPop, _) => closer.markDone(),
        child: child,
      );
}

/// The `browse` callback for the browser sign-in spec: shows the state's page at [url] full-screen and answers the
/// URL the page ended at (it starts with [until]), or null when the worker closed the page. Main-frame navigations are
/// held to [allowed] (the hosts the flow runs with; the phone's own, currentAllowedHosts, when null).
Future<String?> openBrowserSignIn(BuildContext context, String url, String until, {Iterable<String>? allowed}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => BrowserSignInPage(url: url, until: until, allowed: allowed)),
  );
}

/// The state's sign-in page in a webview. Pops with the URL the sign-in ended at, or null when closed.
class BrowserSignInPage extends StatefulWidget {
  final String url;
  final String until;

  /// The hosts a main-frame navigation may go to ([decideBrowserNavigation]); null means currentAllowedHosts.
  final Iterable<String>? allowed;

  const BrowserSignInPage({super.key, required this.url, required this.until, this.allowed});

  @override
  State<BrowserSignInPage> createState() => _BrowserSignInPageState();
}

class _BrowserSignInPageState extends State<BrowserSignInPage> {
  late final WebViewController _controller;
  final _closer = SignInPageCloser();
  bool _loading = true; // a main-frame page has started and not yet finished
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          // onPageStarted and onUrlChange are a backstop for the end of the sign-in: onNavigationRequest is the
          // primary path, but a hop that bypasses the delegate (a redirect a platform doesn't route through it) still
          // ends the page here. The state's site may show for a moment first; the flow's own `state` check still
          // guards what is handed back.
          onPageStarted: (url) {
            if (!mounted || _closer.done) return;
            if (_endsSignIn(url)) {
              _finish(url);
              return;
            }
            setState(() {
              _loading = true;
              _failed = false;
            });
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url != null && _endsSignIn(url)) _finish(url);
          },
          onPageFinished: (_) {
            if (!mounted || _closer.done) return;
            setState(() => _loading = false);
          },
          // Only a main-frame page that was loading counts: a refused navigation never starts a page, and a frame's
          // or sub-resource's error leaves the page usable. Nothing from the error is shown.
          onWebResourceError: (error) {
            if (!mounted || _closer.done || error.isForMainFrame == false || !_loading) return;
            setState(() {
              _loading = false;
              _failed = true;
            });
          },
        ),
      );
    unawaited(_start());
  }

  /// Clears what a previous sign-in left, then loads the state's page.
  Future<void> _start() async {
    await _clearSiteData();
    if (!mounted || _closer.done) return;
    await _load();
  }

  Future<void> _load() async {
    try {
      await _controller.loadRequest(Uri.parse(widget.url));
    } catch (_) {
      if (mounted && !_closer.done) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _clearSiteData() => clearSignInBrowserData([
        () => WebViewCookieManager().clearCookies(),
        () => _controller.clearCache(),
        () => _controller.clearLocalStorage(),
      ]);

  bool _endsSignIn(String url) => widget.until.isNotEmpty && url.startsWith(widget.until);

  /// Every way the sign-in ends comes here: pops with [url] once, never a second time (SignInPageCloser).
  void _finish(String url) {
    if (!mounted) return;
    _closer.finish(context, url);
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    if (_closer.done) return NavigationDecision.prevent;
    final nav = decideBrowserNavigation(request.url,
        until: widget.until, isMainFrame: request.isMainFrame, allowed: widget.allowed);
    switch (nav.kind) {
      case BrowserNavKind.navigate:
        return NavigationDecision.navigate;
      case BrowserNavKind.prevent:
        return NavigationDecision.prevent;
      case BrowserNavKind.finish:
        _finish(nav.url!);
        return NavigationDecision.prevent;
    }
  }

  void _retry() {
    setState(() {
      _failed = false;
      _loading = true;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _closer.markDone();
    // Best effort, fire-and-forget, never throws; the clearing before the next load is the guarantee.
    unawaited(_clearSiteData());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignInPageCloser.scope(
      closer: _closer,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(signInOnStatePageLabel),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => _closer.close(context),
          ),
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading && !_failed) const LinearProgressIndicator(),
            if (_failed)
              Container(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(browserPageLoadFailedMessage, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _retry, child: const Text('Retry')),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
