// A small hub for every kDebugMode-only diagnostic screen this app has, reached from select_center_page.dart's
// own debug-only AppBar icon - one list rather than a growing row of icons there as more of these get added.
// Nothing here is compiled into a profile/release build: see select_center_page.dart's own comment on
// kDebugMode for why that's a compile-time guarantee, not just a runtime check.
import 'package:flutter/material.dart';

import 'debug_adhoc_coa_diagnostics_page.dart';
import 'debug_background_features_page.dart';
import 'debug_coa_label_page.dart';
import 'debug_launch_cart_page.dart';
import 'debug_local_storage_page.dart';
import 'debug_server_link_page.dart';
import 'debug_signin_files_page.dart';
import 'debug_state_data_page.dart';
import 'flow/flow_spec.dart';
import 'session.dart';
import 'session_store.dart';

class DebugToolsPage extends StatelessWidget {
  final Session session;

  /// Needed by DebugLaunchCartPage, which opens a real CartPage - everything else here only ever reads the
  /// session.
  final FlowSpec spec;
  final SessionStore sessionStore;

  /// Forwarded to whichever tool below takes it - see each one's own initialStateId doc comment.
  final int? initialStateId;

  const DebugToolsPage({super.key, required this.session, required this.spec, required this.sessionStore, this.initialStateId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Debug tools')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Launch cart by state id'),
            subtitle: const Text("Opens the real cart for any center's state id, skipping the license picker "
                "entirely - for testing a center this account isn't actually licensed for yet."),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DebugLaunchCartPage(session: session, spec: spec, sessionStore: sessionStore, initialStateId: initialStateId),
            )),
          ),
          ListTile(
            title: const Text('Background features'),
            subtitle: const Text('Manually runs the merge/push, COA-on-cart-add, label and sale-log/failure '
                'calls CartPage normally makes silently.'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DebugBackgroundFeaturesPage(session: session, initialStateId: initialStateId),
            )),
          ),
          ListTile(
            title: const Text('State data browser'),
            subtitle: const Text("Raw, unmerged licenses/mazama-packages/state-packages fetches - what each "
                'side actually says on its own.'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DebugStateDataPage(session: session, initialStateId: initialStateId),
            )),
          ),
          ListTile(
            title: const Text('Local storage'),
            subtitle: const Text('Inspect and clear the session/cart-draft/inventory-cache/device-id files this '
                'app keeps on disk.'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DebugLocalStoragePage(initialStateId: initialStateId),
            )),
          ),
          ListTile(
            title: const Text('Server link'),
            subtitle: const Text("Whether Mazama's server is counted as reachable, the reports waiting to be sent, the "
                'dead letters and the work waiting to catch up.'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DebugServerLinkPage())),
          ),
          ListTile(
            title: const Text('Adhoc-COA diagnostics'),
            subtitle: const Text("Exercises an unconfigured center's own COA pipeline step by step."),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DebugAdhocCoaDiagnosticsPage(session: session, initialStateId: initialStateId),
            )),
          ),
          ListTile(
            title: const Text('COA → label (on phone)'),
            subtitle: const Text("Reads a package's lab report and builds its label with the shared reader, step by "
                'step on this phone; no server calls.'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DebugCoaLabelPage(session: session, initialStateId: initialStateId),
            )),
          ),
          ListTile(
            title: const Text('Sign-in files'),
            subtitle: const Text("The bundled, Mazama server and hosted copies of login.yaml, login_browser.yaml and "
                'hosts.json: checked, signatures verified, and tried without saving anything.'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DebugSigninFilesPage(addressStore: DebugSigninAddressStore(dataDir: sessionStore.dataDir)),
            )),
          ),
        ],
      ),
    );
  }
}
