// A manufacturer's stock mix of mg TPE by strain and by product type, the numbers of
// the server's "By strain" / "By type" pies (stockview.mix, charts.mix_view). The mix, and the word a kind code's pies
// show, are the shared core's
// (mazama_core::stock; ../mazama_modules/stock/README.md § 5), held to its golden vectors
// (assets/shared/stock/vectors/mix.json, test/stock_mix_test.dart), texts included. Drawing is the page's own (mazama_inventory_page.dart). A center's By type
// pie (stockByType) is § 6 on top of it, held to vectors/by_type.json (test/stock_by_type_test.dart).
import 'mazama_core.dart';
import 'stock_summary.dart';

/// The word each kind code's pies show (rules.yaml `mix_type_words`; a code not listed shows as itself), in order: the
/// core's stock.type_words, one call for the list.
List<String> stockTypeWords(List<String> codes, {CoreFunctions? core}) {
  if (codes.isEmpty) return const [];
  final got = (core ?? MazamaCore.instance).stockTypeWords({'codes': codes});
  return [for (final w in got['words'] as List) w as String];
}

/// One row of the mix: a strain, a kind code and its mg TPE (GET /p/mazama-inventory sends them summed per strain and type).
class MixCell {
  final String? strain;
  final String? type;
  final num? mg;

  const MixCell({this.strain, this.type, this.mg});

  factory MixCell.fromJson(Map<String, Object?> j) =>
      MixCell(strain: j['strain'] as String?, type: j['type'] as String?, mg: j['mg'] as num?);

  Map<String, Object?> toJson() => {'strain': strain, 'type': type, 'mg': mg};
}

/// The stock mix of [rows] (README § 5): {"total": 0} when nothing has mg; else {"total", "by_strain", "by_type",
/// "strain_cards", "type_cards", "types", "table", "type_totals"}, a pie being {"total", "slices": [{"name", "value",
/// "slot", "pct"}]} and a card {"name", "slot", "total", "pie"}.
/// The core's stock.mix; [core] defaults to this app's ([MazamaCore.instance]).
Map<String, Object?> stockMix(List<MixCell> rows, {CoreFunctions? core}) =>
    (core ?? MazamaCore.instance).stockMix({'rows': [for (final c in rows) c.toJson()]});

/// A center's By type pie (README § 6): the By type pie of [stockMix] over the rows on hand, each weighing quantity x
/// mg per unit in [mgMode] when the rows have an mg figure, else its quantity (units); null when nothing is left to
/// weigh. The core's stock.by_type, held to assets/shared/stock/vectors/by_type.json (test/stock_by_type_test.dart).
Map<String, Object?>? stockByType(List<StockRow> rows, String mgMode, {CoreFunctions? core}) {
  if (!stockMgModes.contains(mgMode)) throw ArgumentError.value(mgMode, 'mgMode', 'must be one of $stockMgModes');
  final pie = (core ?? MazamaCore.instance).stockByType({'rows': [for (final r in rows) r.toJson()], 'mg_mode': mgMode})['pie'];
  return pie == null ? null : Map<String, Object?>.from(pie as Map);
}

/// The word of every type [stockByType] weighs above 0, "Other (n)"'s included: the types a pick can name.
/// The core's stock.classify.
Set<String> stockByTypeWords(List<StockRow> rows, String mgMode, {CoreFunctions? core}) =>
    stockClassify(rows, mgMode, core: core).typeWords.toSet();

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
