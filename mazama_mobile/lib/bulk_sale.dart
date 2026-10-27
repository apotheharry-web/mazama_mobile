// Bulk sell (specs/multi-cart MC-D8 to MC-D10): the cart sold as the same sale N times, each its own state sale
// record. This file decides which lots every copy draws its units from, before anything is sent, so the N copies
// together never take more from a lot than it holds. CartPage does the sending.
import 'packages_client.dart';

/// MC-D9: the most sales one bulk sell may make.
const maxBulkSales = 50;

/// One cart line as the allocation needs it: the lots behind its package (a snapshot, as on the line) and the units
/// one sale takes.
typedef BulkLine = ({List<Package> lots, int qty});

/// [sales] copies of a sale of [lines]: for each copy, for each line (in order), the (lot, units) it draws - the
/// usual draw order (drawOrder, SM-D29) within a line, each copy taking from what the copies before it left. Lines
/// of the same package share its lots (by lot id). [shortLine] is the index of the first line that couldn't be
/// covered, and [perSale] is then null; nothing is ever put on a lot beyond what it holds.
({List<List<List<(Package, int)>>>? perSale, int? shortLine}) allocateBulkSales(List<BulkLine> lines, int sales) {
  if (sales < 1) throw ArgumentError.value(sales, 'sales', 'at least 1');
  final left = <int, int>{}; // lot id -> units not yet drawn
  final ordered = [for (final l in lines) drawOrder(l.lots)];
  for (final lots in ordered) {
    for (final lot in lots) {
      left.putIfAbsent(lot.id, () => lot.quantity);
    }
  }
  final perSale = <List<List<(Package, int)>>>[];
  for (var s = 0; s < sales; s++) {
    final sale = <List<(Package, int)>>[];
    for (var i = 0; i < lines.length; i++) {
      final takes = <(Package, int)>[];
      var need = lines[i].qty;
      for (final lot in ordered[i]) {
        if (need <= 0) break;
        final have = left[lot.id]!;
        final take = need < have ? need : have;
        if (take > 0) {
          takes.add((lot, take));
          left[lot.id] = have - take;
          need -= take;
        }
      }
      if (need > 0) return (perSale: null, shortLine: i);
      sale.add(takes);
    }
    perSale.add(sale);
  }
  return (perSale: perSale, shortLine: null);
}

/// Every lot [perSale] draws from, with the units all the copies take from it together and the package it belongs
/// to: what the stock is checked against before a bulk sale (MC-D11). In the order lots are first drawn.
List<({Package lot, int units})> bulkDrawPerLot(List<List<List<(Package, int)>>> perSale) {
  final byId = <int, ({Package lot, int units})>{};
  for (final sale in perSale) {
    for (final line in sale) {
      for (final (lot, take) in line) {
        final had = byId[lot.id];
        byId[lot.id] = (lot: had?.lot ?? lot, units: (had?.units ?? 0) + take);
      }
    }
  }
  return byId.values.toList();
}
