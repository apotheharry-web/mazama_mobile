// The shared core for the phone's tests (specs/core CR-R3): the library CI's core-ffi-build made, given as
// MAZAMA_CORE_FFI_LIB. A test that needs the core fails without it - never skips: the core is part of every build
// (CR-D2), so a run without it hasn't tested the app.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/mazama_core.dart';

const coreLibMissing = "MAZAMA_CORE_FFI_LIB isn't set: build mazama_core_ffi (cargo build --release in "
    'mazama_modules/core/mazama_core_ffi) and set it';

/// The core from MAZAMA_CORE_FFI_LIB (it is also [MazamaCore.instance] from then on, as in the app); fails the test
/// when the variable isn't set.
MazamaCore loadTestCore() {
  final path = Platform.environment['MAZAMA_CORE_FFI_LIB'];
  if (path == null || path.isEmpty) fail(coreLibMissing);
  return MazamaCore.load(path: path);
}
