// A debug-only shortcut straight into CartPage for ANY service center's own state id, bypassing
// SelectCenterPage's own license picker entirely - normally the only way to reach a center's cart at all is
// for the signed-in account to actually hold a ServiceCenter license for it (licenses_client.dart's
// fetchApplicableLicenses). That's exactly right for a real worker, but it means testing a second, third, or
// not-yet-licensed-to-this-account center means either signing in as someone else or waiting for the state
// system to actually grant the license - neither of which is a reasonable thing to ask of a developer just
// trying to check a config change. This page opens the exact same CartPage a real worker would land on, built
// from whatever state id is typed in, with a placeholder License standing in for the real one
// GetApplicableLicenses would have supplied.
//
// Only ever reachable from a kDebugMode build - see debug_tools_page.dart, which is what links to this.
import 'package:flutter/material.dart';

import 'cart_page.dart';
import 'coa_data_client.dart' as coa_data_client;
import 'flow/flow_spec.dart';
import 'licenses_client.dart';
import 'session.dart';
import 'session_store.dart';

class DebugLaunchCartPage extends StatefulWidget {
  final Session session;
  final FlowSpec spec;
  final SessionStore sessionStore;

  /// Pre-fills the state-id field, same convenience as every other debug page's own initialStateId.
  final int? initialStateId;

  /// Overridable for tests. Defaults to the real centerIsConfigured (coa_data_client.dart) - lets you check
  /// up front, before opening a real CartPage, whether mazama_sales actually tracks this center at all (a
  /// CartPage opened for an unconfigured center still works - it just runs the adhoc-COA path throughout -
  /// but knowing which one you're about to get is worth a quick check first).
  final Future<bool> Function(int stateId) centerIsConfigured;

  DebugLaunchCartPage({
    super.key,
    required this.session,
    required this.spec,
    required this.sessionStore,
    this.initialStateId,
    Future<bool> Function(int)? centerIsConfigured,
  }) : centerIsConfigured = centerIsConfigured ?? coa_data_client.centerIsConfigured;

  @override
  State<DebugLaunchCartPage> createState() => _DebugLaunchCartPageState();
}

class _DebugLaunchCartPageState extends State<DebugLaunchCartPage> {
  late final _stateIdController = TextEditingController(text: widget.initialStateId?.toString() ?? '');
  late final _nameController = TextEditingController();

  bool _checking = false;
  String? _statusText;

  @override
  void dispose() {
    _stateIdController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  int? get _stateId => int.tryParse(_stateIdController.text.trim());

  Future<void> _checkStatus() async {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() => _statusText = 'Enter a numeric state id first.');
      return;
    }
    setState(() {
      _checking = true;
      _statusText = null;
    });
    try {
      final configured = await widget.centerIsConfigured(stateId);
      if (!mounted) return;
      setState(() => _statusText = configured
          ? 'mazama_sales tracks this center - CartPage will use its normal tier-1 inventory path.'
          : 'mazama_sales does NOT track this center yet - CartPage will fall back to the adhoc-COA path '
              'throughout, the same as a real brand-new center would.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusText = 'Could not check: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _openCart() {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() => _statusText = 'Enter a numeric state id first.');
      return;
    }
    final name = _nameController.text.trim();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CartPage(
        session: widget.session,
        // A stand-in for the real License GetApplicableLicenses would have supplied - CartPage only ever
        // reads center.id (every network call is keyed by the state id, never licenseId/licenseName/
        // licenseType) and shows center.licenseName in its own AppBar title, so this is enough to make a real
        // CartPage behave exactly as it would for a worker who really held this license.
        center: License(
          id: stateId,
          licenseId: 'DEBUG',
          licenseName: name.isEmpty ? 'Debug center $stateId' : name,
          licenseType: 'ServiceCenter',
        ),
        spec: widget.spec,
        sessionStore: widget.sessionStore,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Launch cart by state id (debug)')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Opens the real CartPage for any service center\'s own state id, whether or not this signed-in '
              "account actually holds a license for it - skips SelectCenterPage's own license picker entirely.",
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _stateIdController,
              decoration: const InputDecoration(labelText: 'Service center state id', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Display name (optional - shown in the cart\'s own AppBar)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _checking ? null : _checkStatus,
              child: _checking ? const Text('Checking...') : const Text('Check center status first'),
            ),
            if (_statusText != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_statusText!)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _openCart, child: const Text('Open cart')),
          ],
        ),
      ),
    );
  }
}
