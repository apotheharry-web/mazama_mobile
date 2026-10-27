# Mazama service-center app

The phone app (Android and iPhone) that staff at Oregon psilocybin service centers use with
[Mazama Mushrooms](https://mazamamushrooms.com), a licensed psilocybin manufacturer. It brings together, on one phone,
what a center's staff need to sell Mazama's products and keep the state's records right.

## What it does

- **Signs in to the state's system.** Staff sign in to Oregon Psilocybin Services' product-tracking system with their
  own state account, on the phone. A center with several licenses is picked from a list.
- **Shows the center's stock.** What the state's system says the center holds: units and potency by strain and
  product type, the lots, and anything that can't be sold and why.
- **Sells, straight to the state.** Staff build a cart (several at once, each with its own timer, also shown in a
  home-screen widget), and the sale is recorded in the state's system from the phone. A sale that couldn't be
  recorded is kept and reported so it can be checked and finished.
- **Reads product labels.** Scanning a package's label with the camera finds the matching package in the center's
  stock. The text is read on the phone.
- **Draws product labels and dosing.** From each lot's lab report, using the same reader and rules as Mazama's own
  labels (`mazama_modules/coa/`), so the dose on a label never exceeds what the product holds.
- **Orders from Mazama.** Staff see what Mazama has available, set the center's par levels, and send an order.
- **Counts the safe.** A reconciliation page compares the state's figures with a physical count, item by item.
- **Keeps working when Mazama's server is down.** Selling never depends on it; reports wait on the phone and are sent
  when it is back.
- **Has a demo mode** with an invented center, for trying the app without a state account.

## Privacy and security

To work, the app asks for each person's **own state email and password**. They go only to the state, never to
Mazama: [**SECURITY.md**](SECURITY.md) says exactly how, and how anyone can check it against this code with an AI
assistant. What the app does send to Mazama, who sees it and how long it is kept is in the
[**privacy policy**](PRIVACY.md).

## What is here

| Path | What |
|---|---|
| `mazama_mobile/` | The app (Flutter). `lib/` is the code, `test/` its tests, `assets/` what it bundles, `android/` and `ios/` the native parts. [`SIGN-IN-SECURITY.md`](mazama_mobile/SIGN-IN-SECURITY.md) is the detailed account of the sign-in. |
| `mazama_modules/coa/` | The lab-report reader the app compiles in (Rust: `coa_core`, its C interface `coa_core_ffi`, and the rules it reads, `rules/coa_rules.yaml`). |
| `login.yaml`, `login_browser.yaml`, `hosts.json` and their `.sig` files | Signed copies of the app's sign-in steps and allowed sign-in addresses, which let Mazama follow a change to the state's sign-in page without a new app release (see SECURITY.md). |
| `SECURITY.md`, `PRIVACY.md`, `AUDIT.md`, `audits/` | Security, the privacy policy, the audit prompt and our audit reports. |
| `codemagic.yaml` | How the released apps are built. |
| `LICENSE`, `NOTICE` | Apache License 2.0, and who holds the copyright. |

The sign-in steps and test data under `mazama_mobile/assets/` are copies of files Mazama keeps in a private
repository along with its server; the copies here are the ones the app uses.

## Releases

Every release is a tag `v<version>`, matching the `version:` in `mazama_mobile/pubspec.yaml`, built by Codemagic from
that tag's commit. The Android app is attached to the tag's [GitHub release](../../releases) with its SHA-256; the
iPhone app is on the App Store.

## Build it yourself

You need Flutter (stable) and Rust (`rustup`), with the targets for your phone:

```
cd mazama_mobile
rustup target add aarch64-linux-android x86_64-linux-android     # Android; iPhone: aarch64-apple-ios
flutter pub get
flutter test
flutter run                                                     # a debug build on a connected phone
```

A build made this way signs in to the state normally, but Mazama's server turns it away: the server wants an app key
given at build time (`--dart-define=APP_API_KEY=...`), which only Mazama's builds have. That key is not a secret from
anyone holding the app and protects nothing about a worker's sign-in.

## Licence

[Apache License 2.0](LICENSE): you may use, change and share this code, including in your own products, provided you
keep the licence and the [NOTICE](NOTICE) and say what you changed. It comes with no warranty. The licence doesn't
cover Mazama's name: a changed version must not be presented as Mazama's app.

## Contact

Open an [issue](../../issues) on this repository. For a security problem, please don't: report it privately as
[SECURITY.md](SECURITY.md) says.
