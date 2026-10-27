// The shared reader (mazama_modules/coa/coa_core_ffi) loaded through dart:ffi (SM-02, plan 08 Task 6). CI builds the
// library and passes its path as COA_CORE_FFI_LIB (ci/run.sh, coa-ffi-build); without it the tests that need it skip
// and say why. The cases are this app's vendored copies (assets/shared/coa/, tool/sync_flows.sh): every golden
// label case, generated from the server's Python, one lab report's extracted text, and every scan-matching case. The Rust and Python suites
// run the whole corpus; these prove the same answers come through the C interface.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/coa_core_ffi.dart';

final String? _lib = Platform.environment['COA_CORE_FFI_LIB'];
final String? _skip = _lib == null ? 'COA_CORE_FFI_LIB is not set (CI sets it after building coa_core_ffi)' : null;
const _shared = 'assets/shared/coa/corpus';

Map<String, Object?> _json(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

/// True only in the public copy of this app (specs/public-app PA-R5), which has neither the folder nor the private
/// mazama_modules/ beside it: here a missing folder still fails the test.
bool _missingInPublicCopy(String dir) =>
    !Directory(dir).existsSync() && !File('../mazama_modules/vendored.txt').existsSync();

/// JSON equality with floats compared to 1e-9, as coa_core's own label_cases.rs does.
bool _same(Object? a, Object? b) {
  if (a is num && b is num) return (a - b).abs() < 1e-9;
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _same(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

void main() {
  group('without the library', () {
    test('tryLoad returns null for a missing file', () {
      expect(CoaCore.tryLoad(path: '/nonexistent/libcoa_core_ffi.so'), isNull);
    });

    test('tryLoad returns null, not an error, for a file that is not the library', () {
      expect(CoaCore.tryLoad(path: 'pubspec.yaml'), isNull);
    });

    test('the status line says it isn\'t built', () {
      expect(coaCoreStatus(null), coaCoreMissingMessage);
      expect(coaCoreMissingMessage, contains("isn't built"));
    });
  });

  group('through the library', () {
    late final CoaCore core = CoaCore.tryLoad(path: _lib)!;

    test('loads and names its version', () {
      expect(core.version, startsWith('coa_core '));
      expect(coaCoreStatus(core), core.version);
    });

    test('every golden label case gives the server\'s answer', () {
      final cases = _json('$_shared/labels/cases.json');
      final expected = _json('$_shared/labels/expected.json');
      expect(cases.keys.toSet(), expected.keys.toSet());
      expect(cases.length, greaterThanOrEqualTo(14));
      for (final MapEntry(key: name, value: input) in cases.entries) {
        final got = core.labelSpec((input as Map).cast<String, Object?>());
        expect(_same(got, expected[name]), isTrue, reason: '$name: got $got, want ${expected[name]}');
      }
    });

    test('a lab report\'s text parses to the lots and values expected of it', () {
      const dir = '$_shared/synthetic/multi-section-fd-first';
      final got = core.parse(File('$dir/text.server.json').readAsStringSync());
      final want = (_json('$dir/expected.json')['lots'] as Map).cast<String, Object?>();
      final sections = (got['sections'] as List).cast<Map<String, Object?>>();
      expect(want, isNotEmpty);
      for (final MapEntry(key: uid, value: lot as Map) in want.entries) {
        final i = (got['of_record'] as Map)[uid.toLowerCase()];
        expect(i, isNotNull, reason: '$uid not of record');
        final s = sections[i as int];
        if (lot.containsKey('status')) expect(s['status'], lot['status'], reason: '$uid status');
        final got0 = (s['analytes'] as Map)['psilocybin'] as Map, want0 = lot['psilocybin'] as Map;
        expect([got0['kind'], got0['value']], [want0['kind'], want0['value']], reason: '$uid psilocybin');
      }
    });

    test('findLot gives every shared AD-19 case\'s answer: a lot printed under another id', () {
      // corpus/lots/cases.json: a process lot reported under the harvest batch it was made from (document 3092,
      // PL-de20657a as HB-597a95ef), by the report's own request or the state's psilocybin; held to the same cases
      // as coa_core's lot_cases.rs and the server's binding
      final cases = (_json('$_shared/lots/cases.json')['cases'] as List).cast<Map<String, Object?>>();
      expect(cases.length, greaterThanOrEqualTo(12));
      for (final c in cases) {
        // the public copy of this app has no real lab reports (specs/public-app PA-R5); here they are always vendored
        if (_missingInPublicCopy('$_shared/${c['report']}')) continue;
        final text = _json('$_shared/${c['report']}/text.server.json');
        final reply = core.findLot(text, c['lot'] as String, statePsilocybin: (c['state_psilocybin'] as num?)?.toDouble());
        final found = reply['found'] as Map?;
        final sections = ((reply['result'] as Map)['sections'] as List).cast<Map>();
        final got = found == null
            ? null
            : {'uid': sections[found['section'] as int]['uid'], 'is_fd': sections[found['section'] as int]['is_fd'], 'via': found['via']};
        expect(got, c['expect'], reason: '${c['name']}');
        if (found != null) expect(found['uid'], got!['uid'], reason: '${c['name']}: found uid is the section\'s');
      }
    });

    test('scan matching gives every shared case\'s answer: the server\'s matcher, on the phone', () {
      // corpus/scan/cases.json: what the server's Python matcher (ocr.find_ids / ocr.closest) answered before it moved
      // into coa_core; coa_core's scan_cases.rs, the binding and the server's test_ocr.py are held to the same cases
      final cases = _json('$_shared/scan/cases.json');
      final find = (cases['find_ids'] as List).cast<Map<String, Object?>>();
      final closest = (cases['closest'] as List).cast<Map<String, Object?>>();
      expect(find.length, greaterThanOrEqualTo(40));
      expect(closest.length, greaterThanOrEqualTo(30));
      for (final c in find) {
        final got = core.scanFindIds((c['texts'] as List).cast<String>(), (c['guids'] as List).cast<String>(), typed: c['typed'] as bool);
        expect(_same(got, c['expect']), isTrue, reason: '${c['name']}: got $got, want ${c['expect']}');
      }
      for (final c in closest) {
        final got = core.scanClosest((c['texts'] as List).cast<String>(), (c['packages'] as List).cast<Map<String, Object?>>());
        expect(_same(got, c['expect']), isTrue, reason: '${c['name']}: got $got, want ${c['expect']}');
      }
    });

    test('bad input is a CoaCoreUnavailable carrying the library\'s error, not a crash', () {
      expect(() => core.parse('{'), throwsA(isA<CoaCoreUnavailable>()));
      expect(() => core.labelSpec({'package': 'not an object'}), throwsA(isA<CoaCoreUnavailable>()));
      expect(() => core.scanClosest(['x'], [{'guid': 'PKPR-aaaa0001', 'records': 'not a list'}]), throwsA(isA<CoaCoreUnavailable>()));
      expect(core.version, startsWith('coa_core ')); // still usable afterwards
    });
  }, skip: _skip);
}
