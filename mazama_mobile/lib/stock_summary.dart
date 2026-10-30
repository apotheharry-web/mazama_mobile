// The stock page's shared rules (specs/stock-page/README.md SP-R2, SP-R10): filterRows, summarize, pies and parTable
// are the shared core's (mazama_core::stock, specs/core row 8), the same functions the server's stockview.py calls;
// they are held to the golden vectors vendored at assets/shared/stock/vectors/ (test/stock_summary_test.dart). The
// algorithm in words is mazama_modules/stock/README.md; the constants are its rules.yaml, vendored at
// assets/shared/stock/rules/rules.yaml. The constants and the small lookups below (size words, par sizes, a row's
// kind and size, Python's %g for the par page's figures) stay here for the pages.
//
// Data only: drawing the pies is the page's job. Results are plain maps in the JSON shapes the vectors hold (rows
// in filterRows' result are the caller's StockRow objects, which jsonEncode writes as their JSON).

import 'dart:math' as math;

import 'mazama_core.dart';

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

/// Python's int(f"{x:.0f}"): the nearest whole number, an exact .5 to the even one (12.5 -> 12, 13.5 -> 14).
int roundHalfEven(double x) {
  final low = x.floorToDouble();
  if (x - low == 0.5) return (low % 2 == 0 ? low : low + 1).toInt();
  return x.round();
}

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

/// The rows as the core takes them, each with its place in [rows] (`_row`), so answers map back to the caller's rows.
List<Map<String, Object?>> _sent(List<StockRow> rows) => [
      for (var i = 0; i < rows.length; i++) {...rows[i].toJson(), '_row': i},
    ];

/// SP-D2, SP-D3: {"counted": [StockRow], "other": [{"row": StockRow, "reason": "expired" | "other_maker"}]}.
/// Rows with no units on hand are in neither; expired beats other maker. [makers] is 'all' or 'mazama'. The core's
/// stock.filter; [core] defaults to this app's ([MazamaCore.instance]).
Map<String, Object?> filterRows(List<StockRow> rows, String makers, {CoreFunctions? core}) {
  if (!stockFilters.contains(makers)) throw ArgumentError.value(makers, 'makers', 'must be one of $stockFilters');
  final got = (core ?? MazamaCore.instance).stockFilter({'rows': _sent(rows), 'makers': makers});
  StockRow back(Object? r) => rows[((r as Map)['_row'] as num).toInt()];
  return {
    'counted': [for (final r in got['counted'] as List) back(r)],
    'other': [
      for (final o in got['other'] as List) {'row': back((o as Map)['row']), 'reason': o['reason']},
    ],
  };
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

/// Counted rows -> {"total", "mg_total", "mg_mode", "strains": [{"name", "units", "mg", "sizes", "mg_sizes"}]}.
/// [mgMode] is 'tpe' or 'psilocybin'. Rows not on hand are skipped. The core's stock.summarize.
Map<String, Object?> summarize(List<StockRow> rows, String mgMode, {CoreFunctions? core}) {
  if (!stockMgModes.contains(mgMode)) throw ArgumentError.value(mgMode, 'mgMode', 'must be one of $stockMgModes');
  return (core ?? MazamaCore.instance).stockSummarize({'rows': [for (final r in rows) r.toJson()], 'mg_mode': mgMode});
}

/// A summary -> {"units": pie | null, "mg": pie | null, "rows": [...], "more": n} (charts.stock_view's data); a pie is
/// {"total", "slices": [{"name", "value", "slot", "pct"}]}. The core's stock.pies.
Map<String, Object?> pies(Map<String, Object?> summary, {CoreFunctions? core}) =>
    (core ?? MazamaCore.instance).stockPies({'summary': summary});

/// The summary of ALL counted stock (SP-D4) and the center's par levels ->
/// {"heads": [25, 20, 15, 10, 5, -1, -2, 0], "rows": [{"name", "cells": [{"size", "have", "par", "short"}], "short"}],
/// "short_total", "summary", "all"} (charts.par_view's data; mazama_modules/stock/README.md section 4). The core's
/// stock.par_table.
Map<String, Object?> parTable(Map<String, Object?> summary, List<ParLevel> levels, {CoreFunctions? core}) =>
    (core ?? MazamaCore.instance).stockParTable({'summary': summary, 'levels': [for (final l in levels) l.toJson()]});
