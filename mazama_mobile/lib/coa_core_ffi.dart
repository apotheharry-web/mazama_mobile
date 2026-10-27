// The shared lab-report reader (mazama_modules/coa/coa_core, through its C interface coa_core_ffi) loaded with
// dart:ffi: JSON in, JSON out, the same Rust the server's Python binding runs (SM-02 in
// specs/shared-modules/README.md; design specs/coa/08-phone-label-debug.md).
//
// Android packs it as libcoa_core_ffi.so (android/app/build.gradle.kts); iOS links it into the app itself
// (ios/build_coa_core_ffi.sh), so its functions are looked up in the running process. Both builds fail when Rust
// isn't set up, unless COA_CORE_OPTIONAL=1 was set to build without it on purpose; the library can then be missing.
// Nothing a sale depends on may need it, so loading never throws: [CoaCore.tryLoad] returns null and [coaCoreStatus]
// says "isn't built". Errors from the
// library itself come back as {"error": ...} and are thrown here as [CoaCoreUnavailable].
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// What to show when the library isn't in this app.
const coaCoreMissingMessage = "coa_core isn't built into this app (it was built with COA_CORE_OPTIONAL=1, or without Rust)";

/// The library answered with an error object, or with something that isn't one of its JSON replies.
class CoaCoreUnavailable implements Exception {
  final String message;
  const CoaCoreUnavailable(this.message);
  @override
  String toString() => 'CoaCoreUnavailable: $message';
}

typedef _JsonFn = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _VersionFn = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeFn = void Function(Pointer<Utf8>);

/// The file name the Android build packs into the app (and the name on Linux, where tests load it by path).
const _libraryName = 'libcoa_core_ffi.so';

class CoaCore {
  final DynamicLibrary _lib;
  final _JsonFn _parse;
  final _JsonFn _labelSpec;
  final _VersionFn _version;
  final _FreeFn _free;

  CoaCore._(DynamicLibrary lib)
      : _lib = lib,
        _parse = lib.lookupFunction<_JsonFn, _JsonFn>('coa_parse_json'),
        _labelSpec = lib.lookupFunction<_JsonFn, _JsonFn>('coa_label_spec_json'),
        _version = lib.lookupFunction<_VersionFn, _VersionFn>('coa_version'),
        _free = lib.lookupFunction<_FreeNative, _FreeFn>('coa_free');

  /// The library at [path], else the one built into this app; null when there is none, when the file isn't this
  /// library, or when it doesn't answer. Never throws.
  static CoaCore? tryLoad({String? path}) {
    try {
      final DynamicLibrary lib;
      if (path != null) {
        lib = DynamicLibrary.open(path);
      } else if (Platform.isAndroid || Platform.isLinux) {
        lib = DynamicLibrary.open(_libraryName);
      } else if (Platform.isIOS) {
        lib = DynamicLibrary.process(); // linked into the app (ios/build_coa_core_ffi.sh)
      } else {
        return null; // macOS, Windows: not built for them
      }
      final core = CoaCore._(lib);
      // proves the functions are callable before anyone relies on them
      return core.version.startsWith('coa_core') ? core : null;
    } catch (_) {
      // DynamicLibrary.open and lookupFunction report a missing file or symbol with ArgumentError (an Error, not an
      // Exception), so everything is caught: a missing library is a normal state of this app, not a crash.
      return null;
    }
  }

  /// `coa_core <version> / rules <version>`.
  String get version => _take(_version());

  /// CoaText JSON (from a PDF) -> CoaParseResult.
  Map<String, Object?> parse(String coaTextJson) => _call(_parse, coaTextJson);

  /// LabelInput -> {"spec": ..., "warnings": [...]} or {"blocked": [...], "warnings": [...]}.
  Map<String, Object?> labelSpec(Map<String, Object?> input) => _call(_labelSpec, jsonEncode(input));

  /// A product name read for display (SM-19): `{"strain_raw", "strain", "code", "expiry"}` - the strain as written,
  /// the strain cleaned and spelled the built-in way (null when the name has none), the type code, the ISO date.
  /// Looked up on first use, so a library built before SM-19 still loads (this throws for it instead).
  Map<String, Object?> parseName(String name) => _call(_name, jsonEncode({'name': name}));
  late final _JsonFn _name = _lib.lookupFunction<_JsonFn, _JsonFn>('coa_name_json');

  /// AD-19 (coa_core's lot::find_lot): which section of a lab report is [lot]'s value of record when the lab may
  /// have printed another id, e.g. a process lot reported under the harvest batch it was made from. Its own UID
  /// first, else the batch the report's own request / chain of custody pairs it with, else the one primary section
  /// whose psilocybin equals [statePsilocybin] (the state's mg/g) at 3 significant figures. Returns
  /// `{"result": CoaParseResult, "found": {"section": i, "uid": "HB-...", "via": "own" | "request" |
  /// "state_psilocybin"} | null}`. Looked up on first use, so a library built before AD-19 still loads.
  Map<String, Object?> findLot(Map<String, Object?> coaText, String lot, {double? statePsilocybin}) =>
      _call(_findLot, jsonEncode({'coa_text': coaText, 'lot': lot, 'state_psilocybin': statePsilocybin}));
  late final _JsonFn _findLot = _lib.lookupFunction<_JsonFn, _JsonFn>('coa_find_lot_json');

  /// Scan matching, step one (coa_core's scan::find_ids, the matcher the server's /p/scan-match runs too): the package
  /// ids among [guids] found in a label's [texts], exactly or with a character or two misread (two only on a "Lot:"
  /// line or when [typed]). Returns `[{"guid", "hex", "dist", "line"}]`, best first. Looked up on first use, so a
  /// library built before scan matching moved into coa_core still loads (this throws for it instead).
  List<Map<String, Object?>> scanFindIds(List<String> texts, List<String> guids, {bool typed = false}) =>
      _list(_call(_scanFindIds, jsonEncode({'texts': texts, 'guids': guids, 'typed': typed})), 'matches');
  late final _JsonFn _scanFindIds = _lib.lookupFunction<_JsonFn, _JsonFn>('coa_scan_find_ids_json');

  /// Scan matching, step two (scan::closest): when no id was found, the packages the rest of the label fits best.
  /// [packages] is `[{"guid", "records": [{"weightPerUnit", "analyteWeight", "description", "quantity", "expires":
  /// "YYYY-MM-DD" | null}]}]`, only records that can be sold. Returns `[{"guid", "score", "why", "weight", "mg",
  /// "record", "stock"}]`, best first (record: the index of the record the score is for). Looked up on first use.
  List<Map<String, Object?>> scanClosest(List<String> texts, List<Map<String, Object?>> packages) =>
      _list(_call(_scanClosest, jsonEncode({'texts': texts, 'packages': packages})), 'guesses');
  late final _JsonFn _scanClosest = _lib.lookupFunction<_JsonFn, _JsonFn>('coa_scan_closest_json');

  List<Map<String, Object?>> _list(Map<String, Object?> reply, String key) {
    final items = reply[key];
    if (items is! List) throw CoaCoreUnavailable('coa_core answered without "$key"');
    return [
      for (final m in items)
        if (m is Map<String, Object?>) m else throw CoaCoreUnavailable('coa_core answered with a "$key" item that is not an object'),
    ];
  }

  /// Reads a string the library returned and gives it back to the library to free.
  String _take(Pointer<Utf8> out) {
    if (out == nullptr) throw const CoaCoreUnavailable('coa_core returned nothing');
    try {
      return out.toDartString();
    } finally {
      _free(out);
    }
  }

  Map<String, Object?> _call(_JsonFn fn, String input) {
    final arg = input.toNativeUtf8();
    try {
      final reply = _decode(_take(fn(arg)));
      if (reply is! Map<String, Object?>) throw const CoaCoreUnavailable('coa_core answered with something that is not an object');
      if (reply['error'] case final Object error) throw CoaCoreUnavailable(error.toString());
      return reply;
    } finally {
      malloc.free(arg);
    }
  }
}

Object? _decode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException catch (ex) {
    throw CoaCoreUnavailable('coa_core answered with something that is not JSON: ${ex.message}');
  }
}

/// One line for a diagnostics page: the library's version, or [coaCoreMissingMessage].
String coaCoreStatus(CoaCore? core) => core == null ? coaCoreMissingMessage : core.version;
