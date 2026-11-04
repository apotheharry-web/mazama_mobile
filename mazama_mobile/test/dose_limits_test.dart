// The per-sale raw psilocybin cap and session length are the shared core's (mazama_core::dose;
// lib/dose.dart's saleLimits), the same rule the server's worker and cart ask. Held to the frozen vectors from
// this app's vendored copies: selling/vectors/dose_limits.json (with a unit of unknown potency refused)
// and dose/vectors/dose_cases.json (the DOSE rows as the owner approved them). The phone counts the lots a sale
// draws, each its own figures, every bulk copy on its own draw, and fails closed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/cart_page.dart' show sessionTimeLeft, sessionTimeLeftText;
import 'package:mazama_mobile/dose.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/packages_client.dart';

import 'support/core.dart';

final _limits = (jsonDecode(File('assets/shared/selling/vectors/dose_limits.json').readAsStringSync()) as List)
    .cast<Map<String, Object?>>();
final _cases = jsonDecode(File('assets/shared/dose/vectors/dose_cases.json').readAsStringSync()) as Map<String, Object?>;

const _unknown = "This sale holds a unit whose psilocybin isn't known (no weightPerUnit or analyteWeight), so it can't be "
    'sold here.';

Package _lot(int id, int quantity, double weightPerUnit, double analyteWeight, {DateTime? expires}) => Package(
    productGuid: 'PKPR-ab12c',
    productType: 'Extract',
    id: id,
    weightPerUnit: weightPerUnit,
    analyteWeight: analyteWeight,
    quantity: quantity,
    expires: expires);

/// A core whose doseSaleLimits answers [reply] (or throws it, when it is an error or exception), counting its calls.
class _Core implements CoreFunctions {
  final Object? Function(Map<String, Object?> input) reply;
  var calls = 0;
  _Core(this.reply);

  @override
  List<Object?> doseSaleLimits(Map<String, Object?> input) {
    calls++;
    final r = reply(input);
    if (r is Error) throw r;
    if (r is Exception) throw r;
    return r as List<Object?>;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<SaleLimitLine> _one(double w, double a, int qty, [String dose = 'initial']) => [
      (record: {'weightPerUnit': w, 'analyteWeight': a}, qty: qty, dose: dose),
    ];

void main() {
  late final MazamaCore core = loadTestCore();

  test('there are cases', () => expect(_limits.length, greaterThanOrEqualTo(19)));

  test('every dose_limits.json case, the two DOSE-5 cases refused', () {
    final sales = [
      for (final c in _limits)
        [
          for (final ln in (c['lines'] as List).cast<Map<String, Object?>>())
            (record: Map<String, Object?>.from(ln['record'] as Map), qty: ln['qty'] as int, dose: 'initial'),
        ],
    ];
    final got = saleLimits(sales, core: core);
    for (var i = 0; i < _limits.length; i++) {
      final c = _limits[i];
      expect(got[i].psilocybinMg, c['psilocybin_mg'], reason: '${c['name']}');
      expect(got[i].allowed, c['allowed'], reason: '${c['name']}');
      expect(got[i].sessionMinutes, c['session_minutes'], reason: '${c['name']}');
    }
    final dose5 = [for (var i = 0; i < _limits.length; i++) if ('${_limits[i]['name']}'.contains('known counts as 0')) got[i]];
    expect([for (final v in dose5) v.error], [_unknown, _unknown]);
  });

  test("every DOSE row's sale case, as approved, in one call per case", () {
    final cases = (_cases['sale_limits'] as List).cast<Map<String, Object?>>();
    expect(cases.length, greaterThanOrEqualTo(60));
    for (final c in cases) {
      expect(core.doseSaleLimits({'sales': c['sales']}), c['answers'], reason: '${c['name']}');
    }
  });

  group('the lines the cap counts: the lots a sale draws, each its own figures (DOSE-1)', () {
    test('a product whose first lot is weaker: the stronger lot drawn after it counts at its own figure', () {
      // lot 1 (expires first): 2 units of 1.0 g x 10 mg/g; lot 2: 2.0 g x 12 mg/g. 4 units: 2 x 10 + 2 x 24 = 68 mg
      final lots = [_lot(1, 2, 1.0, 10.0, expires: DateTime(2027, 1, 31)), _lot(2, 10, 2.0, 12.0, expires: DateTime(2028, 1, 31))];
      final draw = allocateBulkSales([(lots: lots, qty: 4)], 1).perSale!;
      final lines = drawnSaleLimitLines(draw, ['initial']).single;
      expect([for (final l in lines) (l.record['weightPerUnit'], l.record['analyteWeight'], l.qty, l.dose)],
          [(1.0, 10.0, 2, 'initial'), (2.0, 12.0, 2, 'initial')]);
      final v = saleLimits([lines], core: core).single;
      expect((v.psilocybinMg, v.allowed), ('68.00', false));
      expect(saleCapRefusal(draw.single, core: core),
          'This sale draws later lots and would total 68.0 mg psilocybin - more than the 50 mg limit per sale '
          '(mg TPE is not subject to this cap).');
    });

    test('a product whose first lot is stronger: the weaker lot drawn after it counts at its own figure', () {
      final lots = [_lot(1, 2, 2.0, 12.0, expires: DateTime(2027, 1, 31)), _lot(2, 10, 1.0, 10.0, expires: DateTime(2028, 1, 31))];
      final draw = allocateBulkSales([(lots: lots, qty: 4)], 1).perSale!;
      final v = saleLimits(drawnSaleLimitLines(draw, ['initial']), core: core).single;
      expect((v.psilocybinMg, v.allowed, v.sessionMinutes), ('68.00', false, null)); // 2 x 24 + 2 x 10
      final within = allocateBulkSales([(lots: lots, qty: 3)], 1).perSale!; // 2 x 24 + 10 = 58: over
      expect(saleLimits(drawnSaleLimitLines(within, ['initial']), core: core).single.allowed, isFalse);
      final two = allocateBulkSales([(lots: lots, qty: 2)], 1).perSale!; // 48 mg: within, 6 hours
      expect(saleLimits(drawnSaleLimitLines(two, ['initial']), core: core).single.sessionMinutes, 360);
    });

    test('an initial and a secondary line of one product share its lots, each its own dose', () {
      final lots = [_lot(1, 3, 1.0, 5.0, expires: DateTime(2027, 1, 31)), _lot(2, 10, 1.0, 10.0, expires: DateTime(2028, 1, 31))];
      final draw = allocateBulkSales([(lots: lots, qty: 2), (lots: lots, qty: 2)], 1).perSale!;
      final lines = drawnSaleLimitLines(draw, ['initial', 'secondary']).single;
      expect([for (final l in lines) (l.record['analyteWeight'], l.qty, l.dose)],
          [(5.0, 2, 'initial'), (5.0, 1, 'secondary'), (10.0, 1, 'secondary')]);
      final v = saleLimits([lines], core: core).single;
      // 10 initial + 5 + 10 secondary = 25 mg: 5 hours w/ booster, 3 hours for the initial dose alone
      expect((v.psilocybinMg, v.sessionMinutes, v.sessionMinutesInitial), ('25.00', 300, 180));
    });

    test("DOSE-18: a lot the phone can't read fails the whole list, so no sale of its product is offered", () {
      expect(() => Package.fromJson({'productGuid': 'PKPR-ab12c', 'id': 2, 'weightPerUnit': '0.5', 'analyteWeight': 7.25}),
          throwsA(isA<TypeError>()));
    });

    test('DOSE-5: a lot of unknown potency drawn refuses the sale, with the core\'s words', () {
      final lots = [_lot(1, 2, 1.0, 10.0, expires: DateTime(2027, 1, 31)), _lot(2, 10, 1.0, 0.0, expires: DateTime(2028, 1, 31))];
      final draw = allocateBulkSales([(lots: lots, qty: 3)], 1).perSale!;
      expect(saleLimits(drawnSaleLimitLines(draw, ['initial']), core: core).single.error, _unknown);
      expect(saleCapRefusal(draw.single, core: core), 'This sale is refused: $_unknown');
    });
  });

  group('DOSE-17: a bulk sell, every copy on its own draw', () {
    // the review's case: lot 1 (drawn first) 3 units of 1.0 g x 10 mg/g; lot 2 2.0 g x 12 mg/g. 3 units a copy.
    List<Package> lots() => [_lot(1, 3, 1.0, 10.0, expires: DateTime(2027, 1, 31)), _lot(2, 9, 2.0, 12.0, expires: DateTime(2028, 1, 31))];

    test('copy 2 draws the stronger lot: 30 mg and 72 mg, refused naming copy 2', () {
      final draw = allocateBulkSales([(lots: lots(), qty: 3)], 2).perSale!;
      final copies = drawnSaleLimitLines(draw, ['initial']);
      final counting = _Core((input) => core.doseSaleLimits(input));
      final v = bulkSaleLimits(copies, core: counting);
      expect(counting.calls, 1); // every copy in one call
      expect([for (final c in v) c.psilocybinMg], ['30.00', '72.00']);
      expect([for (final c in v) c.allowed], [false, false]);
      expect(v[1].error, 'This sale would total 72.0 mg psilocybin - more than the 50 mg limit per sale (mg TPE is not subject to this cap).');
      expect(v[0].error, 'copy 2 of 2 is refused: ${v[1].error}');
      expect(bulkCapRefusal(draw, core: core),
          'Sale 2 of 2 draws later lots and would total 72.0 mg psilocybin - more than the 50 mg limit per sale '
          '(mg TPE is not subject to this cap).');
    });

    test('every copy within the cap: each its own figure and session', () {
      final draw = allocateBulkSales([(lots: lots(), qty: 2)], 2).perSale!; // 20 mg, then 10 + 24 = 34 mg
      final v = bulkSaleLimits(drawnSaleLimitLines(draw, ['initial']), core: core);
      expect([for (final c in v) (c.psilocybinMg, c.allowed, c.sessionMinutes)], [('20.00', true, 240), ('34.00', true, 300)]);
      expect(bulkCapRefusal(draw, core: core), isNull);
    });
  });

  group('DOSE-7: a core that fails refuses the sale', () {
    final lines = [_one(1.0, 10.0, 2)];
    final cases = <String, Object? Function(Map<String, Object?>)>{
      'no core loaded (StateError)': (_) => StateError('mazama_core is not loaded'),
      'a core error (MazamaCoreError)': (_) => const MazamaCoreError('dose.sale_limits failed'),
      'any other exception': (_) => const FormatException('bad'),
      'no answer': (_) => <Object?>[],
      'an answer that is not an object': (_) => <Object?>['allowed'],
      'a numeric total': (_) => <Object?>[
            {'psilocybin_mg': 20.0, 'allowed': true, 'error': null, 'session_minutes': 240, 'session_minutes_initial': 240},
          ],
      'allowed with a refusal': (_) => <Object?>[
            {'psilocybin_mg': '20.00', 'allowed': true, 'error': 'no', 'session_minutes': 240, 'session_minutes_initial': 240},
          ],
      'allowed with no total': (_) => <Object?>[
            {'psilocybin_mg': null, 'allowed': true, 'error': null, 'session_minutes': 240, 'session_minutes_initial': 240},
          ],
      'a session that is not whole minutes': (_) => <Object?>[
            {'psilocybin_mg': '20.00', 'allowed': true, 'error': null, 'session_minutes': 240.5, 'session_minutes_initial': 240},
          ],
    };
    for (final MapEntry(key: name, value: reply) in cases.entries) {
      test(name, () {
        final v = saleLimits(lines, core: _Core(reply)).single;
        expect(identical(v, SaleLimits.failed), isTrue);
        expect((v.allowed, v.error), (false, doseCoreFailedReason));
        // a timer for it runs the longest session, 6 hours, and says the length can't be worked out
        final dose = sessionDoseOf(v, booster: false);
        expect(dose, (minutes: 360, booster: false, unknown: true));
        expect(sessionTimeLeft(Duration(minutes: dose.minutes!), const Duration(hours: 1), booster: false, unknown: dose.unknown),
            "5:00:00 left (the session length can't be worked out)");
      });
    }

    test('a bulk sell whose core fails refuses every copy', () {
      final v = bulkSaleLimits([_one(1.0, 10.0, 1), _one(1.0, 10.0, 1)], core: _Core((_) => StateError('no core')));
      expect([for (final c in v) c.allowed], [false, false]);
      expect(v[0].error, doseCoreFailedReason);
    });

    test('a sale the core can\'t take refuses only itself: each sale is asked alone when the list fails', () {
      final v = saleLimits([_one(1.0, 10.0, 1), _one(double.nan, 10.0, 1), _one(1.0, 5.0, 2)], core: core);
      expect([for (final c in v) (c.psilocybinMg, c.allowed)], [('10.00', true), (null, false), ('10.00', true)]);
      expect(v[1].error, doseCoreFailedReason);
      // and a sale that sells is never read as one the core couldn't answer
      expect(identical(v[0], SaleLimits.failed), isFalse);
    });
  });

  test("an older build's kept dose (a total only) is timed by the core, never shorter than its own", () {
    expect(keptMgLimits(22.5, core: core).sessionMinutes, 240);
    expect(keptMgLimits(2.4999999999999996, core: core).sessionMinutes, 60); // rounded up to 2.5: the longer session
    expect(keptMgLimits(0, core: core).sessionMinutes, 30);
    expect(keptMgLimits(60, core: core).sessionMinutes, isNull); // over the cap: no length
    expect(identical(keptMgLimits(double.nan, core: core), SaleLimits.failed), isTrue);
    expect(sessionTimeLeftText(22.5, const Duration(minutes: 7), booster: false), '3:53:00 left');
  });
}
