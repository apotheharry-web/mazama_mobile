// Bulk sell (specs/multi-cart MC-D8 to MC-D10): the cart sold as the same sale N times, each its own state sale
// record. This file decides which lots every copy draws its units from, before anything is sent, so the N copies
// together never take more from a lot than it holds, and holds every copy to the cap per sale on the lots it draws
// (DOSE-17: the shared core's cap, dose.dart's saleLimits, each lot its own figures). A single sale is the same draw
// with one copy (SALE-4). CartPage does the sending.
import 'dose.dart';
import 'mazama_core.dart';
import 'packages_client.dart';

/// MC-D9: the most sales one bulk sell may make.
const maxBulkSales = 50;

/// One cart line as the allocation needs it: the lots behind its package (a snapshot, as on the line) and the units
/// one sale takes.
typedef BulkLine = ({List<Package> lots, int qty});

/// [sales] copies of a sale of [lines]: for each copy, for each line (in order), the (lot, units) it draws - the
/// usual draw order (drawOrder, SM-D29) within a line, each copy taking from what the copies before it left. Lines
/// of the same package share its lots (by lot id). [shortLine] is the index of the first line that couldn't be
/// covered (or whose lots the shared core couldn't order: refused, PkprGroup.drawRefused), and [perSale] is then null;
/// nothing is ever put on a lot beyond what it holds. The draw is the shared core's (selling.allocate_sale, specs/core
/// row 7, SALE-4): the copies are one sale of every line repeated [sales] times. When the core can't answer, nothing
/// is drawn: the first line is short and [coreFailed] is true, so the words say the core failed ([drawCoreFailedText])
/// rather than that the stock is short (fail closed, SALE-14; review M6).
({List<List<List<(Package, int)>>>? perSale, int? shortLine, bool coreFailed}) allocateBulkSales(List<BulkLine> lines, int sales,
    {CoreFunctions? core}) {
  if (sales < 1) throw ArgumentError.value(sales, 'sales', 'at least 1');
  if (lines.isEmpty) return (perSale: [for (var s = 0; s < sales; s++) <List<(Package, int)>>[]], shortLine: null, coreFailed: false);
  String day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  try {
    final reply = (core ?? MazamaCore.instance).sellingAllocateSale({
      'lines': [
        for (var s = 0; s < sales; s++)
          for (var i = 0; i < lines.length; i++) {'product': 'line $i', 'qty': lines[i].qty, 'dose': 'initial'},
      ],
      'lots': {
        for (var i = 0; i < lines.length; i++)
          'line $i': [
            for (final l in lines[i].lots)
              {'id': l.id, 'quantity': l.quantity, 'expires': l.expires == null ? null : day(l.expires!), 'state_only': l.stateOnly},
          ],
      },
    });
    final short = reply['short'], draws = reply['draws'];
    if (short is int && draws == null && short >= 0 && short < sales * lines.length) {
      return (perSale: null, shortLine: short % lines.length, coreFailed: false);
    }
    if (short != null || draws is! List) return (perSale: null, shortLine: 0, coreFailed: true);
    final perSale = [
      for (var s = 0; s < sales; s++) [for (var i = 0; i < lines.length; i++) <(Package, int)>[]],
    ];
    final drawn = <int, int>{}; // lot id -> units the reply takes from it, never more than it holds
    final want = List<int>.filled(sales * lines.length, 0);
    for (final d in draws) {
      if (d is! List || d.length != 3 || d[0] is! int || d[1] is! int || d[2] is! int) return (perSale: null, shortLine: 0, coreFailed: true);
      final (k, id, units) = (d[0] as int, d[1] as int, d[2] as int);
      if (k < 0 || k >= want.length || units <= 0) return (perSale: null, shortLine: 0, coreFailed: true);
      final i = k % lines.length;
      final lot = lines[i].lots.where((l) => l.id == id).firstOrNull;
      if (lot == null) return (perSale: null, shortLine: i, coreFailed: true);
      drawn[id] = (drawn[id] ?? 0) + units;
      if (drawn[id]! > lot.quantity) return (perSale: null, shortLine: i, coreFailed: true);
      perSale[k ~/ lines.length][i].add((lot, units));
      want[k] += units;
    }
    for (var k = 0; k < want.length; k++) {
      final need = lines[k % lines.length].qty;
      if (want[k] != (need < 0 ? 0 : need)) return (perSale: null, shortLine: k % lines.length, coreFailed: true);
    }
    return (perSale: perSale, shortLine: null, coreFailed: false);
  } catch (_) {
    return (perSale: null, shortLine: 0, coreFailed: true); // StateError (no core), MazamaCoreError, anything else: nothing is drawn
  }
}

/// Why a cart isn't drawn from its stock when the shared core couldn't draw it ([allocateBulkSales]' coreFailed).
const drawCoreFailedText = "This phone can't draw this cart from its stock (its shared core failed), so it can't be sold here.";

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

/// SM-25, DOSE-8 (I10): whether a sale drawing from [lots] must read the state again before it is sent: always when any
/// lot's figures are only a phone's upload ([Package.confirmed] false), whatever the age of the stock; else unless the
/// state vouched for the stock recently ([stateVouches]) or every lot was checked recently ([lotVouched]).
bool stockRecheckNeeded(List<Package> lots, {required bool stateVouches, required bool Function(Package lot) lotVouched}) =>
    lots.any((lot) => !lot.confirmed) || !(stateVouches || (lots.isNotEmpty && lots.every(lotVouched)));

/// The core's answer for every copy in [perSale] on the lots it draws (dose.dart's saleLimits, one call; a copy the core
/// can't answer is refused, DOSE-7). The cap and the session length don't depend on the dose, so every line is counted
/// as an initial one here.
List<SaleLimits> _copyLimits(List<List<List<(Package, int)>>> perSale, CoreFunctions? core) =>
    saleLimits(drawnSaleLimitLines(perSale, List.filled(perSale.isEmpty ? 0 : perSale.first.length, 'initial')), core: core);

/// DOSE-17: the raw mg psilocybin each copy in [perSale] sells, counted by the core on the lots it actually draws (each
/// lot's own weightPerUnit x analyteWeight, the figures its sale records carry to the state, summed exactly): copy 2
/// onwards may draw later lots than the cart's first-lot figure shows. NaN for a copy the core refuses for a figure.
List<double> bulkCopyAnalyteMg(List<List<List<(Package, int)>>> perSale, {CoreFunctions? core}) =>
    [for (final v in _copyLimits(perSale, core)) v.psilocybinMgValue ?? double.nan];

/// [why], the core's refusal of one sale, said of [who] ("Sale 2 of 3", "This sale"): an over-cap total as "[who] draws
/// later lots and would total ...", anything else as "[who] is refused: [why]".
String _refusal(String who, String why) {
  const over = 'This sale would total ';
  return why.startsWith(over) ? '$who draws later lots and would total ${why.substring(over.length)}' : '$who is refused: $why';
}

/// DOSE-17: null when every copy in [perSale] is within the cap on the lots it draws (the core's saleLimits), else why
/// the whole bulk sale is refused, naming the first copy refused and, over the cap, its mg (the core's words).
String? bulkCapRefusal(List<List<List<(Package, int)>>> perSale, {CoreFunctions? core}) {
  final verdicts = _copyLimits(perSale, core);
  for (var k = 0; k < verdicts.length; k++) {
    if (!verdicts[k].allowed) return _refusal('Sale ${k + 1} of ${verdicts.length}', verdicts[k].error!);
  }
  return null;
}

/// DOSE-17 for a single sale: null when [sale] (one copy's draw, every line of the cart sharing its lots) is within the
/// cap on the lots it draws, else why it is refused, with its mg. A line that runs past its first lot is counted on the
/// lots it spills onto, as its records send them.
String? saleCapRefusal(List<List<(Package, int)>> sale, {CoreFunctions? core}) {
  final v = _copyLimits([sale], core).single;
  return v.allowed ? null : _refusal('This sale', v.error!);
}
