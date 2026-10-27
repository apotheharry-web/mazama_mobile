// Lets a worker compare what the state system's own records say this center has (the exact same
// /p/packages/{state_id} data StockPage already shows) against what they actually count in the safe, and see
// exactly how many units of each PKPR are missing or in excess. This never writes anything back to the state
// system or to Mazama's own server - a worker's physical count is theirs to act on; this page's only job is
// doing the subtraction and showing the result clearly, same as a plain paper tally sheet would, just with the
// state's own figures already filled in.
//
// Counting and the report are two views of the same page (_showingReport), not two separate pushed routes -
// backing out of the report to fix a typo'd count doesn't lose anything already typed, since every box's
// TextEditingController lives on this page's own state the whole time, not just while that view is showing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'enrichment_store.dart';
import 'licenses_client.dart';
import 'packages_client.dart';
import 'packages_client.dart' as packages_client; // see ReconcilePage.fetchPackages: avoids a same-name default-value ambiguity
import 'product_type_icon.dart';
import 'responsive.dart';

class ReconcilePage extends StatefulWidget {
  final License center;

  /// Overridable for tests, so a widget test never makes a real network call - same reasoning and the same
  /// real default as StockPage.fetchPackages.
  final Future<List<Package>> Function(int stateId) fetchPackages;

  /// The signed-in worker's own email, printed on the generated report (see _reportView) so whoever reads it
  /// later - the worker themselves, or whoever they share it with - knows who counted it and when. Defaults
  /// to '' (shown as nothing) rather than required, so a widget test can construct this page without a real
  /// session in hand.
  final String workerEmail;

  const ReconcilePage({
    super.key,
    required this.center,
    this.fetchPackages = packages_client.fetchPackages,
    this.workerEmail = '',
  });

  @override
  State<ReconcilePage> createState() => _ReconcilePageState();
}

class _ReconcilePageState extends State<ReconcilePage> {
  List<Package>? _inventory;
  String? _error;
  bool _showingReport = false;
  bool _saving = false;

  /// One controller per PKPR (keyed by productGuid), created lazily the first time its row is built and kept
  /// for the life of this page - see _controllerFor. An empty box means "not counted yet", never "counted
  /// zero" (see _buildReport), so nothing here pre-fills a 0 or the state's own figure.
  final Map<String, TextEditingController> _controllers = {};

  /// Wraps the report's own content (not the Back/Save buttons below it) so _onSaveReportPressed can render
  /// exactly that subtree to an image - see that method's own comment for why a plain RepaintBoundary on a
  /// Column, rather than a ListView, is what makes capturing the WHOLE report (not just whatever's currently
  /// scrolled into view) possible at all.
  final GlobalKey _reportBoundaryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _load() {
    setState(() {
      _inventory = null;
      _error = null;
      _showingReport = false;
    });
    widget.fetchPackages(widget.center.id).then((pkgs) {
      if (!mounted) return;
      setState(() => _inventory = pkgs);
    }).catchError((e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    });
  }

  List<PkprGroup> get _groups {
    final inventory = _inventory;
    if (inventory == null) return const [];
    return sortedPkprGroups(inventory);
  }

  TextEditingController _controllerFor(PkprGroup g) => _controllers.putIfAbsent(g.productGuid, () => TextEditingController());

  /// One reconciliation line per PKPR whose box has a valid, non-negative whole number typed into it right
  /// now. A blank box, or anything that doesn't parse as a non-negative integer, means "not counted yet" and
  /// is left out entirely - never treated as "counted zero", which would wrongly report every uncounted PKPR
  /// as fully missing. diff is counted minus the state's own quantity: negative means short, positive means
  /// extra on hand. Includes every counted PKPR, matches and all - _reportView is what filters this down to
  /// just the mismatches for display; the summary line still wants the full picture.
  List<({PkprGroup group, int counted, int diff})> _buildReport() {
    final rows = <({PkprGroup group, int counted, int diff})>[];
    for (final g in _groups) {
      final text = _controllers[g.productGuid]?.text.trim() ?? '';
      if (text.isEmpty) continue;
      final counted = int.tryParse(text);
      if (counted == null || counted < 0) continue;
      rows.add((group: g, counted: counted, diff: counted - g.quantity));
    }
    return rows;
  }

  /// Renders _reportBoundaryKey's own subtree (the report's content, not the buttons around it) to a PNG and
  /// hands it to the platform's native share sheet - "save to device" (Photos/Files) and "email/text it" are
  /// both just options that sheet already offers for an image, so this doesn't need to implement either one
  /// itself. Written to the app's own temp directory (path_provider) first since share_plus shares a file by
  /// path, not raw bytes.
  Future<void> _onSaveReportPressed() async {
    setState(() => _saving = true);
    try {
      final boundary = _reportBoundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) return; // report isn't showing/laid out - nothing to capture
      final image = await boundary.toImage(pixelRatio: 3); // 3x for a crisp result once zoomed in or printed
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('could not encode the image');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/reconciliation_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      if (!mounted) return;
      await Share.shareXFiles([XFile(file.path)], text: 'Inventory reconciliation - ${widget.center.licenseName}');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save the report: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Reconcile · ${widget.center.licenseName}')),
      body: ResponsiveBody(child: _body()),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text('Inventory did not load: $_error', textAlign: TextAlign.center),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_inventory == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _showingReport ? _reportView() : _countingView();
  }

  /// One row per PKPR (packages_client.dart's sortedPkprGroups - the same type-then-strain-then-size order
  /// StockPage shows), with the same type/strain section headers StockPage uses so a worker counting down the
  /// safe sees an identical layout to the one they already know, just with a box to fill in next to each line
  /// instead of a checkbox.
  Widget _countingView() {
    final groups = _groups;
    if (groups.isEmpty) {
      return const Center(child: Text('Nothing in stock to reconcile.'));
    }
    String? lastType;
    String? lastStrain;
    final rows = <Widget>[];
    for (final g in groups) {
      if (g.productType != lastType) {
        rows.add(_typeHeader(g.productType));
        lastType = g.productType;
        lastStrain = null; // a new type always shows its first strain's header too, even if the name repeats
      }
      if (g.strain != lastStrain) {
        rows.add(_strainHeader(g.strain));
        lastStrain = g.strain;
      }
      rows.add(_countRow(g));
    }
    return Column(
      children: [
        Expanded(child: ListView(children: rows)),
        _bottomBar(
          FilledButton.icon(
            onPressed: () => setState(() => _showingReport = true),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Generate report'),
          ),
        ),
      ],
    );
  }

  Widget _typeHeader(String productType) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(iconForProductType(productType), size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Text(
            productType.isEmpty ? '(no product type on file)' : productType,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _strainHeader(String strain) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Text(
        strain.isEmpty ? '—' : strain,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _countRow(PkprGroup g) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(g.productGuid),
                Text('State record: ${g.quantity} · ${g.tpeMg}${g.mgLabel} each${tpeProvenanceNote(g)}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 92,
            child: TextField(
              controller: _controllerFor(g),
              decoration: const InputDecoration(labelText: 'Counted', isDense: true, border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(Widget child) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }

  String _formatDateTime(DateTime d) {
    final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final time = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  /// The report content itself (date, worker, summary, mismatches) lives inside a RepaintBoundary wrapped
  /// around a plain Column - deliberately not the ListView the counting view uses, because a ListView only
  /// builds whatever's currently scrolled into view, so capturing it as an image would only ever capture that
  /// one screenful. A Column lays out every child regardless of what's visible, so RenderRepaintBoundary.
  /// toImage (see _onSaveReportPressed) captures the WHOLE report in one image, scrolled-off parts included -
  /// the SingleChildScrollView around it is only for how a worker reads it on screen before saving.
  Widget _reportView() {
    final allReport = _buildReport();
    final backButton = OutlinedButton(
      onPressed: () => setState(() => _showingReport = false),
      child: const Text('Back to counting'),
    );
    if (allReport.isEmpty) {
      return Column(
        children: [
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text('No counts were entered - nothing to report.', textAlign: TextAlign.center),
              ),
            ),
          ),
          _bottomBar(backButton),
        ],
      );
    }
    final mismatches = allReport.where((r) => r.diff != 0).toList();
    final short = allReport.where((r) => r.diff < 0).length;
    final over = allReport.where((r) => r.diff > 0).length;
    final matched = allReport.where((r) => r.diff == 0).length;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: RepaintBoundary(
              key: _reportBoundaryKey,
              child: Container(
                width: double.infinity,
                // A solid, theme-independent background for the captured image - this is likely to be viewed
                // outside the app (emailed, texted, printed), where a transparent or dark-mode background
                // would look wrong or make text unreadable against whatever it lands on.
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Inventory Reconciliation', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black)),
                    const SizedBox(height: 4),
                    Text(widget.center.licenseName, style: const TextStyle(fontSize: 16, color: Colors.black)),
                    const SizedBox(height: 8),
                    Text('Date: ${_formatDateTime(DateTime.now())}', style: const TextStyle(color: Colors.black87)),
                    if (widget.workerEmail.isNotEmpty) Text('Counted by: ${widget.workerEmail}', style: const TextStyle(color: Colors.black87)),
                    const SizedBox(height: 12),
                    Text(
                      '${allReport.length} PKPR(s) counted · $matched match · $short short · $over extra',
                      style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black),
                    ),
                    const SizedBox(height: 16),
                    if (mismatches.isEmpty)
                      const Text('Every counted PKPR matched the state record. Nothing to flag.', style: TextStyle(color: Colors.black87))
                    else
                      for (final r in mismatches) ...[
                        _mismatchRow(r),
                        const Divider(height: 1),
                      ],
                  ],
                ),
              ),
            ),
          ),
        ),
        _bottomBar(
          Row(
            children: [
              Expanded(child: backButton),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saving ? null : _onSaveReportPressed,
                  icon: _saving
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.ios_share),
                  label: const Text('Save report'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Colors here are hardcoded (not Theme.of(context)) same as the rest of the captured report content -
  /// see _reportView's own comment on why the captured image always renders on a fixed white background
  /// regardless of the app's current theme.
  Widget _mismatchRow(({PkprGroup group, int counted, int diff}) r) {
    final diffText = r.diff > 0 ? '+${r.diff} extra' : '${r.diff} short';
    final diffColor = r.diff > 0 ? Colors.blue.shade700 : Colors.red.shade700;
    final subtitleParts = [r.group.productGuid, if (r.group.strain.isNotEmpty) r.group.strain];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(iconForProductType(r.group.productType), size: 20, color: Colors.black54),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.group.productType.isEmpty ? r.group.productGuid : r.group.productType,
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
                ),
                Text(
                  '${subtitleParts.join(' · ')} · state ${r.group.quantity}, counted ${r.counted}',
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                ),
              ],
            ),
          ),
          Text(diffText, style: TextStyle(color: diffColor, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
