// A debug-only diagnostic screen that exercises the adhoc-COA pipeline's three network legs end to end, one
// step at a time, against a real center/stateId typed in here - NOT coa_data_resolver.dart's own
// resolveAdhocInventory, which always tries the server's batch cache first and would skip the
// download/upload legs entirely for any lot the server has already resolved. This page exists specifically
// to exercise those two legs on demand - the thing you actually want to check before trusting a brand-new
// unconfigured center at a real site, where every lot's cache is, by definition, still empty.
//
// Only ever reachable from a kDebugMode build - see select_center_page.dart's own debug-only entry point.
// Never shown, and never linked to, in a release build a worker could stumble into: it takes a service
// center's own state_id directly (no "is this center configured" check at all, unlike CartPage) and happily
// re-parses and re-uploads a lot any worker is actively relying on, which is exactly the kind of thing that
// should require deliberately opening a hidden screen, not be one tap away for anyone.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'coa_data_client.dart' as coa_data_client;
import 'coa_data_resolver.dart' show newestPotencyPdfDocId;
import 'device_id.dart';
import 'packages_client.dart';
import 'session.dart';
import 'state_client.dart';
import 'state_document_client.dart' as state_document_client;
import 'state_packages_client.dart' as state_packages_client;

enum _StepStatus { pending, running, ok, error, skipped }

class _Step {
  final String title;
  _StepStatus status;
  String? detail;
  _Step(this.title) : status = _StepStatus.pending;
}

/// Every test result in a GetPackagedProductInfo reply, with its fields and documents, marking the one
/// newestPotencyPdfDocId picked - for checking which lab report a lot's label would be read from. Field names
/// beyond test/status/dateCompleted are printed as the state sent them (productId, labTestBatchNumber, ...).
String describeTestResults(Object? info, int? picked) {
  final results = info is Map ? info['testResults'] : null;
  if (results is! List || results.isEmpty) return 'The state returned no test results for this package.';
  final out = StringBuffer('The state returned ${results.length} test result(s):');
  for (final tr in results) {
    if (tr is! Map) continue;
    out.write('\n• ${tr['test']} / ${tr['status']} / completed ${tr['dateCompleted'] ?? '?'}');
    for (final e in tr.entries) {
      if (const {'test', 'status', 'dateCompleted', 'testingManifest'}.contains(e.key)) continue;
      final v = e.value;
      if (v == null || v is Map || v is List) continue;
      out.write('\n   ${e.key}: $v');
    }
    final manifest = tr['testingManifest'];
    final docs = manifest is Map ? manifest['documents'] : null;
    if (docs is! List || docs.isEmpty) {
      out.write('\n   (no documents)');
      continue;
    }
    for (final d in docs) {
      if (d is! Map) continue;
      out.write("\n   - doc ${d['id']} '${d['name'] ?? ''}'");
      if (d['deprecated'] == true) out.write(' (deprecated)');
      if (picked != null && d['id'] == picked) out.write(' <- picked');
    }
  }
  return out.toString();
}

class DebugAdhocCoaDiagnosticsPage extends StatefulWidget {
  final Session session;

  /// Pre-fills the state-id field - the entry point in select_center_page.dart passes whichever center was
  /// already loaded there, if any, so the common case (checking the center you're already looking at) needs
  /// no typing. Still just a starting point: the field is editable, since the whole reason this page exists
  /// is to test a center that may not even be in this account's own license list yet.
  final int? initialStateId;

  /// Overridable for tests, so a widget test never makes a real network call for any of the four steps
  /// either - same real-by-default pattern as every other page in this app (CartPage's own fetchPackages/
  /// fetchPackagesFromState fields, etc.). Defaults to the real fetchPackagesFromState.
  final Future<List<Package>> Function(int stateId, {required String accessToken}) fetchPackagesFromState;

  /// Wraps fetchStateFlow('packaged_product_info', {'package_id': packageId}, ...) - the same call
  /// coa_data_resolver.dart's own miss-path worker makes. Takes a PACKAGE's own state-system id (Package.id - see
  /// step 1's own call site in _run), never the service center's state id; keeping this as its own overridable
  /// field means a test fixture doesn't have to know the flow's inputs either way.
  final Future<Object?> Function(int packageId, {required String accessToken}) fetchProductInfo;

  /// Overridable for tests. Defaults to the real downloadStateDocument (state_document_client.dart).
  final Future<Uint8List> Function(int docId, {required String accessToken}) downloadDocument;

  /// Overridable for tests. Defaults to the real uploadCoaParse (coa_data_client.dart) - the same call that
  /// actually writes to the server's adhoc_coa table, so a successful run of this page's last step really
  /// did cache this lot for every other worker/center too, same as the real app flow would.
  final Future<coa_data_client.CoaData> Function({
    required String guid,
    required Uint8List pdfBytes,
    int? docId,
    required String workerEmail,
    required String deviceId,
    double? statePsilocybin,
  }) uploadCoaParse;

  /// Hands the downloaded lab report to the platform's share sheet (save to Files, email, message), so a
  /// report the server couldn't read can be sent on for a look. Overridable for tests; defaults to _sharePdf
  /// (written to the temp directory first, since share_plus shares files by path).
  final Future<void> Function(Uint8List bytes, String fileName) sharePdf;

  /// Overridable for tests, so a widget test never touches the real app-data directory - same pattern as
  /// every other page's own deviceIdStore field. Defaults to a real DeviceIdStore.
  final DeviceIdStore deviceIdStore;

  DebugAdhocCoaDiagnosticsPage({
    super.key,
    required this.session,
    this.initialStateId,
    Future<List<Package>> Function(int, {required String accessToken})? fetchPackagesFromState,
    Future<Object?> Function(int, {required String accessToken})? fetchProductInfo,
    Future<Uint8List> Function(int, {required String accessToken})? downloadDocument,
    Future<coa_data_client.CoaData> Function({
      required String guid,
      required Uint8List pdfBytes,
      int? docId,
      required String workerEmail,
      required String deviceId,
      double? statePsilocybin,
    })? uploadCoaParse,
    this.deviceIdStore = const DeviceIdStore(),
    Future<void> Function(Uint8List bytes, String fileName)? sharePdf,
  })  : sharePdf = sharePdf ?? _sharePdf,
         fetchPackagesFromState = fetchPackagesFromState ?? state_packages_client.fetchPackagesFromState,
        fetchProductInfo = fetchProductInfo ??
            ((packageId, {required accessToken}) =>
                fetchStateFlow('packaged_product_info', {'package_id': packageId}, accessToken: accessToken)),
        downloadDocument = downloadDocument ?? state_document_client.downloadStateDocument,
        uploadCoaParse = uploadCoaParse ?? coa_data_client.uploadCoaParse;

  static Future<void> _sharePdf(Uint8List bytes, String fileName) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    final mime = fileName.endsWith('.json') ? 'application/json' : 'application/pdf';
    await Share.shareXFiles([XFile(file.path, mimeType: mime)], text: fileName);
  }

  @override
  State<DebugAdhocCoaDiagnosticsPage> createState() => _DebugAdhocCoaDiagnosticsPageState();
}

class _DebugAdhocCoaDiagnosticsPageState extends State<DebugAdhocCoaDiagnosticsPage> {
  late final _stateIdController = TextEditingController(text: widget.initialStateId?.toString() ?? '');
  bool _running = false;

  /// The last run's downloaded lab report (kept after a failed upload, which is when it's most wanted).
  Uint8List? _pdf;
  String? _pdfName;

  /// The last run's GetPackagedProductInfo reply, as the state sent it: every test result and document that the
  /// lab report was chosen from, for checking that the right one was picked.
  Object? _productInfo;
  String? _productInfoName;

  late final List<_Step> _steps = [
    _Step('Pull inventory from the state system'),
    _Step("Find this lot's own lab report"),
    _Step('Download the lab report PDF'),
    _Step('Upload it to the server for parsing'),
  ];

  void _resetSteps() {
    for (final s in _steps) {
      s.status = _StepStatus.pending;
      s.detail = null;
    }
  }

  Future<void> _run() async {
    final stateId = int.tryParse(_stateIdController.text.trim());
    if (stateId == null) {
      setState(() {
        _resetSteps();
        _steps[0].status = _StepStatus.error;
        _steps[0].detail = 'Enter a numeric state id first.';
      });
      return;
    }

    setState(() {
      _running = true;
      _resetSteps();
      _pdf = null;
      _pdfName = null;
      _productInfo = null;
      _productInfoName = null;
    });

    Future<void> runStep(int i, Future<void> Function() body) async {
      setState(() => _steps[i].status = _StepStatus.running);
      try {
        await body();
        if (!mounted) return;
        setState(() => _steps[i].status = _StepStatus.ok);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _steps[i].status = _StepStatus.error;
          _steps[i].detail = e.toString();
        });
        rethrow;
      }
    }

    String? guid;
    String? productGuid;
    double? statePsilocybin;
    int? packageId;
    int? docId;
    Uint8List? pdfBytes;

    try {
      await runStep(0, () async {
        final packages = await widget.fetchPackagesFromState(stateId, accessToken: widget.session.accessToken);
        final withGuid = packages.where((p) => p.lotGuid != null && p.lotGuid!.isNotEmpty).toList();
        if (withGuid.isEmpty) {
          throw Exception('Got ${packages.length} package(s) from the state system, but none carry a lotGuid '
              '(harvestBatchGuid/processLotGuid) - nothing here for the rest of this pipeline to resolve.');
        }
        guid = withGuid.first.lotGuid;
        // GetPackagedProductInfo (the next step) is keyed by a PACKAGE's own state-system id, never the
        // service center's - see coa_data_resolver.dart's own comment on this same point, and
        // mazama_sales' labpdfs.py _package_candidates/session.packaged_product_info for the server-side
        // precedent this mirrors. This package is simply one representative holder of the lot being tested;
        // any package carrying the same lotGuid would do equally well.
        packageId = withGuid.first.id;
        productGuid = withGuid.first.productGuid;
        statePsilocybin = withGuid.first.analyteWeight;
        _steps[0].detail =
            '${packages.length} package(s), ${withGuid.map((p) => p.lotGuid).toSet().length} distinct lot guid(s). '
            "Testing lot $guid (package ${withGuid.first.productGuid}, state package id $packageId).";
      });

      await runStep(1, () async {
        final info = await widget.fetchProductInfo(packageId!, accessToken: widget.session.accessToken);
        _productInfo = info;
        _productInfoName = '${productGuid}_product_info_$packageId.json';
        docId = newestPotencyPdfDocId(info);
        if (docId == null) {
          throw Exception('GetPackagedProductInfo/$packageId has no accepted, non-deprecated Potency-test PDF '
              'on file for this lot yet - nothing for the next step to download.\n${describeTestResults(info, null)}');
        }
        _steps[1].detail = 'Newest accepted Potency-test PDF is document $docId.\n${describeTestResults(info, docId)}';
      });

      await runStep(2, () async {
        pdfBytes = await widget.downloadDocument(docId!, accessToken: widget.session.accessToken);
        _steps[2].detail = '${pdfBytes!.length} bytes downloaded.';
        _pdf = pdfBytes;
        _pdfName = '${guid}_document_$docId.pdf';
      });

      await runStep(3, () async {
        final deviceId = await widget.deviceIdStore.idOrCreate();
        final data = await widget.uploadCoaParse(
          guid: guid!,
          pdfBytes: pdfBytes!,
          docId: docId,
          workerEmail: widget.session.email,
          deviceId: deviceId,
          statePsilocybin: statePsilocybin,
        );
        _steps[3].detail = 'strain "${data.strain}" - psilocybin ${data.psilocybin ?? 'unknown'} mg/g, psilocin '
            '${data.psilocin ?? 'unknown'} mg/g, tpe ${data.tpe?.toStringAsFixed(2) ?? 'unknown'} mg/g. Cached on the server for every '
            'other worker/center that sees this same lot.';
      });
    } catch (_) {
      // Each step's own catch already recorded the failure on that step and set it to _StepStatus.error - the
      // steps after it were simply never reached, so they stay at whatever status _resetSteps() left them in
      // (pending). Nothing further to do here; this outer catch exists purely to stop the sequence.
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _onSharePressed() => _share(_pdf!, _pdfName!);

  Future<void> _share(List<int> bytes, String name) async {
    try {
      await widget.sharePdf(Uint8List.fromList(bytes), name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share the PDF: $e')));
    }
  }

  @override
  void dispose() {
    _stateIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adhoc-COA diagnostics (debug)')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "Runs the adhoc-COA pipeline's three network legs against a real service center, bypassing the "
              "server's own batch cache so the download/upload legs are actually exercised even for a lot "
              "that's already been resolved. The last step really does write to the server, the same as a "
              'worker using the real app would.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _stateIdController,
              enabled: !_running,
              decoration: const InputDecoration(labelText: 'Service center state id', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _running ? null : _run,
              child: _running ? const Text('Running...') : const Text('Run diagnostic'),
            ),
            const SizedBox(height: 24),
            for (final s in _steps) _stepTile(s),
            if (_productInfo != null && !_running) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.data_object),
                label: const Text("Share the state's product info (JSON)"),
                onPressed: () => _share(utf8.encode(const JsonEncoder.withIndent('  ').convert(_productInfo)), _productInfoName!),
              ),
            ],
            if (_pdf != null && !_running) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.share),
                label: const Text('Share the lab report PDF'),
                onPressed: _onSharePressed,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stepTile(_Step s) {
    // A switch EXPRESSION (Dart 3's "=>" form), not the classic colon-and-break statement form - every
    // branch here is a single value, and this form needs no break/return per case to avoid a fallthrough
    // error.
    final Widget icon = switch (s.status) {
      _StepStatus.pending => const Icon(Icons.circle_outlined, color: Colors.grey),
      _StepStatus.running => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      _StepStatus.ok => const Icon(Icons.check_circle, color: Colors.green),
      _StepStatus.error => const Icon(Icons.error, color: Colors.red),
      _StepStatus.skipped => const Icon(Icons.remove_circle_outline, color: Colors.grey),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 28, child: icon),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title, style: Theme.of(context).textTheme.titleSmall),
                if (s.detail != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(s.detail!)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
