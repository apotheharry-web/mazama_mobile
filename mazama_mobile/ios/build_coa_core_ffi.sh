#!/bin/sh
# Builds coa_core_ffi (the shared lab-report reader, Rust) for the iOS app: run by the Runner target's
# "Build coa_core_ffi" phase, before anything is linked. The static library it writes is linked into the app with
# -force_load (OTHER_LDFLAGS in Runner.xcodeproj), and lib/coa_core_ffi.dart finds its functions in the app itself
# (DynamicLibrary.process()). The iOS twin of android/app/build.gradle.kts's buildCoaCoreFfi.
#
# OTHER_LDFLAGS also passes -Wl,-u,_<name> for each C function: nothing in the app calls them directly, and the
# linker's dead stripping (on in release builds) removes unreferenced functions from an app's executable, even when
# -force_load brought them in. Without -u, a release/App Store build had no coa_* functions and the phone said
# "isn't built". Adding a function to coa_core_ffi means adding it there (all three Runner configurations) and to
# the stand-in below.
#
# Needs Rust with the iOS targets: rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
# Without them the build FAILS, saying what to install: an app without coa_core can't draw labels on the phone, and a
# warning in a build log nobody reads is how that went unnoticed. To build without it on purpose (a machine without
# Rust), set COA_CORE_OPTIONAL=1: the app is linked with an empty stand-in and says "isn't built" on the phone.
set -eu

out_dir="${TARGET_TEMP_DIR}/coa_core_ffi"
out="${out_dir}/libcoa_core_ffi.a"
manifest="${PROJECT_DIR}/../../mazama_modules/coa/coa_core_ffi/Cargo.toml"
target_dir="${PROJECT_DIR}/../build/coa_core_ffi_ios"
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
    *) echo "error: coa_core_ffi: no Rust target for ${PLATFORM_NAME} ${arch}"; exit 1 ;;
  esac
  targets="${targets} ${t}"
done

stand_in() {
  # a stand-in library defining the same functions, so -force_load and the -u flags in OTHER_LDFLAGS still link;
  # coa_version returns NULL, so lib/coa_core_ffi.dart's CoaCore.tryLoad gives null and the app says "isn't built"
  echo "warning: coa_core_ffi: $1; COA_CORE_OPTIONAL=1, so the app is built without it (\"isn't built\" on the phone)"
  tmp="${out_dir}/stand_in"
  mkdir -p "$tmp"
  cat > "${tmp}/stand_in.c" <<'C'
void coa_core_ffi_not_built(void) {}
char *coa_parse_json(const char *s) { (void)s; return 0; }
char *coa_label_spec_json(const char *s) { (void)s; return 0; }
char *coa_find_lot_json(const char *s) { (void)s; return 0; }
char *coa_name_json(const char *s) { (void)s; return 0; }
char *coa_version(void) { return 0; }
void coa_free(char *s) { (void)s; }
C
  arch_flags=""
  for arch in ${ARCHS}; do arch_flags="${arch_flags} -arch ${arch}"; done
  # shellcheck disable=SC2086
  xcrun --sdk "${PLATFORM_NAME}" clang ${arch_flags} -c "${tmp}/stand_in.c" -o "${tmp}/stand_in.o"
  rm -f "$out"
  xcrun libtool -static -o "$out" "${tmp}/stand_in.o"
  exit 0
}

fail() {
  if [ "${COA_CORE_OPTIONAL:-}" = "1" ]; then stand_in "$1"; fi
  echo "error: coa_core_ffi: $1. To build without it on purpose, set COA_CORE_OPTIONAL=1 (the phone then can't draw labels)."
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
  libs="${libs} ${target_dir}/${t}/release/libcoa_core_ffi.a"
done

rm -f "$out"
# shellcheck disable=SC2086  # split on purpose: one argument per library
set -- ${libs}
if [ "$#" -eq 1 ]; then
  cp "$1" "$out"
else
  xcrun lipo -create "$@" -output "$out"
fi
echo "coa_core_ffi: built for${targets}"
