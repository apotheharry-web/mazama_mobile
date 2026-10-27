// The stock page's shared rules (specs/stock-page/README.md SP-R2, SP-R10): the Dart twin of the server's
// mazama_sales/src/mazama_sales/stockview.py (the reference). filterRows, summarize, pies and parTable give exactly the
// server's answers, held to the golden vectors vendored at assets/shared/stock/vectors/ (generated from the Python by
// ../../mazama_modules/stock/gen.py; see test/stock_summary_test.dart). The algorithm in words, with every detail
// that decides a number or a string, is mazama_modules/stock/README.md; the constants are its rules.yaml, vendored
// at assets/shared/stock/rules/rules.yaml.
//
// Data only: drawing the pies is the page's job. Results are plain maps in the JSON shapes the vectors hold (rows
// in filterRows' result are StockRow objects, which jsonEncode writes as their JSON).
//
// Where Dart and Python differ, this file copies Python: rounding to 2 decimals and the key's whole percent are
// half to even on the exact binary value (Dart's round() is half away from zero), and the par summary's number is
// formatted as Python's f"{x:g}".

import 'dart:math' as math;

/// The standard serving sizes, mg per unit, largest first (rules.yaml serving_sizes).
const List<int> stockServingSizes = [25, 20, 15, 10, 5];

/// The size key for every other size: no size in the description (rules.yaml other_size).
const String stockOtherSize = 'other';

/// specs/edibles ED-D1, ED-A1: a kind code that is an edible -> the product it is counted under (rules.yaml
/// edibles.products).
const Map<String, String> stockEdibles = {'CH': 'Chocolate', 'GM': 'Gummy', 'HN': 'Honey'};

/// ED-D2, ED-A2: a package holding less than this many mg is a Microdose, else a Booster (rules.yaml
/// edibles.booster_from_mg).
const num stockBoosterFromMg = 3;

/// The size keys of the two edible classes (rules.yaml edibles.sizes).
const String stockBooster = 'booster', stockMicro = 'micro';

/// An edible class's par/order size code (ED-A4: codes, not mg), word and pie slot (rules.yaml edibles.sizes).
const Map<String, (int, String, String)> stockEdibleSizes = {
  stockBooster: (-1, 'Booster', 'db'),
  stockMicro: (-2, 'Microdose', 'dm'),
};

/// A row with no type: the first of these words its name contains, any case (rules.yaml name_keywords).
const List<(String, String)> stockNameKeywords = [
  ('gumm', 'GM'), ('chocolate', 'CH'), ('choc', 'CH'), ('honey', 'HN'), ('extract', 'EX'),
];

/// The sizes of a strain's summary, in order (rules.yaml size_order).
const List<String> stockSizeOrder = ['25', '20', '15', '10', '5', stockBooster, stockMicro, stockOtherSize];

/// The par table's columns; -1 Booster, -2 Microdose, 0 = other sizes (rules.yaml par_columns).
const List<int> stockParColumns = [25, 20, 15, 10, 5, -1, -2, 0];

/// Strain colour slots s1..s7 by rank; the rest are "oth" (rules.yaml strain_slots).
const int stockStrainSlots = 7;

/// Strains listed with their own serving-size pies; the rest are counted in "more" (rules.yaml strain_rows).
const int stockMaxStrainRows = 12;

/// SP-D3: all inventory, or made by Mazama only; the first is the default (rules.yaml filters, default_filter).
const List<String> stockFilters = ['all', 'mazama'];

/// SP-D6: mg TPE (the server's figure) or mg psilocybin (the state's figures), never mixed (rules.yaml mg_modes).
const List<String> stockMgModes = ['tpe', 'psilocybin'];

const String _unknown = 'Unknown';
const Map<String, String> _mgTitles = {'tpe': 'Total mg TPE', 'psilocybin': 'Total mg psilocybin'};

/// One package as the stock rules see it (specs/stock-page/stock-page.plan.md "Stock row").
class StockRow {
  const StockRow({
    required this.productGuid,
    required this.id,
    required this.quantity,
    this.zeroOut = false,
    this.expired = false,
    this.mazama = false,
    this.strain = '',
    this.description = '',
    this.unitMgTpe,
    this.weightPerUnit,
    this.analyteWeight,
    this.type,
  });

  final String productGuid;
  final int id;

  /// Units on hand; null counts as 0.
  final num? quantity;
  final bool zeroOut;

  /// Expired (SM-18: from the day after its date); the server decides it, or the phone offline (SP-R13).
  final bool expired;

  /// Made by Mazama (Stock.made_by_us on the server; the manufacturer license offline).
  final bool mazama;

  /// The canonical strain name; '' or null = unknown.
  final String? strain;
  final String? description;

  /// mg TPE per unit (the server's figure); null when unknown.
  final num? unitMgTpe;
  final num? weightPerUnit;

  /// The state's psilocybin figure; mg psilocybin per unit = weightPerUnit x analyteWeight.
  final num? analyteWeight;

  /// The kind code (FD, DH, HG, CH, GM, HN, ...): the server's, else read from the name offline; null or '' = read
  /// it from [description] ([stockTypeOf], specs/edibles ED-R2).
  final String? type;

  factory StockRow.fromJson(Map<String, Object?> j) => StockRow(
        productGuid: (j['productGuid'] as String?) ?? '',
        id: ((j['id'] as num?) ?? 0).toInt(),
        quantity: j['quantity'] as num?,
        zeroOut: j['zeroOut'] == true,
        expired: j['expired'] == true,
        mazama: j['mazama'] == true,
        strain: j['strain'] as String?,
        description: j['description'] as String?,
        unitMgTpe: j['unitMgTpe'] as num?,
        weightPerUnit: j['weightPerUnit'] as num?,
        analyteWeight: j['analyteWeight'] as num?,
        type: j['type'] as String?,
      );

  Map<String, Object?> toJson() => {
        'productGuid': productGuid,
        'id': id,
        'quantity': quantity,
        'zeroOut': zeroOut,
        'expired': expired,
        'mazama': mazama,
        'strain': strain,
        'description': description,
        'unitMgTpe': unitMgTpe,
        'weightPerUnit': weightPerUnit,
        'analyteWeight': analyteWeight,
        if (type != null) 'type': type,
      };

  /// Units on hand: quantity above 0 and not zeroed out.
  bool get onHand => (quantity ?? 0) > 0 && !zeroOut;
}

/// One par level: [size] 25/20/15/10/5, -1 Booster, -2 Microdose (edibles), or 0 for other sizes; [par] null removes
/// it (when saving).
class ParLevel {
  const ParLevel({required this.strain, required this.size, required this.par});

  final String strain;
  final int size;
  final int? par;

  factory ParLevel.fromJson(Map<String, Object?> j) => ParLevel(
        strain: (j['strain'] as String?) ?? '',
        size: ((j['size'] as num?) ?? -99).toInt(),     // missing: no column (-1 and -2 are the edible classes)
        par: (j['par'] as num?)?.toInt(),
      );

  Map<String, Object?> toJson() => {'strain': strain, 'size': size, 'par': par};
}

// --- Python's rounding and formatting ----------------------------------------------------------------------------

/// Python's round(x, 2): the nearest 2-decimal number to the exact binary value, an exact tie to the even last
/// digit. An exact tie at the third decimal is only possible when x x 8 is an odd whole number (0.125, 0.375, ...).
double roundTo2(num value) {
  final x = value.toDouble();
  if (!x.isFinite) return x;
  final eighths = x * 8;
  if (eighths == eighths.truncateToDouble() && eighths.abs() % 2 == 1) {
    final hundredths = x * 100;                 // k x 12.5: exact
    final low = hundredths.floorToDouble();
    final even = low % 2 == 0 ? low : low + 1;
    return even / 100;
  }
  return double.parse(x.toStringAsFixed(2));
}

/// Python's int(f"{x:.0f}"): the nearest whole number, an exact .5 to the even one (12.5 -> 12, 13.5 -> 14).
int roundHalfEven(double x) {
  final low = x.floorToDouble();
  if (x - low == 0.5) return (low % 2 == 0 ? low : low + 1).toInt();
  return x.round();
}

/// A slice's whole percent: 100 x value / total (multiplied first, as the server does), rounded half to even.
int stockPercent(num value, num total) => roundHalfEven(100 * value / total);

/// Python's f"{x:.{d}f}" for x >= 0: toStringAsFixed, except that an exact tie goes to the even last digit
/// (toStringAsFixed takes the larger). x is an exact tie at d decimals only when x x 2^(d+1) is an odd whole number.
String _fixedHalfEven(double x, int d) {
  final scaled = x * math.pow(2, d + 1);
  if (d <= 15 && x < 1e15 && scaled == scaled.truncateToDouble() && scaled % 2 == 1) {
    var n = (x * math.pow(10, d)).floorToDouble();       // x x 10^d = n + 0.5 exactly
    if (n % 2 != 0) n += 1;
    final digits = n.toStringAsFixed(0).padLeft(d + 1, '0');
    return d == 0 ? digits : '${digits.substring(0, digits.length - d)}.${digits.substring(digits.length - d)}';
  }
  return x.toStringAsFixed(d);
}

String _stripZeros(String s) =>
    s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;

/// Python's f"{x:g}": 6 significant digits rounded half to even, trailing zeros dropped, exponent form ("1e+06")
/// outside 1e-4 .. 1e6.
String formatG(num value) {
  final v = value.toDouble();
  if (v.isNaN) return 'nan';
  if (v.isInfinite) return v > 0 ? 'inf' : '-inf';
  if (v == 0) return v.isNegative ? '-0' : '0';
  final sign = v < 0 ? '-' : '';
  final x = v.abs();
  final parts = x.toStringAsExponential(5).split('e');
  final exp = int.parse(parts[1]);
  if (exp >= -4 && exp < 6) return '$sign${_stripZeros(_fixedHalfEven(x, 5 - exp))}';
  if (x == x.truncateToDouble() && x < 9e15) {
    // A whole number: round to 6 digits in integer arithmetic (ties to even), as Python does.
    final xi = x.toInt();
    var e = xi.toString().length - 1;
    var p = 1;
    for (var i = 0; i < e - 5; i++) {
      p *= 10;
    }
    var m = xi ~/ p;
    final r = xi - m * p;
    if (2 * r > p || (2 * r == p && m.isOdd)) m += 1;
    if (m >= 1000000) {
      m ~/= 10;
      e += 1;
    }
    final ms = '$m';
    return '$sign${_stripZeros('${ms[0]}.${ms.substring(1)}')}e+${'$e'.padLeft(2, '0')}';
  }
  return '$sign${_stripZeros(parts[0])}e${exp < 0 ? '-' : '+'}${exp.abs().toString().padLeft(2, '0')}';
}

// --- 1. filter ---------------------------------------------------------------------------------------------------

/// SP-D2, SP-D3: {"counted": [StockRow], "other": [{"row": StockRow, "reason": "expired" | "other_maker"}]}.
/// Rows with no units on hand are in neither; expired beats other maker. [makers] is 'all' or 'mazama'.
Map<String, Object?> filterRows(List<StockRow> rows, String makers) {
  if (!stockFilters.contains(makers)) throw ArgumentError.value(makers, 'makers', 'must be one of $stockFilters');
  final counted = <StockRow>[];
  final other = <Map<String, Object?>>[];
  for (final r in rows) {
    if (!r.onHand) continue;
    if (r.expired) {
      other.add({'row': r, 'reason': 'expired'});
    } else if (makers == 'mazama' && !r.mazama) {
      other.add({'row': r, 'reason': 'other_maker'});
    } else {
      counted.add(r);
    }
  }
  return {'counted': counted, 'other': other};
}

// --- 2. summary --------------------------------------------------------------------------------------------------

final RegExp _doseRe = RegExp(r'(?<![0-9.])([0-9]{1,3})\s*mg\b', caseSensitive: false);

/// The size key of a description: "25" .. "5" for the first "N mg" when N is a standard size, else "other"
/// (the server's stockmath.serving_size).
String stockSizeKey(String? description) {
  final m = _doseRe.firstMatch(description ?? '');
  if (m != null) {
    final n = int.parse(m.group(1)!);
    if (stockServingSizes.contains(n)) return '$n';
  }
  return stockOtherSize;
}

/// The mg in one unit of [r] in [mgMode] (0 when not known): the stock page's By type pie weighs rows by it (SP-D17).
num stockMgPerUnit(StockRow r, String mgMode) => _mgPerUnit(r, mgMode);

num _mgPerUnit(StockRow r, String mgMode) {
  if (mgMode == 'tpe') return r.unitMgTpe ?? 0.0;
  final w = r.weightPerUnit, a = r.analyteWeight;
  return w != null && a != null ? w * a : 0.0;
}

final RegExp _nameCodeRe = RegExp(r'\bTPE\s+([A-Z]{2})\b');
final RegExp _packageMgRe = RegExp(r'(?<![0-9.])([0-9]{1,4}(?:\.[0-9]{1,2})?)\s*mg\b', caseSensitive: false);

/// A row's kind code (ED-R2): its type when not empty; else the code after "TPE" in its name; else the first
/// [stockNameKeywords] word its lower-cased name contains; else ''.
String stockTypeOf(StockRow r) {
  final t = r.type ?? '';
  if (t.isNotEmpty) return t;
  final desc = r.description ?? '';
  final m = _nameCodeRe.firstMatch(desc);
  if (m != null) return m.group(1)!;
  final low = desc.toLowerCase();
  for (final (word, code) in stockNameKeywords) {
    if (low.contains(word)) return code;
  }
  return '';
}

/// The product an edible row is counted under ("Chocolate", "Gummy", "Honey"); null for anything else (ED-D1).
String? stockEdibleOf(StockRow r) => stockEdibles[stockTypeOf(r)];

/// A row's size key: "25" .. "5" for a serving size, "booster" / "micro" for an edible (by the first "N mg" in its
/// name, else its mg per unit in [mgMode]: ED-D2, ED-A3), else "other".
String stockRowSizeKey(StockRow r, String mgMode) {
  if (stockEdibleOf(r) == null) return stockSizeKey(r.description);
  final m = _packageMgRe.firstMatch(r.description ?? '');
  final num mg = m != null ? double.parse(m.group(1)!) : _mgPerUnit(r, mgMode);
  if (mg <= 0) return stockOtherSize;
  return mg < stockBoosterFromMg ? stockMicro : stockBooster;
}

/// A summary size key -> its par/order size: "25" -> 25, "booster" -> -1, "micro" -> -2, "other" -> 0.
int stockSizeCode(String key) {
  final e = stockEdibleSizes[key];
  if (e != null) return e.$1;
  return key == stockOtherSize ? 0 : int.parse(key);
}

/// A par/order size -> its words: "25 mg", "Booster", "Microdose", "Other".
String stockSizeWord(int code) {
  for (final e in stockEdibleSizes.values) {
    if (e.$1 == code) return e.$2;
  }
  return code == 0 ? 'Other' : '$code mg';
}

/// True for a par/order row named after an edible product ("Chocolate", "gummy"): it takes Booster, Microdose and
/// Other; a strain takes 25 .. 5 mg and Other (ED-A6).
bool stockIsProduct(String name) => stockEdibles.values.any((w) => w.toLowerCase() == name.trim().toLowerCase());

/// The product's own word for a product name ("chocolate" -> "Chocolate"); the name itself otherwise.
String stockProductWord(String name) =>
    stockEdibles.values.firstWhere((w) => w.toLowerCase() == name.trim().toLowerCase(), orElse: () => name);

/// The par/order sizes a row takes, in column order (ED-A6).
List<int> stockSizesFor(String name) {
  final product = stockIsProduct(name);
  return [
    for (final d in stockParColumns)
      if (d == 0 || (d < 0) == product) d,
  ];
}

/// The combined par/order row's name (rules.yaml all_strains): every strain's stock together, for centers that don't
/// care which strain they get.
const String stockAllStrains = 'All strains';

/// True for the combined row's name, any case or spacing ("all strains", "All  Strains").
bool stockIsAll(String name) => name.trim().split(RegExp(r'\s+')).join(' ').toLowerCase() == stockAllStrains.toLowerCase();

/// The kind code of an edible product's order lines (CH, GM, HN); null for a strain.
String? stockProductCode(String name) {
  for (final e in stockEdibles.entries) {
    if (e.value.toLowerCase() == name.trim().toLowerCase()) return e.key;
  }
  return null;
}

List<String> get _sizeOrder => stockSizeOrder;

Map<String, Object?> _ordered(Map<String, num> sizes) => {
      for (final k in _sizeOrder)
        if (sizes.containsKey(k)) k: sizes[k],
    };

class _Strain {
  final Map<String, num> spell = {};
  num units = 0;
  final Map<String, num> sizes = {};
  double mg = 0.0;
  final Map<String, double> mgSizes = {};
}

/// Counted rows -> {"total", "mg_total", "mg_mode", "strains": [{"name", "units", "mg", "sizes", "mg_sizes"}]}.
/// [mgMode] is 'tpe' or 'psilocybin'. Rows not on hand are skipped.
Map<String, Object?> summarize(List<StockRow> rows, String mgMode) {
  if (!stockMgModes.contains(mgMode)) throw ArgumentError.value(mgMode, 'mgMode', 'must be one of $stockMgModes');
  final by = <String, _Strain>{};
  for (final r in rows) {
    if (!r.onHand) continue;
    final q = r.quantity!;
    final s = r.strain;
    final name = stockEdibleOf(r) ?? ((s == null || s.isEmpty) ? _unknown : s);
    final slot = by.putIfAbsent(name.toLowerCase(), _Strain.new);
    slot.spell[name] = (slot.spell[name] ?? 0) + q;
    final k = stockRowSizeKey(r, mgMode);
    final mg = q * _mgPerUnit(r, mgMode);
    slot.units += q;
    slot.sizes[k] = (slot.sizes[k] ?? 0) + q;
    slot.mg += mg;
    slot.mgSizes[k] = (slot.mgSizes[k] ?? 0.0) + mg;
  }
  String shown(_Strain v) {
    String? best;
    for (final n in v.spell.keys) {
      if (best == null) {
        best = n;
        continue;
      }
      final c = v.spell[n]!.compareTo(v.spell[best]!);
      if (c > 0 || (c == 0 && n.compareTo(best) > 0)) best = n;
    }
    return best!;
  }

  final named = [for (final v in by.values) (shown(v), v)];
  named.sort((a, b) {
    final c = b.$2.units.compareTo(a.$2.units);
    return c != 0 ? c : a.$1.toLowerCase().compareTo(b.$1.toLowerCase());
  });
  final strains = <Map<String, Object?>>[
    for (final (n, v) in named)
      {
        'name': n,
        'units': v.units,
        'mg': roundTo2(v.mg),
        'sizes': _ordered(v.sizes),
        'mg_sizes': _ordered({for (final e in v.mgSizes.entries) e.key: roundTo2(e.value)}),
      },
  ];
  num total = 0;
  num mgSum = 0;
  for (final s in strains) {
    total += s['units'] as num;
    mgSum += s['mg'] as num;
  }
  return {'total': total, 'mg_total': strains.isEmpty ? 0 : roundTo2(mgSum), 'mg_mode': mgMode, 'strains': strains};
}

// --- 3. pies -----------------------------------------------------------------------------------------------------

Map<String, Object?> _slice(String name, num value, String slot, num total) =>
    {'name': name, 'value': value, 'slot': slot, 'pct': stockPercent(value, total)};

Map<String, Object?> _strainPie(List<(String, num)> pairs, num total) {
  final slices = <Map<String, Object?>>[];
  for (var i = 0; i < pairs.length && i < stockStrainSlots; i++) {
    if (pairs[i].$2 > 0) slices.add(_slice(pairs[i].$1, pairs[i].$2, 's${i + 1}', total));
  }
  if (pairs.length > stockStrainSlots) {
    num other = 0;
    for (final p in pairs.skip(stockStrainSlots)) {
      other += p.$2;
    }
    if (other > 0) slices.add(_slice('Other (${pairs.length - stockStrainSlots} strains)', other, 'oth', total));
  }
  return {'total': total, 'slices': slices};
}

bool _nonZero(Object? v) => v is num && v != 0;

Map<String, Object?>? _sizePie(Map sizes, String title) {
  num total = 0;
  for (final k in _sizeOrder) {
    total += (sizes[k] as num?) ?? 0;
  }
  if (total <= 0) return null;
  final parts = <(String, num, String)>[
    for (final d in stockServingSizes)
      if (_nonZero(sizes['$d'])) ('$d mg', sizes['$d'] as num, 'd$d'),
    for (final e in stockEdibleSizes.entries)
      if (_nonZero(sizes[e.key])) (e.value.$2, sizes[e.key] as num, e.value.$3),
    if (_nonZero(sizes[stockOtherSize])) ('Other size', sizes[stockOtherSize] as num, 'dx'),
  ];
  final slices = parts.length == 1
      ? [_slice(parts[0].$1, parts[0].$2, 'c', total)]
      : [for (final p in parts) _slice(p.$1, p.$2, p.$3, total)];
  return {'title': title, 'total': total, 'slices': slices};
}

/// A summary -> {"units": pie | null, "mg": pie | null, "rows": [...], "more": n} (charts.stock_view's data).
/// A pie is {"total", "slices": [{"name", "value", "slot", "pct"}]}; a row is {"name", "units", "mg", "slot",
/// "size_pies": [{"title", "total", "slices"}]}.
Map<String, Object?> pies(Map<String, Object?> summary) {
  final strains = [for (final s in summary['strains'] as List) s as Map];
  final total = summary['total'] as num;
  final mgTotal = summary['mg_total'] as num;
  final view = <String, Object?>{'units': null, 'mg': null, 'rows': <Map<String, Object?>>[], 'more': 0};
  if (total <= 0) return view;
  final slots = <String, String>{
    for (var i = 0; i < strains.length && i < stockStrainSlots; i++) strains[i]['name'] as String: 's${i + 1}',
  };
  view['units'] = _strainPie([for (final s in strains) (s['name'] as String, s['units'] as num)], total);
  if (mgTotal > 0) view['mg'] = _strainPie([for (final s in strains) (s['name'] as String, s['mg'] as num)], mgTotal);
  final mgTitle = _mgTitles[summary['mg_mode']] ?? _mgTitles['tpe']!;
  final rows = <Map<String, Object?>>[];
  for (final s in strains.take(stockMaxStrainRows)) {
    final name = s['name'] as String;
    final sizePies = [
      _sizePie(s['sizes'] as Map, 'Quantity'),
      if (mgTotal > 0) _sizePie(s['mg_sizes'] as Map, mgTitle),
    ];
    rows.add({
      'name': name,
      'units': s['units'],
      'mg': s['mg'],
      'slot': slots[name] ?? 'oth',
      'size_pies': [for (final p in sizePies) if (p != null) p],
    });
  }
  view['rows'] = rows;
  view['more'] = strains.length > stockMaxStrainRows ? strains.length - stockMaxStrainRows : 0;
  return view;
}

// --- 4. par ------------------------------------------------------------------------------------------------------

/// The summary of ALL counted stock (SP-D4) and the center's par levels ->
/// {"heads": [25, 20, 15, 10, 5, -1, -2, 0], "rows": [{"name", "cells": [{"size", "have", "par", "short"}], "short"}],
/// "short_total", "summary", "all"} (charts.par_view's data). "all" is the combined row ([stockAllStrains]), never one
/// of "rows": {"name", "cells": [{"size", "have", "par", "short", "extra"}] for 25 .. 5 and 0, "short", "extra"}; its
/// have is every non-edible row's units, extra what it lacks beyond the strain rows' own shortfall of that size
/// (mazama_modules/stock/README.md section 4), and short_total counts the extras, not its short.
Map<String, Object?> parTable(Map<String, Object?> summary, List<ParLevel> levels) {
  final par = <String, Map<int, int>>{};
  final names = <String, String>{};
  final combined = <int, int>{};
  final allSizes = stockSizesFor(stockAllStrains);
  for (final lv in levels) {
    final p = lv.par;
    if (p == null || !stockParColumns.contains(lv.size)) continue;
    if (stockIsAll(lv.strain)) {
      if (allSizes.contains(lv.size)) combined[lv.size] = p;
      continue;
    }
    final k = lv.strain.toLowerCase();
    par.putIfAbsent(k, () => {})[lv.size] = p;
    names[k] = lv.strain;
  }
  final table = <(String, Map<int, num>, Map<int, int>)>[];
  final seen = <String>{};
  for (final s in summary['strains'] as List) {
    final m = s as Map;
    final name = m['name'] as String;
    if (stockIsAll(name)) continue;
    seen.add(name.toLowerCase());
    final have = <int, num>{
      for (final e in (m['sizes'] as Map).entries)
        stockSizeCode(e.key as String): e.value as num,
    };
    table.add((name, have, par[name.toLowerCase()] ?? const <int, int>{}));
  }
  final parOnly = [for (final k in par.keys) if (!seen.contains(k)) k]
    ..sort((a, b) => names[a]!.toLowerCase().compareTo(names[b]!.toLowerCase()));
  for (final k in parOnly) {
    table.add((names[k]!, const <int, num>{}, par[k]!));
  }
  final rows = <Map<String, Object?>>[];
  num shortTotal = 0;
  final allHave = <int, num>{};
  final strainShort = <int, num>{};
  for (final (name, have, lvl) in table) {
    final cells = <Map<String, Object?>>[];
    num short = 0;
    final product = stockIsProduct(name);
    for (final d in stockParColumns) {
      final h = have[d] ?? 0;
      final p = lvl[d];
      final num gap = p != null && h < p ? p - h : 0;
      short += gap;
      cells.add({'size': d, 'have': h, 'par': p, 'short': gap});
      if (!product) {
        allHave[d] = (allHave[d] ?? 0) + h;
        strainShort[d] = (strainShort[d] ?? 0) + gap;
      }
    }
    shortTotal += short;
    rows.add({'name': name, 'cells': cells, 'short': short});
  }
  final allCells = <Map<String, Object?>>[];
  num allShort = 0, allExtra = 0;
  for (final d in allSizes) {
    final h = allHave[d] ?? 0;
    final p = combined[d];
    final num gap = p != null && h < p ? p - h : 0;
    final num rest = gap - (strainShort[d] ?? 0);
    final num extra = rest > 0 ? rest : 0;
    allShort += gap;
    allExtra += extra;
    allCells.add({'size': d, 'have': h, 'par': p, 'short': gap, 'extra': extra});
  }
  shortTotal += allExtra;
  final line = shortTotal != 0
      ? '${formatG(shortTotal)} units below par'
      : (par.isNotEmpty || combined.isNotEmpty ? 'All strains with a par level are at or above it.' : 'No par levels entered yet.');
  return {
    'heads': List<int>.of(stockParColumns),
    'rows': rows,
    'short_total': shortTotal,
    'summary': line,
    'all': {'name': stockAllStrains, 'cells': allCells, 'short': allShort, 'extra': allExtra},
  };
}
