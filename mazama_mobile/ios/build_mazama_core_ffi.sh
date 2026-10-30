#!/bin/sh
# Builds mazama_core_ffi (the shared core, Rust) for the iOS app: run by the Runner target's "Build mazama_core_ffi"
# phase, before anything is linked. The static library it writes is linked into the app with -force_load
# (OTHER_LDFLAGS in Runner.xcodeproj), and lib/mazama_core.dart finds its functions in the app itself
# (DynamicLibrary.process()). The iOS twin of android/app/build.gradle.kts's buildMazamaCoreFfi.
#
# OTHER_LDFLAGS also passes -Wl,-u,_<name> for each C function: nothing in the app calls them directly, and the
# linker's dead stripping (on in release builds) removes unreferenced functions from an app's executable, even when
# -force_load brought them in. The list is mazama_modules/core/ios_symbols.txt (generated from functions.yaml by
# mazama_modules/core/gen.py); mazama_modules/core/tests/test_functions.py fails while any of the three Runner
# configurations misses one, and Codemagic's symbol check fails the build when the app lacks one.
#
# Needs Rust with the iOS targets: rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
# Without them the build FAILS, saying what to install: the core is part of every build (specs/core CR-D2), and an app
# without it can't start (it shows "This build is missing a part").
set -eu

out_dir="${TARGET_TEMP_DIR}/mazama_core_ffi"
out="${out_dir}/libmazama_core_ffi.a"
manifest="${PROJECT_DIR}/../../mazama_modules/core/mazama_core_ffi/Cargo.toml"
target_dir="${PROJECT_DIR}/../build/mazama_core_ffi_ios"
mkdir -p "$out_dir"

# Xcode's own PATH doesn't include rustup's
export PATH="${HOME}/.cargo/bin:${PATH}"

# Rust targets for this build: a device build is arm64; a simulator build is whichever of arm64 / x86_64 Xcode asks for
targets=""
for arch in ${ARCHS}; do
  case "${PLATFORM_NAME}:${arch}" in
    iphoneos:arm64) t=aarch64-apple-ios ;;
    iphonesimulator:arm64) t=aarch64-apple-ios-sim ;;
    iphonesimulator:x86_64) t=x86_64-apple-ios ;;
    *) echo "error: mazama_core_ffi: no Rust target for ${PLATFORM_NAME} ${arch}"; exit 1 ;;
  esac
  targets="${targets} ${t}"
done

fail() {
  echo "error: mazama_core_ffi: $1. The app can't be built without it (specs/core CR-D2)."
  exit 1
}

[ -f "$manifest" ] || fail "${manifest} not found (build from the monorepo)"
command -v cargo >/dev/null 2>&1 || fail "cargo not found: install Rust (https://rustup.rs), then rustup target add${targets}"
if command -v rustup >/dev/null 2>&1; then
  installed=$(rustup target list --installed)
  for t in ${targets}; do
    echo "$installed" | grep -qx "$t" || fail "Rust target ${t} missing: rustup target add ${t}"
  done
fi

libs=""
for t in ${targets}; do
  # Xcode's environment is for the iOS SDK: left in place, SDKROOT makes cargo link its build-machine helpers
  # (serde_derive, build scripts) against the iOS SDK, which fails. IPHONEOS_DEPLOYMENT_TARGET is kept, so the
  # library targets the same iOS version as the app.
  env -u SDKROOT -u LIBRARY_PATH -u LD -u CC -u CXX -u CFLAGS -u LDFLAGS \
    cargo build --release --target "$t" --manifest-path "$manifest" --target-dir "$target_dir" \
    || fail "cargo build for ${t} failed (output above)"
  libs="${libs} ${target_dir}/${t}/release/libmazama_core_ffi.a"
done

rm -f "$out"
# shellcheck disable=SC2086  # split on purpose: one argument per library
set -- ${libs}
if [ "$#" -eq 1 ]; then
  cp "$1" "$out"
else
  xcrun lipo -create "$@" -output "$out"
fi
echo "mazama_core_ffi: built for${targets}"
