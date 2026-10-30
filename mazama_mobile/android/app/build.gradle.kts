import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// --- Release signing and the app key ---------------------------------------------------------------------------------
// A release build (flutter build apk/appbundle --release, assembleRelease/bundleRelease) is signed with the owner's upload
// key, from either
//   - Codemagic's Android code signing: CM_KEYSTORE_PATH, CM_KEYSTORE_PASSWORD, CM_KEY_ALIAS, CM_KEY_PASSWORD; or
//   - android/key.properties (never committed: .gitignore), lines storeFile=/absolute/path/upload.jks, storePassword=...,
//     keyAlias=..., keyPassword=... (the keystore itself lives outside the repository too);
// and must carry the app key (--dart-define=APP_API_KEY=..., lib/app_api_key.dart). Without either, the release build
// FAILS. To try a release build on your own phone without them, set MAZAMA_DEV_RELEASE=1: it is then signed with the
// debug key and carries whatever app key it was given (with none, the real server refuses its /p/ calls).
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.isFile) FileInputStream(f).use { load(it) }
}
fun signingValue(env: String, prop: String): String? =
    System.getenv(env)?.takeIf { it.isNotEmpty() } ?: keyProps.getProperty(prop)?.trim()?.takeIf { it.isNotEmpty() }
val releaseStoreFile = signingValue("CM_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signingValue("CM_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("CM_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("CM_KEY_PASSWORD", "keyPassword")
val hasReleaseSigning = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).all { it != null }
// Flutter hands --dart-define values to Gradle as -Pdart-defines=<base64>,<base64>,...
val dartDefines: List<String> = (project.findProperty("dart-defines") as String?)
    ?.split(",")?.filter { it.isNotEmpty() }
    ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
    ?: emptyList()
val hasAppKey = dartDefines.any { it.startsWith("APP_API_KEY=") && it.length > "APP_API_KEY=".length }
val buildingRelease = gradle.startParameter.taskNames.any { it.contains("Release") }
if (buildingRelease) {
    val missing = buildList {
        if (!hasReleaseSigning) add("release signing (android/key.properties, or Codemagic's CM_KEYSTORE_* variables)")
        if (!hasAppKey) add("the app key (--dart-define=APP_API_KEY=...)")
    }
    if (missing.isNotEmpty()) {
        if (System.getenv("MAZAMA_DEV_RELEASE") != "1") {
            throw GradleException("a release build needs ${missing.joinToString(" and ")}; see android/app/build.gradle.kts. " +
                "For a test build on your own phone only, set MAZAMA_DEV_RELEASE=1")
        }
        logger.warn("MAZAMA_DEV_RELEASE=1: building a release without ${missing.joinToString(" and ")}; not for distribution")
    }
}

// where buildMazamaCoreFfi (below) puts the compiled library, one folder per ABI
val coreJniLibs: File = layout.buildDirectory.dir("coreJniLibs").get().asFile

android {
    // The Kotlin package of MainActivity, TextScanner and CartTimersWidget (src/main/kotlin/com/example/mazama_mobile/);
    // only a code name, separate from applicationId, which is what phones and app stores see.
    namespace = "com.example.mazama_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // The app's identity on phones and in stores, the same as the iOS bundle id. Changing it makes a different app:
        // a phone keeps the old one, with its saved data, beside the new one.
        applicationId = "com.mazamamushrooms.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // The owner's upload key (see "Release signing" above); the debug key only for a MAZAMA_DEV_RELEASE=1 build.
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "release" else "debug")
        }
    }

    dependencies {
         implementation("com.google.mlkit:text-recognition:16.0.0")
     }

    // The shared core, compiled by buildMazamaCoreFfi below (SM-02; specs/core CR-R3)
    sourceSets {
        getByName("main") {
            jniLibs.srcDir(coreJniLibs)
        }
    }
}

// --- mazama_core_ffi: the shared Rust core, built for the phone during the normal Flutter build -------------------
// For each ABI below, `cargo build --release --target <triple>` of ../../mazama_modules/core/mazama_core_ffi with the
// NDK's clang as linker, copied to build/coreJniLibs/<abi>/libmazama_core_ffi.so, which the app packs (sourceSets
// above). Nothing is written to the source tree. When cargo or a Rust Android target is missing, or the build fails,
// the BUILD FAILS with the fix: the core is part of every build (specs/core CR-D2), and an app without it can't start.
// Install once: rustup target add aarch64-linux-android x86_64-linux-android. ios/build_mazama_core_ffi.sh is the iOS
// twin.
val coreFfiManifest: File = rootProject.file("../../mazama_modules/core/mazama_core_ffi/Cargo.toml")
val coreTargets = mapOf("aarch64-linux-android" to "arm64-v8a", "x86_64-linux-android" to "x86_64")

val buildMazamaCoreFfi by tasks.registering {
    description = "Compiles mazama_core_ffi (Rust) for the app's ABIs; fails when Rust isn't set up."
    doLast {
        fun fail(msg: String): Nothing = throw GradleException("mazama_core_ffi: $msg. The app can't be built without it (specs/core CR-D2)")
        // rustup's folder, which a Gradle daemon started before Rust was installed (or from an IDE) doesn't have on its PATH
        val cargoBin = File(System.getProperty("user.home"), ".cargo/bin")
        fun tool(name: String): String = File(cargoBin, name).takeIf { it.canExecute() }?.path ?: name
        fun sh(cmd: List<String>, env: Map<String, String> = emptyMap()): Pair<Int, String> = try {
            val pb = ProcessBuilder(listOf(tool(cmd.first())) + cmd.drop(1)).redirectErrorStream(true)
            pb.environment()["PATH"] = cargoBin.path + File.pathSeparator + (System.getenv("PATH") ?: "")
            pb.environment().putAll(env)
            val proc = pb.start()
            val out = proc.inputStream.bufferedReader().readText()
            Pair(proc.waitFor(), out)
        } catch (e: Exception) {
            Pair(-1, e.message ?: e.toString())
        }

        if (!coreFfiManifest.isFile) fail("${coreFfiManifest.path} not found (build from the monorepo)")
        if (sh(listOf("cargo", "--version")).first != 0) {
            fail("cargo not found (looked in ${cargoBin.path} and the Gradle daemon's PATH); install Rust " +
                "(rustup.rs, or nix-shell -p rustup), then rustup target add ${coreTargets.keys.joinToString(" ")}. A daemon keeps " +
                "the PATH it started with: if cargo is elsewhere on your shell's PATH, stop it (./gradlew --stop) and build again")
        }
        val (rustupOk, installed) = sh(listOf("rustup", "target", "list", "--installed"))
        if (rustupOk == 0) {
            val missing = coreTargets.keys.filter { it !in installed.lines().map(String::trim) }
            if (missing.isNotEmpty()) fail("Rust targets missing: rustup target add ${missing.joinToString(" ")}")
        }
        val ndk = try {
            project.extensions.getByType(com.android.build.gradle.BaseExtension::class.java).ndkDirectory
        } catch (e: Exception) {
            fail("the Android NDK was not found (${e.message})")
        }
        val host = if (System.getProperty("os.name").lowercase().contains("mac")) "darwin-x86_64" else "linux-x86_64"
        val minSdk = android.defaultConfig.minSdk ?: 21
        val targetDir = layout.buildDirectory.dir("mazama_core_ffi").get().asFile
        for ((triple, abi) in coreTargets) {
            val linker = File(ndk, "toolchains/llvm/prebuilt/$host/bin/$triple$minSdk-clang")
            if (!linker.isFile) {
                fail("no NDK linker at ${linker.path}")
            }
            val linkerVar = "CARGO_TARGET_${triple.uppercase().replace('-', '_')}_LINKER"
            val (rc, out) = sh(
                listOf("cargo", "build", "--release", "--target", triple, "--manifest-path", coreFfiManifest.path, "--target-dir", targetDir.path),
                mapOf(linkerVar to linker.path),
            )
            if (rc != 0) {
                fail("cargo build for $triple failed:\n${out.takeLast(4000)}")
            }
            val built = File(targetDir, "$triple/release/libmazama_core_ffi.so")
            val dest = File(coreJniLibs, "$abi/libmazama_core_ffi.so")
            dest.parentFile.mkdirs()
            built.copyTo(dest, overwrite = true)
            logger.lifecycle("mazama_core_ffi: built for $abi")
        }
    }
}

tasks.named("preBuild") { dependsOn(buildMazamaCoreFfi) }

flutter {
    source = "../.."
}
