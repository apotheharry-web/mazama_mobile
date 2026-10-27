// A debug-only screen for manually exercising the things CartPage normally does silently in the background -
// item 2/3a's merge-and-push-after-every-read, item 3b's fire-and-forget COA submission on a cart add, item
// 4's server-side label queueing that follows a successful COA parse, and the fire-and-forget sale-log/
// sale-failure posts - all deliberately swallow their own errors in the real flow (see merged_inventory.dart's
// own "a push failing is never surfaced to the worker" comment, configured_coa_submit.dart's "never surfaced
// to the worker" comment, and cart_page.dart's _sell/_queueFailedSale) so there's normally nothing to look at
// even when one of them is silently failing. This page runs each one on demand and shows exactly what came
// back - the real functions, not a reimplementation, so a green result here really did happen for real.
//
// Only ever reachable from a kDebugMode build, same as DebugAdhocCoaDiagnosticsPage (see debug_tools_page.dart,
// which is what links to both) - this page writes to the real server for real (a snapshot upload, a COA
// submission that queues a real label job, a sale-log/sale-failure entry that becomes part of a worker+device's
// real audit history), so it should never be one tap away for a worker who isn't deliberately testing.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'coa_data_client.dart' as coa_data_client;
import 'configured_coa_submit.dart' as configured_coa_submit;
import 'device_id.dart';
import 'inventory_upload_client.dart' as inventory_upload_client;
import 'label_client.dart' as label_client;
import 'merged_inventory.dart' as merged_inventory;
import 'sale_failure_client.dart' as sale_failure_client;
import 'sale_log_client.dart' as sale_log_client;
import 'session.dart';

class DebugBackgroundFeaturesPage extends StatefulWidget {
  final Session session;

  /// Pre-fills the state-id field, same convenience as DebugAdhocCoaDiagnosticsPage.initialStateId.
  final int? initialStateId;

  /// Overridable for tests. Defaults to the real fetchMergedInventory (merged_inventory.dart) - the exact
  /// function _fetchMergedForCart calls, so a run here really does exercise items 2/3a end to end.
  final Future<merged_inventory.MergedInventoryResult> Function(int stateId, {required String accessToken})
      fetchMergedInventory;

  /// Overridable for tests. Defaults to the real uploadInventorySnapshot (inventory_upload_client.dart) - the
  /// same call _fetchMergedForCart makes fire-and-forget after every merge; this page makes it on demand and
  /// actually shows the response (or the error) instead of swallowing it.
  final Future<Map<String, Object?>> Function(int stateId, List<Object?> records,
      {required String workerEmail, required String deviceId}) uploadInventorySnapshot;

  /// Overridable for tests. Defaults to the real submitCoaForLot (configured_coa_submit.dart) - the exact
  /// function _ensureCoaForCartLine calls fire-and-forget on a cart add; this page calls it directly against a
  /// lot you type in, so you can watch the whole GetPackagedProductInfo -> download -> parse-and-upload chain
  /// resolve (or fail) without needing a cart in the right state to trigger it.
  final Future<coa_data_client.CoaData?> Function({
    required String lotGuid,
    required int representativePackageId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    double? statePsilocybin,
  }) submitCoaForLot;

  /// Overridable for tests. Defaults to the real fetchLabel (label_client.dart) - lets you check, right after a
  /// submitCoaForLot run above, whether item 4's server-side auto-queued label has actually shown up yet for
  /// that same product.
  final Future<Uint8List> Function(int stateId, String guid) fetchLabel;

  /// Overridable for tests. Defaults to the real postSaleLog (sale_log_client.dart) - the same call CartPage._sell
  /// makes fire-and-forget after a confirmed sale.
  final Future<void> Function(int stateId,
      {required String workerEmail,
      required String deviceId,
      required List<Map<String, Object?>> request,
      required Object? response}) postSaleLog;

  /// Overridable for tests. Defaults to the real postSaleFailure (sale_failure_client.dart) - the same call
  /// CartPage._queueFailedSale makes fire-and-forget when a sale attempt is stopped by a SessionExpired.
  final Future<void> Function(int stateId,
      {required String workerEmail, required String deviceId, required String reason, required List<Map<String, Object?>> request})
      postSaleFailure;

  /// Overridable for tests, same pattern as every other page's own deviceIdStore field. Defaults to a real
  /// DeviceIdStore.
  final DeviceIdStore deviceIdStore;

  DebugBackgroundFeaturesPage({
    super.key,
    required this.session,
    this.initialStateId,
    Future<merged_inventory.MergedInventoryResult> Function(int, {required String accessToken})? fetchMergedInventory,
    Future<Map<String, Object?>> Function(int, List<Object?>, {required String workerEmail, required String deviceId})?
        uploadInventorySnapshot,
    Future<coa_data_client.CoaData?> Function({
      required String lotGuid,
      required int representativePackageId,
      required String accessToken,
      required String workerEmail,
      required String deviceId,
    double? statePsilocybin,
    })? submitCoaForLot,
    Future<Uint8List> Function(int, String)? fetchLabel,
    Future<void> Function(int,
            {required String workerEmail,
            required String deviceId,
            required List<Map<String, Object?>> request,
            required Object? response})?
        postSaleLog,
    Future<void> Function(int,
            {required String workerEmail, required String deviceId, required String reason, required List<Map<String, Object?>> request})?
        postSaleFailure,
    this.deviceIdStore = const DeviceIdStore(),
  })  : fetchMergedInventory = fetchMergedInventory ?? merged_inventory.fetchMergedInventory,
        uploadInventorySnapshot = uploadInventorySnapshot ?? inventory_upload_client.uploadInventorySnapshot,
        submitCoaForLot = submitCoaForLot ?? configured_coa_submit.submitCoaForLot,
        fetchLabel = fetchLabel ?? ((stateId, guid) => label_client.fetchLabel(stateId, guid)),
        postSaleLog = postSaleLog ?? sale_log_client.postSaleLog,
        postSaleFailure = postSaleFailure ?? sale_failure_client.postSaleFailure;

  @override
  State<DebugBackgroundFeaturesPage> createState() => _DebugBackgroundFeaturesPageState();
}

/// One on-demand action's own little status line, shared by every section below - just enough to say what
/// happened, not a build-up of history across runs (re-running always replaces whatever's showing).
class _Result {
  final bool ok;
  final String text;
  const _Result(this.ok, this.text);
}

class _DebugBackgroundFeaturesPageState extends State<DebugBackgroundFeaturesPage> {
  late final _stateIdController = TextEditingController(text: widget.initialStateId?.toString() ?? '');
  late final _lotGuidController = TextEditingController();
  late final _packageIdController = TextEditingController();
  late final _productGuidController = TextEditingController();

  String? _deviceId;
  bool _busyMerge = false, _busyPush = false, _busyCoa = false, _busyLabel = false, _busySaleLog = false, _busyFailure = false;
  _Result? _mergeResult, _pushResult, _coaResult, _labelResult, _saleLogResult, _failureResult;

  /// Set by a successful _runMerge, so _runPush (which needs the exact raw records that read just produced,
  /// same as _fetchMergedForCart's own real push) has something to send - pushing a snapshot that wasn't just
  /// read would test something real workers never actually do.
  List<Object?>? _lastRawStateRecords;

  @override
  void initState() {
    super.initState();
    widget.deviceIdStore.idOrCreate().then((id) {
      if (mounted) setState(() => _deviceId = id);
    });
  }

  @override
  void dispose() {
    _stateIdController.dispose();
    _lotGuidController.dispose();
    _packageIdController.dispose();
    _productGuidController.dispose();
    super.dispose();
  }

  int? get _stateId => int.tryParse(_stateIdController.text.trim());

  Future<void> _runMerge() async {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() => _mergeResult = const _Result(false, 'Enter a numeric state id first.'));
      return;
    }
    setState(() {
      _busyMerge = true;
      _mergeResult = null;
      _pushResult = null;
      _lastRawStateRecords = null;
    });
    try {
      final result = await widget.fetchMergedInventory(stateId, accessToken: widget.session.accessToken);
      _lastRawStateRecords = result.rawStateRecords;
      final needsWork = result.packages.where((p) => !p.coaAvailable || !p.labelAvailable).length;
      if (!mounted) return;
      setState(() => _mergeResult = _Result(
            true,
            'mazamaOk=${result.mazamaOk}, stateOk=${result.stateOk}. ${result.packages.length} merged package(s), '
            '$needsWork missing a COA/label. ${result.rawStateRecords == null ? "No raw state records to push (state read failed)." : "${result.rawStateRecords!.length} raw state record(s) ready to push below."}',
          ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _mergeResult = _Result(false, e.toString()));
    } finally {
      if (mounted) setState(() => _busyMerge = false);
    }
  }

  Future<void> _runPush() async {
    final stateId = _stateId;
    final records = _lastRawStateRecords;
    if (stateId == null || records == null) {
      setState(() => _pushResult = const _Result(false, 'Run "Fetch & merge" first - this pushes exactly what that just read.'));
      return;
    }
    setState(() {
      _busyPush = true;
      _pushResult = null;
    });
    try {
      final deviceId = await widget.deviceIdStore.idOrCreate();
      final resp =
          await widget.uploadInventorySnapshot(stateId, records, workerEmail: widget.session.email, deviceId: deviceId);
      if (!mounted) return;
      setState(() => _pushResult = _Result(true, 'Server applied it: $resp'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _pushResult = _Result(false, e.toString()));
    } finally {
      if (mounted) setState(() => _busyPush = false);
    }
  }

  Future<void> _runCoaSubmit() async {
    final lotGuid = _lotGuidController.text.trim();
    final packageId = int.tryParse(_packageIdController.text.trim());
    if (lotGuid.isEmpty || packageId == null) {
      setState(() => _coaResult = const _Result(false, 'Enter both a lot guid and a representative package id.'));
      return;
    }
    setState(() {
      _busyCoa = true;
      _coaResult = null;
    });
    try {
      final deviceId = await widget.deviceIdStore.idOrCreate();
      final data = await widget.submitCoaForLot(
        lotGuid: lotGuid,
        representativePackageId: packageId,
        accessToken: widget.session.accessToken,
        workerEmail: widget.session.email,
        deviceId: deviceId,
      );
      if (!mounted) return;
      setState(() => _coaResult = data == null
          ? const _Result(true, 'null - no accepted Potency-test PDF on file for this lot at the state system yet.')
          : _Result(
              true,
              'Parsed and uploaded: strain "${data.strain}", psilocybin ${data.psilocybin ?? 'unknown'} mg/g, psilocin '
              '${data.psilocin ?? 'unknown'} mg/g, tpe ${data.tpe?.toStringAsFixed(2) ?? 'unknown'} mg/g. Cached server-side for every worker/'
              'center, and a label should now be queued (item 4) - check with "Check label" below once you have this '
              "lot's own productGuid.",
            ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _coaResult = _Result(false, e.toString()));
    } finally {
      if (mounted) setState(() => _busyCoa = false);
    }
  }

  Future<void> _runLabelCheck() async {
    final stateId = _stateId;
    final guid = _productGuidController.text.trim();
    if (stateId == null || guid.isEmpty) {
      setState(() => _labelResult = const _Result(false, 'Enter a state id and a product guid.'));
      return;
    }
    setState(() {
      _busyLabel = true;
      _labelResult = null;
    });
    try {
      final bytes = await widget.fetchLabel(stateId, guid);
      if (!mounted) return;
      setState(() => _labelResult = _Result(true, 'Label found - ${bytes.length} bytes.'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _labelResult = _Result(false, e.toString()));
    } finally {
      if (mounted) setState(() => _busyLabel = false);
    }
  }

  List<Map<String, Object?>> get _fakeSaleRecords => [
        {'debug': true, 'note': 'synthetic record from DebugBackgroundFeaturesPage - never sent to the state system'}
      ];

  Future<void> _runSaleLog() async {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() => _saleLogResult = const _Result(false, 'Enter a numeric state id first.'));
      return;
    }
    setState(() {
      _busySaleLog = true;
      _saleLogResult = null;
    });
    try {
      final deviceId = await widget.deviceIdStore.idOrCreate();
      await widget.postSaleLog(
        stateId,
        workerEmail: widget.session.email,
        deviceId: deviceId,
        request: _fakeSaleRecords,
        response: {'debug': true},
      );
      if (!mounted) return;
      setState(() => _saleLogResult =
          const _Result(true, 'Posted - this really did add a row to this worker/device\'s confirmed-sale history on the server.'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saleLogResult = _Result(false, e.toString()));
    } finally {
      if (mounted) setState(() => _busySaleLog = false);
    }
  }

  Future<void> _runSaleFailure() async {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() => _failureResult = const _Result(false, 'Enter a numeric state id first.'));
      return;
    }
    setState(() {
      _busyFailure = true;
      _failureResult = null;
    });
    try {
      final deviceId = await widget.deviceIdStore.idOrCreate();
      await widget.postSaleFailure(
        stateId,
        workerEmail: widget.session.email,
        deviceId: deviceId,
        reason: '[debug] synthetic failure from DebugBackgroundFeaturesPage',
        request: _fakeSaleRecords,
      );
      if (!mounted) return;
      setState(() => _failureResult =
          const _Result(true, 'Posted - this really did queue a row on the server\'s /sale-review page for a human to look at.'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _failureResult = _Result(false, e.toString()));
    } finally {
      if (mounted) setState(() => _busyFailure = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final msLeft = session.expiresAtMs - DateTime.now().millisecondsSinceEpoch;
    return Scaffold(
      appBar: AppBar(title: const Text('Background features (debug)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section(
            title: 'Device & session',
            description: 'Read-only - what this install and session actually are right now, no network call.',
            children: [
              Text('Device id: ${_deviceId ?? "(loading...)"}'),
              Text('Worker email: ${session.email}'),
              Text(
                'Access token expires in ${(msLeft / 1000).round()}s'
                '${session.needsRenewal() ? " - already past the renewal margin, the next real call will renew it first" : ""}.',
              ),
            ],
          ),
          const Divider(height: 32),
          _section(
            title: 'Merged inventory (items 2 & 3a)',
            description: 'The exact fetchMergedInventory/uploadInventorySnapshot calls CartPage makes silently '
                'on every load of a configured center\'s cart.',
            children: [
              TextField(
                controller: _stateIdController,
                decoration: const InputDecoration(labelText: 'Service center state id', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busyMerge ? null : _runMerge,
                child: _busyMerge ? const Text('Fetching...') : const Text('Fetch & merge'),
              ),
              if (_mergeResult != null) _resultText(_mergeResult!),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busyPush || _lastRawStateRecords == null ? null : _runPush,
                child: _busyPush ? const Text('Pushing...') : const Text('Push this snapshot to mazama_sales now'),
              ),
              if (_pushResult != null) _resultText(_pushResult!),
            ],
          ),
          const Divider(height: 32),
          _section(
            title: 'Submit a lot\'s COA (item 3b)',
            description: 'The exact submitCoaForLot call CartPage makes fire-and-forget when a cart add finds no '
                'COA/label on file yet - run it directly against any lot, whether or not it\'s actually in a cart.',
            children: [
              TextField(
                controller: _lotGuidController,
                decoration: const InputDecoration(labelText: 'Lot guid (harvestBatchGuid or processLotGuid)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _packageIdController,
                decoration:
                    const InputDecoration(labelText: 'Representative package id (any package in that lot)', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busyCoa ? null : _runCoaSubmit,
                child: _busyCoa ? const Text('Submitting...') : const Text('Submit via submitCoaForLot'),
              ),
              if (_coaResult != null) _resultText(_coaResult!),
            ],
          ),
          const Divider(height: 32),
          _section(
            title: 'Check for a label (item 4)',
            description: 'mazama_sales auto-queues a label once a COA parse succeeds - run this right after the '
                'submission above to see whether it has actually shown up yet (uses the state id above).',
            children: [
              TextField(
                controller: _productGuidController,
                decoration: const InputDecoration(labelText: 'Product guid', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busyLabel ? null : _runLabelCheck,
                child: _busyLabel ? const Text('Checking...') : const Text('Check label'),
              ),
              if (_labelResult != null) _resultText(_labelResult!),
            ],
          ),
          const Divider(height: 32),
          _section(
            title: 'Sale-log / sale-failure posts',
            description: 'The exact postSaleLog/postSaleFailure calls CartPage makes fire-and-forget after a '
                'confirmed sale or a sign-in failure mid-sale. These write REAL rows to the server (confirmed-sale '
                'history / the /sale-review queue) using a synthetic sale record - use a test center\'s state id, '
                'not a real one, unless you mean to add this to its real history.',
            children: [
              FilledButton(
                onPressed: _busySaleLog ? null : _runSaleLog,
                child: _busySaleLog ? const Text('Posting...') : const Text('Send test sale-log'),
              ),
              if (_saleLogResult != null) _resultText(_saleLogResult!),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busyFailure ? null : _runSaleFailure,
                child: _busyFailure ? const Text('Posting...') : const Text('Send test sale-failure'),
              ),
              if (_failureResult != null) _resultText(_failureResult!),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section({required String title, required String description, required List<Widget> children}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(description, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }

  Widget _resultText(_Result r) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          r.text,
          style: TextStyle(color: r.ok ? Colors.green[800] : Colors.red[800]),
        ),
      );
}
