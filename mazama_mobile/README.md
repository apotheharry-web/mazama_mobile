# mazama_mobile

The service-center phone app (Android and iOS, one Flutter codebase). Workers sign in to the state system on the
device, see the center's stock, build carts and send sales straight to the state; the Mazama server is called only
on its `/p/` routes (labels, packages, lab-report data, scan matching, sale logs, par levels, orders, uploads of what
the phone read from the state, sign-in files and app updates). Selling never waits on the Mazama server.

- Instructions for working here: the repository's `AGENTS.md` ("mazama_mobile (phone app) conventions"). The
  feature specs are under `../specs/` (for example `phone-sync`, `state-login`, `app-updates`, `public-app`).
- After changing anything in `../mazama_modules/` that this app vendors: `bash tool/sync_flows.sh` (copies it into
  `assets/`; the copies are committed, and builds use them as they are: no build runs the script).
- Native camera text scanners: `ios/Runner/TextScanner.swift` and
  `android/app/src/main/kotlin/com/example/mazama_mobile/TextScanner.kt` (channel `mazama/text_scanner`); they return
  raw text lines and the shared core matches them. iOS builds: the root `codemagic.yaml`.
- **What the phone keeps** (carts, timers, the device id, the par columns chosen, and the sync engine's tables: its
  queue of sale logs, failed-sale reports, lab reports and snapshots waiting for the server, and its datasets, each
  kept with where it came from and when) is in one SQLite file, `mazama.db`, in the app's data folder, through
  `lib/local_store.dart`. The session's tokens are in the phone's Keychain/Keystore (`lib/secret_store.dart`). Only the
  sign-in spec and host list are still files. Nothing an older build kept in files or documents of its own is moved
  in (specs/phone-sync PS-D8; only an old `session.json` is moved into the secret store and deleted).
  `test/local_store_guard_test.dart` fails on a new file write. (`flutter_secure_storage`
  registers its Linux plugin too, so a Linux desktop build needs `libsecret-1` installed.)
- **Features in their own folders** (specs/features): a new phone feature keeps its code in `lib/features/<name>/` and
  its tests in `test/features/<name>/`, with its entry point in `lib/features/<name>/entry.dart` (`const FeatureEntry
  entry`, `lib/feature_entry.dart`). The rest of `lib/` reaches a folder only through the generated
  `lib/feature_pages.g.dart` (`featureEntries`, by feature name), and no file outside the folder imports from it
  (`test/features_test.dart`). While its registry entry has only `on.phone_debug`, the feature is on in debug builds
  alone: `featureOnForLicense` and `licenseTypeListed` take `debugBuild` (default `kDebugMode`), and the public copy
  (below) leaves the folder out. It reaches the release app when the owner moves its license types to `on.phone`.
- **Manufacturer licenses** (specs/manufacturer-phone): in a build where a feature is on for `Manufacturer`, the
  license picker (`lib/select_center_page.dart`) lists the account's Manufacturer licenses after its centers (the
  core's `records.licenses_of_type`) and opens that feature folder's page on top of the picker. The release app lists
  none. Three such folders exist, each on for `Manufacturer` in debug builds only: `manufacturer_home` (the page, its
  Home tab), `make_products` (its Make tab: make page, review, job page) and `transfers` (its Transfer tab: send or
  retrieve, review with the manifest preview through pdfrx, job page). Their reads are kept in the `manufacturer`
  dataset; their writes are never queued and need the owner's approval of the pair and grant for the manufacturer.
- Tests run in CI (`mobile-analyze`, `mobile-public-analyze`: the public copy on its own, `mobile-test`); see
  `AGENTS.md` for reading the results. After adding, renaming
  or removing a test file, run `dart run tool/gen_test_bundle.dart` and commit the bundle it writes.
- **The shared core is part of every build** (`lib/mazama_core.dart`): Android and iOS builds compile
  `../mazama_modules/core/mazama_core_ffi` and fail without Rust (`rustup target add aarch64-linux-android
  armv7-linux-androideabi x86_64-linux-android`, or `aarch64-apple-ios`); an app that still can't load it shows one
  screen, "This build is missing a part. Reinstall the app." (`lib/missing_core_app.dart`). The tests need it too:
  build it and point `MAZAMA_CORE_FFI_LIB` at it, or the tests that reach it fail (`test/support/core.dart`):

  ```
  (cd ../mazama_modules/core/mazama_core_ffi && cargo build --release)
  MAZAMA_CORE_FFI_LIB=$PWD/../mazama_modules/core/mazama_core_ffi/target/release/libmazama_core_ffi.so flutter test
  ```

  A machine with Flutter but without Rust can't run them; CI always can (`core-ffi-build` runs first). Only the
  Android and iOS builds compile the core: a desktop debug run (Linux, macOS) shows the missing-part screen instead of
  failing to build.

- **Every number the phone shows or sends is the core's**: a unit's mg TPE, prices and the cart's split, the cart's
  totals (each line's, the cart's, each group's, a bulk sell's for n sales: `lib/cart_pricing.dart`'s `cartTotals`), the
  lot a unit is drawn from, the sale records, their date and the days the date pickers offer (`lib/selling.dart`'s
  `saleDateBounds`), and the 50 mg cap per sale with its session length (`lib/dose.dart`'s `saleLimits`; a line its
  lots can't cover counted on its strongest lot, `highestLot`). The cap counts only the lots the sale actually draws, each with its own figures,
  drawn as the records will be sent (`bulk_sale.dart`'s `cartDrawLimits`); a bulk sell checks every copy's own draw,
  refuses all of them when one is refused (naming the copy) and times the session by the largest copy. Before a sale
  the stock is read again when it is old or a drawn lot is only a phone's upload (`/p/packages`' `confirmed` false),
  and the cap is checked again on the state's figures. When the core can't answer, the sale is refused. The stock
  pages' figures and how each row is read (its kind, size, mg per unit, units on hand, a state record's kind) are the
  core's too (`stock_summary.dart`, `stock_mix.dart`, `stock_rows.dart`; specs/stock-page SP-R17, SP-R18), and
  `test/record_rules_guard_test.dart` fails on a read of a record's flags (`zeroOut`, `locked`, ...) in `lib/`
  outside the files that build records. The formulas and their sources: [specs/core/README.md, "How every number is calculated"](../specs/core/README.md#how-every-number-is-calculated).

## Release builds

A release build needs two things kept outside the repository, and fails without them (`android/app/build.gradle.kts`,
root `codemagic.yaml`):

- **The app key** the phone sends as `X-App-Key` (`lib/app_api_key.dart`): the value of the server's sops secret
  `mazama-sales-app-api-key`, given as `--dart-define=APP_API_KEY=...`. iOS (Codemagic): the secret variable
  `APP_API_KEY` in the app's environment variable group `mazama_app_key`.
- **Android release signing**: the owner's upload keystore, named by `android/key.properties` (git-ignored):

  ```
  storeFile=/absolute/path/to/mazama-upload.jks
  storePassword=...
  keyAlias=upload
  keyPassword=...
  ```

  or, on Codemagic, its Android code signing (`CM_KEYSTORE_PATH`, `CM_KEYSTORE_PASSWORD`, `CM_KEY_ALIAS`,
  `CM_KEY_PASSWORD`).

```
flutter build apk --release --dart-define=APP_API_KEY="$APP_API_KEY"         # or: flutter build appbundle ...
```

To try a release build on your own phone without either, set `MAZAMA_DEV_RELEASE=1`: it is signed with the debug key,
and with no app key the real server refuses its `/p/` calls. Not for distribution.

The Android application id is `com.mazamamushrooms.mobile` (the iOS bundle id). A phone treats an install with any
other id (such as `com.example.mazama_mobile`) as a different app.

## The public copy

`apotheharry-web/mazama_mobile` holds this folder and the shared core (`mazama_modules/core/`, with the lab-report
rules in `mazama_modules/coa/rules/`) for anyone to read, and Codemagic builds the releases there
(`../specs/public-app/README.md`). To publish a release:

1. Raise `version:` in `pubspec.yaml` (`x.y.z+N`, `N` above every earlier build) and merge to `main`.
2. `mazama_mobile/tool/publish_public.sh ~/mazama_mobile-public` (a clean clone of the public repository; it needs
   Python with PyYAML, e.g. under `nix-shell -p 'python3.withPackages(p: [p.pyyaml])'`, or one named with `PYTHON=`): it copies
   `main`'s commit without the real lab reports and without the unreleased features (debug-only: their folders, and
   the generated `features.g.dart`, `feature_pages.g.dart` and `api_contract.g.dart` written again without them and
   the `/p/` routes only they use; in the shared core, their Rust folders, schemas and vectors, and the core's
   generated files, `functions.yaml` and the iOS project's `-Wl,-u` lines written again without their functions by
   `mazama_modules/core/gen.py --public`), checks it and commits there. It never pushes. It refuses a copy that still
   names an unreleased feature, page class, folder, dropped route or core function (`<area>.<name>`, its C symbol or
   Dart method).
3. Read the commit, push it, then push the tag it prints (`v<version>`): Codemagic builds both apps from it.

The public repository's own root files (README, PRIVACY.md, AUDIT.md, SECURITY.md, codemagic.yaml, .gitignore,
.gitleaks.toml, LICENSE, NOTICE) and its dated audits are in `tool/public/`. Left out of the copy (`publish_public.sh`'s
list): `tool/`, `test/vendored_test.dart`, CI's test bundle, the desktop and web folders, the core's examples and
Rust tests (they read the private corpus), the real lab reports and every unreleased feature.
`tool/publish_public.sh --copy-only DIR` makes the same copy from the files on disk into DIR and stops after the
unreleased-feature check; CI's `mobile-public-analyze` runs `flutter analyze` over it.
