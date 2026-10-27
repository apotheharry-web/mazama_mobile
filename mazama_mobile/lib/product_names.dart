// The strain in a product's name, for a package read straight from the state system (state_packages_client.dart),
// which carries none: the server's own name reading (names.parse_product_name) is coa_core's too (SM-19), reached
// through the FFI (coa_core_ffi.dart). Display only - nothing a sale depends on - so a missing library, a name with
// no usable strain, or any error from it gives '' (the old blank), never an exception.
import 'coa_core_ffi.dart';

/// The strain written in [name] ("GT 25 mg TPE FD (2027-01-31)" -> "Golden Teacher"), cleaned and spelled the
/// built-in way; '' when [core] is null, the name has no usable strain, or the library can't answer.
String strainFromName(String? name, CoaCore? core) {
  if (core == null || name == null || name.trim().isEmpty) return '';
  try {
    final strain = core.parseName(name)['strain'];
    return strain is String ? strain : '';
  } catch (_) {
    // CoaCoreUnavailable, or ArgumentError from a library built before coa_name_json existed
    return '';
  }
}

CoaCore? _shared;
bool _tried = false;

/// This app's coa_core, loaded the first time it's asked for (null when it isn't built into the app).
CoaCore? sharedCoaCore() {
  if (!_tried) {
    _tried = true;
    _shared = CoaCore.tryLoad();
  }
  return _shared;
}
