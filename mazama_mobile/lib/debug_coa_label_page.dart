// "COA → label (on phone)": a debug-only page that runs a package's whole chain on the phone, step by step, with
// the same shared code the server uses - the state's inventory, the lot's lab report from the state, its text
// with pdfium (pdf_text.dart), the shared core's parse and label spec (mazama_core.dart), and a drawn preview
// (label_preview.dart). Design: specs/coa/08-phone-label-debug.md; plan 08 Task 8.
//
// For finding out, at a center, at which step a lot fails to get lab values or a label, without the server: the
// page calls only the state system (with the worker's own session) and never the Mazama server. Reachable only
// from DebugToolsPage, itself kDebugMode-only.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'coa_data_resolver.dart' show newestPotencyPdfDocId;
import 'debug_adhoc_coa_diagnostics_page.dart' show describeTestResults;
import 'label_preview.dart';
import 'mazama_core.dart';
import 'package_ids.dart';
import 'pdf_text.dart';
import 'session.dart';
import 'state_client.dart';
import 'state_document_client.dart' as state_document_client;
import 'state_packages_client.dart' as state_packages_client;
import 'state_records.dart';

enum _Status { pending, running, ok, error, skipped }

class _Step {
  final String title;
  _Status status = _Status.pending;
  String? detail;
  _Step(this.title);
}

/// A step's failure, with what the step saw before it failed.
class _StepFailed implements Exception {
  final String message;
  _StepFailed(this.message);
  @override
  String toString() => message;
}

String _num2(Object? v) => v is num ? v.toStringAsFixed(2) : '$v';

/// A package as the page shows and tests it: the state's own record, with the fields the steps use.
class _Package {
  final Map<String, Object?> record;
  final int id;
  final String pkpr;
  _Package(this.record, this.id, this.pkpr);

  String get description => '${record['description'] ?? ''}';
  String? get lot => packageSource(record);
  double get weightPerUnit => (record['weightPerUnit'] as num?)?.toDouble() ?? 0;
  double get analyteWeight => (record['analyteWeight'] as num?)?.toDouble() ?? 0;
  String get productType => '${record['productType'] ?? ''}';
}

class DebugCoaLabelPage extends StatefulWidget {
  final Session session;

  /// Pre-fills the state-id field with the center already selected; editable.
  final int? initialStateId;

  /// The center's packaged products as the state sends them (every one with an id and a PKPR, sellable or not).
  /// Defaults to state_packages_client.fetchRawPackagesFromState.
  final Future<List<Object?>> Function(int stateId, {required String accessToken}) fetchRawPackages;

  /// GetPackagedProductInfo for one package (the shared packaged_product_info flow).
  final Future<Object?> Function(int packageId, {required String accessToken}) fetchProductInfo;

  /// A state document's bytes. Defaults to state_document_client.downloadStateDocument.
  final Future<Uint8List> Function(int docId, {required String accessToken}) downloadDocument;

  /// A PDF's CoaText. Defaults to pdf_text.dart's extractCoaText (pdfium).
  final Future<Map<String, Object?>> Function(Uint8List pdf) extractText;

  /// The shared core. Defaults to this app's ([MazamaCore.instance]).
  final CoreFunctions core;

  /// Hands the downloaded lab report to the share sheet.
  final Future<void> Function(Uint8List bytes, String fileName) sharePdf;

  /// Puts the results on the clipboard.
  final Future<void> Function(String text) copyText;

  /// The page's "today" default.
  final DateTime Function() now;

  DebugCoaLabelPage({
    super.key,
    required this.session,
    this.initialStateId,
    Future<List<Object?>> Function(int, {required String accessToken})? fetchRawPackages,
    Future<Object?> Function(int, {required String accessToken})? fetchProductInfo,
    Future<Uint8List> Function(int, {required String accessToken})? downloadDocument,
    Future<Map<String, Object?>> Function(Uint8List pdf)? extractText,
    CoreFunctions? core,
    Future<void> Function(Uint8List bytes, String fileName)? sharePdf,
    Future<void> Function(String text)? copyText,
    DateTime Function()? now,
  })  : fetchRawPackages = fetchRawPackages ?? state_packages_client.fetchRawPackagesFromState,
        fetchProductInfo = fetchProductInfo ??
            ((packageId, {required accessToken}) =>
                fetchStateFlow('packaged_product_info', {'package_id': packageId}, accessToken: accessToken)),
        downloadDocument = downloadDocument ?? state_document_client.downloadStateDocument,
        extractText = extractText ?? extractCoaText,
        core = core ?? MazamaCore.instance,
        sharePdf = sharePdf ?? _sharePdf,
        copyText = copyText ?? _copy,
        now = now ?? DateTime.now;

  static Future<void> _sharePdf(Uint8List bytes, String fileName) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles([XFile(file.path, mimeType: 'application/pdf')], text: fileName);
  }

  static Future<void> _copy(String text) => Clipboard.setData(ClipboardData(text: text));

  @override
  State<DebugCoaLabelPage> createState() => _DebugCoaLabelPageState();
}

class _DebugCoaLabelPageState extends State<DebugCoaLabelPage> {
  late final _stateId = TextEditingController(text: widget.initialStateId?.toString() ?? '');
  final _pkpr = TextEditingController();
  final _shelfMonths = TextEditingController(text: '12');
  final _fdMonths = TextEditingController(text: '24');
  final _shelfDays = TextEditingController();
  final _fdDays = TextEditingController();
  late final _today = TextEditingController(text: _isoDay(widget.now()));

  bool _running = false;
  List<_Package>? _packages;
  Uint8List? _pdf;
  String? _pdfName;
  Map<String, Object?>? _spec;

  final _steps = [
    _Step('Inventory'),
    _Step('Lab report'),
    _Step('Download'),
    _Step('Text'),
    _Step('Parse'),
    _Step('Label spec'),
    _Step('Preview'),
  ];

  static String _isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    for (final c in [_stateId, _pkpr, _shelfMonths, _fdMonths, _shelfDays, _fdDays, _today]) {
      c.dispose();
    }
    super.dispose();
  }

  void _reset() {
    for (final s in _steps) {
      s.status = _Status.pending;
      s.detail = null;
    }
    _pdf = null;
    _pdfName = null;
    _spec = null;
  }

  Future<List<_Package>> _fetchPackages(int stateId) async {
    final raw = await widget.fetchRawPackages(stateId, accessToken: widget.session.accessToken);
    final out = <_Package>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final r = Map<String, Object?>.from(e);
      final key = packagedProductKey(r);
      if (key != null) out.add(_Package(r, key.stateId, key.pkpr));
    }
    return out;
  }

  /// Step 1 alone: the center's packages, listed for picking.
  Future<void> _load() async {
    final stateId = int.tryParse(_stateId.text.trim());
    setState(() {
      _reset();
      _packages = null;
    });
    if (stateId == null) {
      setState(() => _fail(0, 'Enter a numeric state id first.'));
      return;
    }
    setState(() {
      _running = true;
      _steps[0].status = _Status.running;
    });
    try {
      final packages = await _fetchPackages(stateId);
      if (!mounted) return;
      setState(() {
        _packages = packages;
        _steps[0].status = _Status.ok;
        _steps[0].detail = '${packages.length} package(s); pick one below, or type a PKPR.';
      });
    } catch (e) {
      if (mounted) setState(() => _fail(0, '$e'));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Every step for the typed PKPR, fetching the inventory afresh.
  Future<void> _testTyped() async {
    final stateId = int.tryParse(_stateId.text.trim());
    var typed = _pkpr.text.trim();
    setState(_reset);
    if (stateId == null) {
      setState(() => _fail(0, 'Enter a numeric state id first.'));
      return;
    }
    if (typed.isEmpty) {
      setState(() => _fail(0, 'Type a PKPR first, or load the packages and pick one.'));
      return;
    }
    if (!typed.toUpperCase().startsWith('PKPR-')) typed = 'PKPR-$typed';
    await _runAll(() async {
      final packages = await _fetchPackages(stateId);
      if (mounted) setState(() => _packages = packages);
      for (final p in packages) {
        if (p.pkpr.toUpperCase() == typed.toUpperCase()) return (p, packages.length);
      }
      throw _StepFailed("$typed is not in this center's inventory (${packages.length} package(s)).");
    });
  }

  /// Every step for a package picked from the loaded list (the inventory isn't fetched again).
  Future<void> _testPicked(_Package p) async {
    final count = _packages?.length ?? 0;
    setState(_reset);
    await _runAll(() async => (p, count));
  }

  void _fail(int i, String message) {
    _steps[i].status = _Status.error;
    _steps[i].detail = message;
    for (final s in _steps.skip(i + 1)) {
      s.status = _Status.skipped;
    }
  }

  Future<void> _runAll(Future<(_Package, int)> Function() inventory) async {
    setState(() => _running = true);
    var i = 0;
    Future<T> step<T>(int n, Future<T> Function() body) async {
      i = n;
      setState(() => _steps[n].status = _Status.running);
      final out = await body();
      if (mounted) setState(() => _steps[n].status = _Status.ok);
      return out;
    }

    void say(int n, String detail) => _steps[n].detail = detail;

    try {
      final (pkg, _) = await step(0, () async {
        final (p, n) = await inventory();
        say(0, '$n package(s). Testing ${p.pkpr}: "${p.description}", unit weight ${p.weightPerUnit} g, '
            '${p.productType.isEmpty ? 'no product type' : p.productType}, lot ${p.lot ?? '(none)'}, '
            'analyteWeight ${p.analyteWeight} (state package id ${p.id}).');
        return (p, n);
      });

      final docId = await step(1, () async {
        final info = await widget.fetchProductInfo(pkg.id, accessToken: widget.session.accessToken);
        final id = newestPotencyPdfDocId(info);
        if (id == null) {
          throw _StepFailed('No accepted, non-deprecated potency PDF on file for this package.\n'
              '${describeTestResults(info, null)}');
        }
        say(1, 'document $id, completed ${_completedDate(info, id) ?? '?'}\n${describeTestResults(info, id)}');
        return id;
      });

      final pdf = await step(2, () async {
        final bytes = await widget.downloadDocument(docId, accessToken: widget.session.accessToken);
        _pdf = bytes;
        _pdfName = '${pkg.lot ?? pkg.pkpr}_document_$docId.pdf';
        final head = String.fromCharCodes(bytes.take(5));
        if (!head.startsWith('%PDF')) {
          throw _StepFailed('${bytes.length} bytes, not a PDF (it starts "${head.replaceAll(RegExp(r'[^ -~]'), '?')}").');
        }
        say(2, '${bytes.length} bytes.');
        return bytes;
      });

      final text = await step(3, () async {
        final t = await widget.extractText(pdf);
        say(3, _describeText(t));
        return t;
      });

      final section = await step(4, () async {
        final core = widget.core;
        final lot = pkg.lot;
        if (lot == null) {
          final described = _describeParse(core.parse(jsonEncode(text)));
          throw _StepFailed('The package names no batch/lot (harvestBatchGuid/processLotGuid).\n$described');
        }
        // AD-19, the shared rule: the lot's own UID, else the batch the report's request pairs it with (a process
        // lot reported under its harvest batch), else the state's psilocybin
        final reply = core.findLot(text, lot, statePsilocybin: pkg.analyteWeight > 0 ? pkg.analyteWeight : null);
        final parsed = ((reply['result'] as Map?) ?? const {}).cast<String, Object?>();
        final described = _describeParse(parsed);
        final sections = (parsed['sections'] as List? ?? const []).cast<Map<String, Object?>>();
        final found = reply['found'];
        final at = found is Map ? found['section'] : null;
        if (at is! int || at < 0 || at >= sections.length) {
          final uids = {for (final s in sections) if (s['uid'] != null) '${s['uid']}'};
          throw _StepFailed('$lot is not in this report; it has: ${uids.isEmpty ? 'no UID lines' : uids.join(', ')}\n'
              '$described');
        }
        final hit = found as Map;
        final how = switch (hit['via']) {
          'own' => '$lot is of record',
          'request' => "$lot is reported as ${hit['uid']} (found by the report's request / chain of custody)",
          'state_psilocybin' => "$lot is reported as ${hit['uid']} (found by the state's psilocybin, ${pkg.analyteWeight} mg/g)",
          final other => '$lot is reported as ${hit['uid']} (found by $other)',
        };
        say(4, '$how: section ${at + 1}\n$described');
        return (core, sections[at]);
      });

      final spec = await step(5, () async {
        final (core, sec) = section;
        final out = core.labelSpec({
          'package': {
            'pkpr': pkg.pkpr,
            'description': pkg.description,
            'weight_per_unit': pkg.weightPerUnit,
            'product_type': pkg.productType,
            'analyte_weight': pkg.analyteWeight,
            'lot': pkg.lot,
          },
          'section': sec,
          'settings': _settings(),
          'today': _todayValue(),
        });
        final warnings = (out['warnings'] as List? ?? const []).map((w) => 'warning: $w');
        final blocked = out['blocked'];
        if (blocked is List) {
          throw _StepFailed(['Blocked:', for (final b in blocked) '• $b', ...warnings].join('\n'));
        }
        final s = (out['spec'] as Map).cast<String, Object?>();
        say(5, [_describeSpec(s), ...warnings].join('\n'));
        return s;
      });

      await step(6, () async {
        setState(() => _spec = spec);
        say(6, 'Drawn below.');
      });
    } catch (e) {
      if (mounted) setState(() => _fail(i, e is _StepFailed ? e.message : '$e'));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Map<String, Object?> _settings() {
    int? whole(TextEditingController c, String name, {required bool optional}) {
      final t = c.text.trim();
      if (t.isEmpty && optional) return null;
      final v = int.tryParse(t);
      if (v == null || v < 0) throw _StepFailed('$name must be a whole number${optional ? ' or empty' : ''}.');
      return v;
    }

    return {
      'shelf_months': whole(_shelfMonths, 'Shelf months', optional: false),
      'fd_months': whole(_fdMonths, 'FD months', optional: false),
      'shelf_days': whole(_shelfDays, 'Shelf days', optional: true),
      'fd_days': whole(_fdDays, 'FD days', optional: true),
    };
  }

  String _todayValue() {
    final t = _today.text.trim();
    final d = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t) ? DateTime.tryParse(t) : null;
    if (d == null || _isoDay(d) != t) throw _StepFailed('Today must be a date as YYYY-MM-DD.');
    return t;
  }

  /// The completed date of the test result that holds document [docId].
  static String? _completedDate(Object? info, int docId) {
    final results = info is Map ? info['testResults'] : null;
    if (results is! List) return null;
    for (final tr in results) {
      final manifest = tr is Map ? tr['testingManifest'] : null;
      final docs = manifest is Map ? manifest['documents'] : null;
      if (docs is List && docs.any((d) => d is Map && d['id'] == docId)) return '${(tr as Map)['dateCompleted']}';
    }
    return null;
  }

  static String _describeText(Map<String, Object?> text) {
    final pages = (text['pages'] as List? ?? const []).cast<Map>();
    final perPage = [for (final p in pages) '${(p['index'] as num).toInt() + 1}: ${(p['words'] as List? ?? const []).length}'];
    final none = [for (final p in pages) if (p['source'] != 'text_layer') '${(p['index'] as num).toInt() + 1}'];
    return '${pages.length} page(s); words per page ${perPage.join(', ')}; '
        '${none.isEmpty ? 'every page has a text layer' : 'no text layer: pages ${none.join(', ')} (not read: no OCR on the phone)'}.';
  }

  static String _describeParse(Map<String, Object?> parsed) {
    final report = (parsed['report'] as Map?) ?? const {};
    final out = StringBuffer('${parsed['parser_version'] ?? '?'}\nlab ${report['lab'] ?? '?'}, licensee ${report['licensee'] ?? '?'}, '
        'reported ${report['reported_date'] ?? '?'}');
    final sections = (parsed['sections'] as List? ?? const []).cast<Map>();
    if (sections.isEmpty) out.write('\nno sections');
    for (final (n, s) in sections.indexed) {
      final reasons = (s['reasons'] as List? ?? const []);
      out.write('\n${n + 1}. ${s['uid'] ?? '(no UID)'} "${s['sample'] ?? ''}"${s['is_fd'] == true ? ' FD' : ''}, '
          'page ${s['page']}, ${s['status']}${reasons.isEmpty ? '' : ': ${reasons.join('; ')}'}');
    }
    return out.toString();
  }

  static String _describeSpec(Map<String, Object?> s) {
    final mg = (s['per_unit_mg'] as Map? ?? const {}).entries.map((e) => '${e.key} ${_num2(e.value)}').join(', ');
    final from = switch (s['best_by_from']) {
      'name' => 'from the name',
      'coa_analyzed_date' => "from the report's analysed date",
      'today' => 'counted from today',
      final other => 'from $other',
    };
    return 'TPE ${s['tpe_mg_per_g']} mg/g, dose ${s['dose_mg_tpe']} mg, psilocybin from the ${s['psilocybin_from'] == 'state' ? 'state' : 'COA'}, '
        '${_num2(s['net_wt_g'])} g per unit\nmg per unit: $mg\nbest-by ${s['best_by']} ($from), type ${s['type_code']}, '
        'strain "${s['strain']}"';
  }

  String _results() {
    final out = StringBuffer('COA → label (on phone), state id ${_stateId.text.trim()}, PKPR ${_pkpr.text.trim()}\n');
    for (final (n, s) in _steps.indexed) {
      final mark = switch (s.status) {
        _Status.ok => '✓',
        _Status.error => '✗',
        _Status.skipped => 'skipped',
        _Status.running => 'running',
        _Status.pending => 'not run',
      };
      out.write('\n${n + 1}. ${s.title}: $mark');
      if (s.detail != null) out.write('\n${s.detail}');
      out.write('\n');
    }
    if (_spec != null) out.write('\nLabel:\n${labelPreviewLines(_spec!).join('\n')}\n');
    return out.toString();
  }

  Future<void> _copy() async {
    await widget.copyText(_results());
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Results copied.')));
  }

  Future<void> _share() async {
    try {
      await widget.sharePdf(_pdf!, _pdfName!);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share the PDF: $e')));
    }
  }

  Widget _field(TextEditingController c, String label, {double width = 110, TextInputType? keyboard}) => SizedBox(
        width: width,
        child: TextField(
          controller: c,
          enabled: !_running,
          keyboardType: keyboard,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ran = _steps.any((s) => s.status != _Status.pending);
    return Scaffold(
      appBar: AppBar(title: const Text('COA → label (debug)')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("Reads a package's lab report from the state and builds its label with the shared reader, all "
                'on this phone: no calls to the Mazama server.'),
            const SizedBox(height: 16),
            TextField(
              controller: _stateId,
              enabled: !_running,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Service center state id', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _running ? null : _load, child: const Text('Load packages')),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pkpr,
                    enabled: !_running,
                    decoration: const InputDecoration(labelText: 'PKPR to test', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _running ? null : _testTyped, child: const Text('Test this PKPR')),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _field(_shelfMonths, 'Shelf months', keyboard: TextInputType.number),
                _field(_fdMonths, 'FD months', keyboard: TextInputType.number),
                _field(_shelfDays, 'Shelf days', keyboard: TextInputType.number),
                _field(_fdDays, 'FD days', keyboard: TextInputType.number),
                _field(_today, 'Today', width: 140),
              ],
            ),
            const SizedBox(height: 16),
            for (final (n, s) in _steps.indexed) _stepTile(n, s),
            if (_spec != null) ...[
              const SizedBox(height: 8),
              LabelPreview(spec: _spec!),
            ],
            if (ran && !_running) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(icon: const Icon(Icons.copy), label: const Text('Copy results'), onPressed: _copy),
            ],
            if (_pdf != null && !_running)
              OutlinedButton.icon(icon: const Icon(Icons.share), label: const Text('Share the lab report PDF'), onPressed: _share),
            if (_packages != null) ...[
              const Divider(height: 32),
              Text('Packages (${_packages!.length})', style: Theme.of(context).textTheme.titleSmall),
              for (final p in _packages!)
                ListTile(
                  dense: true,
                  title: Text(p.pkpr),
                  subtitle: Text([p.description, if (p.lot != null) p.lot!].join(' · ')),
                  enabled: !_running,
                  onTap: () {
                    _pkpr.text = p.pkpr;
                    _testPicked(p);
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stepTile(int n, _Step s) {
    final Widget icon = switch (s.status) {
      _Status.pending => const Icon(Icons.circle_outlined, color: Colors.grey),
      _Status.running => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      _Status.ok => const Icon(Icons.check_circle, color: Colors.green),
      _Status.error => const Icon(Icons.error, color: Colors.red),
      _Status.skipped => const Icon(Icons.remove_circle_outline, color: Colors.grey),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 28, child: icon),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${n + 1}. ${s.title}', style: Theme.of(context).textTheme.titleSmall),
                if (s.detail != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(s.detail!)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
