// MI-R1 (specs/mazama-inventory): a manufacturer's stock mix of mg TPE by strain and by product type, the numbers of
// the server's "By strain" / "By type" pies (stockview.mix, charts.mix_view). The algorithm is
// ../mazama_modules/stock/README.md § 5; this port is held to its golden vectors (assets/shared/stock/vectors/mix.json,
// test/stock_mix_test.dart), texts included. Drawing is the page's own (mazama_inventory_page.dart). A center's By type
// pie (stockByType) is § 6 on top of it, held to vectors/by_type.json (test/stock_by_type_test.dart).
import 'stock_summary.dart';

/// A product kind's code -> the word its pies show (rules.yaml `mix_type_words`); a code not listed shows as itself.
const Map<String, String> mixTypeWords = {
  'FD': 'Freeze dried',
  'DH': 'Dehydrated',
  'HG': 'Homogenized',
  'CH': 'Chocolate',
  'EX': 'Extract',
  'HN': 'Honey',
  'GM': 'Gummy',
  'LOT': 'Process lot',
  'WF': 'Whole fungi',
  '': 'Other type',
};

const String _unknown = 'Unknown';

/// One row of the mix: a strain, a kind code and its mg TPE (route C12 sends them summed per strain and type).
class MixCell {
  final String? strain;
  final String? type;
  final num? mg;

  const MixCell({this.strain, this.type, this.mg});

  factory MixCell.fromJson(Map<String, Object?> j) =>
      MixCell(strain: j['strain'] as String?, type: j['type'] as String?, mg: j['mg'] as num?);

  Map<String, Object?> toJson() => {'strain': strain, 'type': type, 'mg': mg};
}

String _word(String code) => mixTypeWords[code] ?? code;

String _slot(int i) => i < stockStrainSlots ? 's${i + 1}' : 'oth';

Map<String, Object?> _slice(String name, num value, String slot, num total) =>
    {'name': name, 'value': value, 'slot': slot, 'pct': stockPercent(value, total)};

/// Sorted by [compare], items that compare equal kept in their input order (Python's sorted is stable; Dart's sort is not).
List<T> _stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final numbered = [for (final (i, x) in items.indexed) (i, x)];
  numbered.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final (_, x) in numbered) x];
}

Map<String, Object?> _mixPie(List<(String, num)> pairs, num total) {
  final top = pairs.take(stockStrainSlots).toList();
  final rest = pairs.skip(stockStrainSlots).toList();
  final slices = [
    for (final (i, (n, v)) in top.indexed)
      if (v > 0) _slice(n, v, 's${i + 1}', total),
  ];
  num other = 0;
  for (final (_, v) in rest) {
    other += v;
  }
  if (other > 0) slices.add(_slice('Other (${rest.length})', other, 'oth', total));
  return {'total': total, 'slices': slices};
}

Map<String, Object?> _breakdown(List<(String, num)> pairs, num total) {
  var slices = [
    for (final (i, (n, v)) in pairs.indexed)
      if (v > 0) _slice(n, v, 's${i + 1}', total),
  ];
  if (slices.length == 1) slices = [{...slices.single, 'slot': 'c'}];
  return {'total': total, 'slices': slices};
}

/// The stock mix of [rows] (README § 5): {"total": 0} when nothing has mg; else {"total", "by_strain", "by_type",
/// "strain_cards", "type_cards", "types", "table", "type_totals"}, a pie being {"total", "slices": [{"name", "value",
/// "slot", "pct"}]} and a card {"name", "slot", "total", "pie"}.
Map<String, Object?> stockMix(List<MixCell> rows) {
  final clean = <(String, String, double)>[];
  for (final r in rows) {
    final mg = r.mg;
    if (mg != null && mg > 0) {
      final s = r.strain;
      clean.add(((s == null || s.isEmpty) ? _unknown : s, r.type ?? '', mg.toDouble()));
    }
  }
  num total = 0;
  for (final (_, _, mg) in clean) {
    total += mg;
  }
  if (total <= 0) return {'total': 0};

  // Insertion-ordered maps: first-seen order, as Python's dicts.
  final strains = <String, num>{};
  final types = <String, num>{};
  final cell = <(String, String), num>{};
  for (final (s, c, mg) in clean) {
    strains[s] = (strains[s] ?? 0) + mg;
    types[c] = (types[c] ?? 0) + mg;
    cell[(s, c)] = (cell[(s, c)] ?? 0) + mg;
  }
  int byValueThenKey(MapEntry<String, num> a, MapEntry<String, num> b) {
    final c = b.value.compareTo(a.value);
    return c != 0 ? c : a.key.compareTo(b.key);
  }

  final orderS = strains.entries.toList()..sort(byValueThenKey);
  final orderT = types.entries.toList()..sort(byValueThenKey);
  int largestFirst((String, num) a, (String, num) b) => b.$2.compareTo(a.$2);

  final strainCards = [
    for (final (i, e) in orderS.indexed)
      {
        'name': e.key,
        'slot': _slot(i),
        'total': e.value,
        'pie': _breakdown(
            _stableSorted([for (final c in types.keys) if (cell.containsKey((e.key, c))) (_word(c), cell[(e.key, c)]!)], largestFirst),
            e.value),
      },
  ];
  final typeCards = [
    for (final (i, e) in orderT.indexed)
      {
        'name': _word(e.key),
        'slot': _slot(i),
        'total': e.value,
        'pie': _breakdown(
            _stableSorted([for (final s in strains.keys) if (cell.containsKey((s, e.key))) (s, cell[(s, e.key)]!)], largestFirst),
            e.value),
      },
  ];
  return {
    'total': total,
    'by_strain': _mixPie([for (final e in orderS) (e.key, e.value)], total),
    'by_type': _mixPie([for (final e in orderT) (_word(e.key), e.value)], total),
    'strain_cards': strainCards,
    'type_cards': typeCards,
    'types': [for (final e in orderT) _word(e.key)],
    'table': [
      for (final s in orderS)
        {
          'strain': s.key,
          'cells': [for (final t in orderT) cell[(s.key, t.key)]],
          'total': s.value,
        },
    ],
    'type_totals': [for (final e in orderT) e.value],
  };
}

/// A center's By type pie (README § 6, specs/web-charts WC-D1): the By type pie of [stockMix] over the rows on hand,
/// one cell per row in row order with no strain, its type [stockTypeOf] and its weight: quantity x [stockMgPerUnit] in
/// [mgMode] when [summarize] of the same rows has an mg total above 0, else its quantity (units). Null when nothing is
/// left to weigh. Held to assets/shared/stock/vectors/by_type.json (test/stock_by_type_test.dart).
Map<String, Object?>? stockByType(List<StockRow> rows, String mgMode) {
  final pie = stockMix(stockByTypeCells(rows, mgMode));
  return (pie['total'] as num) > 0 ? pie['by_type'] as Map<String, Object?> : null;
}

/// The cells [stockByType] weighs, one per row on hand in row order (README § 6); a cell weighing 0 or less is left
/// out of the pie by [stockMix].
List<MixCell> stockByTypeCells(List<StockRow> rows, String mgMode) {
  final byMg = (summarize(rows, mgMode)['mg_total'] as num) > 0;
  return [
    for (final r in rows)
      if (r.onHand)
        MixCell(strain: '', type: stockTypeOf(r), mg: (r.quantity ?? 0) * (byMg ? stockMgPerUnit(r, mgMode) : 1)),
  ];
}

/// The word of every type [stockByType] weighs above 0, "Other (n)"'s included: the types a pick can name.
Set<String> stockByTypeWords(List<StockRow> rows, String mgMode) => {
      for (final c in stockByTypeCells(rows, mgMode))
        if ((c.mg ?? 0) > 0) _word(c.type ?? ''),
    };

/// An mg figure as the server's page writes it, Python's f"{x:,.0f}": rounded half to even on the exact value
/// (2.5 -> 2, 999.5 -> 1,000), a comma every three digits.
String formatMixMg(num value) {
  final n = roundHalfEven(value.toDouble());
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// A key line's text, as the server's: "1,234 mg · 45%".
String mixKeyText(Map<String, Object?> slice) => '${formatMixMg(slice['value'] as num)} mg · ${slice['pct']}%';
