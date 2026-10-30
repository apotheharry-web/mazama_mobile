// Runs before every test file (and every test bundle, tool/gen_test_bundle.dart): loads the shared core as the
// app's main() does (missing_core_app.dart), so code that uses MazamaCore.instance finds it. Without
// MAZAMA_CORE_FFI_LIB nothing is loaded here, and every test that reaches the core fails, naming the variable
// (support/core.dart; specs/core CR-R3).
import 'dart:async';
import 'dart:io';

import 'package:mazama_mobile/mazama_core.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final path = Platform.environment['MAZAMA_CORE_FFI_LIB'];
  if (path != null && path.isNotEmpty) {
    try {
      MazamaCore.load(path: path);
    } on MazamaCoreError {
      // a wrong path: the tests that need the core fail with loadTestCore's own error
    }
  }
  await testMain();
}
