// SP-R17, SP-R18: how a stock row is read (its kind, size, edible product, mg per unit, units on hand, By type weight),
// a state record's kind and whether it has units on hand moved from Dart into the shared core (stock.classify,
// stock.record_types, records.judge). This test keeps the Dart the phone ran before as its oracle and compares the
// core's answers with it over generated rows and records, hundreds of each: missing, zero, negative, fractional,
// huge and boundary figures, names with and without sizes, codes and keywords.
//
// Known differences, each the server's reading (Python's, which the core follows) and asserted below: a non-ASCII
// letter touching "TPE XX" (Dart's ASCII word boundary saw a word end there, the core's Unicode one doesn't); a
// record whose quantity is true or whose zeroOut is a truthy non-bool (Dart read only a number and `true`).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/package_ids.dart';
import 'package:mazama_mobile/state_records.dart';
import 'package:mazama_mobile/stock_mix.dart';
import 'package:mazama_mobile/stock_rows.dart';
import 'package:mazama_mobile/stock_summary.dart';

// ---- the old Dart, as lib/ had it --------------------------------------------------------------------------------

const _servingSizes = [25, 20, 15, 10, 5];
const _edibles = {'CH': 'Chocolate', 'GM': 'Gummy', 'HN': 'Honey'};
const _nameKeywords = [('gumm', 'GM'), ('chocolate', 'CH'), ('choc', 'CH'), ('honey', 'HN'), ('extract', 'EX')];
const _mixTypeWords = {
  'FD': 'Freeze dried', 'DH': 'Dehydrated', 'HG': 'Homogenized', 'CH': 'Chocolate', 'EX': 'Extract', 'HN': 'Honey',
  'GM': 'Gummy', 'LOT': 'Process lot', 'WF': 'Whole fungi', '': 'Other type',
};
const _kindKeywords = [('freeze', 'FD'), ('dehydrat', 'DH'), ('homogen', 'HG')];
const _sourceKinds = {'HB-': 'DH', 'PL-': 'HG'};
final _doseRe = RegExp(r'(?<![0-9.])([0-9]{1,3})\s*mg\b', caseSensitive: false);
final _nameCodeRe = RegExp(r'\bTPE\s+([A-Z]{2})\b');
final _packageMgRe = RegExp(r'(?<![0-9.])([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*mg\b', caseSensitive: false);

String _oldSizeKey(String? description) {
  final m = _doseRe.firstMatch(description ?? '');
  if (m != null) {
    final n = int.parse(m.group(1)!);
    if (_servingSizes.contains(n)) return '$n';
  }
  return 'other';
}

num _oldMgPerUnit(StockRow r, String mgMode) {
  if (mgMode == 'tpe') return r.unitMgTpe ?? 0.0;
  final w = r.weightPerUnit, a = r.analyteWeight;
  return w != null && a != null ? w * a : 0.0;
}

String _oldTypeOf(StockRow r) {
  final t = r.type ?? '';
  if (t.isNotEmpty) return t;
  final desc = r.description ?? '';
  final m = _nameCodeRe.firstMatch(desc);
  if (m != null) return m.group(1)!;
  final low = desc.toLowerCase();
  for (final (word, code) in _nameKeywords) {
    if (low.contains(word)) return code;
  }
  return '';
}

String _oldRowSizeKey(StockRow r, String mgMode) {
  if (_edibles[_oldTypeOf(r)] == null) return _oldSizeKey(r.description);
  final m = _packageMgRe.firstMatch(r.description ?? '');
  final num mg = m != null ? double.parse(m.group(1)!) : _oldMgPerUnit(r, mgMode);
  if (mg <= 0) return 'other';
  return mg < 3 ? 'micro' : 'booster';
}

bool _oldOnHand(StockRow r) => (r.quantity ?? 0) > 0 && !r.zeroOut;

String? _oldStateTypeOf(Map<String, Object?> r) {
  final name = textOrNull(r['description']) ?? '';
  final named = _oldTypeOf(StockRow(productGuid: '', id: 0, quantity: 0, description: name));
  if (named.isNotEmpty) return named;
  final productType = textOrNull(r['productType']) ?? '';
  final text = '$name $productType'.toLowerCase();
  for (final (word, code) in _kindKeywords) {
    if (text.contains(word)) return code;
  }
  final source = packageSource(r);
  final fromSource = source == null ? null : _sourceKinds[source.substring(0, 3).toUpperCase()];
  if (fromSource != null) return fromSource;
  return productType.toLowerCase().contains('whole fungi') ? 'WF' : null;
}

bool _oldHasUnits(Map<String, Object?> record) {
  final q = record['quantity'];
  return record['zeroOut'] != true && q is num && q > 0;
}

// ---- generated inputs ----------------------------------------------------------------------------------------------

const _nums = <num?>[null, 0, 0.0, -1, -0.5, 1, 2, 2.5, 3, 2.99, 3.0, 3.01, 24.71, 1e12, 1e-9, 99999, 7, 125];
const _words = [
  'Bluey', 'GT', '25 mg', '20mg', '5 MG', '10 mg', '1000 mg', '12.5 mg', '2.99 mg', '3 mg', '0 mg', 'TPE CH', 'TPE FD',
  'TPE  GM', 'TPEHN', 'tpe ch', 'TPE CHx', 'chocolate', 'Choc', 'gummies', 'HONEY', 'extract', 'freeze dried',
  'Dehydrated', 'homogenized', '(2027-02-03)', 'x.5 mg', '15mgs', 'mg', '', ' ', 'caps', '1.25mg', '1234.56 mg',
];
const _types = <String?>[null, '', 'CH', 'GM', 'HN', 'FD', 'DH', 'XX', 'LOT', 'EX', 'WF'];
const _productTypes = <Object?>[null, '', 'Whole Fungi', 'whole fungi caps', 'Dehydrated', 'Freeze dried', 'Homogenized', 'Extract', 5, true];
const _sources = <Object?>[null, 'HB-12345', 'PL-abcdef', 'hb-12345', 'HB-123', 'PL-123456789', 'XX-12345', 12345, 'HB-0a1b2c3d'];

T _pick<T>(Random r, List<T> xs) => xs[r.nextInt(xs.length)];

String? _name(Random r) => r.nextInt(8) == 0 ? null : [for (var i = r.nextInt(5); i > 0; i--) _pick(r, _words)].join(' ');

StockRow _row(Random r, int i) => StockRow(
      productGuid: 'PKPR-${i.toString().padLeft(4, '0')}',
      id: i,
      quantity: _pick(r, _nums),
      zeroOut: r.nextInt(7) == 0,
      expired: r.nextInt(10) == 0,
      mazama: r.nextBool(),
      strain: _pick(r, ['Bluey', '', null, 'Avery']),
      description: _name(r),
      unitMgTpe: _pick(r, _nums),
      weightPerUnit: _pick(r, _nums),
      analyteWeight: _pick(r, _nums),
      type: _pick(r, _types),
    );

bool _close(num? a, num? b) => a == null || b == null ? a == b : (a - b).abs() <= 1e-9 * max(1, max(a.abs(), b.abs()));

void main() {
  test('stock.classify gives the old Dart answers over 600 generated row lists, both mg modes', () {
    final rnd = Random(20261101);
    var rows = 0;
    for (var n = 0; n < 600; n++) {
      final list = [for (var i = rnd.nextInt(13); i > 0; i--) _row(rnd, i)];
      for (final mode in stockMgModes) {
        final got = stockClassify(list, mode);
        expect(got.rows, hasLength(list.length));
        final byMg = ((summarize(list, mode)['mg_total'] as num?) ?? 0) > 0;
        final words = <String>{};
        for (final (i, r) in list.indexed) {
          rows++;
          final c = got.rows[i];
          final type = _oldTypeOf(r);
          final why = '${r.toJson()} $mode';
          expect(c.type, type, reason: why);
          expect(c.word, _mixTypeWords[type] ?? type, reason: why);
          expect(c.edible, _edibles[type], reason: why);
          expect(c.sizeKey, _oldRowSizeKey(r, mode), reason: why);
          expect(_close(c.mgPerUnit, _oldMgPerUnit(r, mode)), isTrue, reason: '$why: ${c.mgPerUnit}');
          expect(c.hasUnits, _oldOnHand(r), reason: why);
          final weight = _oldOnHand(r) ? (r.quantity ?? 0) * (byMg ? _oldMgPerUnit(r, mode) : 1) : null;
          expect(_close(c.typeMg, weight), isTrue, reason: '$why: ${c.typeMg} != $weight');
          if (weight != null && weight > 0) words.add(_mixTypeWords[type] ?? type);
        }
        expect(got.typeWords.toSet(), words);
        expect(stockByTypeWords(list, mode), words);
      }
    }
    expect(rows, greaterThan(3000));
  });

  test('stock.record_types gives the old stateTypeOf answers over 3000 generated records', () {
    final rnd = Random(7);
    final records = [
      for (var i = 0; i < 3000; i++)
        <String, Object?>{
          'description': rnd.nextInt(10) == 0 ? _pick(rnd, <Object?>[5, true]) : _name(rnd),
          'productType': _pick(rnd, _productTypes),
          'harvestBatchGuid': _pick(rnd, _sources),
          'processLotGuid': _pick(rnd, _sources),
        },
    ];
    expect(stockRecordTypes(records), [for (final r in records) _oldStateTypeOf(r)]);
  });

  test('records.judge has_units gives the old Dart answer for every state-shaped record', () {
    final rnd = Random(11);
    final records = [
      for (var i = 0; i < 1000; i++)
        <String, Object?>{
          'productGuid': 'PKPR-0001',
          'id': i,
          if (rnd.nextInt(6) != 0) 'quantity': _pick(rnd, <Object?>[..._nums, '5', '', 'x']),
          if (rnd.nextInt(4) != 0) 'zeroOut': _pick(rnd, <Object?>[true, false, null]),
        },
    ];
    expect(recordsHaveUnits(records), [for (final r in records) _oldHasUnits(r)]);
  });

  test("the known differences are the server's reading", () {
    // a non-ASCII letter touching "TPE XX": no code in it for the core (nor Python), Dart's ASCII \b saw CH
    final row = StockRow(productGuid: 'P', id: 1, quantity: 1, description: 'TPE CHé');
    expect(_oldTypeOf(row), 'CH');
    expect(stockClassify([row], 'tpe').rows.single.type, '');
    // a quantity of true counts as 1 unit, a truthy zeroOut zeroes the record out, as Python reads them
    final odd = <Map<String, Object?>>[{'quantity': true}, {'quantity': 3, 'zeroOut': 1}];
    expect([for (final r in odd) _oldHasUnits(r)], [false, true]);
    expect(recordsHaveUnits(odd), [true, false]);
  });
}
