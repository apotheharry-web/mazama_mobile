// specs/mazama-inventory MI-R7: the collapsible lot table at the bottom of the Mazama inventory page. One row per batch
// or lot in Mazama's stock, grouped under its strain (MI-D12), with its potency in mg per gram (MI-D11) and a coloured
// tag for each minor analyte its lab report found (MI-D13). Tapping the column's heading, or any number in it, switches
// every row between mg TPE / g, mg psilocybin / g and mg psilocin / g (MI-D14). Closed when the page opens. A lot id
// with a public product information sheet is a link to it (MI-D18): [MazamaLotTable.onOpen] opens it. A pick on a pie
// above narrows it to a strain or a type ([LotFilter], MI-D20). The stock page shows the same table for the center's
// lots, in place of its product information sheets (specs/stock-page SP-D18).
import 'package:flutter/material.dart';

import 'mazama_inventory_client.dart';
import 'stock_mix.dart';

/// What the number column shows, in the order a tap steps through them.
enum LotMeasure {
  tpe('TPE mg/g'),
  psilocybin('Psilocybin mg/g'),
  psilocin('Psilocin mg/g');

  const LotMeasure(this.label);
  final String label;

  LotMeasure get next => LotMeasure.values[(index + 1) % LotMeasure.values.length];

  num? of(MazamaLot l) => switch (this) {
        LotMeasure.tpe => l.tpe,
        LotMeasure.psilocybin => l.psilocybin,
        LotMeasure.psilocin => l.psilocin,
      };
}

/// "8.64", or "—" when the lab result isn't known (never 0: unknown is not none, AD-3).
String formatLotValue(num? v) => v == null ? '—' : v.toStringAsFixed(2);

/// A minor analyte's tag: its word, and its colours (background, text) in light and dark, as 0xFFRRGGBB.
typedef AnalyteTag = ({String word, int lightBg, int lightFg, int darkBg, int darkFg});

/// Each minor analyte's tag, by its name, in the order of the shared rules (rules.yaml `analyte_tags`, which the
/// server's pages use too, specs/web-charts WC-R7). The app doesn't bundle assets/shared/, so these stay in code:
/// test/mazama_lot_table_test.dart holds them equal to the vendored assets/shared/stock/rules/rules.yaml.
const Map<String, AnalyteTag> analyteTags = {
  'baeocystin': (word: 'Baeocystin', lightBg: 0xFFD7F2EE, lightFg: 0xFF0B5D52, darkBg: 0xFF16433D, darkFg: 0xFFA6E8DD),
  'norbaeocystin': (word: 'Norbaeocystin', lightBg: 0xFFE0E3FA, lightFg: 0xFF2E3A8C, darkBg: 0xFF262C5C, darkFg: 0xFFC2C9F5),
  'norpsilocin': (word: 'Norpsilocin', lightBg: 0xFFFCEBCF, lightFg: 0xFF7A4A00, darkBg: 0xFF4A3510, darkFg: 0xFFF5D39A),
  'aeruginascin': (word: 'Aeruginascin', lightBg: 0xFFFADDE6, lightFg: 0xFF8A1F45, darkBg: 0xFF4F1F2F, darkFg: 0xFFF4B8CB),
};

/// The word on an analyte's tag; a name this app doesn't know yet shows as itself, capitalised.
String analyteWord(String name) =>
    analyteTags[name]?.word ?? (name.isEmpty ? name : name[0].toUpperCase() + name.substring(1));

/// What a pick on a pie narrows the table to (MI-D20, SP-D18): its words for the title, and which rows it keeps.
typedef LotFilter = ({String label, bool Function(MazamaLot lot) keep});

/// A pick on a strain pie: the rows of that strain, ignoring case; "Unknown" keeps the rows whose strain isn't known.
LotFilter lotStrainFilter(String strain) {
  final want = strain.toLowerCase();
  return (label: strain, keep: (l) => (l.strain.isEmpty ? 'Unknown' : l.strain).toLowerCase() == want);
}

/// A pick on a By type pie (its slice names are [mixTypeWords]'): the lots with that type among theirs.
LotFilter lotTypeFilter(String typeWord) =>
    (label: typeWord, keep: (l) => l.types.any((c) => (mixTypeWords[c] ?? c) == typeWord));

class MazamaLotTable extends StatefulWidget {
  const MazamaLotTable({super.key, required this.lots, this.onOpen, this.filter, this.note, this.noteIsError = false});

  /// The rows, sorted by strain then lot id. A lot made into two strains may be a row under each.
  final List<MazamaLot> lots;

  /// Opens a lot's product information sheet (MI-D18); lot ids are plain text when null or the lot has no sheet.
  final void Function(MazamaLot lot)? onOpen;

  /// The pick on a pie the rows are narrowed to (MI-D20, SP-D18); all rows when null. It applies while the table is
  /// closed too: its title says so.
  final LotFilter? filter;

  /// Said under the title instead of the counts: "Loading…", or why the rows did not load ([noteIsError]).
  final String? note;
  final bool noteIsError;

  @override
  State<MazamaLotTable> createState() => _MazamaLotTableState();
}

/// "1 lot", "3 lots"; lots are counted once however many strains they are under.
String _lots(int n) => '$n ${n == 1 ? 'lot' : 'lots'}';

class _MazamaLotTableState extends State<MazamaLotTable> {
  LotMeasure _measure = LotMeasure.tpe;

  void _switch() => setState(() => _measure = _measure.next);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filter = widget.filter;
    final shown = filter == null ? widget.lots : [for (final l in widget.lots) if (filter.keep(l)) l];
    final all = {for (final l in widget.lots) l.lot.toLowerCase()}.length;
    final count = {for (final l in shown) l.lot.toLowerCase()}.length;
    // One heading per strain whatever its case ("golden teacher" goes under "Golden Teacher"), spelled as first seen.
    final groups = <String, List<MazamaLot>>{};
    final spelled = <String, String>{};
    for (final l in shown) {
      final name = l.strain.isEmpty ? 'Unknown' : l.strain;
      groups.putIfAbsent(spelled.putIfAbsent(name.toLowerCase(), () => name), () => []).add(l);
    }
    final note = widget.note;
    final String subtitle;
    if (note != null) {
      subtitle = note;
    } else if (filter != null) {
      subtitle = '$count of ${_lots(all)}';
    } else {
      subtitle = '${_lots(all)} · ${groups.length} ${groups.length == 1 ? 'strain' : 'strains'}';
    }
    return Card(
      key: const ValueKey('lot-table'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey('lot-table-tile'),
        title: Text(filter == null ? 'Strains in stock' : 'Strains in stock: ${filter.label}'),
        subtitle: Text(subtitle,
            key: const ValueKey('lot-table-subtitle'),
            style: note != null && widget.noteIsError ? TextStyle(color: theme.colorScheme.error) : null),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                  note != null
                      ? note
                      : filter != null
                          ? 'Nothing in stock for ${filter.label}.'
                          : 'No lots in stock.',
                  key: const ValueKey('lot-table-empty')),
            )
          else ...[
            Row(
              children: [
                Expanded(child: Text('Strain / lot', style: theme.textTheme.labelMedium)),
                InkWell(
                  key: const ValueKey('lot-measure'),
                  onTap: _switch,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_measure.label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
                        const SizedBox(width: 2),
                        Icon(Icons.swap_vert, size: 16, color: theme.colorScheme.primary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            for (final g in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 2),
                child: Text(g.key, key: ValueKey('lot-strain-${g.key}'), style: theme.textTheme.titleSmall),
              ),
              for (final l in g.value) _row(context, l, g.key),
            ],
            const SizedBox(height: 6),
            Text(
                'Tap ${_measure.label} to switch between TPE, psilocybin and psilocin. Tags: other analytes the lab found. '
                'Tap a lot id for its product information sheet.',
                style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  /// One lot under [group]: its key names both, since a lot made into two strains is a row under each.
  Widget _row(BuildContext context, MazamaLot l, String group) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('lot-row-$group|${l.lot}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _lotId(context, l),
                if (l.detected.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, runSpacing: 4, children: [for (final a in l.detected) _tag(context, a)]),
                ],
              ],
            ),
          ),
          InkWell(
            key: ValueKey('lot-value-${l.lot}'),
            onTap: _switch,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(formatLotValue(_measure.of(l)), style: theme.textTheme.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }

  /// The lot id: a link to its sheet when it has one (underlined, in the theme's link colour), else plain text.
  Widget _lotId(BuildContext context, MazamaLot l) {
    final theme = Theme.of(context);
    final open = widget.onOpen;
    if (open == null || l.path == null) return Text(l.lot, style: theme.textTheme.bodyMedium);
    return InkWell(
      key: ValueKey('lot-link-${l.lot}'),
      onTap: () => open(l),
      borderRadius: BorderRadius.circular(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.lot,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: theme.colorScheme.primary)),
          const SizedBox(width: 4),
          Icon(Icons.open_in_new, size: 14, color: theme.colorScheme.primary),
        ],
      ),
    );
  }

  Widget _tag(BuildContext context, String analyte) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final t = analyteTags[analyte];
    final scheme = Theme.of(context).colorScheme;
    final bg = t == null ? scheme.surfaceContainerHighest : Color(dark ? t.darkBg : t.lightBg);
    final fg = t == null ? scheme.onSurfaceVariant : Color(dark ? t.darkFg : t.lightFg);
    return Container(
      key: ValueKey('lot-tag-$analyte'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(analyteWord(analyte), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
    );
  }
}
