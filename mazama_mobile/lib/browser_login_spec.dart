// SL-R16: the phone's own sign-in on the state's page, assets/flows_phone/login_browser.yaml (vendored from
// ../mazama_modules/flows/phone/ by tool/sync_flows.sh, bundled by pubspec.yaml). Its `login` flow takes no inputs and
// needs a `browse` callback (the webview page); its `renew` is login.yaml's.
//
// SL-R19: like login.yaml it can be fixed without a release. After a browser sign-in fails (closed or refused by B2C
// included), SignInPage fetches the newest one from Mazama's server (/p/flows/login_browser,
// login_spec_client.dart's fetchBrowserLoginSpec), retries once with a newer one and, after a session, keeps it in
// `login_browser_spec.yaml` (LoginSpecStore.browser, apart from login.yaml's login_spec.yaml). The newer usable one of
// that saved copy and the bundled one is used from then on; the bundled one is the fallback.
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'flow/flow_spec.dart';
import 'login_spec_store.dart' show LoginSpecStore, ServedAs, usableLoginSpec;

/// Where the bundled browser sign-in spec lives in the app's assets.
const browserLoginSpecAsset = 'assets/flows_phone/login_browser.yaml';

/// The browser sign-in spec to use: the one saved in [store] (a [LoginSpecStore.browser]) when it is usable and its
/// spec_version is newer than the bundled one's, otherwise the bundled one, read from [bundle] (the app's own,
/// [rootBundle], unless a test passes one). Both are held to the sign-in spec rule in the browser served mode
/// ([usableLoginSpec]); with neither usable this throws [FlowSpecError] rather than run anything.
Future<FlowSpec> loadBrowserLoginSpec({AssetBundle? bundle, LoginSpecStore? store}) async {
  final yaml = await (bundle ?? rootBundle).loadString(browserLoginSpecAsset);
  final bundled = usableLoginSpec(yaml, served: ServedAs.browser);
  final saved = store?.savedSpec();
  if (saved != null && (bundled == null || compareSpecVersions(saved.specVersion, bundled.specVersion) > 0)) {
    return saved;
  }
  if (bundled == null) throw FlowSpecError('the bundled browser sign-in spec is not a usable sign-in spec');
  return bundled;
}
