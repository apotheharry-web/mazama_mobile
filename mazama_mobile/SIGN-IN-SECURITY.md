# Sign-in security: claims you can check in this source code

This app signs a service-center worker in to the Oregon Psilocybin Services product-tracking system ("the state
system") with the worker's own email and password. This page states, precisely, where those credentials and the
resulting tokens go, and points to the exact files and functions that make each statement true, so that anyone (or
any AI assistant) reading this repository can check it.

Every path below is relative to this folder (`mazama_mobile/`). Function and constant names are given so you can
search for them; line numbers are left out on purpose because they change.

## Definitions

- **The state's hosts**: exactly `psilocybin.oregon.gov` (the state site and its API) and
  `oregonpsilocybinprodb2c.b2clogin.com` (the state's own Microsoft Azure AD B2C sign-in tenant), over `https` on
  port 443. Nothing else, not even another `*.b2clogin.com` tenant or a subdomain.
- **Credentials**: the email address and password the worker types.
- **Tokens**: the access token and refresh token the state's sign-in returns, and the one-time authorization code
  used to get them.
- **Mazama's server**: `https://sales.mazamamushrooms.com` (`apiBaseUrl` in `lib/api_contract.g.dart`), which the app
  uses for labels, inventory and sale records.

## Claims

### 1. The password goes only to the state's sign-in, as a form field of a POST

- **Statement:** the password is read from the sign-in form and handed only to the sign-in flow. That flow sends it
  only as a form field of a POST to the sign-in host: never in an address, a query, a header or any other request, and
  never to `psilocybin.oregon.gov` (the state's API, where writes and readable records live). It is never stored on
  the device, never logged, never shown, and never sent to Mazama's server or anyone else.
- **The rule, for every sign-in spec the app runs:** the text `{{password}}` may appear in a spec only as the entire
  value of a `form` field of a `request` step whose `method` is exactly `POST` and whose address, filled in with the
  spec's own `vars`, has a host other than `psilocybin.oregon.gov`. Anywhere else (an address, `params`, `headers`, a
  form value with other text around it, a `when`, a question to the worker, an error message, a check, an
  `open_browser` step) the spec is refused. No `when` (the condition that decides whether a step runs) and no
  `json_var` may name `password`, `email` or `refresh_token`, and no check may name `password`, so which step runs
  can't depend on any of them, and whether a step fails can't depend on the password (a check may still compare the
  email or refresh token). More rules close the ways around that:
  - the search for `{{password}}` covers every key and every value at any depth of `vars`, the flow names and every
    step (other top-level keys are never read); the template syntax is exactly `{{name}}`: `{{ password }}` is never
    filled;
  - every `params`, `headers` and `form` value is plain text (a YAML string) and none of their keys contains `{{`,
    since the interpreter turns any other value (a nested mapping, a list) into text and fills templates inside it;
  - no step may set a name that is one of the spec's `vars` or an input of its flow (`email` and `password` in
    sign-in, `refresh_token` in renewal; the one exception is renewal's request reading the state's new refresh
    token), so a value read from an answer can't change an address's host after it was checked;
  - answers the worker types follow the password rule: every name a question to the worker sets (an `await_input`'s
    `into`, such as a one-time code) may appear only as the entire value of a `form` field of a POST to a host other
    than `psilocybin.oregon.gov`, and no `when`, check or `json_var` may name it. So a spec that asks "re-enter your
    password" can still only post the answer where the password itself could go;
  - no var may be named `email`, `password` or `refresh_token` (the flow's input would override it at run time).

  What the rule does not decide: a spec chooses the words of any question it puts to the worker (shown under the fixed
  title "The state is asking", `lib/sign_in_prompt.dart`) and whether the answer is hidden as it is typed. An answer
  to a question not marked secret is shown as typed and is not scrubbed from errors (claim 6); it can still be posted
  only where the password could go. The rule limits where `{{password}}` is written in a spec, not values read back
  from the state's answers: if an allowed host ever sent the posted password back, a spec could read it under another
  name. The state's sign-in is not known to do that.

  A spec fetched from Mazama's server or saved from one is checked before it runs; the bundled specs are held to the same rule by tests. Within the state's hosts, "the sign-in host"
  is in practice the state's B2C tenant; a host added by a signed host list (claim 4) could also receive the POST.
  - `lib/login_spec_store.dart`, `usableLoginSpec` with `_secretsPlaced`, `_plainMapsOk` and `_setNamesOk` (the
    rule); it runs on a saved spec
    (`LoginSpecStore.savedSpec`, `save`), a fetched one (`lib/login_spec_client.dart`, and again in `lib/main.dart`
    before the retry) and the browser spec (`lib/browser_login_spec.dart`, `loadBrowserLoginSpec`).
  - Mazama's server holds a spec to the same rule before serving it (`login_spec_source._valid_version`, not in this
    folder); both sides run the same cases, `assets/shared/flows/contracts/login_spec_validity.json` (one case for
    each refused place, from "password in a url path" to "a var named refresh_token", among them the nested-value,
    key, overwritten-var and typed-answer cases; "password posted to the sign-in tenant" and "renew extracts the
    rotated refresh_token" are the allowed ones).
- **Where to look:**
  - `lib/main.dart`, `_SignInPageState._submit`: the password text is placed in the `inputs` map and passed only to
    `_attempt`, then `attemptSignIn` (`lib/sign_in_attempt.dart`), which passes it only to `runFlow` (the flow
    interpreter).
  - `lib/session.dart`, `Session.toJson`: what is saved has no password field (`access_token`, `refresh_token`,
    `email`, expiry).
  - `lib/flow/flow_runner.dart`, `runFlow` / `_runRequest`: every request is checked with `hostAllowedUrl` before it
    is sent (claim 3).
  - `assets/flows/login.yaml`: the only step that uses `{{password}}` is `self_asserted`, a POST to the state's B2C
    tenant.
  - Search check: `password` appears in `lib/` only in the places above, in `login_spec_store.dart` (the names a
    sign-in flow may use, and the rule above), in `flow_runner.dart`'s `defaultSecretKeys` (claim 6), in the
    developer-only Sign-in files page (`lib/debug_signin_files_page.dart`, see "What these claims do not cover"), and
    in comments.
  - The only exception is a local demo account (`isDemoSignIn` in `lib/main.dart`: email `guest`, password `guest`),
    which is checked on the phone and sends nothing.
- **Tests:** `test/login_spec_store_test.dart` (the shared validity cases, and "the shipped login spec is a usable
  sign-in spec"), `test/browser_login_spec_test.dart`, `test/login_spec_client_test.dart`.

### 2. Tokens go only to the allowlisted hosts (today, the state's)

- **Statement:** the access token and refresh token are sent only in requests to hosts on the app's allowlist: today
  exactly the state's two hosts. A signed host list (claim 4) would add its hosts for every token-carrying request:
  state reads, sales, renewal and lab-report downloads. The requests that carry a token are the state system's API reads and sales, the token refresh, and
  lab-report downloads. No request to Mazama's server, or to any other host, carries a token.
- **Where to look:**
  - `assets/flows/state_reads.yaml`, `sale.yaml`, `login.yaml`, `assets/flows_phone/login_browser.yaml` (and
    `sb303.yaml`, bundled but not used by the app):
    every `Authorization: Bearer
    {{access_token}}` header and the `refresh_token` form field are in steps whose URLs are on the state's hosts. All
    of them run through `runFlow` and its host check (claim 3).
  - `lib/state_document_client.dart`, `downloadStateDocument`: the one request built by hand (lab-report PDFs). It
    refuses to start unless the API host passes `hostAllowedUrl`, follows redirects itself (`followRedirects = false`)
    and adds the `Authorization` header only while the request is still on the origin it started on: the same scheme,
    host and port (a redirect to the same host on another port goes without it).
  - `lib/flow/flow_runner.dart`, the redirect code (`redirectRules` and the function that builds the next hop): a hop
    to another host is sent without the `Authorization` header (`crossHost`).
  - Every client that talks to Mazama's server sends `appApiKeyHeaders` (an app key, not a user secret). Search for
    `appApiKeyHeaders`: none of those files puts `accessToken`, `refreshToken` or `Bearer` into a request. When the
    app needs state data on Mazama's behalf, it uses the token itself and uploads only the result (example:
    `lib/configured_coa_submit.dart` downloads the lab report from the state with the token, then sends only the PDF
    bytes, the lot id, the state's document id, the state's psilocybin figure, the worker's email and the device id to
    Mazama's server).
  - Cookies: within one run of a flow, every cookie a host sets is sent on every later request of that run, to any
    allowed host (`flow_runner.dart`'s cookie jar is not kept per host; each run starts with an empty one). The
    sign-in sends nothing to `psilocybin.oregon.gov` (claim 4), so the state's B2C session cookies go only to B2C, and
    to a host a signed list added if a spec requested it. They never leave the allowlist.
- **Tests:** `test/state_document_client_test.dart` (group "the token stays on the state host"),
  `test/flow/flow_runner_test.dart` (redirect and allowlist cases). No test inspects the headers of requests to
  Mazama's server; that part is checked by reading the code (search `appApiKeyHeaders`).

### 3. Every request the sign-in and state flows make is held to the host allowlist, redirects included

- **Statement:** before any request is sent, and before each redirect hop is followed, its URL must be `https`, port
  443, and on an allowed host. A request that fails the check is never sent. The interpreter follows redirects itself,
  and only for GET and HEAD.
- **Where to look:**
  - `lib/flow/flow_spec.dart`: `defaultAllowedHosts` (the two state hosts, exact matches) and `hostAllowedUrl` (the
    check: scheme, port, no `@` or backslash, host shape).
  - `lib/flow/flow_runner.dart`: `runFlow`, `_runRequest`, `_blocked`. Every `http.Request` is made with
    `followRedirects = false`, and each hop is checked before it is sent.
- **Not covered by this claim:** lab-report downloads (`downloadStateDocument`, claim 2) start on an allowed host but
  follow a redirect to any `https` host; the token is dropped there, the `Referer`, `Origin` and `User-Agent` headers
  are sent. The in-app browser's own traffic is claim 5's.
- **Tests:** `test/flow/flow_runner_test.dart`, `test/flow/spec_versions_test.dart` (the shared host cases in
  `assets/shared/flows/contracts/spec_versions.json`).

### 4. Mazama's server is trusted for sign-in only within these rules

- **Statement:** after a failed sign-in, the app may ask Mazama's server for a newer sign-in description (a "sign-in
  spec") and a list of extra sign-in hosts. So Mazama's server is part of what you trust for signing in, but only
  within fixed rules: a fetched spec can choose the steps the sign-in takes on the state's hosts (which addresses it
  asks, in what order, what it reads from the answers), but not where the password goes (claim 1) or what a failure
  report says beyond fixed words (claim 7). In detail:
  - a fetched spec is held to the allowlist on every request, and to the password rule of claim 1 before it runs. The
    phone does not check a signature on a fetched spec (only the server does, before serving a hosted copy): within
    those rules, Mazama's server, or anyone able to answer as it, chooses its steps, the words of its questions to the
    worker (claim 1), and where at the sign-in hosts the email and tokens go;
  - a fetched host list is used only if it carries a valid Ed25519 signature made with the key whose public half is
    built into the app, in `assets/signing/signing.pub`.
- **A sign-in never sends anything to the state's API.** A fetched sign-in spec that signs in is saved; a password
  sign-in spec's `renew` then renews the session at start-up and before sales, with nobody watching, until a newer
  bundled spec replaces it. So two checks keep every sign-in and renewal away from `psilocybin.oregon.gov`, where the
  state's records and writes are:
  - before a fetched or saved spec runs, it may have no `request` step and no `open_browser` page address on that
    host (`_noStateApiRequests` in `lib/login_spec_store.dart`; shared cases "a login request to the state's API",
    "a renew request to the state's API", "an open_browser opening the state's site"). An `open_browser`'s `until`
    may name it: that address is matched, not requested by the app;
  - while any sign-in or renewal runs, bundled specs included, the app itself sends nothing to that host: a step's
    own address there is refused, and a redirect there is not followed (the redirect itself comes back as the
    answer), however the host is spelled (upper case, a trailing dot)
    (`neverRequest: const {stateApiHost}` in `lib/sign_in_attempt.dart` and `lib/session.dart`, enforced in
    `lib/flow/flow_runner.dart`'s `runFlow` / `_runRequest`).

  So a sign-in spec can use the worker's tokens only at the state's sign-in tenant, and at a host a signed list
  added: the tokens can't be used on the worker's records through the app, but whoever runs a host the owner signed
  for, and receives them there, could use them at the state's API themselves.
  **The in-app browser is not covered by this:** "Sign in on the state's page" (claim 5) shows the state's own pages,
  and that browser loads any page on the allowlist, `psilocybin.oregon.gov` included, along with whatever frames and
  scripts those pages load (and, on Android, whatever their forms post); it holds none of the app's tokens. The app's own sale and read specs, which do use the state's API, are
  bundled in the app and never fetched (`lib/state_client.dart`, `lib/cart_page.dart`). A redirect to another allowed
  host carries the step's own headers except `Authorization`, and the run's cookies (claim 3).
- **Tests:** `test/flow/flow_runner_test.dart` ("a host in neverRequest is never sent to"), `test/session_test.dart`
  ("renewal never reaches the state API"), `test/login_spec_store_test.dart` (the shared cases).
- **`assets/signing/signing.pub` holds the owner's public key** (added 2026-10-25; before that it said `none`, which
  accepts no list). So a host list signed with the owner's private key can add sign-in hosts; one signed with any other
  key, or changed after signing, is ignored. Until a phone has used such a list, its allowlist is exactly the two state
  hosts. Any change to that file is visible in this repository. The hosts a list adds
  are named on screen ("Sign-in now also allows: …") only after the sign-in that used them, when the password has
  already been posted there; and a signed list can't be withdrawn from a phone that has none in use (any list ever
  signed counts as newer). `assets/signing/signing.pub` is copied from Mazama's private shared files when the app is
  built there; the copy in this repository is the one the app uses.
- **Where to look:**
  - `lib/login_spec_client.dart`, `lib/login_spec_store.dart` (`usableLoginSpec`, which rejects a spec naming any host
    outside the allowlist, or placing the password anywhere claim 1 doesn't allow).
  - `lib/login_hosts_client.dart`, `lib/login_hosts_store.dart` (`verifiedHostList`, `allowedHostsWith`,
    `currentAllowedHosts`; a list can only add hosts, never remove the two built-in ones, and `HostList` can only be
    made by `verifiedHostList`).
  - `lib/signing.dart` (`verifySigned`, `bundledPublicKey`: `none` means no key, so every check fails).
- **Tests:** `test/signing_test.dart` (shared signature vectors, including tampered and malleated signatures),
  `test/login_hosts_store_test.dart`, `test/sign_in_hosts_test.dart`, `test/login_spec_store_test.dart`.

### 5. Signing in on the state's own page: the app does not read what the worker types

- **Statement:** "Sign in on the state's page" shows the state's real sign-in page in an in-app browser. The app
  injects no JavaScript into that page and registers no JavaScript channel, so it cannot read what the worker types
  there. The state's own page scripts do run (JavaScript is on: the page needs it). Main-frame navigations the page
  starts (links, redirects, addresses set by script) load only on allowed hosts. **On Android, a form the page posts
  is not checked**: Android's WebView never asks the app about a POST navigation, so the state's page posts its own
  form wherever it says (on iPhone, form posts are checked too). Frames inside the page are not checked against the
  allowlist (on Android, frame navigations never reach the navigation check at all), and neither are the scripts,
  styles and images the page itself loads. The
  app reads only the address the page finally goes to (which carries the one-time code; the state's site may begin to
  load in the in-app browser at that moment, with the browser's own cookies, not the app's tokens), and exchanges that code with
  the state's token endpoint. Cookies and site data are cleared before the page opens (every time; a clearing call that
  fails is ignored and the page still opens) and, best effort, after it closes (if the app is killed during a sign-in, that second clearing doesn't happen until the next one). The
  clearing is app-wide. The sign-in page is the app's only webview: the Mazama inventory portal, a second in-app page
  that shared its cookie store, was removed (specs/center-web CW-R9).
- **Where to look:**
  - `lib/browser_sign_in_page.dart`: `decideBrowserNavigation`, the `NavigationDelegate`, and the clearing calls
    (`clearCookies`, `clearCache`, `clearLocalStorage`); its file comment says what the navigation check does and
    doesn't see on each platform.
  - Search check: there is no `runJavaScript`, `addJavaScriptChannel` or `JavaScriptChannel` anywhere in `lib/`.
  - `assets/flows_phone/login_browser.yaml`: the address opened, and the token request.
- **Tests:** `test/browser_sign_in_test.dart`, `test/sign_in_browser_test.dart`.

### 6. Secrets are scrubbed from error messages

- **Statement:** error messages from the sign-in and state flows have every exact copy of the password, email, access
  token and refresh token that the run holds under those names (`password`, `email`, `access_token`,
  `refresh_token`: given to it, or read by it under one of those names) replaced (in any upper or lower case) before they are shown.
  An encoded copy (URL- or base64-encoded, say) is not recognised. Only the values that run holds are known to it: the
  email is an input of the password sign-in only, so an email the state repeats in an error of the browser sign-in,
  a renewal or a state read is shown as it is; after a renewal reads the state's new refresh token, the old one is no
  longer known to that run; a value a spec reads from an answer under some other name is not recognised; and an
  answer to a question not marked secret (claim 1) is not scrubbed. The interpreter's own messages about a spec's
  settings name no value. Sign-in, renewal and state-read errors are shown only on the phone; a sale's error text,
  scrubbed the same way, also goes to Mazama's server in the failed-sale report (claim 7). The one-time authorization code is not one of those values; instead, the
  step that opens the state's page never puts the address it comes back with (which carries the code) in an error, and
  the bundled browser spec's error messages don't name the code. (A spec's own error message could name it; sign-in
  error messages are shown only on the phone.) Renewal errors are never sent to the
  server either: when a sale is stopped because the session couldn't be renewed, the failed-sale report says one of
  three fixed texts (`sessionFailureReportText` in `lib/session.dart`, used by `lib/cart_page.dart`), never the
  error's own message, which a renewal spec could fill with a value it read under another name.
- **Where to look:** `lib/flow/flow_runner.dart`: `defaultSecretKeys`, `_scrub` (used for every `FlowError` message
  built from a spec), and `_runOpenBrowser` (the returned address goes only to the step's extract rules);
  `assets/flows_phone/login_browser.yaml` (its `error:` lines).
- **Tests:** `test/flow/flow_runner_test.dart` (secret-scrubbing cases for the password, email and access token; the
  refresh token goes through the same code without a test of its own); `test/session_test.dart` ("a failed-sale
  report names a session problem in fixed words, never its message") and `test/cart_page_sell_outcomes_test.dart` ("a renew error
  carrying a captured token ... never reaches the failed-sale report").

### 7. What the app does send to Mazama's server

- **The worker's email address** (`workerEmail`, in sale logs, failed-sale reports, orders, par levels, inventory
  uploads and lab-report submissions), so sales can be attributed to the worker who made them. Search for
  `workerEmail` in `lib/*_client.dart` and `lib/configured_coa_submit.dart`.
- **A random install id** (`lib/device_id.dart`: a random token made the first time the app needs it, not a hardware
  id).
- **Business data:** sale records and the state's reply to them (`lib/sale_log_client.dart`), the state's raw
  inventory records (`lib/inventory_upload_client.dart`), orders (`lib/order_client.dart`), par levels
  (`lib/par_client.dart`), the text read from a scanned label (`lib/scan_match_client.dart`), lab-report PDFs with
  the state's document id and psilocybin figure for the lot, and look-ups of lab-report data by lot id
  (`lib/coa_data_client.dart`), and label look-ups by lot id (`lib/label_client.dart`). The center's state id is in
  the address of most requests to the server (`lib/api_contract.g.dart` lists every route and its address),
  and every request carries Dart's default `User-Agent` (platform and Dart version).
- **Failed-sale reports** (`lib/sale_failure_client.dart`): the sale records and a reason. For a session problem the
  reason is a fixed text (claim 6); otherwise it is the sale flow's own error text, from the bundled
  `assets/flows/sale.yaml` (never fetched from the server), which can include the state's reply to the sale (for
  example "[uncertain] the state answered 200 but …"), or "unexpected <type> while selling".
- **Sign-in failure reports** (`lib/signin_failure_client.dart`, `postSigninFailureFor`, called by
  `defaultSigninFailureReporter` in `lib/main.dart`): only the install id, the failed step's name, how far the request
  got (one of three words), the HTTP status, the failure's reason word and the sign-in spec's version. They carry no
  email, password, token or message, and are not sent for a wrong password. They carry only fixed words, whatever
  spec ran: the step's name only when it is a step of the app's own bundled `assets/flows/login.yaml` or
  `assets/flows_phone/login_browser.yaml` (else `other`, `bundledSigninStepIds`, `reportedSigninStep`), and the
  reason only when it is one of `structure`, `unavailable`, `refused`, `needs_person`, `not_allowed` (else nothing,
  `reportedSigninReasons`). So a fetched spec can't choose the text that reaches the server. (It can still choose
  *which* of those fixed words a failed sign-in reports, by testing values it read from the state's answers; that is a
  few bits per failed sign-in, never the password itself, which no condition may test.) Tests:
  `test/signin_failure_client_test.dart` (group "only fixed words reach the server").
- **Also:** a free-text note the worker may add to an order (`lib/order_client.dart`); and, like any server, the
  phone's IP address and the time of every request, including the `/p/ping` check that the server is up. The install
  id is in both the sign-in failure reports and the sale logs, so the server can tell they came from the same phone.
- **The email is the one the worker typed.** The password sign-in proves it to the state; "Sign in on the state's
  page" doesn't (the worker signs in on the state's page, and the app keeps the email typed on its own form). So when
  Mazama's server attributes a sale, order or lab report to an email, it is the email the phone was given.
- Never the password or a token (claims 1 and 2).

### 8. Third-party code: no analytics or crash reporting, one Google library on Android

- **Statement:** the app's Dart code includes no analytics, advertising, tracking or crash-reporting SDK. **One
  native exception, on Android only:** label scanning uses Google ML Kit Text Recognition
  (`com.google.mlkit:text-recognition` in `android/app/build.gradle.kts`). It reads the photo on the phone, but per
  Google's ML Kit terms it sends performance and usage metrics about the library to Google. It never receives the
  email, password or tokens. On iPhone, label scanning uses Apple's on-device Vision framework. On Android the label
  photo is taken by the phone's own camera app (`ACTION_IMAGE_CAPTURE`, `TextScanner.kt`), whichever app that is.
- **Where to look:** `pubspec.yaml` (`dependencies:`), `pubspec.lock`, and the native dependencies in
  `android/app/build.gradle.kts`. The Dart dependencies are:
  - `http`, `crypto`, `cryptography`, `yaml`, `path_provider`, `url_launcher`, `webview_flutter`, `share_plus`,
    `ffi`, `pdfrx`, `sqlite3`, `flutter_secure_storage`;
  - `pdfrx` gets its PDF engine when the app is built; the app opens PDFs only from memory;
  - `sqlite3` likewise gets a prebuilt SQLite library when the app is built (its build hook); it keeps what the app
    stores on the phone in one local file (claim 9) and talks to nothing;
  - `flutter_secure_storage` is the iOS Keychain / Android Keystore, for the session (claim 9);
  - `share_plus` opens the share sheet only when the worker taps "Save report" on the reconciliation report (an image
    that shows the worker's email); in debug builds, also lab-report PDFs and the state's product-info JSON.
- The phone's own browser engine (Android System WebView, WKWebView) may send its own diagnostics and safe-browsing
  checks under the phone's settings; the app doesn't turn them off.

### 9. Where credentials and tokens are stored on the phone

- **Statement:** the password is never stored. The session (email, access token, refresh token and expiry) is kept in
  the phone's secure storage, so the worker doesn't have to sign in every time the app opens: the iOS Keychain or the
  Android Keystore (`flutter_secure_storage`, key `mazama.session`, `PlatformSecretStore` in `lib/secret_store.dart`),
  never in the app's database or any file on those phones. On iPhone the item is
  `first_unlock_this_device`: readable from the first unlock after the phone starts, never synced to iCloud Keychain
  and never restored onto another phone.
- **Builds before this one kept it in a file**, `session.json`, in the app's private data folder, not encrypted by the
  app. The first launch of this build moves that session into secure storage and deletes the file (deletes, never
  renames; a corrupt file is deleted too).
- **A reinstalled app does not get the previous session back.** iOS keeps Keychain items after an app is deleted, so
  the app keeps a non-secret install marker (the `session_install` document) in its database, which is deleted with
  the app: when the marker is missing, the app deletes any session in secure storage before it reads one
  (`SessionStore` in `lib/session_store.dart`, `test/secret_store_test.dart`). If that deletion fails, or the database
  can't be opened, no session is loaded; a session the worker then saves overwrites the old one and writes the marker,
  so it is kept.
- **If secure storage fails** (a locked keychain, a damaged Keystore key), nothing is kept anywhere else: the worker
  signs in again.
- **The rest of what the app keeps is in one database file**, `mazama.db` (SQLite, `lib/local_store.dart`), in the
  app's private data folder, not encrypted by the app (the operating system's per-app sandbox protects it). Builds
  before this one wrote separate files; the first launch imports them and renames each `<name>.migrated` (deleted by a
  later release).
- **These are kept out of backups.** Android: the app turns backup off (`android:allowBackup="false"`,
  `android:fullBackupContent="false"`) and excludes everything from cloud backup and device-to-device transfer
  (`android:dataExtractionRules`, `android/app/src/main/res/xml/data_extraction_rules.xml`), all in
  `android/app/src/main/AndroidManifest.xml`. iPhone: at launch the app marks its Application Support folder, where the
  file lives, as excluded from iCloud and computer backups (`excludeAppSupportFromBackup` in
  `ios/Runner/AppDelegate.swift`; best effort). Builds made before that change did include the session file in
  backups. (Keychain items themselves are `ThisDeviceOnly`, so an encrypted backup can't carry them to another phone.)
- **The email is also kept elsewhere**, in `mazama.db` in the same private, backup-excluded folder: in its
  `server_outbox.json` document (`lib/server_outbox.dart`: sale logs and failed-sale reports waiting to reach Mazama's
  server, which carry it, claim 7) and its `server_catch_up.json` document (`lib/catch_up_store.dart`: work waiting to
  be redone), and, until the clean-up release, in the `server_outbox.json.migrated` and
  `server_catch_up.json.migrated` files an older build left. Signing out deletes the session from secure storage
  (and any `session.json` left) only: those keep what still has to be sent. The reconciliation report image, which shows the
  email, is written to the app's temporary folder when the worker shares it, and on Android label photos stay in its
  cache folder; the app doesn't delete either (the system may clear those folders). On iPhone, the cart-timers widget's shared settings hold cart names and
  timers (no email or token) outside the backup-excluded folder.
- The in-app browser keeps the state's page cookies in the phone's own web view storage while that page is open;
  the app clears them before it opens and after it closes (claim 5).
- Only Android and iPhone builds are made.
- **Where to look:** `lib/session_store.dart` (`SessionStore`, the install marker and the move, `initAppDataDir`,
  which uses `path_provider`'s application support folder), `lib/secret_store.dart` (`PlatformSecretStore`),
  `lib/local_store.dart` and `lib/session.dart` (`toJson`). `test/local_store_guard_test.dart` fails on a file write
  under `lib/` outside the allowed files, and on the phones' secret store reaching the database.
- Off the phones (the desktop builds, and `flutter test`), where there is no secure storage, the session is a document
  in `mazama.db` (`DocumentSecretStore`).
- On iPhone, the web view's own cookies and site data (the state's sign-in page while it is open, the app's only web
  view since the Mazama inventory portal was removed, specs/center-web CW-R9) are kept by the system outside the
  Application Support folder, so the backup exclusion may not cover them.
- **Developer builds only:** `lib/debug_local_storage_page.dart` can show a summary of the session on screen (the email,
  the expiry and whether tokens are present, not the tokens). It is reachable only in
  debug builds (`kDebugMode`, `lib/debug_tools_page.dart`) and sends nothing.

## What these claims do not cover

- **That the app on your phone was built from this source.** Release builds are not reproducible, so these claims
  describe the source, not a particular binary.
- **The state system itself:** what the state does with your credentials is up to the state.
- **The phone's own keyboard, autofill and password manager.** The email and password fields are ordinary text
  fields (`lib/main.dart`; the password is hidden as it is typed), and so is a question a spec asks
  (`lib/sign_in_prompt.dart`) and the state's page itself. The phone's password manager or autofill service, and a
  keyboard app the worker installed, can see, save or sync what is typed there, under the phone's own settings.
- **The Mazama server's code** (not published here). It receives the data in claim 7. By design it never receives the
  password or tokens, which this source lets you check from the phone's side.
- **Who holds the signing key** behind `assets/signing/signing.pub`. The key's holder (the owner, who keeps it in the
  server's encrypted secrets) can sign a list adding a sign-in host (claim 4), so whoever can read that key, including
  anyone who takes over the server, could too.
- **Interception by a trusted certificate authority.** The app doesn't pin certificates, so a certificate authority
  the phone trusts (installed by an employer's device management, say) could read its traffic.
- **The developer-only "Sign-in files" page** (`lib/debug_signin_files_page.dart`, reachable only in debug builds:
  `kDebugMode`, `lib/debug_tools_page.dart`). It reads the hosted sign-in files (`login.yaml`, `login_browser.yaml`,
  `hosts.json` and their `.sig` files) straight from the https address typed into it, with no credentials and no app
  key, besides Mazama's server's copies through the usual `/p/` clients. Its "Try" buttons run a copy's sign-in through
  the same code as the sign-in page (`attemptSignIn` in `lib/sign_in_attempt.dart`): the typed password goes only where
  a normal sign-in sends it, under the same rules (claims 1 and 3; a copy that isn't a usable sign-in spec is not run).
  A try saves nothing (no session, spec or host list, nothing put in use) and reports nothing; the page keeps only the
  typed address, in `debug_signin_files.json`.
- **Links Mazama's server chooses.** Product-sheet links the app opens are built from paths the server sends
  (`lib/sheets_client.dart`, `lib/mazama_inventory_client.dart`); they never carry credentials. The path is not checked
  to begin with `/`, so the server can make such a link open any site. They open in a browser tab over the app
  (`LaunchMode.inAppBrowserView`), not in the app's own web views.

- **The Contact sheet's links** (`lib/mazama_contact.dart`): Mazama's site with its shared guest login in the
  address, and a Signal link, each opened outside the app when the worker taps it.
- **The link to this repository** on the sign-in page (`OpenSourceLink`, `lib/open_source_link.dart`) opens
  `https://github.com/apotheharry-web/mazama_mobile` in the phone's browser. It carries nothing typed on the page.

## Known gaps

- Release builds still write some error text to the device log (`debugPrint`). Flow errors in that text are scrubbed
  as claim 6 says. Other error text is written as it is: an unexpected exception while selling (`lib/cart_page.dart`),
  errors from Mazama's server or from saving the app's own files (`lib/cart_page.dart`, `lib/server_outbox.dart`,
  `lib/catch_up_store.dart`), and errors from the cart-timer widget (`lib/cart_timer_widget.dart`). Flutter itself
  may also log the text of an error the app doesn't catch.
- Builds made before 2026-10-26 were signed with a debug key under the app id `com.example.mazama_mobile`; remove
  them from phones: anyone holding that debug keystore could sign an "update" that Android installs over them and that
  inherits their saved session. Builds since then are `com.mazamamushrooms.mobile`, signed with the owner's upload key
  (`android/app/build.gradle.kts` refuses a release build without it, unless `MAZAMA_DEV_RELEASE=1` is set for a
  test build, which is then signed with the debug key under that same app id: such a test build has the same weakness,
  so it is only for the developer's own phone, and removed after testing).
- The app's key for Mazama's server (`appApiKey`, `lib/app_api_key.dart`) is given at build time and is in every
  build, so it is not a secret from anyone holding the app. It only turns away strangers who find the server's
  address; it is not a worker credential and gives no access to the state system.
- `lib/mazama_contact.dart` holds a deliberately shared guest login for Mazama's own website (`mazamaGuestLogin`),
  given out on purpose; it is not a worker credential either.

## Checking these claims with an AI assistant

Give an assistant this folder (or this repository) and this prompt:

> You are auditing the Flutter app in this repository. Read `SIGN-IN-SECURITY.md`, then check each numbered claim
> against the source code, not against the comments. For each claim, open every file and function it names, follow
> the data (the password, the email, the access and refresh tokens, the authorization code) from where it enters to
> every place it is sent, stored, logged or displayed, and look for any path the claim doesn't mention. Search the
> whole `lib/` folder for `http.`, `Request(`, `Uri.parse`, `post(`, `get(`, `send(`, `WebView`, `runJavaScript`,
> `print(`, `debugPrint(`, `workerEmail`, `accessToken`, `refreshToken`, `password` and `Bearer`. Also check the
> request URLs in `assets/flows/*.yaml` and `assets/flows_phone/*.yaml`, and the native code and settings under
> `android/` and `ios/` (permissions, backup settings, native libraries). For each claim answer TRUE, FALSE or PARTLY
> TRUE, with the file and line numbers that prove it, and list anything else you found that sends user data off the
> phone.
