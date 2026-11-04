// What the phone may sell is the shared core's rule (sellability.dart calls
// mazama_core::selling through the FFI), held to the golden vectors: sellability.json (the base cases)
// and sellability_cases.json (the cases as the owner decided them), reason text included, read
// from this app's vendored copy, assets/shared/selling/vectors/ (tool/sync_flows.sh; vendored_test.dart proves it
// equals the source). And it fails closed: a core that can't answer refuses, never sells.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/sellability.dart';

import 'support/core.dart';

List<Map<String, Object?>> _vectors(String name) =>
    (jsonDecode(File('assets/shared/selling/vectors/$name').readAsStringSync()) as List).cast<Map<String, Object?>>();

/// A core whose sellingSellable answers [reply] (or throws it, when it is an error), counting its calls.
class _Core implements CoreFunctions {
  final Object? Function(Map<String, Object?> input) reply;
  final inputs = <Map<String, Object?>>[];
  _Core(this.reply);

  @override
  List<Object?> sellingSellable(Map<String, Object?> input) {
    inputs.add(input);
    final r = reply(input);
    if (r is Error) throw r;
    if (r is Exception) throw r;
    return r as List<Object?>;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The real core, counting calls.
class _Counting implements CoreFunctions {
  final MazamaCore real;
  var calls = 0;
  _Counting(this.real);

  @override
  List<Object?> sellingSellable(Map<String, Object?> input) {
    calls++;
    return real.sellingSellable(input);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final Map<String, Object?> _plain = {'productGuid': 'PKPR-0005', 'quantity': 10};

void main() {
  late final MazamaCore core = loadTestCore();
  final old = _vectors('sellability.json');
  final sl = _vectors('sellability_cases.json');

  test('the vectors are there to test against', () {
    expect(old.length, greaterThanOrEqualTo(20));
    expect(sl.length, greaterThanOrEqualTo(60));
  });

  for (final c in old) {
    test('vector: ${c['name']}', () {
      final record = Map<String, Object?>.from(c['record'] as Map);
      expect(unsellableReason(record, qty: c['qty'] as int, core: core), c['reason']);
      expect(isSellable(record, qty: c['qty'] as int, core: core), c['reason'] == null);
    });
  }

  for (final c in sl) {
    test('${c['sl']}: ${c['name']}', () {
      final record = c['record'] == null ? null : Map<String, Object?>.from(c['record'] as Map);
      final qty = c['qty'];
      // a whole number of units the phone can ask goes through the app's own functions; the rest (a fraction, an
      // integer beyond 64 bits, which jsonDecode makes a double here) straight to the core, as the vectors give them
      if (record != null && qty is int) {
        expect(unsellableReason(record, qty: qty, core: core), c['reason']);
      }
      // an ask beyond 64 bits is a double once jsonDecode has read it: the phone can't send it as the integer it is
      if (qty is double && qty.abs() >= 9.2e18) return;
      final got = core.sellingSellable({
        'checks': [
          {'record': record, 'qty': qty},
        ],
      });
      expect(got, [
        {'reason': c['reason'], 'sellable_record': c['sellable_record']},
      ]);
    });
  }

  test('a list is judged in one core call, in order', () {
    final counting = _Counting(core);
    final records = [for (final c in old) Map<String, Object?>.from(c['record'] as Map)];
    final got = unsellableReasons(records, core: counting);
    expect(counting.calls, 1);
    expect(got, [for (final r in records) unsellableReason(r, core: core)]);
    expect(unsellableReasons(const [], core: counting), isEmpty);
    expect(counting.calls, 1);
  });

  test('only the keys the rule reads are sent to the core', () {
    final fake = _Core((_) => [
          {'reason': null, 'sellable_record': true},
        ]);
    unsellableReason({..._plain, 'id': 5, 'when': DateTime(2026), 'description': 'GT'}, core: fake);
    expect(fake.inputs.single, {
      'checks': [
        {'record': _plain, 'qty': 1},
      ],
    });
  });

  test('a scan match\'s one-key record is judged on its quantity alone', () {
    expect(unsellableReason({'quantity': 3}, core: core), isNull);
    expect(unsellableReason({'quantity': 0}, core: core), 'no units remaining (system reports quantity=0, zeroOut=None)');
    expect(unsellableReason({'quantity': 2.5}, qty: 3, core: core), 'no units remaining (system reports quantity=2.5, zeroOut=None)');
  });

  group('fails closed when the core can\'t answer (SL-15)', () {
    final cases = <String, Object? Function(Map<String, Object?>)>{
      'the core is not loaded (StateError)': (_) => StateError("mazama_core isn't loaded"),
      'the core answers an error (MazamaCoreError)': (_) => const MazamaCoreError('selling.sellable: no'),
      'the core throws something else': (_) => const FormatException('odd'),
      'an empty reply': (_) => <Object?>[],
      // one entry more than the checks asked, whatever their number
      'an entry more than the records asked': (input) => [
            for (var i = 0; i <= (input['checks'] as List).length; i++) {'reason': null, 'sellable_record': true},
          ],
      'an entry that is not an object': (_) => ['sellable'],
      'a numeric reason': (_) => [
            {'reason': 0, 'sellable_record': true},
          ],
      'no sellable_record': (_) => [
            {'reason': null},
          ],
      'a sellable_record that is not a bool': (_) => [
            {'reason': null, 'sellable_record': 'yes'},
          ],
    };
    for (final MapEntry(key: name, value: reply) in cases.entries) {
      test(name, () {
        final fake = _Core(reply);
        expect(unsellableReason(_plain, core: fake), coreFailedReason);
        expect(isSellable(_plain, core: fake), isFalse);
        expect(saleLineRefusal(_plain, 'PKPR-0005', 1, core: fake), 'PKPR-0005: $coreFailedReason.');
        expect(unsellableReasons([_plain, _plain], core: fake), [coreFailedReason, coreFailedReason]);
      });
    }

    test('a reply one short, for a list and for each record alone, refuses every record', () {
      final fake = _Core((input) => [
            for (var i = 1; i < (input['checks'] as List).length; i++) {'reason': null, 'sellable_record': true},
          ]);
      expect(unsellableReasons([_plain, _plain], core: fake), [coreFailedReason, coreFailedReason]);
    });
  });

  group('a record the core can\'t take refuses only itself (row 4 review, I2)', () {
    test('a core that fails on one record: the others are judged alone', () {
      final fake = _Core((input) {
        final checks = (input['checks'] as List).cast<Map<String, Object?>>();
        if (checks.any((c) => (c['record'] as Map)['quantity'] == 13)) return const MazamaCoreError('no');
        return [
          for (var i = 0; i < checks.length; i++) {'reason': null, 'sellable_record': true},
        ];
      });
      final bad = {..._plain, 'quantity': 13};
      expect(unsellableReasons([_plain, bad, _plain], core: fake), [null, coreFailedReason, null]);
      expect(fake.inputs.length, 1 + 3);
    });

    test('a quantity jsonEncode can\'t write (infinity) refuses that record only, through the real core', () {
      final inf = {..._plain, 'quantity': double.infinity};
      expect(unsellableReasons([_plain, inf, _plain], core: core), [null, coreFailedReason, null]);
    });

    test('a lone surrogate the core can\'t read refuses that record only, through the real core', () {
      final lone = {..._plain, 'locked': true, 'reasonLocked': String.fromCharCode(0xD800)};
      final got = unsellableReasons([lone, _plain], core: core);
      expect(got[0], isNotNull); // refused: the core's error, or locked if the text reached it some other way
      expect(got[1], isNull);
    });

    test('the same core, answering properly, sells', () {
      final fake = _Core((_) => [
            {'reason': null, 'sellable_record': true},
          ]);
      expect(unsellableReason(_plain, core: fake), isNull);
      expect(saleLineRefusal(_plain, 'PKPR-0005', 1, core: fake), isNull);
    });
  });
}
