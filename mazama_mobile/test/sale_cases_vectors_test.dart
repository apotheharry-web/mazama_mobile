// specs/core row 7: the phone's sale records, dates, draws, checks and outcomes are the shared core's, held to the SALE
// rows the owner approved on 2026-10-31 (assets/shared/selling/vectors/sale_cases.json, vendored from
// ../mazama_modules/selling/vectors/; mazama_modules/core/tests/test_sale.py holds the server's side to the same file).
// A case marked "big" holds an integer beyond 64 bits, which Dart's JSON reader can't carry: the server and the core
// run it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/selling.dart';

import 'support/core.dart';

final Map<String, Object?> _cases =
    jsonDecode(File('assets/shared/selling/vectors/sale_cases.json').readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _section(String name) =>
    [for (final c in (_cases[name] as List).cast<Map<String, Object?>>()) if (c['big'] != true) c];

DateTime _day(String iso) {
  final p = iso.split('-').map(int.parse).toList();
  return DateTime.utc(p[0], p[1], p[2]);
}

void main() {
  late MazamaCore core;
  setUpAll(() => core = loadTestCore());

  test('every section is there', () {
    for (final s in ['build_sale', 'parse_sale_date', 'check_sale_date', 'pacific_midnight', 'today', 'allocate_sale',
        'check_sale', 'sale_outcome', 'sale_proof', 'review_each', 'review_sale_date', 'expiry', 'parse_state_date']) {
      expect(_section(s), isNotEmpty, reason: s);
    }
  });

  test('build_sale: the record, or the words of why not (SALE-10, SALE-12, SALE-13)', () {
    for (final c in _section('build_sale')) {
      final i = (c['input'] as Map).cast<String, Object?>();
      expect(core.sellingBuildSale(i), {'record': c['record'], 'refusal': c['refusal']}, reason: c['name'] as String);
      if (i['price_cents'] is int && i['qty'] is int && i['dose'] is String) {
        final item = (i['item'] as Map).cast<String, Object?>();
        if (c['refusal'] == null) {
          expect(buildSale(item, i['price_cents'] as int, _day(i['sale_date'] as String), dose: i['dose'] as String, qty: i['qty'] as int),
              c['record'], reason: c['name'] as String);
        } else {
          expect(() => buildSale(item, i['price_cents'] as int, _day(i['sale_date'] as String), dose: i['dose'] as String, qty: i['qty'] as int),
              throwsA(isA<SaleRefused>().having((e) => e.message, 'message', c['refusal'])), reason: c['name'] as String);
        }
      }
    }
  });

  test('dates: parse, check, Pacific midnight and today (SALE-1, SALE-2)', () {
    for (final c in _section('parse_sale_date')) {
      expect(core.sellingParseSaleDate({'text': c['text'], 'today': c['today']}), {'date': c['date'], 'error': c['error']}, reason: '$c');
    }
    for (final c in _section('check_sale_date')) {
      expect(checkSaleDate(_day(c['date'] as String), _day(c['today'] as String)), c['error'], reason: '$c');
    }
    for (final c in _section('pacific_midnight')) {
      expect(pacificMidnightUtc(_day(c['date'] as String)), c['utc'], reason: c['date'] as String);
    }
    for (final c in _section('today')) {
      expect(core.sellingToday({'now': c['now']}), {'date': c['date']}, reason: c['now'] as String);
    }
    for (final c in _section('parse_state_date')) {
      expect(stateDateIso(c['text'] as String?), c['date'], reason: '${c['text']}');
    }
  });

  test('pacificToday is the Pacific date whatever the device zone (SALE-2)', () {
    expect(pacificToday(DateTime.utc(2026, 10, 31, 6, 59, 59)), DateTime.utc(2026, 10, 30));
    expect(pacificToday(DateTime.utc(2026, 10, 31, 7)), DateTime.utc(2026, 10, 31));
    expect(pacificToday(DateTime.utc(2026, 12, 1, 7, 59)), DateTime.utc(2026, 11, 30));
  });

  test('draws, checks, outcomes and proofs (SALE-4, SALE-5, SALE-6, SALE-16, SALE-17)', () {
    for (final c in _section('allocate_sale')) {
      expect(core.sellingAllocateSale((c['input'] as Map).cast<String, Object?>()), {'draws': c['draws'], 'short': c['short']},
          reason: c['name'] as String);
    }
    for (final c in _section('check_sale')) {
      expect(core.sellingCheckSale((c['input'] as Map).cast<String, Object?>()), {'refusal': c['refusal']}, reason: c['name'] as String);
    }
    for (final c in _section('sale_outcome')) {
      expect(core.sellingSaleOutcome({'event': c['event'], 'sent': c['sent']}), {'outcome': c['outcome'], 'sale_number': c['sale_number']},
          reason: c['name'] as String);
    }
    for (final c in _section('sale_proof')) {
      expect(saleNumberOf(c['reply'], c['sent'] as int), c['sale_number'], reason: c['name'] as String);
    }
  });

  test('what the core refuses with an error, it refuses here too (review M2, M4)', () {
    for (final c in _section('rejects')) {
      final input = (c['input'] as Map).cast<String, Object?>();
      final call = switch (c['function']) {
        'review_each' => () => core.sellingReviewEach(input),
        'check_sale' => () => core.sellingCheckSale(input),
        'today' => () => core.sellingToday(input),
        _ => () => fail('no function ${c['function']}'),
      };
      expect(call, throwsA(isA<MazamaCoreError>()), reason: c['why'] as String);
    }
    expect(() => pacificToday(DateTime.utc(1, 1, 1, 7, 59, 59)), throwsStateError);
  });

  test('a core that fails builds nothing, dates nothing and proves nothing (SALE-14)', () {
    final broken = _Broken();
    expect(() => buildSale(const {'productGuid': 'PKPR-1'}, 100, DateTime.utc(2026, 10, 20), core: broken), throwsStateError);
    expect(() => pacificMidnightUtc(DateTime.utc(2026, 10, 20), core: broken), throwsStateError);
    expect(() => parseSaleDate('2026-10-20', DateTime.utc(2026, 10, 20), core: broken), throwsStateError);
    expect(() => pacificToday(DateTime.utc(2026, 10, 20), core: broken), throwsStateError);
    expect(checkSaleDate(DateTime.utc(2026, 10, 20), DateTime.utc(2026, 10, 20), core: broken), 'unchecked');
    expect(looksLikeConfirmedSale([{'saleNumber': 'S-1'}], 1, core: broken), isFalse);
    expect(stateDateIso('2026-10-20', core: broken), isNull);
    final odd = _Odd();
    expect(() => buildSale(const {'productGuid': 'PKPR-1'}, 100, DateTime.utc(2026, 10, 20), core: odd), throwsStateError);
    expect(looksLikeConfirmedSale([{'saleNumber': 'S-1'}], 1, core: odd), isFalse);
  });
}

class _Unnamed implements Exception {}

/// Every call throws an exception of a type nothing names.
class _Broken implements CoreFunctions {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw _Unnamed();
}

/// Every call answers an object of the wrong shape.
class _Odd implements CoreFunctions {
  @override
  dynamic noSuchMethod(Invocation invocation) => <String, Object?>{'record': 5, 'sale_number': 7};
}
