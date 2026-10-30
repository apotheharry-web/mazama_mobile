// The phone's order form lines as order_form_page.dart built them before specs/core row 9 (Task 15), copied verbatim
// from the page's load block (its widgets left out): the frozen oracle that test/order_lines_test.dart holds the
// shared core's stock.order_form to, over the shared cases and a generated grid. Never edit it to make a test pass.
import 'package:mazama_mobile/stock_summary.dart';

final List<int> _edibleSizes = [for (final e in stockEdibleSizes.values) e.$1];

/// (strain, size, par) per line, in the form's order.
List<(String, int, int)> oldOrderFormLines(List<ParLevel> levels) {
  final byKey = <String, ParLevel>{};
  for (final l in levels) {
    // a size the row doesn't take (a product's serving size, a strain's Booster) can't be ordered: ED-A6; nor is
    // an edible's Other, which the par table no longer shows (MI-D17)
    if (l.par == null || !stockSizesFor(l.strain).contains(l.size)) continue;
    if (stockIsProduct(l.strain) && l.size == 0) continue;
    final name = stockIsAll(l.strain) ? stockAllStrains : l.strain;
    byKey['${name.toLowerCase()}|${l.size}'] = l;
  }
  int bySize(ParLevel a, ParLevel b) => stockParColumns.indexOf(a.size).compareTo(stockParColumns.indexOf(b.size));
  final strains = [
    for (final l in byKey.values)
      if (!stockIsProduct(l.strain) && !stockIsAll(l.strain)) l,
  ]..sort((a, b) {
      final c = a.strain.toLowerCase().compareTo(b.strain.toLowerCase());
      return c != 0 ? c : bySize(a, b);
    });
  final combined = [for (final l in byKey.values) if (stockIsAll(l.strain)) l]..sort(bySize);
  final products = {for (final l in byKey.values) if (stockIsProduct(l.strain)) stockProductWord(l.strain)};
  return [
    for (final l in strains) (l.strain, l.size, l.par!),
    for (final l in combined) (stockAllStrains, l.size, l.par!),
    for (final w in stockEdibles.values)
      if (products.contains(w))
        for (final d in _edibleSizes) (w, d, byKey['${w.toLowerCase()}|$d']?.par ?? 0),
  ];
}
