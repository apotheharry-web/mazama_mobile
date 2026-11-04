// Bulk sell: the cart sold as the same sale N times, each its own state sale
// record. This file decides which lots every copy draws its units from, before anything is sent, so the N copies
// together never take more from a lot than it holds, and holds every copy to the cap per sale on the lots it draws
// (the shared core's cap, dose.dart's saleLimits, each lot its own figures). A single sale is the same draw
// with one copy. CartPage does the sending.
import 'dose.dart';
import 'mazama_core.dart';
import 'packages_client.dart';

/// The most sales one bulk sell may make.
const maxBulkSales = 50;

/// One cart line as the allocation needs it: the lots behind its package (a snapshot, as on the line) and the units
/// one sale takes.
typedef BulkLine = ({List<Package> lots, int qty});

/// [sales] copies of a sale of [lines]: for each copy, for each line (in order), the (lot, units) it draws - the
/// usual draw order (drawOrder) within a line, each copy taking from what the copies before it left. Lines
/// of the same package share its lots (by lot id). [shortLine] is the index of the first line that couldn't be
/// covered (or whose lots the shared core couldn't order: refused, PkprGroup.drawRefused), and [perSale] is then null;
/// nothing is ever put on a lot beyond what it holds. The draw is the shared core's (selling.allocate_sale): the copies are one sale of every line repeated [sales] times. When the core can't answer, nothing
/// is drawn: the first line is short and [coreFailed] is true, so the words say the core failed ([drawCoreFailedText])
/// rather than that the stock is short (fail closed).
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
/// to: what the stock is checked against before a bulk sale. In the order lots are first drawn.
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

/// Whether a sale drawing from [lots] must read the state again before it is sent: always when any
/// lot's figures are only a phone's upload ([Package.confirmed] false), whatever the age of the stock; else unless the
/// state vouched for the stock recently ([stateVouches]) or every lot was checked recently ([lotVouched]).
bool stockRecheckNeeded(List<Package> lots, {required bool stateVouches, required bool Function(Package lot) lotVouched}) =>
    lots.any((lot) => !lot.confirmed) || !(stateVouches || (lots.isNotEmpty && lots.every(lotVouched)));

/// The core's answer for every copy in [perSale] on the lots it draws (dose.dart's saleLimits, one call; a copy the core
/// can't answer is refused). The cap and the session length don't depend on the dose, so every line is counted
/// as an initial one here.
List<SaleLimits> _copyLimits(List<List<List<(Package, int)>>> perSale, CoreFunctions? core) =>
    saleLimits(drawnSaleLimitLines(perSale, List.filled(perSale.isEmpty ? 0 : perSale.first.length, 'initial')), core: core);

/// The raw mg psilocybin each copy in [perSale] sells, counted by the core on the lots it actually draws (each
/// lot's own weightPerUnit x analyteWeight, the figures its sale records carry to the state, summed exactly): copy 2
/// onwards may draw later lots than the cart's first-lot figure shows. NaN for a copy the core refuses for a figure.
List<double> bulkCopyAnalyteMg(List<List<List<(Package, int)>>> perSale, {CoreFunctions? core}) =>
    [for (final v in _copyLimits(perSale, core)) v.psilocybinMgValue ?? double.nan];

/// Whether copy [k] of [perSale] draws from any lot after its product's first: the lot copy 1's first line of that
/// product starts on (a draw starts with the product's first lot in draw order).
bool _drawsLaterLots(List<List<List<(Package, int)>>> perSale, int k) {
  final first = <String, int>{};
  for (final line in perSale.first) {
    for (final (lot, _) in line) {
      first.putIfAbsent(lot.productGuid, () => lot.id);
    }
  }
  return perSale[k].any((line) => line.any((take) => take.$1.id != first[take.$1.productGuid]));
}

/// [why], the core's refusal of copy [k] of [perSale], as the cart says it: of "This sale" for one copy, "Sale 2 of 3"
/// for a bulk sell's. An over-cap total as "[who] would total ...", or "[who] draws later lots and would total ..."
/// when that copy draws from a lot after its product's first; anything else as "[who] is refused: [why]", or, when
/// [plain], as [why] itself (the core's words already say "This sale ...": the cart's own line beside Sell).
String copyRefusal(List<List<List<(Package, int)>>> perSale, int k, String why, {bool plain = false}) {
  const over = 'This sale would total ';
  final who = perSale.length == 1 ? 'This sale' : 'Sale ${k + 1} of ${perSale.length}';
  if (why.startsWith(over)) {
    return '$who${_drawsLaterLots(perSale, k) ? ' draws later lots and' : ''} would total ${why.substring(over.length)}';
  }
  return plain ? why : '$who is refused: $why';
}

/// Null when every copy in [perSale] is within the cap on the lots it draws (the core's saleLimits), else why
/// the whole bulk sale is refused, naming the first copy refused and, over the cap, its mg (the core's words).
String? bulkCapRefusal(List<List<List<(Package, int)>>> perSale, {CoreFunctions? core}) {
  final verdicts = _copyLimits(perSale, core);
  for (var k = 0; k < verdicts.length; k++) {
    if (!verdicts[k].allowed) return copyRefusal(perSale, k, verdicts[k].error!);
  }
  return null;
}

/// The per-copy cap check of a bulk sell, for a single sale: null when [sale] (one copy's draw, every line of the cart sharing its lots) is within the
/// cap on the lots it draws, else why it is refused, with its mg. A line that runs past its first lot is counted on the
/// lots it spills onto, as its records send them.
String? saleCapRefusal(List<List<(Package, int)>> sale, {CoreFunctions? core}) {
  final v = _copyLimits([sale], core).single;
  return v.allowed ? null : copyRefusal([sale], 0, v.error!);
}

/// One cart line as the cap reads it: the lots behind its package (in draw order, as PkprGroup holds them), the units
/// one sale takes, and its dose ('initial' or 'secondary').
typedef DoseLine = ({List<Package> lots, int qty, String dose});

/// The one place the phone decides a cart's cap and session, the shared core's
/// dose.sale_limits over the lots the sale actually draws: the cart sold [copies] times (one for a single sale) drawn as
/// the sale will be ([allocateBulkSales]: every line of one product sharing its lots, each copy taking what the copies
/// before it left; the records sent are built from this same draw), each drawn lot its own weightPerUnit x
/// analyteWeight, every copy its own verdict ([bulkSaleLimits]: any copy refused refuses them all, naming it). Never the
/// product's first-lot figure alone (PkprGroup's): that stays the line's tpeMg and price, not its cap.
///
/// When the lots can't cover the cart ([shortLine]; the sale is refused by the phone's own stock check before any cap,
/// nothing sent) or the core can't draw it ([coreFailed]: refused, as when the core can't check the cap), [perSale] is null and [limits] is
/// still an answer for the cart to show: each line drawn on its own from its product's first lot, and a line its lots
/// can't cover counted wholly on the product's strongest lot (dose.dart's highestLot, so never counted lower than any lot it could draw),
/// one verdict per copy; a core that
/// can't draw it, [SaleLimits.failed]. Pure but for the core; never awaits anything.
({List<List<List<(Package, int)>>>? perSale, int? shortLine, bool coreFailed, List<SaleLimits> limits}) cartDrawLimits(
    List<DoseLine> lines, int copies,
    {CoreFunctions? core}) {
  final draw = allocateBulkSales([for (final l in lines) (lots: l.lots, qty: l.qty)], copies, core: core);
  final perSale = draw.perSale;
  final List<SaleLimits> limits;
  if (perSale != null) {
    final sales = drawnSaleLimitLines(perSale, [for (final l in lines) l.dose]);
    limits = copies == 1 ? saleLimits(sales, core: core) : bulkSaleLimits(sales, core: core);
  } else if (draw.coreFailed || lines.any((l) => l.lots.isEmpty)) {
    limits = List.filled(copies, SaleLimits.failed); // nothing drawn or nothing to count: refused, never counted as 0
  } else {
    // each line on its own; one its lots can't cover counted wholly on its strongest lot (the core's highestLot)
    final own = <SaleLimitLine>[];
    var failed = false;
    for (final l in lines) {
      var takes = allocateLots(l.lots, l.qty, core: core);
      if (takes == null) {
        final i = highestLot(l.lots, core: core);
        if (i == null) {
          failed = true; // the core can't pick it: refused, never counted on a weaker lot
          break;
        }
        takes = [(l.lots[i], l.qty)];
      }
      own.addAll(takes.map((t) => (record: doseFigures(t.$1), qty: t.$2, dose: l.dose)));
    }
    limits = List.filled(copies, failed ? SaleLimits.failed : saleLimits([own], core: core).single);
  }
  return (perSale: perSale, shortLine: draw.shortLine, coreFailed: draw.coreFailed, limits: limits);
}
