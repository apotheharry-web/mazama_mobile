// The shared secret this app sends on every call to a mazama_sales /p/ route (every client attaches
// appApiKeyHeaders). See mazama_sales' web/access.py: a PUBLIC route checks this header against
// settings.app_api_key (MS_APP_API_KEY, from the sops secret mazama-sales-app-api-key, mazama_sales/default.nix)
// whenever that setting is non-empty.
//
// This is NOT per-device authentication: the same value ships inside every build of the app, so anyone who
// unpacks the app has it. Its only job is to turn away someone who just finds the bare URL (a scanner, a
// scraper). Nothing under /p/ may rely on it being secret.
//
// The value is never in the source: it is given at build time,
//   flutter build apk --release --dart-define=APP_API_KEY=<the value in sops>
// (Codemagic: the APP_API_KEY variable of the mazama_app_key group, codemagic.yaml). A release build without it is
// refused (android/app/build.gradle.kts; codemagic.yaml checks the variable before building). A build without the
// define (`flutter test`, a debug build) has an empty key and sends no header, which a server with no
// MS_APP_API_KEY accepts and the real server refuses.
const String appApiKey = String.fromEnvironment('APP_API_KEY', defaultValue: '');

/// The header name every mazama_sales /p/ route checks (see access.py).
const String appApiKeyHeaderName = 'X-App-Key';

/// `{appApiKeyHeaderName: key}`, or `{}` for an empty key: no header at all rather than an empty one, which some
/// servers and proxies treat differently from none.
Map<String, String> appApiKeyHeadersFor(String key) => key.isEmpty ? const {} : {appApiKeyHeaderName: key};

/// The headers for this build's key: spread into every /p/ request's headers map
/// (e.g. `{...appApiKeyHeaders, 'content-type': 'application/json'}`).
Map<String, String> get appApiKeyHeaders => appApiKeyHeadersFor(appApiKey);
