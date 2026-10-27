// Every case here was cross-checked against the real pricing.to_cents/money (Python) before this file was
// written - see the session that built this for the verification script. Not a guess at what the port should
// do; a record of what was actually confirmed to match.
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/pricing.dart';

void main() {
  group('toCents', () {
    const cases = <String, int?>{
      '12.50': 1250,
      '12.5': 1250,
      '12': 1200,
      '0': 0,
      '0.00': 0,
      '0.004': 0,
      '0.005': 1, // round-half-up at the boundary
      '0.006': 1,
      '0.994999': 99,
      '0.995': 100,
      '10000': 1000000,
      '10000.00': 1000000,
      '10000.01': null, // over the $10,000 ceiling
      '9999.995': 1000000,
      '9999.994': 999999,
      '-1': null,
      '-0.01': null,
      'abc': null,
      '': null,
      '  12.50  ': 1250,
      '12,50': 1250, // comma as decimal separator
      '1.005': 101,
      '1.015': 102,
      '1.025': 103,
      '0.001': 0,
      '99999999': null,
      '12.999': 1300,
      '100.345': 10035,
      '100.344': 10034,
      '7': 700,
      '7.1': 710,
      '7.10': 710,
      '7.100': 710,
      '3.14159': 314,
    };

    cases.forEach((text, expected) {
      test('${text.isEmpty ? "(empty string)" : text} -> $expected', () {
        expect(toCents(text), expected);
      });
    });
  });

  group('perMgRateToCents', () {
    // Same string-based parsing as toCents, just bounded to pricing.py's MAX_PER_MG ($1,000/mg) instead of the
    // $10,000 per-unit ceiling - cross-checked against pricing.to_dec(text, MAX_PER_MG) directly, the same way
    // toCents above was checked against to_cents.
    const cases = <String, int?>{
      '0.02': 2,
      '1000': 100000,
      '1000.00': 100000,
      '1000.01': null, // over the $1,000/mg ceiling (toCents's own $10,000 ceiling would have allowed this)
      '-1': null,
      '': null,
      'abc': null,
      '0.005': 1,
      '0.004': 0,
      '999.995': 100000,
      '999.994': 99999,
      '0': 0,
      '1,5': 150, // comma as decimal separator
    };

    cases.forEach((text, expected) {
      test('${text.isEmpty ? "(empty string)" : text} -> $expected', () {
        expect(perMgRateToCents(text), expected);
      });
    });
  });

  group('perMgPriceCentsEach', () {
    // Cross-checked against the real pricing.per_mg_prices(Decimal(rate), [mg]) directly, same as the rest of
    // this file - see pricing.dart's own file comment for why this is the one calculation here that still
    // multiplies by a plain double (a package's analyteWeight arrives from the server as one already).
    final cases = <(int, double), int>{
      (2, 4.5): 9, // $0.02/mg x 4.5mg = 9c exactly
      (2, 7.25): 15, // 14.5c, a tie - rounds half up to 15
      (150, 20.9575): 3144, // 3143.625c, rounds up to 3144
      (0, 0.5): 0,
      (99999, 1.0): 99999,
    };

    cases.forEach((args, expected) {
      final (rateCentsPerMg, mg) = args;
      test('$rateCentsPerMg c/mg x ${mg}mg -> $expected', () {
        expect(perMgPriceCentsEach(rateCentsPerMg, mg), expected);
      });
    });
  });

  group('money', () {
    const cases = <int, String>{
      0: r'$0.00',
      5: r'$0.05',
      50: r'$0.50',
      999: r'$9.99',
      1000: r'$10.00',
      1250: r'$12.50',
      100000: r'$1,000.00',
      1000000: r'$10,000.00',
      1234567: r'$12,345.67',
      12345678: r'$123,456.78',
    };

    cases.forEach((cents, expected) {
      test('$cents -> $expected', () {
        expect(money(cents), expected);
      });
    });
  });
}
