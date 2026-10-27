// A thin in-app browser for Mazama's own separate inventory portal (ppi.mazamamushrooms.com) - not anything
// this app talks to, parses, or depends on; just a web app a worker may also want open without leaving this
// app entirely. Uses webview_flutter (the Flutter team's own official WebView plugin) to show it in-app, per
// request, rather than always handing it off to the device's external browser - the external browser is
// still one tap away (the AppBar's "Open in browser" action, see _openExternally) for anything the in-app
// WebView can't handle, a login flow some identity providers refuse to run inside an embedded WebView being
// the most common case.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

const inventoryPortalUrl = 'https://ppi.mazamamushrooms.com';

class InventoryPortalPage extends StatefulWidget {
  const InventoryPortalPage({super.key});

  @override
  State<InventoryPortalPage> createState() => _InventoryPortalPageState();
}

class _InventoryPortalPageState extends State<InventoryPortalPage> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _error = null;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _loading = false);
          },
          // A WebResourceError here means the page itself failed to load (no connectivity, a bad cert, DNS,
          // the server down) - not a 404/500 the page itself renders, which the WebView shows normally same
          // as any browser would. _error drives the full-screen retry/open-externally view below.
          onWebResourceError: (err) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = err.description;
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(inventoryPortalUrl));
  }

  /// The one escape hatch out of the in-app WebView - see this file's own comment for why it exists at all.
  /// Swallows a launch failure into a snackbar rather than letting it surface as an unhandled exception; a
  /// worker who taps this already knows the in-app view isn't working for them, so a silent failure here
  /// would be worse than "it didn't open."
  Future<void> _openExternally() async {
    try {
      final launched = await launchUrl(Uri.parse(inventoryPortalUrl), mode: LaunchMode.externalApplication);
      if (launched || !mounted) return;
    } catch (_) {
      // falls through to the snackbar below either way
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open a browser.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mazama Mushrooms Inventory'),
        actions: [
          IconButton(onPressed: () => _controller.reload(), icon: const Icon(Icons.refresh), tooltip: 'Reload'),
          IconButton(onPressed: _openExternally, icon: const Icon(Icons.open_in_browser), tooltip: 'Open in browser'),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading && _error == null) const LinearProgressIndicator(),
          if (_error != null)
            Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Could not load the page: $_error', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: () => _controller.reload(), child: const Text('Retry')),
                      const SizedBox(height: 8),
                      OutlinedButton(onPressed: _openExternally, child: const Text('Open in browser instead')),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
