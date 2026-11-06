# A NixOS module that installs the toolchain needed to build and test the phone app (mazama_mobile/) on a NixOS
# machine: Flutter/Dart, a JDK, and an Android SDK built from whatever versions the host's own nixpkgs ships (see
# the androidComposition comment below for why this doesn't pin exact sub-component versions). The flake exports it
# as nixosModules.mazama-mobile-dev (options only, off by default); a host turns it on with
# programs.mazamaMobileDev.enable and picks its Android platform and build-tools versions there.
#
# What this does NOT give you: an iOS build. Xcode is Apple's and only runs on macOS; nothing in nixpkgs can stand
# in for it on NixOS/Linux. This module covers the Dart/Flutter logic itself (buildable and testable anywhere,
# `dart test`/`flutter test`) and Android builds; an iPhone build needs a Mac with Xcode installed, pointed at a
# mazama_mobile checkout - there is no way around that from a NixOS machine.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.programs.mazamaMobileDev;

  # Every sub-component (cmdline-tools, platform-tools, platforms, build-tools, ...) only exists in the exact
  # versions nixpkgs happened to snapshot from Google's repository.json when your channel was built, and pinning a
  # version by hand, as earlier drafts of this module did, just means guessing wrong against a channel I can't see
  # from the sandbox this was written in. So: pass nothing but what actually needs to be a *choice* (which Android
  # platform/build-tools to target, left overridable below) and let composeAndroidPackages fall back to whichever
  # versions of everything else it already knows exist for your nixpkgs. If `androidPlatformVersion` or
  # `androidBuildToolsVersion` themselves turn out not to exist on your channel, the error will name the ones that
  # do (the same shape of error as the platform-tools one you just hit) - set the option to one of those.
  androidComposition = pkgs.androidenv.composeAndroidPackages ({
    includeNDK = true;            # the app has no native (C/C++) code today; flip this on in your own override if that changes
    ndkVersions = [ "28.2.13676358" ];

    # the jni plugin's native module configures its build with CMake (see its CMakeLists.txt) and asks Gradle
    # for this exact CMake version - same "install into the read-only store" failure as a missing platform or
    # build-tools version otherwise, so it's pinned here the same way ndkVersions is, rather than left to
    # composeAndroidPackages' own default (which doesn't include a cmake package at all unless asked).
    cmakeVersions = [ "3.22.1" ];
    includeEmulator = cfg.includeEmulator;
    includeSystemImages = cfg.includeEmulator;
  } // optionalAttrs (cfg.androidPlatformVersion != null) { platformVersions = toList cfg.androidPlatformVersion; }
    // optionalAttrs (cfg.androidBuildToolsVersion != null) { buildToolsVersions = toList cfg.androidBuildToolsVersion; });

  androidSdkRoot = "${androidComposition.androidsdk}/libexec/android-sdk";

  # pkgs.flutter's own engine binaries (bin/cache/artifacts/engine/**/flutter_tester, gen_snapshot, ...) come out
  # of nixpkgs non-executable - confirmed against the *official* cache.nixos.org copy itself (re-fetching a fresh
  # copy still showed `-r--r--r--`), not local corruption on this machine. The reason a chmod can't just be added
  # inside nixpkgs' own packaging: the engine files are extracted by `flutter precache` inside
  # pkgs/development/compilers/flutter/artifacts/fetch-artifacts.nix, a *fixed-output* derivation whose hash is
  # pinned in that package's versions/<ver>/data.json - any change to its output (including permission bits,
  # which NAR serialization does encode) would fail that derivation's own hash check. Rebuilding it yourself
  # reproduces the identical, deterministic (broken) output rather than fixing it.
  #
  # So this wraps the already-built `pkgs.flutter` instead, as a plain ordinary derivation (no fixed-output hash
  # to fight): dereference everything into a real, writable copy, chmod the engine binaries executable, and
  # rewrap `flutter`'s own entry point so FLUTTER_ROOT defaults to this copy instead of the original broken store
  # path. flutter_tools itself (the dart interpreter + flutter_tools.snapshot that actually runs) is untouched
  # and still runs from the original, perfectly-fine store path - only *engine artifact lookups* get redirected,
  # via the FLUTTER_ROOT environment variable flutter_tools already reads for exactly this purpose (that's the
  # same mechanism nixpkgs' own sdk-symlink.nix uses to point FLUTTER_ROOT at its symlinkJoin'd tree).
  #
  # This is a real, ordinary Nix build (just copying + chmod, no network, no compilation) - buildable locally and
  # pushable to a binary cache like nix-serve, unlike trying to "fix" the fixed-output derivation itself.
  #
  # Real build failure from a real rebuild, caught and fixed before the second attempt: the first draft used
  # `cp --no-preserve=mode,ownership`, meaning to strip the Nix store's read-only bit so the tree would be
  # writable - but `--no-preserve=mode` throws away ALL original permission bits, including the executable bit
  # on `bin/flutter`/`bin/dart` themselves, which were perfectly fine in the original. `makeWrapper` then
  # correctly refused to wrap a `.flutter-unwrapped` that had come out non-executable. Fixed by preserving mode
  # on the copy (`cp -a`-style, keeping each file's original executable bit) and adding writability separately
  # via `chmod -R u+w`, then still forcing +x specifically on the engine subtree that needs it.
  #
  # Unverified beyond `nix-instantiate --parse` plus one real failed rebuild now folded into this fix; I have no
  # Flutter toolchain to actually run `flutter test` against this myself. Please report back whether
  # `flutter_tester` runs (and whether its own permissions, under $out/bin/cache/artifacts/engine, actually show
  # +x) once this builds.
  fixedFlutter = pkgs.runCommand "flutter-${pkgs.flutter.version}-execfix" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    mkdir --parents "$out"
    cp --recursive --dereference --preserve=mode --no-preserve=ownership "${pkgs.flutter}/." "$out/"
    chmod --recursive u+w "$out"
    find "$out/bin/cache/artifacts/engine" -type f -exec chmod +x {} +

    mv "$out/bin/flutter" "$out/bin/.flutter-unwrapped"
    makeWrapper "$out/bin/.flutter-unwrapped" "$out/bin/flutter" \
      --set-default FLUTTER_ROOT "$out"
  '';
in {
  options.programs.mazamaMobileDev = {
    enable = mkEnableOption "the Flutter/Dart + Android toolchain for building mazama_mobile";

    androidPlatformVersion = mkOption {
      type = types.nullOr (types.either types.str (types.listOf types.str));
      default = null;
      example = [ "35" "36" ];
      description = ''
        Android platform(s) (API level) to install - a single version ("34") or several ([ "35" "36" ]). Left at
        `null`, composeAndroidPackages installs whichever platform(s) it defaults to for your nixpkgs channel; set
        this if `flutter`'s own Gradle build later asks for a specific `compileSdkVersion`/`targetSdkVersion` that
        default doesn't cover. A Flutter app's own module and its plugins (e.g. a `jni_flutter`-style native
        plugin) can each target a different compileSdk, so don't assume one version covers the whole build -
        the error names exactly which one is still missing if you guessed short.
      '';
    };

    androidBuildToolsVersion = mkOption {
      type = types.nullOr (types.either types.str (types.listOf types.str));
      default = null;
      example = [ "34.0.0" "35.0.0" ];
      description = ''
        Android build-tools version(s) to install - a single version ("34.0.0") or several. Left at `null`,
        composeAndroidPackages installs whichever version(s) it defaults to for your nixpkgs channel.
      '';
    };

    includeEmulator = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Also install an emulator and a system image, so `flutter run` can target a virtual device with no phone
        plugged in. Adds a lot to the closure size; leave this off if you'll always test on your own phone over USB
        (the common case - this is what gets you from "it's on my phone" to a sale, which an emulator can't do).
      '';
    };

    user = mkOption {
      type = types.str;
      default = "harrison";
      description = "The account that needs USB access to a plugged-in Android phone for `flutter run`/`adb`.";
    };

    enableAdb = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install `pkgs.android-tools`, so the `adb` command is on PATH for `flutter run` over USB. Set this to
        `false` if you don't want adb installed at all.
      '';
    };

    legacyAdbGroup = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Also turn on NixOS's old `programs.adb` (a udev rule plus an `adbusers` group that `user` is added to).
        Pre-systemd-258 channels needed this for a plugged-in phone to be usable by a non-root user; systemd
        >= 258 tags adb devices with `uaccess` itself and makes `programs.adb` a hard error if anything sets it
        at all, even via `mkDefault` - so this is a plain static option you flip per host, rather than something
        this module tries to detect: on nixos-25.11 (still has `programs.adb`) set it `true` if plain `adb` from
        `android-tools` isn't already usable as yourself; on nixos-unstable (systemd >= 258, `programs.adb`
        removed) leave it `false` or the rebuild fails outright. An earlier draft tried to detect this
        automatically from `pkgs.systemd.version`, and that reintroduced the exact infinite-recursion bug this
        module used to have via `cfg.enableAdb` (see the `config` block below) - through a different door: this
        module itself writes `nixpkgs.config.allowUnfree`, so on a config where `pkgs` is built internally by
        the module system (true for both your hosts - neither overrides `pkgs` via specialArgs), forcing
        `pkgs.systemd.version` strictly to decide an `optionalAttrs` branch ties `pkgs` back to this same
        module's own `config` output, which is what we're in the middle of building. Static and manual avoids
        that class of bug entirely.
      '';
    };

    useFixedFlutter = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Use the `fixedFlutter` wrapper (see its definition above) instead of plain `pkgs.flutter` directly.
        Whether nixpkgs' own `flutter` package needs this depends on the specific engine artifacts your channel
        fetched, which can differ by channel and by version - confirmed broken (non-executable
        `bin/cache/artifacts/engine/**`) on `nixos-unstable` as of 3.41.6, straight from the official
        cache.nixos.org substituter, not just locally. Set this to `false` on a host where plain `pkgs.flutter`
        already works (check with `ls -l $(dirname $(readlink -f $(which flutter)))/cache/artifacts/engine/*/flutter_tester`
        after a rebuild without this option) - a plain static per-host toggle, same reasoning as
        `legacyAdbGroup` above, rather than something this module tries to auto-detect.
      '';
    };

    devDisplay = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Run a virtual X11 display (Xvfb) plus an x11vnc server pointed at it, as two system services, so
          `flutter run -d linux` has somewhere to draw its GTK window on a headless host like `amanita`. Without
          this, `flutter run -d linux` fails with "Gtk-WARNING: cannot open display" - there's no X server at all
          to connect to. x11vnc is bound to loopback only (`-localhost`); view the window from elsewhere by
          SSH-tunnelling the VNC port (`ssh -L 5900:localhost:5900 user@host`, port is `5900 + displayNumber`)
          and pointing an ordinary VNC client at `localhost:5900` - nothing is exposed on the LAN, and no
          firewall rule is opened for this on purpose.
        '';
      };

      displayNumber = mkOption {
        type = types.int;
        default = 1;
        description = ''
          X display number Xvfb listens on (":1" by default). `DISPLAY` is set to this automatically in
          `environment.sessionVariables` while `devDisplay.enable` is on, so plain `flutter run -d linux` just
          works without exporting DISPLAY by hand. The VNC port is `5900 + displayNumber`.
        '';
      };

      resolution = mkOption {
        type = types.str;
        default = "1280x800x24";
        description = "Xvfb screen geometry, as widthxheightxdepth - passed straight to `Xvfb -screen 0 ...`.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      # composeAndroidPackages refuses to build at all until something accepts the SDK's licenses on your behalf -
      # that's the "--- android-sdk-license ---" error nixos-rebuild throws without this. Android's own
      # build-tools and platform packages are also marked unfree, hence allowUnfree.
      nixpkgs.config.android_sdk.accept_license = true;
      nixpkgs.config.allowUnfree = true;

      environment.systemPackages = [
        (if cfg.useFixedFlutter then fixedFlutter else pkgs.flutter)
        pkgs.jdk17
        androidComposition.androidsdk
      ];

      # Flutter and Gradle both look for these; without them `flutter doctor` reports Android tooling as missing
      # even though it's right there in the Nix store.
      environment.sessionVariables = {
        ANDROID_HOME = androidSdkRoot;
        ANDROID_SDK_ROOT = androidSdkRoot;
        JAVA_HOME = pkgs.jdk17.home;
        # Dart's own HTTP/TLS stack (used by `pub get`, and by `flutter doctor`'s "Network resources" check)
        # doesn't fall back to the system's /etc/ssl/certs the way most Linux tools do - without this it's blind
        # to any CA bundle at all, surfacing as `flutter doctor`'s "[☠] Network resources ... TlsException:
        # Failed to find root cert file". NIX_SSL_CERT_FILE is the Nix-ecosystem convention; SSL_CERT_FILE is the
        # more widely recognized one Dart itself actually reads - setting both covers either lookup.
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
    })

    # Gets you the `adb` binary itself, on every channel - harmless alongside the SDK's own bundled
    # platform-tools/adb from androidComposition above. This used to be `{...} // optionalAttrs cfg.enableAdb
    # {...}` merged into the block above, which caused a real infinite-recursion error on rebuild: `optionalAttrs`
    # isn't module-system-aware, so forcing its condition (cfg.enableAdb, an option declared by *this* module) to
    # decide whether those keys even exist required this module's own `config` to already be fully built - which
    # was what we were in the middle of building. `mkIf`, unlike `optionalAttrs`, is special-cased by the module
    # system to defer exactly this, so keeping each condition in its own `mkIf`, merged with `mkMerge`, gives the
    # same conditional effect without the cycle.
    (mkIf (cfg.enable && cfg.enableAdb) {
      environment.systemPackages = [ pkgs.android-tools ];
    })

    # See the `legacyAdbGroup` option's own description above for why this is a plain static switch rather than
    # something this module detects on its own.
    (mkIf (cfg.enable && cfg.enableAdb && cfg.legacyAdbGroup) {
      programs.adb.enable = mkDefault true;
      users.users.${cfg.user}.extraGroups = [ "adbusers" ];
    })

    # See `devDisplay.enable`'s own description above. Two services: Xvfb owns the virtual display itself,
    # x11vnc just connects to it and serves VNC on loopback - `requires`/`after` on the Xvfb service means
    # x11vnc won't come up (or will restart until it does) before there's actually a display for it to attach
    # to. Both run as root, same as the rest of `systemd.services` here; Xvfb and x11vnc don't care who owns the
    # X socket in /tmp/.X11-unix, and `flutter run` (run as `cfg.user`, over the DISPLAY env var set below) only
    # needs to *connect* to it, not own the server process.
    (mkIf (cfg.enable && cfg.devDisplay.enable) {
      environment.systemPackages = [ pkgs.xorg.xvfb pkgs.x11vnc ];

      environment.sessionVariables = {
        DISPLAY = ":${toString cfg.devDisplay.displayNumber}";
      };

      systemd.services."mazama-dev-xvfb" = {
        description = "Virtual X11 display for mazamaMobileDev's devDisplay (lets `flutter run -d linux` draw a window on a headless host)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.xorg.xvfb}/bin/Xvfb :${toString cfg.devDisplay.displayNumber} -screen 0 ${cfg.devDisplay.resolution}";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };

      systemd.services."mazama-dev-x11vnc" = {
        description = "VNC server exposing mazama-dev-xvfb's display, loopback-only - view it by SSH-tunnelling the VNC port";
        after = [ "mazama-dev-xvfb.service" ];
        requires = [ "mazama-dev-xvfb.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          # -localhost: refuse anything not arriving via the loopback interface, so an SSH tunnel is the only
          # way in - deliberately not opened in the firewall. -nopw: fine given that; nothing reaches this
          # except whoever can already SSH in as a user who can open the tunnel. -forever: survive a client
          # disconnecting instead of exiting after one VNC session. -shared: more than one viewer can connect
          # (e.g. yourself from two laptops) without kicking the first.
          ExecStart =
            "${pkgs.x11vnc}/bin/x11vnc -display :${toString cfg.devDisplay.displayNumber} -localhost -nopw -forever -shared -quiet";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
    })
  ];
}