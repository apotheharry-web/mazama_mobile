// The shared core (mazama_modules/core/mazama_core, through its C interface mazama_core_ffi) loaded with dart:ffi:
// JSON in, JSON out, the same Rust the server's Python binding runs (specs/core; SM-02 in specs/shared-modules).
//
// Android packs it as libmazama_core_ffi.so (android/app/build.gradle.kts); iOS links it into the app itself
// (ios/build_mazama_core_ffi.sh), so its functions are looked up in the running process. Both builds fail without
// Rust: the core is part of every build (specs/core CR-D2). main() loads it once, before the first frame
// (missing_core_app.dart's startWidgetFor); an app that can't load it shows MissingCoreApp, never a degraded app.
//
// The functions are the core's table (mazama_modules/core/functions.yaml), generated into mazama_core.g.dart as
// [CoreFunctions]; [MazamaCore] is the library's, and the typed helpers below ([CoreHelpers]) work on any
// CoreFunctions, so a test's fake gets them too. Errors from the library come back as {"error": ...} and are thrown
// here as [MazamaCoreError].
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'mazama_core.g.dart';

export 'mazama_core.g.dart' show CoreFunctions;

/// The library is missing or isn't this one, or it answered with an error object or with something that isn't one
/// of its JSON replies.
class MazamaCoreError implements Exception {
  final String message;
  const MazamaCoreError(this.message);
  @override
  String toString() => 'MazamaCoreError: $message';
}

typedef _VersionFn = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeFn = void Function(Pointer<Utf8>);

/// The file name the Android build packs into the app (and the name on Linux, where tests load it by path).
const _libraryName = 'libmazama_core_ffi.so';

class MazamaCore implements CoreFunctions {
  final _VersionFn _version;
  final _FreeFn _free;
  late final CoreFunctionsFfi _fns;

  MazamaCore._(DynamicLibrary lib)
      : _version = lib.lookupFunction<_VersionFn, _VersionFn>('mz_version'),
        _free = lib.lookupFunction<_FreeNative, _FreeFn>('mz_free') {
    _fns = CoreFunctionsFfi(lib, _call, (message) => throw MazamaCoreError(message));
  }

  static MazamaCore? _instance;

  /// The core main() loaded at start-up (the first one [load] gave). Throws StateError before that: every caller
  /// runs after main(), and a test loads it with test/support/core.dart (or test/flutter_test_config.dart).
  static MazamaCore get instance =>
      _instance ??
      (throw StateError("mazama_core isn't loaded: main() loads it before the app starts; a test sets "
          'MAZAMA_CORE_FFI_LIB (test/support/core.dart)'));

  /// The library at [path], else the one built into this app. Throws [MazamaCoreError] when there is none, when the
  /// file isn't this library or misses one of its functions, or when it doesn't answer. The first one loaded becomes
  /// [instance].
  static MazamaCore load({String? path}) {
    final MazamaCore core;
    try {
      final DynamicLibrary lib;
      if (path != null) {
        lib = DynamicLibrary.open(path);
      } else if (Platform.isAndroid || Platform.isLinux) {
        lib = DynamicLibrary.open(_libraryName);
      } else if (Platform.isIOS) {
        lib = DynamicLibrary.process(); // linked into the app (ios/build_mazama_core_ffi.sh)
      } else {
        throw const MazamaCoreError('mazama_core is not built for this platform');
      }
      core = MazamaCore._(lib);
    } on MazamaCoreError {
      rethrow;
    } catch (ex) {
      // DynamicLibrary.open and lookupFunction report a missing file or symbol with ArgumentError (an Error, not an
      // Exception): everything is turned into the one error the app shows
      throw MazamaCoreError("mazama_core can't be loaded${path == null ? '' : ' from $path'}: $ex");
    }
    final version = core.version; // proves the functions are callable before anyone relies on them
    if (!version.startsWith('mazama_core ')) throw MazamaCoreError('$path is not mazama_core (it says "$version")');
    _instance ??= core;
    return core;
  }

  /// `mazama_core <version> / rules <version>`.
  String get version => _take(_version());

  /// Reads a string the library returned and gives it back to the library to free.
  String _take(Pointer<Utf8> out) {
    if (out == nullptr) throw const MazamaCoreError('mazama_core returned nothing');
    try {
      return out.toDartString();
    } finally {
      _free(out);
    }
  }

  Object? _call(CoreJsonFn fn, String input) {
    final arg = input.toNativeUtf8();
    try {
      final reply = _decode(_take(fn(arg)));
      if (reply is Map) {
        if (reply['error'] case final Object error) throw MazamaCoreError(error.toString());
      }
      return reply;
    } finally {
      malloc.free(arg);
    }
  }

  @override
  Map<String, Object?> coaParse(Map<String, Object?> input) => _fns.coaParse(input);
  @override
  Map<String, Object?> coaParseWithRules(Map<String, Object?> input) => _fns.coaParseWithRules(input);
  @override
  Map<String, Object?> coaFindLot(Map<String, Object?> input) => _fns.coaFindLot(input);
  @override
  List<Object?> coaSelectDocuments(Map<String, Object?> input) => _fns.coaSelectDocuments(input);
  @override
  Map<String, Object?> labelSpec(Map<String, Object?> input) => _fns.labelSpec(input);
  @override
  Map<String, Object?> namesName(Map<String, Object?> input) => _fns.namesName(input);
  @override
  Map<String, Object?> scanFindIds(Map<String, Object?> input) => _fns.scanFindIds(input);
  @override
  Map<String, Object?> scanClosest(Map<String, Object?> input) => _fns.scanClosest(input);
  @override
  List<Object?> recordsJudge(Map<String, Object?> input) => _fns.recordsJudge(input);
  @override
  List<Object?> recordsCanTransfer(Map<String, Object?> input) => _fns.recordsCanTransfer(input);
  @override
  List<Object?> recordsPackageKeys(Map<String, Object?> input) => _fns.recordsPackageKeys(input);
  @override
  List<Object?> recordsServiceCenters(Map<String, Object?> input) => _fns.recordsServiceCenters(input);
  @override
  Map<String, Object?> stockFilter(Map<String, Object?> input) => _fns.stockFilter(input);
  @override
  Map<String, Object?> stockSummarize(Map<String, Object?> input) => _fns.stockSummarize(input);
  @override
  Map<String, Object?> stockPies(Map<String, Object?> input) => _fns.stockPies(input);
  @override
  Map<String, Object?> stockParTable(Map<String, Object?> input) => _fns.stockParTable(input);
  @override
  Map<String, Object?> stockMix(Map<String, Object?> input) => _fns.stockMix(input);
  @override
  List<Object?> stockMixCells(Map<String, Object?> input) => _fns.stockMixCells(input);
  @override
  Map<String, Object?> stockByType(Map<String, Object?> input) => _fns.stockByType(input);
  @override
  Map<String, Object?> stockOrderCheck(Map<String, Object?> input) => _fns.stockOrderCheck(input);
  @override
  List<Object?> stockOrderForm(Map<String, Object?> input) => _fns.stockOrderForm(input);
  @override
  Map<String, Object?> manufacturingCoaEdit(Map<String, Object?> input) => _fns.manufacturingCoaEdit(input);
  @override
  Map<String, Object?> manufacturingCoaNumber(Map<String, Object?> input) => _fns.manufacturingCoaNumber(input);
  @override
  Map<String, Object?> manufacturingCleanText(Map<String, Object?> input) => _fns.manufacturingCleanText(input);
  @override
  Map<String, Object?> namesProductName(Map<String, Object?> input) => _fns.namesProductName(input);
}

Object? _decode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException catch (ex) {
    throw MazamaCoreError('mazama_core answered with something that is not JSON: ${ex.message}');
  }
}

/// Today's typed calls, on any [CoreFunctions] (the library or a test's fake).
extension CoreHelpers on CoreFunctions {
  /// CoaText JSON (from a PDF) -> CoaParseResult.
  Map<String, Object?> parse(String coaTextJson) {
    final text = _decode(coaTextJson);
    if (text is! Map<String, Object?>) throw const MazamaCoreError('a CoaText is a JSON object');
    return coaParse(text);
  }

  /// A product name read for display (SM-19): `{"strain_raw", "strain", "code", "expiry"}` - the strain as written,
  /// the strain cleaned and spelled the built-in way (null when the name has none), the type code, the ISO date.
  Map<String, Object?> name(String name) => namesName({'name': name});

  /// AD-19 (the core's coa::lot::find_lot): which section of a lab report is [lot]'s value of record when the lab
  /// may have printed another id, e.g. a process lot reported under the harvest batch it was made from. Its own UID
  /// first, else the batch the report's own request / chain of custody pairs it with, else the one primary section
  /// whose psilocybin equals [statePsilocybin] (the state's mg/g) at 3 significant figures. Returns
  /// `{"result": CoaParseResult, "found": {"section": i, "uid": "HB-...", "via": "own" | "request" | ...} | null}`.
  Map<String, Object?> findLot(Map<String, Object?> coaText, String lot, {double? statePsilocybin}) =>
      coaFindLot({'coa_text': coaText, 'lot': lot, 'state_psilocybin': statePsilocybin});

  /// Scan matching, step one (the core's scan::find_ids, the matcher the server's /p/scan-match runs too): the
  /// package ids among [guids] found in a label's [texts], exactly or with a character or two misread (two only on a
  /// "Lot:" line or when [typed]). Returns `[{"guid", "hex", "dist", "line"}]`, best first.
  List<Map<String, Object?>> findIds(List<String> texts, List<String> guids, {bool typed = false}) =>
      _items(scanFindIds({'texts': texts, 'guids': guids, 'typed': typed}), 'matches');

  /// Scan matching, step two (scan::closest): when no id was found, the packages the rest of the label fits best.
  /// [packages] is `[{"guid", "records": [{"weightPerUnit", "analyteWeight", "description", "quantity", "expires":
  /// "YYYY-MM-DD" | null}]}]`, only records that can be sold. Returns `[{"guid", "score", "why", "weight", "mg",
  /// "record", "stock"}]`, best first (record: the index of the record the score is for).
  List<Map<String, Object?>> closestPackages(List<String> texts, List<Map<String, Object?>> packages) =>
      _items(scanClosest({'texts': texts, 'packages': packages}), 'guesses');

  List<Map<String, Object?>> _items(Map<String, Object?> reply, String key) {
    final items = reply[key];
    if (items is! List) throw MazamaCoreError('mazama_core answered without "$key"');
    return [
      for (final m in items)
        if (m is Map<String, Object?>) m else throw MazamaCoreError('mazama_core answered with a "$key" item that is not an object'),
    ];
  }
}
