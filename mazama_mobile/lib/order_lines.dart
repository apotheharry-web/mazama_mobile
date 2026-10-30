// The lines the order form starts from (specs/mazama-inventory MI-D7, MI-D16, MI-D17; specs/edibles ED-A6): which of
// the center's par levels become lines, and in what order. The rule is the shared core's (stock.order_form, specs/core
// row 9), held to assets/shared/stock/order_form/cases.json; order_form_page.dart only draws them. The server checks
// the order the phone sends with the same core (stock.order_check).
import 'mazama_core.dart';
import 'stock_summary.dart';

/// One line of the form: [strain] (or "All strains", or an edible product's word) at [size], starting at [par] units.
class OrderFormLine {
  final String strain;
  final int size;
  final int par;
  const OrderFormLine(this.strain, this.size, this.par);
}

/// The form's lines from the center's par [levels]: strains by name ignoring case then size, the combined All strains
/// lines, then each edible product with a level, Booster and Microdose. [core] defaults to this app's.
List<OrderFormLine> orderFormLines(List<ParLevel> levels, {CoreFunctions? core}) {
  final reply = (core ?? MazamaCore.instance).stockOrderForm({
    'levels': [for (final l in levels) l.toJson()],
  });
  final out = <OrderFormLine>[];
  for (final l in reply) {
    final strain = l is Map ? l['strain'] : null, size = l is Map ? l['size'] : null, par = l is Map ? l['par'] : null;
    if (strain is! String || size is! int || par is! int) {
      throw MazamaCoreError('stock.order_form gave an unexpected line: $l');
    }
    out.add(OrderFormLine(strain, size, par));
  }
  return out;
}
