// The par table with Edit / Save (SP-R9, SP-R14, SP-D13..D15), as the order's first step (MI-D21: Order opens it,
// order_par_page.dart; it was on the stock page until SP-D19). The strains' rows in the serving-size columns this
// center uses (the sizes it has stock or a par in, plus the ones added on this phone, less the ones deleted here:
// par_columns.dart's ParColumns), then the combined All strains row, then the edibles' rows below with just
// Booster and Microdose. While editing, a column can be deleted (its pars go with it) or added back, and a strain with
// no stock deleted. Every number comes from stock_summary.dart (the shared rules, held to the server's vectors); this
// file only lays them out and formats texts as the server's templates do (formatG for Python's {x:g}).
//
// Par is always compared with ALL counted stock (SP-D4), whatever maker. The worker either confirms the levels as they
// are ("Continue to order") or edits them and saves ("Save and continue"); either way [ParLevelsEditor.onContinue]
// gets the levels the order is to start from. Read-only (the server unreachable, SP-R13) it can't save, but the
// levels shown can still be confirmed. A save that can't reach Mazama's server is never queued: it says to try again
// later and leaves the edits on screen (sync/server_read.dart).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'server_error.dart';
import 'sync/server_read.dart';
import 'par_columns.dart';
import 'stock_summary.dart';

const _cantSave = '$serverUnreachable, so par levels can\'t be saved now - try again later';
const _saved = 'Par levels saved.';

class ParLevelsEditor extends StatefulWidget {
  const ParLevelsEditor({
    super.key,
    required this.rows,
    required this.levels,
    required this.savePar,
    required this.onContinue,
    this.mgMode = 'tpe',
    this.columns = const ParColumns(),
    this.saveParColumns,
    this.readOnly = false,
  });

  /// The center's packages as stock rows (every package: par counts every maker's counted stock, SP-D4).
  final List<StockRow> rows;

  /// 'tpe' or 'psilocybin' (SP-D6); par counts units, so this only feeds the shared summary.
  final String mgMode;

  /// The center's par levels as loaded.
  final List<ParLevel> levels;

  /// SP-D14: the serving-size columns chosen on this phone (added, deleted).
  final ParColumns columns;

  /// The server can't be reached (SP-R13): the table can't be edited, only confirmed.
  final bool readOnly;

  /// Sends the edited par levels (null par removes one) and returns the levels as stored.
  final Future<List<ParLevel>> Function(List<ParLevel> levels) savePar;

  /// Keeps the columns chosen once a save has gone through; kept for this visit only when null.
  final Future<void> Function(ParColumns columns)? saveParColumns;

  /// The levels confirmed or just saved: the ones the order starts from.
  final void Function(List<ParLevel> levels) onContinue;

  @override
  State<ParLevelsEditor> createState() => _ParLevelsEditorState();
}

class _NewParRow {
  final name = TextEditingController();
  final cells = {for (final d in _strainSizes) d: TextEditingController()};

  void dispose() {
    name.dispose();
    for (final c in cells.values) {
      c.dispose();
    }
  }
}

/// The sizes a strain's par row (and the combined row) takes: 25 .. 5 mg and Other.
final List<int> _strainSizes = stockSizesFor(stockAllStrains);

/// The edibles' two classes, the only cells an edible's par row shows (SP-D15): Booster, Microdose.
final List<int> _edibleSizes = [for (final e in stockEdibleSizes.values) e.$1];

class _ParLevelsEditorState extends State<ParLevelsEditor> {
  late List<ParLevel> _levels = widget.levels;

  bool _editing = false;
  bool _saving = false;
  String? _saveMessage;
  final Map<String, TextEditingController> _parCells = {};
  final List<_NewParRow> _newRows = [];

  /// SP-D14: the columns chosen on this phone (kept), and while editing the ones added or deleted since Edit and the
  /// strains deleted (by name, lower case), all sent or kept only by Save.
  late ParColumns _columns = widget.columns;
  final Set<int> _addingCols = {};
  final Set<int> _removingCols = {};
  final Set<String> _removingRows = {};

  @override
  void initState() {
    super.initState();
    // Nothing to confirm yet: a center with no par levels opens straight in the editor.
    if (_levels.every((l) => l.par == null) && !widget.readOnly) {
      _startEditing(_par(), notify: false);
    }
  }

  @override
  void didUpdateWidget(ParLevelsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing) {
      if (!identical(oldWidget.levels, widget.levels)) _levels = widget.levels;
      if (!identical(oldWidget.columns, widget.columns)) _columns = widget.columns;
    }
  }

  @override
  void dispose() {
    _clearEdits(now: true);
    super.dispose();
  }

  /// Drops the edit controllers. The fields using them leave the tree on the next frame, so they are disposed
  /// after it (disposing a controller a field still listens to fails), unless the editor itself is going away.
  void _clearEdits({bool now = false}) {
    final cells = List.of(_parCells.values);
    final newRows = List.of(_newRows);
    _parCells.clear();
    _newRows.clear();
    _addingCols.clear();
    _removingCols.clear();
    _removingRows.clear();
    void disposeAll() {
      for (final c in cells) {
        c.dispose();
      }
      for (final r in newRows) {
        r.dispose();
      }
    }

    if (now) {
      disposeAll();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => disposeAll());
    }
  }

  /// SP-D4: par against every maker's counted stock.
  Map<String, Object?> _par() =>
      parTable(summarize((filterRows(widget.rows, 'all')['counted'] as List).cast<StockRow>(), widget.mgMode), _levels);

  /// Par fields show only while they can be saved: a server that is unreachable shows the table read-only.
  bool get _canEdit => _editing && !widget.readOnly;

  static String _sizeLabel(int d) => stockSizeWord(d); // 25 mg .. 5 mg, Booster, Microdose (edibles), Other

  String _cellKey(String strain, int size) => '$strain|$size';

  /// A row's cell of [size], or an empty one when the row has none.
  static Map<String, Object?> _cellOf(Map<String, Object?> r, int size) {
    for (final c in (r['cells'] as List).cast<Map<String, Object?>>()) {
      if (c['size'] == size) return c;
    }
    return {'size': size, 'have': 0, 'par': null, 'short': 0};
  }

  static bool _hasAny(Map<String, Object?> r, List<int> sizes) => sizes.any((d) {
        final c = _cellOf(r, d);
        return c['par'] != null || (c['have'] as num) > 0;
      });

  /// The strains' rows (no edible's), less the ones deleted while editing.
  List<Map<String, Object?>> _strainRows(Map<String, Object?> par) => [
        for (final r in (par['rows'] as List).cast<Map<String, Object?>>())
          if (!stockIsProduct(r['name'] as String) && !_removingRows.contains((r['name'] as String).toLowerCase())) r,
      ];

  /// The strains deleted while editing: their pars are all removed by Save.
  List<Map<String, Object?>> _removedRows(Map<String, Object?> par) => [
        for (final r in (par['rows'] as List).cast<Map<String, Object?>>())
          if (_removingRows.contains((r['name'] as String).toLowerCase())) r,
      ];

  Map<String, Object?> _allRow(Map<String, Object?> par) => (par['all'] as Map).cast<String, Object?>();

  /// SP-D15: the edibles' rows, below the strains: the products with stock or a par, and while editing every product,
  /// so any of them can be given one.
  List<Map<String, Object?>> _edibleRows(Map<String, Object?> par) {
    final byName = {
      for (final r in (par['rows'] as List).cast<Map<String, Object?>>())
        if (stockIsProduct(r['name'] as String)) (r['name'] as String).toLowerCase(): r,
    };
    final out = <Map<String, Object?>>[];
    for (final w in stockEdibles.values) {
      final r = byName[w.toLowerCase()];
      if (r != null && (_canEdit || _hasAny(r, _edibleSizes))) {
        out.add(r);
      } else if (r == null && _canEdit) {
        out.add({'name': w, 'cells': const <Map<String, Object?>>[], 'short': 0});
      }
    }
    return out;
  }

  /// SP-D14: the serving-size columns the strains' table shows, in column order: the sizes with stock or a par (any
  /// strain's or the combined row's), plus those added on this phone, less those deleted here; a size with a par always
  /// shows (it counts towards par), unless it is being deleted. With nothing in stock, no par and nothing chosen, all.
  List<int> _visibleColumns(Map<String, Object?> par) {
    final rows = [..._strainRows(par), _allRow(par)];
    bool hasPar(int d) => rows.any((r) => _cellOf(r, d)['par'] != null);
    bool inUse(int d) => hasPar(d) || rows.any((r) => (_cellOf(r, d)['have'] as num) > 0);
    final added = {..._columns.added, ..._addingCols}..removeAll(_removingCols);
    final removed = {..._columns.removed, ..._removingCols}..removeAll(_addingCols);
    final nothingToGoBy = !_strainSizes.any(inUse) && added.isEmpty && removed.isEmpty;
    return [
      for (final d in _strainSizes)
        if ((!removed.contains(d) && (inUse(d) || added.contains(d) || nothingToGoBy)) || (hasPar(d) && !_removingCols.contains(d))) d,
    ];
  }

  void _startEditing(Map<String, Object?> par, {bool notify = true}) {
    _clearEdits(now: !notify);
    for (final r in [...(par['rows'] as List).cast<Map<String, Object?>>(), _allRow(par)]) {
      for (final c in (r['cells'] as List).cast<Map<String, Object?>>()) {
        final p = c['par'];
        _parCells[_cellKey(r['name'] as String, c['size'] as int)] = TextEditingController(text: p == null ? '' : '$p');
      }
    }
    _editing = true;
    _saveMessage = null;
    if (notify) setState(() {});
  }

  void _cancelEditing() {
    _clearEdits();
    setState(() {
      _editing = false;
      _saveMessage = null;
    });
  }

  /// The levels to send: every par entered, null for a par that was cleared, sits in a deleted column or belongs to a
  /// deleted strain (null removes it). An edible's Other par isn't shown here and is left as it is.
  List<ParLevel> _editedLevels(Map<String, Object?> par) {
    final out = <ParLevel>[];
    final visible = _visibleColumns(par);
    void fromFields(Map<String, Object?> r, List<int> sizes) {
      final name = r['name'] as String;
      for (final d in sizes) {
        final stored = _cellOf(r, d)['par'];
        if (_removingCols.contains(d) && !stockIsProduct(name)) {
          if (stored != null) out.add(ParLevel(strain: name, size: d, par: null));
          continue;
        }
        final field = _parCells[_cellKey(name, d)];
        if (field == null) continue; // never shown: left as it is
        final value = int.tryParse(field.text.trim());
        if (value != null || stored != null) out.add(ParLevel(strain: name, size: d, par: value));
      }
    }

    for (final r in [..._strainRows(par), _allRow(par)]) {
      fromFields(r, [..._removingCols, ...visible]);
    }
    for (final r in _edibleRows(par)) {
      fromFields(r, _edibleSizes);
    }
    for (final r in _removedRows(par)) {
      for (final c in (r['cells'] as List).cast<Map<String, Object?>>()) {
        if (c['par'] != null) out.add(ParLevel(strain: r['name'] as String, size: c['size'] as int, par: null));
      }
    }
    for (final n in _newRows) {
      final name = n.name.text.trim();
      if (name.isEmpty) continue;
      for (final d in visible) {
        final value = int.tryParse(n.cells[d]!.text.trim());
        if (value != null) out.add(ParLevel(strain: name, size: d, par: value));
      }
    }
    return out;
  }

  /// Saves the edits, then goes on to the order with the levels as stored. A failed save stays here (SP-R14).
  Future<void> _save(Map<String, Object?> par) async {
    if (widget.readOnly) return;
    // A product or the combined row typed as a new strain would land in the wrong cells: they have rows of their own.
    final misplaced = [
      for (final n in _newRows)
        if (stockIsProduct(n.name.text) || stockIsAll(n.name.text)) n.name.text.trim(),
    ];
    if (misplaced.isNotEmpty) {
      setState(() => _saveMessage = 'Par levels were not saved: ${misplaced.first} has a row of its own '
          '(Chocolate, Gummy and Honey under Edibles; All strains below the strains).');
      return;
    }
    final levels = _editedLevels(par);
    final columns = ParColumns(
      added: {..._columns.added, ..._addingCols}..removeAll(_removingCols),
      removed: {..._columns.removed, ..._removingCols}..removeAll(_addingCols),
    );
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    final List<ParLevel> stored;
    try {
      stored = levels.isEmpty ? _levels : await widget.savePar(levels);
    } catch (e) {
      // SP-R14: the edits stay on screen with the server's message; nothing is lost. The server down: try later.
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveMessage = 'Par levels were not saved: ${isServerUnreachable(e) ? serverTryLater : e}';
      });
      return;
    }
    try {
      await widget.saveParColumns?.call(columns);
    } catch (_) {
      // the columns are this phone's convenience; the levels are saved on the server
    }
    if (!mounted) return;
    _clearEdits();
    setState(() {
      _levels = stored;
      _columns = columns;
      _editing = false;
      _saving = false;
      _saveMessage = _saved;
    });
    widget.onContinue(stored);
  }

  Widget _parInput(Key key, TextEditingController c, String label) => SizedBox(
        width: 64,
        child: Semantics(
          label: label,
          child: TextField(
            key: key,
            controller: c,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
            textAlign: TextAlign.end,
            decoration: const InputDecoration(isDense: true, hintText: '–'),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final par = _par();
    final theme = Theme.of(context);
    final low = TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold);
    const bold = TextStyle(fontWeight: FontWeight.bold);
    final shortTotal = par['short_total'] as num;
    final visible = _visibleColumns(par);
    final hidden = [for (final d in _strainSizes) if (!visible.contains(d)) d];
    final strainRows = _strainRows(par);
    final allRow = _allRow(par);
    final edibles = _edibleRows(par);
    final combinedSet = (allRow['cells'] as List).cast<Map<String, Object?>>().any((c) => c['par'] != null);
    const pad = EdgeInsets.symmetric(horizontal: 8, vertical: 6);

    Widget cell(String name, Map<String, Object?> c) {
      final size = c['size'] as int;
      final have = formatG(c['have'] as num);
      if (_canEdit) {
        return Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.end, children: [
          Text('$have / '),
          _parInput(
            ValueKey('par-$name-$size'),
            _parCells.putIfAbsent(_cellKey(name, size), TextEditingController.new), // a strain or size added mid-edit
            'Par level, $name ${_sizeLabel(size)}',
          ),
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('$have / ${c['par'] ?? '–'}'),
        if ((c['short'] as num) > 0)
          Text('short ${formatG(c['short'] as num)}', style: low)
        else if (c['par'] != null)
          Text('ok', style: theme.textTheme.bodySmall),
      ]);
    }

    TableRow head(String first, List<int> sizes, {bool removable = false}) => TableRow(children: [
          Padding(padding: pad, child: Text(first, style: bold)),
          for (final d in sizes)
            Padding(
              padding: pad,
              child: removable && _canEdit
                  ? Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text(_sizeLabel(d), style: bold),
                      IconButton(
                        key: ValueKey('par-col-remove-$d'),
                        tooltip: 'Delete the ${_sizeLabel(d)} column',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: const Icon(Icons.close),
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                  _removingCols.add(d);
                                  _addingCols.remove(d);
                                }),
                      ),
                    ])
                  : Text(_sizeLabel(d), textAlign: TextAlign.end, style: bold),
            ),
          _canEdit ? const SizedBox.shrink() : const Padding(padding: pad, child: Text('Below par', textAlign: TextAlign.end, style: bold)),
        ]);

    TableRow row(Map<String, Object?> r, List<int> sizes, {Widget? label, bool removable = false}) {
      final name = r['name'] as String;
      final short = r['short'] as num;
      return TableRow(children: [
        Padding(key: ValueKey('par-row-$name'), padding: pad, child: label ?? Text(name)),
        for (final d in sizes) Padding(padding: pad, child: Align(alignment: Alignment.centerRight, child: cell(name, _cellOf(r, d)))),
        if (!_canEdit)
          Padding(padding: pad, child: Text(short > 0 ? formatG(short) : '0', textAlign: TextAlign.end, style: short > 0 ? low : null))
        else if (removable)
          IconButton(
            key: ValueKey('par-row-remove-$name'),
            tooltip: 'Delete $name',
            icon: const Icon(Icons.delete_outline),
            onPressed: _saving ? null : () => setState(() => _removingRows.add(name.toLowerCase())),
          )
        else
          const SizedBox.shrink(),
      ]);
    }

    TableRow newRow(int i, _NewParRow n) => TableRow(children: [
          Padding(
            padding: pad,
            child: SizedBox(
              width: 140,
              child: TextField(
                key: ValueKey('par-new-name-$i'),
                controller: n.name,
                maxLength: 30,
                decoration: const InputDecoration(isDense: true, hintText: 'Strain', counterText: ''),
              ),
            ),
          ),
          for (final d in visible)
            Padding(
              padding: pad,
              child: Align(
                alignment: Alignment.centerRight,
                child: _parInput(ValueKey('par-new-$i-$d'), n.cells[d]!, 'Par level, new strain, ${_sizeLabel(d)}'),
              ),
            ),
          IconButton(
            key: ValueKey('par-new-remove-$i'),
            tooltip: 'Remove this new strain',
            icon: const Icon(Icons.delete_outline),
            onPressed: _saving
                ? null
                : () => setState(() {
                      final gone = _newRows.removeAt(i);
                      WidgetsBinding.instance.addPostFrameCallback((_) => gone.dispose());
                    }),
          ),
        ]);

    // A strain with nothing in stock (one added in the par editor, or whose stock has gone) can be deleted.
    bool noStock(Map<String, Object?> r) => (r['cells'] as List).cast<Map<String, Object?>>().every((c) => (c['have'] as num) == 0);

    Widget table(List<TableRow> rows) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: rows,
          ),
        );

    final continueButton = FilledButton.icon(
      key: const ValueKey('par-continue'),
      onPressed: _saving ? null : () => widget.onContinue(_levels),
      icon: const Icon(Icons.arrow_forward),
      label: const Text('Continue to order'),
    );

    return Card(
      key: const ValueKey('par-levels'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Par levels', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(par['summary'] as String, style: shortTotal != 0 ? low : null),
            const SizedBox(height: 8),
            table([
              head('Strain', visible, removable: true),
              for (final r in strainRows) row(r, visible, removable: noStock(r)),
              if (_canEdit)
                for (var i = 0; i < _newRows.length; i++) newRow(i, _newRows[i]),
              row(
                allRow,
                visible,
                label: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  const Text(stockAllStrains, style: bold),
                  Text('combined', style: theme.textTheme.bodySmall),
                ]),
              ),
            ]),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_canEdit ? 'No serving sizes shown: add one with Add a size.' : 'No serving sizes shown.',
                    style: theme.textTheme.bodySmall),
              ),
            if (combinedSet || _canEdit)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    'All strains is every strain together, for a par that doesn\'t care which strain. What the strains\' '
                    'own pars already ask for isn\'t counted again.',
                    style: theme.textTheme.bodySmall),
              ),
            if (edibles.isNotEmpty) ...[
              const SizedBox(height: 12),
              table([
                head('Edible', _edibleSizes),
                for (final r in edibles) row(r, _edibleSizes),
              ]),
            ],
            const SizedBox(height: 8),
            if (widget.readOnly) ...[
              Text('$_cantSave. The order starts from the par levels above.', style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: continueButton),
            ] else if (_editing)
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: _saving ? null : () => setState(() => _newRows.add(_NewParRow())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a strain'),
                ),
                if (hidden.isNotEmpty)
                  PopupMenuButton<int>(
                    key: const ValueKey('par-col-add'),
                    enabled: !_saving,
                    tooltip: 'Add a serving size column',
                    onSelected: (d) => setState(() {
                      _addingCols.add(d);
                      _removingCols.remove(d);
                    }),
                    itemBuilder: (_) => [
                      for (final d in hidden) PopupMenuItem(key: ValueKey('par-col-add-$d'), value: d, child: Text(_sizeLabel(d))),
                    ],
                    child: IgnorePointer(
                      child: OutlinedButton.icon(
                        onPressed: _saving ? null : () {},
                        icon: const Icon(Icons.view_column_outlined),
                        label: const Text('Add a size'),
                      ),
                    ),
                  ),
                FilledButton(
                  key: const ValueKey('par-save'),
                  onPressed: _saving ? null : () => _save(par),
                  child: const Text('Save and continue'),
                ),
                TextButton(onPressed: _saving ? null : _cancelEditing, child: const Text('Cancel')),
              ])
            else
              Wrap(spacing: 8, runSpacing: 8, children: [
                continueButton,
                OutlinedButton.icon(
                  onPressed: () => _startEditing(par),
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit par levels'),
                ),
              ]),
            if (_canEdit)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    'Each cell: units on hand / desired par. Leave a par blank for none. × deletes a size column and its '
                    'pars; a strain with no stock can be deleted too.',
                    style: theme.textTheme.bodySmall),
              ),
            if (_saveMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _saveMessage!,
                  style: _saveMessage == _saved ? null : TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
