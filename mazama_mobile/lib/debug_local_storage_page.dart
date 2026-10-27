// A debug-only inspector for everything this app persists to disk (cart_store.dart/inventory_cache_store.dart/
// session_store.dart/device_id.dart) - all four are deliberately silent about their own contents in normal
// use (a worker never needs to know there's a cart.json or where it lives), which makes "did that save
// actually happen" and "why is this stale data still showing" hard to answer without this. Also the one place
// to deliberately reset any of them - simulating a fresh install, a cleared cart, or a dropped session without
// actually uninstalling the app or waiting out a real expiry.
//
// Only ever reachable from a kDebugMode build - see debug_tools_page.dart, which is what links to this.
import 'package:flutter/material.dart';

import 'cart_store.dart';
import 'device_id.dart';
import 'inventory_cache_store.dart';
import 'session_store.dart';

class DebugLocalStoragePage extends StatefulWidget {
  /// Pre-fills the state-id field used to look up the cart/inventory-cache stores, which are both keyed by
  /// centerId - same convenience as every other debug page's own initialStateId.
  final int? initialStateId;

  /// Overridable for tests, same pattern as every other page's own *Store fields. Defaults to the real stores.
  final SessionStore sessionStore;
  final CartStore cartStore;
  final InventoryCacheStore inventoryCacheStore;
  final DeviceIdStore deviceIdStore;

  const DebugLocalStoragePage({
    super.key,
    this.initialStateId,
    this.sessionStore = const SessionStore(),
    this.cartStore = const CartStore(),
    this.inventoryCacheStore = const InventoryCacheStore(),
    this.deviceIdStore = const DeviceIdStore(),
  });

  @override
  State<DebugLocalStoragePage> createState() => _DebugLocalStoragePageState();
}

class _DebugLocalStoragePageState extends State<DebugLocalStoragePage> {
  late final _stateIdController = TextEditingController(text: widget.initialStateId?.toString() ?? '');

  String? _sessionText;
  String? _cartText;
  String? _inventoryCacheText;
  String? _deviceIdText;

  @override
  void initState() {
    super.initState();
    _reloadAll();
  }

  @override
  void dispose() {
    _stateIdController.dispose();
    super.dispose();
  }

  int? get _stateId => int.tryParse(_stateIdController.text.trim());

  Future<void> _reloadAll() async {
    await Future.wait([_reloadSession(), _reloadCart(), _reloadInventoryCache(), _reloadDeviceId()]);
  }

  Future<void> _reloadSession() async {
    final stored = await widget.sessionStore.load();
    if (!mounted) return;
    setState(() => _sessionText = stored == null
        ? 'Nothing stored.'
        : 'email: ${stored['email']}, expires_at_ms: ${stored['expires_at_ms']}, '
            'has access_token: ${(stored['access_token'] as String?)?.isNotEmpty == true}, '
            'has refresh_token: ${(stored['refresh_token'] as String?)?.isNotEmpty == true}');
  }

  Future<void> _reloadCart() async {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() => _cartText = 'Enter a state id above to check for a saved cart draft for that center.');
      return;
    }
    final lines = await widget.cartStore.load(stateId);
    if (!mounted) return;
    setState(() => _cartText = lines == null
        ? 'Nothing stored for center $stateId (either empty, or the saved draft belongs to a different center).'
        : '${lines.length} line(s) for center $stateId: '
            '${lines.map((l) => '${l.productGuid} x${l.qty}@${l.priceCentsEach}c').join(', ')}');
  }

  Future<void> _reloadInventoryCache() async {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() => _inventoryCacheText = 'Enter a state id above to check for a cached inventory for that center.');
      return;
    }
    final cached = await widget.inventoryCacheStore.load(stateId);
    if (!mounted) return;
    setState(() => _inventoryCacheText = cached == null
        ? 'Nothing stored for center $stateId.'
        : '${cached.packages.length} package(s) for center $stateId, fetched at ${cached.fetchedAt.toIso8601String()}');
  }

  Future<void> _reloadDeviceId() async {
    final id = await widget.deviceIdStore.idOrCreate();
    if (!mounted) return;
    setState(() => _deviceIdText = id);
  }

  Future<void> _clearSession() async {
    await widget.sessionStore.clear();
    await _reloadSession();
  }

  Future<void> _clearCart() async {
    await widget.cartStore.clear();
    await _reloadCart();
  }

  Future<void> _clearInventoryCache() async {
    await widget.inventoryCacheStore.clear();
    await _reloadInventoryCache();
  }

  Future<void> _resetDeviceId() async {
    await widget.deviceIdStore.reset();
    await _reloadDeviceId();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Local storage (debug)'), actions: [
        IconButton(icon: const Icon(Icons.refresh), tooltip: 'Reload everything', onPressed: _reloadAll),
      ]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _stateIdController,
            decoration: const InputDecoration(
              labelText: 'Service center state id (for the cart draft / inventory cache below)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (_) {
              _reloadCart();
              _reloadInventoryCache();
            },
          ),
          const Divider(height: 32),
          _section(
            title: 'Session (session.json)',
            text: _sessionText,
            onClear: _clearSession,
            clearLabel: 'Clear session (forces a real sign-in on next app start)',
          ),
          const Divider(height: 32),
          _section(
            title: 'Cart draft (cart.json)',
            text: _cartText,
            onClear: _clearCart,
            clearLabel: 'Clear cart draft',
          ),
          const Divider(height: 32),
          _section(
            title: 'Inventory cache (inventory_cache.json)',
            text: _inventoryCacheText,
            onClear: _clearInventoryCache,
            clearLabel: 'Clear inventory cache',
          ),
          const Divider(height: 32),
          _section(
            title: 'Device id (device_id.txt)',
            text: _deviceIdText,
            onClear: _resetDeviceId,
            clearLabel: 'Reset device id (simulates a fresh install)',
          ),
        ],
      ),
    );
  }

  Widget _section({required String title, required String? text, required VoidCallback onClear, required String clearLabel}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(text ?? 'Loading...'),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: onClear, child: Text(clearLabel)),
      ],
    );
  }
}
