# mazama_mobile

The service-center phone app (Android + iOS, one Flutter codebase): workers sign in to the state system on the
device, see the center's inventory, build carts and send sales straight to the state; the Mazama server is called
only on its `/p/` routes (labels, packages, lab-report data, scan matching, sale logs).

- Instructions for working here: the repository's `AGENTS.md` ("mazama_mobile (phone app) conventions").
- After changing anything in `../mazama_modules/` that this app vendors: `bash tool/sync_flows.sh` (copies it into
  `assets/`; the copies are committed, and builds use them as they are: no build runs the script).
- Native camera text scanners: `ios/Runner/TextScanner.swift` and
  `android/app/src/main/kotlin/com/example/mazama_mobile/TextScanner.kt` (channel `mazama/text_scanner`). iOS builds: the root `codemagic.yaml`.
- What the app keeps between launches (carts, timers, the device id, the par columns chosen, and the sync engine's
  tables: its queue of sale logs, failed-sale reports, lab reports and snapshots, and its datasets, everything it has
  read with when, specs/phone-sync) is in one SQLite file, `mazama.db`, in the app's data folder, through
  `lib/local_store.dart`; what older builds kept in documents of their own (the outbox, the catch-up list, the reply
  store, the stock page's and Mazama's stock copies) is moved into the engine's tables on start
  (`lib/sync/sync_migration.dart`). The session's tokens are
  in the phone's Keychain/Keystore (`lib/secret_store.dart`). The files older builds wrote are imported on the first
  launch and renamed `*.migrated` (`session.json` is deleted once moved). Only the sign-in spec and host list are still
  files. `test/local_store_guard_test.dart` fails on a new file write. (`flutter_secure_storage` registers its Linux
  plugin too, so a Linux desktop build needs `libsecret-1` installed, although the session never uses it off the
  phones.)
- Tests run in CI (`mobile-analyze`, `mobile-test`); see `AGENTS.md` for reading the results.
- **The shared core is part of every build** (`lib/mazama_core.dart`, specs/core CR-D2): Android and iOS builds compile
  `../mazama_modules/core/mazama_core_ffi` and fail without Rust (`rustup target add aarch64-linux-android
  x86_64-linux-android`, or `aarch64-apple-ios`); an app that still can't load it shows one screen, "This build is
  missing a part. Reinstall the app." (`lib/missing_core_app.dart`). The tests need it too: build it and point
  `MAZAMA_CORE_FFI_LIB` at it, or the tests that reach it fail (`test/support/core.dart`):

  ```
  (cd ../mazama_modules/core/mazama_core_ffi && cargo build --release)
  MAZAMA_CORE_FFI_LIB=$PWD/../mazama_modules/core/mazama_core_ffi/target/release/libmazama_core_ffi.so flutter test
  ```

  A machine with Flutter but without Rust can't run them; CI always can (`core-ffi-build` runs first). Only the Android
  and iOS builds compile the core: a desktop debug run (Linux, macOS) shows the missing-part screen instead of failing to
  build.

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

The Android application id is `com.mazamamushrooms.mobile` (the iOS bundle id). Builds made before it was set used
`com.example.mazama_mobile`, which phones treat as a different app.

## The public copy

`apotheharry-web/mazama_mobile` holds this folder and the shared core (`mazama_modules/core/`, with the lab-report
rules in `mazama_modules/coa/rules/`) for anyone to read,
and Codemagic builds the releases there (`specs/public-app/README.md`). To publish a release:

1. Raise `version:` in `pubspec.yaml` (`x.y.z+N`, `N` above every earlier build) and merge to `main`.
2. `mazama_mobile/tool/publish_public.sh ~/mazama_mobile-public` (a clean clone of the public repository): it copies
   `main`'s commit without the real lab reports, checks it and commits there. It never pushes.
3. Read the commit, push it, then push the tag it prints (`v<version>`): Codemagic builds both apps from it.

The public repository's own README, SECURITY.md, codemagic.yaml and .gitignore are `tool/public/`. Left out of the
copy: `tool/`, `test/vendored_test.dart`, CI's test bundle (`test/all_tests_*.g.dart`, `test/all_tests_bundle_test.dart`),
the desktop/web folders and the real lab reports (`publish_public.sh`).
