// pacificMidnightUtc's expected values here are ground truth taken directly from Python's real
// zoneinfo('America/Los_Angeles') via selling.py's own pacific_midnight_utc, not computed by eye - including
// both DST transition boundary days themselves, where getting the strict-vs-non-strict comparison wrong would
// show up as an off-by-one-hour error. The Pacific midnight rule was also checked against
// zoneinfo for every single day across 2024-2028 (0 mismatches).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/selling.dart';

void main() {
  group('pacificMidnightUtc', () {
    const cases = <String, String>{
      '2026-01-15': '2026-01-15T08:00:00.000Z', // standard time
      '2026-03-08': '2026-03-08T08:00:00.000Z', // DST starts today - midnight is still standard
      '2026-03-09': '2026-03-09T07:00:00.000Z', // day after - daylight
      '2026-07-04': '2026-07-04T07:00:00.000Z', // mid-summer, daylight
      '2026-11-01': '2026-11-01T07:00:00.000Z', // DST ends today - midnight is still daylight
      '2026-11-02': '2026-11-02T08:00:00.000Z', // day after - standard
      '2026-12-31': '2026-12-31T08:00:00.000Z',
      '2028-02-29': '2028-02-29T08:00:00.000Z', // leap day
    };

    cases.forEach((dateText, expected) {
      test('$dateText -> $expected', () {
        final parts = dateText.split('-').map(int.parse).toList();
        final date = DateTime.utc(parts[0], parts[1], parts[2]);
        expect(pacificMidnightUtc(date), expected);
      });
    });
  });

  group('buildSale', () {
    final item = {
      'productGuid': 'GUID-1',
      'productType': 'Extract',
      'id': 42,
      'weightPerUnit': 5.0,
      'analyteWeight': 4.5,
      'serviceCenterId': 231,
      'description': 'Chocolate 10mg',
    };

    test('one unit at a given price, defaulting to the initial dose', () {
      final sale = buildSale(item, 1250, DateTime.utc(2026, 7, 4));
      expect(sale['productGuid'], 'GUID-1');
      expect(sale['productGroup'], 'Extract');
      expect(sale['productId'], 42);
      expect(sale['numberSold'], 1);
      expect(sale['productCost'], 12.5);
      expect(sale['costEach'], 12.5);
      expect(sale['dateOfSale'], '2026-07-04T07:00:00.000Z');
      expect(sale['weightPerUnit'], 5.0);
      expect(sale['analyteWeight'], 4.5);
      expect(sale['deleted'], false);
      expect(sale['serviceCenterId'], 231);
      expect(sale['notes'], ''); // never the description
      expect(sale['initialDose'], 1);
      expect(sale['secondaryDose'], 0);
      expect(sale['id'], 0);
      expect(sale['saleNumber'], '');
    });

    test('multiple units and the secondary dose', () {
      final sale = buildSale(item, 500, DateTime.utc(2026, 1, 15), dose: doseSecondary, qty: 3);
      expect(sale['numberSold'], 3);
      expect(sale['productCost'], 15.0);
      expect(sale['costEach'], 5.0);
      expect(sale['initialDose'], 0);
      expect(sale['secondaryDose'], 3);
    });

    test("notes are empty without a strain or lot TPE, never the item's description (SALE-20)", () {
      expect(item['description'], isNotNull);
      expect(buildSale(item, 100, DateTime.utc(2026, 1, 1))['notes'], '');
      final noDesc = Map<String, Object?>.from(item)..remove('description');
      expect(buildSale(noDesc, 100, DateTime.utc(2026, 1, 1))['notes'], '');
    });

    test("notes are the lot's strain and mg TPE, as every shared case says, the rest of the record unchanged (SALE-20, SALE-21)",
        () {
      final doc = jsonDecode(File('assets/shared/selling/notes/sale_notes.json').readAsStringSync()) as Map;
      final cases = (doc['cases'] as List).cast<Map>();
      expect(cases.length, greaterThanOrEqualTo(20));
      var built = 0;
      for (final c in cases) {
        final it = Map<String, Object?>.from(c['item'] as Map);
        final strain = c['strain'], tpe = c['lot_tpe'];
        // buildSale passes the strain as text and the TPE as a number: the cases that give either some other way
        // are the core's own (its Rust and Python tests run them)
        if ((strain != null && strain is! String) || (tpe != null && (tpe is! num))) continue;
        Map<String, Object?> plain;
        try {
          plain = buildSale(it, 2050, DateTime.utc(2026, 9, 28));
        } on SaleRefused {
          continue; // a refused record has no note
        }
        final got = buildSale(it, 2050, DateTime.utc(2026, 9, 28),
            strain: strain as String?, lotTpe: (tpe as num?)?.toDouble());
        expect(got['notes'], c['note'], reason: c['why'] as String);
        expect({...got}..remove('notes'), {...plain}..remove('notes'), reason: c['why'] as String);
        built++;
      }
      expect(built, greaterThanOrEqualTo(20));
    });
  });

  group('parseSaleDate', () {
    final today = DateTime.utc(2026, 10, 11);

    test('a valid past date parses', () {
      expect(parseSaleDate('2026-10-01', today), DateTime.utc(2026, 10, 1));
    });

    test('today itself is allowed', () {
      expect(parseSaleDate('2026-10-11', today), today);
    });

    test('a future date is rejected as "future"', () {
      expect(() => parseSaleDate('2026-10-12', today),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', 'future')));
    });

    test('the compact and ISO week forms the server accepts are dates too (SM-D6)', () {
      expect(parseSaleDate('20261011', today), today);
      expect(parseSaleDate('2026-W41-7', today), today); // Sunday of ISO week 41
      expect(parseSaleDate('2026W417', today), today);
      expect(parseSaleDate('2026-W41', today), DateTime.utc(2026, 10, 5)); // its Monday
      expect(() => parseSaleDate('2026-284', today), throwsA(isA<FormatException>().having((e) => e.message, 'message', 'bad')));
    });

    test('garbage text is rejected as "bad"', () {
      expect(() => parseSaleDate('not a date', today),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', 'bad')));
    });

    test('an impossible calendar date is rejected as "bad"', () {
      expect(() => parseSaleDate('2026-02-30', today),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', 'bad')));
    });
  });

  // The same three checks as salejobs.py's reply check, every one of them "uncertain" on both sides.
  group('looksLikeConfirmedSale', () {
    test('one record back per record sent, all with the same sale number', () {
      expect(looksLikeConfirmedSale([{'saleNumber': 'S-1'}, {'saleNumber': 'S-1'}], 2), isTrue);
    });

    test('a different number of records from the number sent', () {
      expect(looksLikeConfirmedSale([{'saleNumber': 'S-9'}, {'saleNumber': 'S-9'}], 3), isFalse);
    });

    test('more than one sale number for one request', () {
      expect(looksLikeConfirmedSale([{'saleNumber': 'S-1'}, {'saleNumber': 'S-2'}], 2), isFalse);
    });

    test('a blank or missing sale number', () {
      expect(looksLikeConfirmedSale([{'saleNumber': ''}], 1), isFalse);
      expect(looksLikeConfirmedSale([{'id': 1}], 1), isFalse);
      expect(looksLikeConfirmedSale([null], 1), isFalse);
    });

    test('anything that is not a list', () {
      expect(looksLikeConfirmedSale({'saleNumber': 'S-1'}, 1), isFalse);
      expect(looksLikeConfirmedSale(null, 1), isFalse);
    });
  });
}
