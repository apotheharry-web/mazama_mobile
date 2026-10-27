// A debug-only raw-data browser: three independent on-demand fetches, each run and shown exactly as the app
// itself would see it, with nothing merged or filtered first - unlike debug_background_features_page.dart's
// "Merged inventory" section (which specifically exercises the merge), this is for answering "what does each
// side actually say, on its own" when the two disagree and you need to know which one is wrong.
//
// Only ever reachable from a kDebugMode build - see debug_tools_page.dart, which is what links to this.
import 'package:flutter/material.dart';

import 'licenses_client.dart' as licenses_client;
import 'packages_client.dart' as packages_client;
import 'session.dart';
import 'state_packages_client.dart' as state_packages_client;

class DebugStateDataPage extends StatefulWidget {
  final Session session;

  /// Pre-fills the state-id field, same convenience as every other debug page's own initialStateId.
  final int? initialStateId;

  /// Overridable for tests. Defaults to the real fetchApplicableLicenses (licenses_client.dart) - the exact
  /// call SelectCenterPage makes, but shown here unfiltered (every license, ServiceCenter or Manufacturer
  /// alike - SelectCenterPage only ever shows the former).
  final Future<List<licenses_client.License>> Function(String accessToken) fetchApplicableLicenses;

  /// Overridable for tests. Defaults to the real fetchPackages (packages_client.dart) - mazama_sales' own
  /// mirror's view of a center's inventory.
  final Future<List<packages_client.Package>> Function(int stateId) fetchPackages;

  /// Overridable for tests. Defaults to the real fetchPackagesFromState (state_packages_client.dart) - the
  /// state system's own live view of the same center's inventory, mapped into the same Package shape so the
  /// two are directly comparable.
  final Future<List<packages_client.Package>> Function(int stateId, {required String accessToken}) fetchPackagesFromState;

  DebugStateDataPage({
    super.key,
    required this.session,
    this.initialStateId,
    Future<List<licenses_client.License>> Function(String)? fetchApplicableLicenses,
    Future<List<packages_client.Package>> Function(int)? fetchPackages,
    Future<List<packages_client.Package>> Function(int, {required String accessToken})? fetchPackagesFromState,
  })  : fetchApplicableLicenses = fetchApplicableLicenses ?? licenses_client.fetchApplicableLicenses,
        fetchPackages = fetchPackages ?? packages_client.fetchPackages,
        fetchPackagesFromState = fetchPackagesFromState ?? state_packages_client.fetchPackagesFromState;

  @override
  State<DebugStateDataPage> createState() => _DebugStateDataPageState();
}

class _DebugStateDataPageState extends State<DebugStateDataPage> {
  late final _stateIdController = TextEditingController(text: widget.initialStateId?.toString() ?? '');

  bool _busyLicenses = false, _busyMazama = false, _busyState = false;
  List<String>? _licenseLines;
  String? _licenseError;
  List<String>? _mazamaLines;
  String? _mazamaError;
  List<String>? _stateLines;
  String? _stateError;

  @override
  void dispose() {
    _stateIdController.dispose();
    super.dispose();
  }

  int? get _stateId => int.tryParse(_stateIdController.text.trim());

  String _describe(packages_client.Package p) =>
      '${p.productGuid} (id ${p.id}) - ${p.productType}, qty ${p.quantity}, strain "${p.strain}", '
      '${p.tpeMg}mg TPE, lot ${p.lotGuid ?? "(none)"}, coaAvailable=${p.coaAvailable}, labelAvailable=${p.labelAvailable}';

  Future<void> _runLicenses() async {
    setState(() {
      _busyLicenses = true;
      _licenseLines = null;
      _licenseError = null;
    });
    try {
      final licenses = await widget.fetchApplicableLicenses(widget.session.accessToken);
      if (!mounted) return;
      setState(() => _licenseLines = [
            for (final l in licenses) '${l.id} - ${l.licenseName} (${l.licenseType}, ${l.licenseId})',
          ]);
    } catch (e) {
      if (!mounted) return;
      setState(() => _licenseError = e.toString());
    } finally {
      if (mounted) setState(() => _busyLicenses = false);
    }
  }

  Future<void> _runMazama() async {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() => _mazamaError = 'Enter a numeric state id first.');
      return;
    }
    setState(() {
      _busyMazama = true;
      _mazamaLines = null;
      _mazamaError = null;
    });
    try {
      final packages = await widget.fetchPackages(stateId);
      if (!mounted) return;
      setState(() => _mazamaLines = packages.map(_describe).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _mazamaError = e.toString());
    } finally {
      if (mounted) setState(() => _busyMazama = false);
    }
  }

  Future<void> _runState() async {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() => _stateError = 'Enter a numeric state id first.');
      return;
    }
    setState(() {
      _busyState = true;
      _stateLines = null;
      _stateError = null;
    });
    try {
      final packages = await widget.fetchPackagesFromState(stateId, accessToken: widget.session.accessToken);
      if (!mounted) return;
      setState(() => _stateLines = packages.map(_describe).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _stateError = e.toString());
    } finally {
      if (mounted) setState(() => _busyState = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('State data browser (debug)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Licenses (GetApplicableLicenses)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Every license this signed-in account holds, unfiltered - SelectCenterPage only ever shows '
              'the ServiceCenter ones.'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busyLicenses ? null : _runLicenses,
            child: _busyLicenses ? const Text('Fetching...') : const Text('Fetch licenses'),
          ),
          if (_licenseError != null) _errorText(_licenseError!),
          if (_licenseLines != null) _lines(_licenseLines!, 'No licenses on this account.'),
          const Divider(height: 32),
          Text('Service center state id', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _stateIdController,
            decoration: const InputDecoration(labelText: 'Service center state id', border: OutlineInputBorder()),
            keyboardType: TextInputType.number,
          ),
          const Divider(height: 32),
          Text("mazama_sales' own mirror (GET /p/packages)", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busyMazama ? null : _runMazama,
            child: _busyMazama ? const Text('Fetching...') : const Text('Fetch mazama packages'),
          ),
          if (_mazamaError != null) _errorText(_mazamaError!),
          if (_mazamaLines != null) _lines(_mazamaLines!, 'No packages (or not a configured center).'),
          const Divider(height: 32),
          Text('The state system directly (GetPackagedProducts)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busyState ? null : _runState,
            child: _busyState ? const Text('Fetching...') : const Text('Fetch state packages'),
          ),
          if (_stateError != null) _errorText(_stateError!),
          if (_stateLines != null) _lines(_stateLines!, 'No packages at the state system for this center.'),
        ],
      ),
    );
  }

  Widget _errorText(String text) =>
      Padding(padding: const EdgeInsets.only(top: 8), child: Text(text, style: TextStyle(color: Colors.red[800])));

  Widget _lines(List<String> lines, String emptyText) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${lines.length} result(s).', style: Theme.of(context).textTheme.bodySmall),
            if (lines.isEmpty) Text(emptyText) else for (final l in lines) Text(l),
          ],
        ),
      );
}
