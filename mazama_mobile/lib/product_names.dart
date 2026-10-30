// The strain in a product's name, for a package read straight from the state system (state_packages_client.dart),
// which carries none: the server's own name reading (names.parse_product_name) is the shared core's too (SM-19),
// reached through the FFI (mazama_core.dart). Display only - nothing a sale depends on - so a name with no usable
// strain, or any error from the core, gives '' (the old blank), never an exception.
import 'mazama_core.dart';

/// The strain written in [name] ("GT 25 mg TPE FD (2027-01-31)" -> "Golden Teacher"), cleaned and spelled the
/// built-in way, read by [core] (default: this app's, [MazamaCore.instance]); '' when the name has no usable strain
/// or the core can't answer.
String strainFromName(String? name, [CoreFunctions? core]) {
  if (name == null || name.trim().isEmpty) return '';
  try {
    final strain = (core ?? MazamaCore.instance).name(name)['strain'];
    return strain is String ? strain : '';
  } on MazamaCoreError {
    return '';
  } on StateError {
    return ''; // the core isn't loaded in this isolate (a call before main() loaded it): no strain, not a crash
  }
}
