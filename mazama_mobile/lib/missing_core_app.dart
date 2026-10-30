// What the app starts with (specs/core CR-R3, CR-D2): the shared core is loaded once, before the first frame, and
// an app that can't load it shows one full-screen error instead of the app - never a white screen, a crash loop or
// an app with parts missing. Both builds already fail without Rust (android/app/build.gradle.kts,
// ios/build_mazama_core_ffi.sh) and Codemagic checks the iOS app's symbols, so this is the last line of defence.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'main.dart' show MazamaApp;
import 'mazama_core.dart';

/// The words MissingCoreApp shows.
const missingCoreMessage = 'This build is missing a part. Reinstall the app.';

/// The app's first widget: [MazamaApp] once [loadCore] gave the core (it is then [MazamaCore.instance]), else
/// [MissingCoreApp] with why. Never throws.
Widget startWidgetFor({MazamaCore Function() loadCore = MazamaCore.load}) {
  try {
    loadCore();
    return const MazamaApp();
  } catch (ex) {
    // MazamaCoreError from MazamaCore.load; anything else a loader throws is the same failure
    return MissingCoreApp(error: ex is MazamaCoreError ? ex.message : '$ex');
  }
}

/// The one screen of an app built without the shared core: [missingCoreMessage], and in debug builds the error.
class MissingCoreApp extends StatelessWidget {
  final String error;
  const MissingCoreApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 16),
                    const Text(missingCoreMessage, textAlign: TextAlign.center, style: TextStyle(fontSize: 18)),
                    if (kDebugMode) ...[const SizedBox(height: 16), SelectableText(error, textAlign: TextAlign.center)],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
