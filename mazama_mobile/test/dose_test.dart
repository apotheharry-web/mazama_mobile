// The mg TPE of a unit where the phone works it out itself (the state-only path, and a lab result's TPE from
// the server) is the shared core's (mazama_core::dose), held to the frozen vectors from this app's
// vendored copy (assets/shared/dose/vectors/, tool/sync_flows.sh): unit_mg.json and ceil_mg.json (the old rule's cases)
// and dose_cases.json (the DOSE rows as the owner approved them): the TPE, else the
// state's psilocybin, rounded up as ceil(x - 1e-9). Fails closed: a core that can't answer gives no mg.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/dose.dart';
import 'package:mazama_mobile/mazama_core.dart';

import 'support/core.dart';

Object? _json(String name) => jsonDecode(File('assets/shared/dose/vectors/$name').readAsStringSync());

double? _d(Object? v) => (v as num?)?.toDouble();

/// A core whose dose calls answer [reply] (or throw it, when it is an error or exception).
class _Core implements CoreFunctions {
  final Object? Function() reply;
  _Core(this.reply);

  List<Object?> _answer() {
    final r = reply();
    if (r is Error) throw r;
    if (r is Exception) throw r;
    return r as List<Object?>;
  }

  @override
  List<Object?> doseUnitMg(Map<String, Object?> input) => _answer();
  @override
  List<Object?> doseCeilMg(Map<String, Object?> input) => _answer();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late final MazamaCore core = loadTestCore();

  test('every unit_mg vector', () {
    final cases = (_json('unit_mg.json') as List).cast<Map<String, Object?>>();
    expect(cases.length, greaterThanOrEqualTo(12));
    for (final c in cases) {
      final w = _d(c['weight_per_unit'])!, s = _d(c['state_psilocybin']), t = _d(c['tpe']);
      expect(unitTpeMg(w, s, t, core: core), c['tpe_mg'], reason: '${c['name']}');
      final got = core.doseUnitMg({
        'units': [
          {'record': {'weightPerUnit': w, 'analyteWeight': s}, 'tpe': t},
        ],
      }).single as Map;
      expect(_d(got['tpe_per_g']), _d(c['tpe_per_g']), reason: '${c['name']}');
    }
  });

  test('every ceil_mg vector', () {
    for (final c in (_json('ceil_mg.json') as List).cast<Map<String, Object?>>()) {
      expect(ceilMg(_d(c['x'])!, core: core), c['mg'], reason: '${c['x']}');
    }
  });

  test("the DOSE rows' unit cases, as approved (DOSE-9, DOSE-10, DOSE-11, SM-D17)", () {
    final doc = _json('dose_cases.json') as Map<String, Object?>;
    final units = (doc['unit_mg'] as List).cast<Map<String, Object?>>();
    expect(units.length, greaterThanOrEqualTo(20));
    final got = core.doseUnitMg({
      'units': [for (final c in units) {'record': c['record'], 'tpe': c['tpe']}],
    });
    for (var i = 0; i < units.length; i++) {
      final g = got[i] as Map;
      expect(g['tpe_mg'], units[i]['tpe_mg'], reason: '${units[i]['name']}');
      expect(_d(g['tpe_per_g']), _d(units[i]['tpe_per_g']), reason: '${units[i]['name']}');
    }
    final ceils = (doc['ceil_mg'] as List).cast<Map<String, Object?>>();
    expect(core.doseCeilMg({'xs': [for (final c in ceils) c['x']]}), [for (final c in ceils) c['mg']]);
  });

  test('the phone keeps its names: a unit of 0.3 g at 8.64 mg/g is 3 mg, nothing known is null', () {
    expect(unitTpeMg(0.3, 7.25, 8.64, core: core), 3);
    expect(unitTpeMg(1.0, 0.0, null, core: core), isNull);
    expect(unitTpeMg(5.0, 1.01, null, core: core), 6); // the state-only path: 5.05 mg
    expect(ceilMg(0.56 * 12.5, core: core), 7); // 7.000000000000001: float noise forgiven
    expect(unitTpeMg(1.0, 7.25, double.nan, core: core), isNull); // a figure JSON can't hold: unknown
    expect(ceilMg(double.infinity, core: core), isNull);
  });

  group('DOSE-7: a core that fails gives no mg, never a guess', () {
    final cases = <String, Object? Function()>{
      'no core loaded': () => StateError('mazama_core is not loaded'),
      'a core error': () => const MazamaCoreError('dose.unit_mg failed'),
      'no answer': () => <Object?>[],
      'two answers': () => <Object?>[{'tpe_per_g': 1.0, 'tpe_mg': 1}, {'tpe_per_g': 1.0, 'tpe_mg': 1}],
      'an answer that is not an object': () => <Object?>[5],
      'a mg that is not a whole number': () => <Object?>[{'tpe_per_g': 8.64, 'tpe_mg': 4.32}],
    };
    for (final MapEntry(key: name, value: reply) in cases.entries) {
      test(name, () {
        expect(unitTpeMg(0.5, 7.25, 8.64, core: _Core(reply)), isNull);
      });
    }
    test('ceilMg too', () {
      expect(ceilMg(7.5, core: _Core(() => StateError('no core'))), isNull);
      expect(ceilMg(7.5, core: _Core(() => <Object?>['8'])), isNull);
    });
  });
}
