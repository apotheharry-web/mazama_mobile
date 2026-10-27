// Demo mode (specs/demo-mode, DM-R1): everything the center pages take as a constructor function, answered from
// invented data shipped in the app (assets/demo/demo.json, label.png) instead of the state system or the Mazama
// server. Signing in as guest / guest (main.dart) opens SelectCenterPage.demo with one of these; from then on no page
// reached from it makes a network call (DM-D1). The sale runs the real `sale` flow against [saleClient], a MockClient
// that confirms it, so the cart's own success path is what a reviewer sees; nothing a sale does changes the demo
// stock (DM-D4): every load answers the same packages. Par edits last as long as this backend (the demo session).
//
// The raw records are the state's own GetPackagedProducts shape (state_packages_client.dart), so the merged-inventory
// path, the stock page and the cart's stock re-check run unchanged. Package ids are PKPR-DEMO…: the app's package-id
// rule accepts them (PKPR- and 4 to 16 letters or digits), the state never issues them (its ids are lower-case hex).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import '../cart_slots.dart';
import '../cart_store.dart';
import '../center_status_client.dart';
import '../coa_data_client.dart';
import '../coa_data_resolver.dart';
import '../device_id.dart';
import '../enrichment_store.dart';
import '../inventory_cache_store.dart';
import '../label_client.dart';
import '../licenses_client.dart';
import '../mazama_inventory_client.dart';
import '../order_client.dart';
import '../packages_client.dart';
import '../scan_match_client.dart';
import '../sheets_client.dart';
import '../session.dart';
import '../session_timer_store.dart';
import '../state_packages_client.dart';
import '../stock_cache_store.dart';
import '../stock_summary.dart';

/// The demo center's state id: far outside the state's real license ids.
const int demoStateId = 999999;

class DemoBackend {
  DemoBackend(this._data, this._label, {Directory? dataDir})
      : dataDir = dataDir ?? Directory.systemTemp.createTempSync('mazama_demo_') {
    _par = [for (final l in _data['par'] as List) ParLevel.fromJson(Map<String, Object?>.from(l as Map))];
  }

  /// assets/demo/demo.json and label.png from [bundle].
  static Future<DemoBackend> load(AssetBundle bundle, {Directory? dataDir}) async {
    final data = jsonDecode(await bundle.loadString('assets/demo/demo.json')) as Map<String, Object?>;
    final label = (await bundle.load('assets/demo/label.png')).buffer.asUint8List();
    return DemoBackend(data, label, dataDir: dataDir);
  }

  final Map<String, Object?> _data;
  final Uint8List _label;
  late List<ParLevel> _par;

  /// Where the demo's local stores (cart draft, caches, device id) live: a folder of its own, never the real app's.
  final Directory dataDir;

  CartStore get cartStore => CartStore(dataDir: () => dataDir);
  SessionTimerStore get sessionTimerStore => SessionTimerStore(dataDir: () => dataDir);
  CartSlotsStore get cartSlotsStore => CartSlotsStore(dataDir: () => dataDir);
  InventoryCacheStore get inventoryCacheStore => InventoryCacheStore(dataDir: () => dataDir);
  EnrichmentStore get enrichmentStore => EnrichmentStore(dataDir: () => dataDir);
  DeviceIdStore get deviceIdStore => DeviceIdStore(dataDir: () => dataDir);
  StockCacheStore get stockCacheStore => StockCacheStore(dataDir: () => dataDir);

  /// The demo sign-in's session: never saved, never renewed (DM-D6, DM-R4).
  Session get session => Session.demo();

  License get center => License.fromJson(Map<String, Object?>.from(_data['center'] as Map));

  List<Map<String, Object?>> get _packages => [for (final p in _data['packages'] as List) Map<String, Object?>.from(p as Map)];

  void _checkCenter(int stateId) {
    if (stateId != demoStateId) throw PackagesError('no service center with id $stateId', status: 404);
  }

  // --- SelectCenterPage ------------------------------------------------------------------------------------------

  Future<List<License>> fetchLicenses(String accessToken) async => [center];

  /// /p/packages: every package the server would sell (the locked one is left out, SP-D9), with its fields.
  Future<List<Package>> fetchPackages(int stateId) async {
    _checkCenter(stateId);
    return [
      for (final p in _packages)
        if (p['locked'] != true)
          Package.fromJson({
            ...p,
            'mazama': _mazamaLicenses.contains((p['manufacturerLicenseId'] as String).toLowerCase()),
            'coaAvailable': true,
            'labelAvailable': true,
          }),
    ];
  }

  /// GetPackagedProducts: every package as the state lists it (the locked one included).
  Future<List<Object?>> fetchRawPackagesFromState(int stateId, {required String accessToken}) async {
    _checkCenter(stateId);
    return [
      for (final p in _packages)
        {
          'id': p['id'],
          'productGuid': p['productGuid'],
          'productType': p['productType'],
          'description': p['description'],
          'quantity': p['quantity'],
          'weightPerUnit': p['weightPerUnit'],
          'analyteWeight': p['analyteWeight'],
          'manufacturerLicenseId': p['manufacturerLicenseId'],
          'serviceCenterId': stateId,
          'locked': p['locked'] == true,
          'reasonLocked': p['reasonLocked'] ?? '',
          'flagged': false,
          'pendingTransfer': false,
          'zeroOut': false,
        },
    ];
  }

  Future<List<Package>> fetchPackagesFromState(int stateId, {required String accessToken}) async =>
      mapRawPackagesFromState(await fetchRawPackagesFromState(stateId, accessToken: accessToken));

  Future<Map<String, Object?>> uploadInventorySnapshot(int stateId, List<Object?> records,
          {required String workerEmail, required String deviceId}) async =>
      {'demo': true, 'records': records.length};

  /// The demo has no server to catch up with (README R56): a lot is never kept for later.
  void keepCoaLotForLater(int stateId, {required String lotGuid, required int packageId, double? statePsilocybin}) {}

  /// The invented lab report of the package [representativePackageId] (DM-R2).
  Future<CoaData?> submitCoaForLot({
    required String lotGuid,
    required int representativePackageId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    double? statePsilocybin,
  }) async {
    for (final p in _packages) {
      if (p['id'] == representativePackageId) return coaFor(p['productGuid'] as String);
    }
    return null;
  }

  /// The invented lab report for package [guid], or null.
  CoaData? coaFor(String guid) {
    for (final p in _packages) {
      if (p['productGuid'] != guid) continue;
      final coa = Map<String, Object?>.from(p['coa'] as Map);
      return CoaData.fromJson(guid, {...coa, 'strain': p['strain']});
    }
    return null;
  }

  /// The stock page's product information sheets (specs/stock-page SP-D11): invented, with no page to open (DM-D1).
  Future<List<ProductSheet>> fetchProductSheets(int stateId) async {
    _checkCenter(stateId);
    return [for (final s in _data['sheets'] as List) ProductSheet.fromJson(Map<String, Object?>.from(s as Map))];
  }

  int _orders = 1000;

  /// The Mazama inventory page's order form (specs/mazama-inventory MI-R6): an invented number, nothing sent (DM-D1).
  Future<OrderReceipt> submitOrder(int stateId,
      {required String workerEmail, required String deviceId, required List<OrderLine> lines, required String note}) async {
    _checkCenter(stateId);
    _orders++;
    return OrderReceipt(id: _orders, center: 'demo', lines: lines, note: note);
  }

  /// The Mazama inventory page's mix (specs/mazama-inventory MI-R3): invented, the same on every load.
  Future<MazamaInventory> fetchMazamaInventory() async =>
      MazamaInventory.fromJson(Map<String, Object?>.from(_data['mazamaInventory'] as Map));

  Future<List<ParLevel>> fetchParLevels(int stateId) async {
    _checkCenter(stateId);
    return List.of(_par);
  }

  /// As POST /p/par: changes only the levels listed; a null par removes one.
  Future<List<ParLevel>> saveParLevels(int stateId,
      {required String workerEmail, required String deviceId, required List<ParLevel> levels}) async {
    _checkCenter(stateId);
    String key(ParLevel l) => '${l.strain.toLowerCase()}|${l.size}';
    final byKey = {for (final l in _par) key(l): l};
    for (final l in levels) {
      if (l.par == null) {
        byKey.remove(key(l));
      } else {
        byKey[key(l)] = l;
      }
    }
    _par = byKey.values.toList()
      ..sort((a, b) {
        final c = a.strain.toLowerCase().compareTo(b.strain.toLowerCase());
        return c != 0 ? c : stockParColumns.indexOf(a.size).compareTo(stockParColumns.indexOf(b.size)); // the server's order
      });
    return List.of(_par);
  }

  List<String> get _mazamaLicenses => [for (final l in _data['mazamaLicenses'] as List) '$l'];

  Future<List<String>> fetchMazamaLicenses(int stateId) async => _mazamaLicenses;

  // --- CartPage --------------------------------------------------------------------------------------------------

  Future<bool> centerIsConfigured(int stateId) async => true;

  Future<CartSettings> fetchCartSettings(int stateId) async => CartSettings.fromJson(_data['cart']);

  Future<AdhocInventoryResult> resolveAdhocInventory({
    required int stateId,
    required String accessToken,
    required String workerEmail,
    required String deviceId,
    void Function(List<Package> packages)? onInventoryLoaded,
    void Function(String guid, Package updated)? onResolved,
  }) async {
    final packages = await fetchPackages(stateId);
    onInventoryLoaded?.call(packages);
    return AdhocInventoryResult(packages: packages, guidsTotal: packages.length, guidsResolved: packages.length);
  }

  /// The one sample label picture, for every demo package.
  Future<Uint8List> fetchLabel(int stateId, String guid) async {
    if (stateId != demoStateId || !_packages.any((p) => p['productGuid'] == guid)) {
      throw LabelError('no label for $guid in the demo');
    }
    return _label;
  }

  Future<void> postSaleLog(int stateId,
      {required String workerEmail, required String deviceId, required List<Map<String, Object?>> request, required Object? response}) async {}

  Future<void> postSaleFailure(int stateId,
      {required String workerEmail, required String deviceId, required String reason, required List<Map<String, Object?>> request}) async {}

  /// The scan matcher: a demo package id read anywhere in the lines (with or without PKPR-).
  Future<ScanMatchResult> scanMatch(int stateId, List<String> lines, {bool typed = false}) async {
    final matches = <ScanMatch>[];
    final seen = <String>{};
    for (final line in lines) {
      for (final p in _packages) {
        final guid = p['productGuid'] as String;
        final short = guid.substring('PKPR-'.length);
        if (line.toUpperCase().contains(short) && seen.add(guid)) {
          matches.add(ScanMatch(
              guid: guid,
              name: p['description'] as String,
              dist: 0,
              line: line,
              stock: p['quantity'] as int,
              sellable: p['locked'] != true));
        }
      }
    }
    return ScanMatchResult(matches: matches, guesses: const []);
  }

  /// The client the cart's sale runs through: it confirms CreateSalesRecords with one demo sale number for every
  /// record sent, and refuses anything else. It never reaches the network, and a sale never changes demo stock.
  http.Client saleClient() => http_testing.MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/CreateSalesRecords/false')) {
          final records = jsonDecode(request.body);
          final n = records is List ? records.length : 0;
          return http.Response(
              jsonEncode([for (var i = 0; i < n; i++) {'id': 990900 + i, 'saleNumber': 'DEMO-SALE-0001'}]), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{"detail": "not part of the demo"}', 404);
      });
}
