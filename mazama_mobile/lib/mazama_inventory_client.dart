// Mazama's own stock mix for the Mazama inventory page (specs/mazama-inventory MI-R2): GET /p/mazama-inventory (C12),
// the manufacturer's public page mix summed per strain and type. Contract: ../mazama_modules/api/routes.yaml, schema
// mazama_inventory.response, vendored example at assets/shared/api/examples/ (test/mazama_inventory_client_test.dart).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;
import 'stock_mix.dart';

/// A request for Mazama's mix that failed; [message] is the server's own `detail` when it sent one. [unreachable]: the
/// server couldn't be reached (server_error.dart's rule).
class MazamaInventoryError implements ServerRequestError {
  @override
  final String message;
  @override
  final bool unreachable;
  MazamaInventoryError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}

/// The minor analytes a lot's lab report can show (specs/mazama-inventory MI-D13), in the order the server lists them.
const minorAnalytes = ['baeocystin', 'norbaeocystin', 'norpsilocin', 'aeruginascin'];

/// One batch or lot behind Mazama's stock, for the page's lot table (MI-R7): its potency in mg per gram (null when
/// unknown) and the minor analytes its lab report found.
class MazamaLot {
  final String strain;
  final String lot;
  final num? tpe;
  final num? psilocybin;
  final num? psilocin;
  final List<String> detected;

  /// Its public product information sheet on the server ("/p/lots/mazama/HB-…", MI-D18); null when the public may not
  /// see one, or the server is from before MI-D18, or in demo mode.
  final String? path;

  /// The type codes of what is held of it (FD, DH, WF, LOT, ..., '' unknown), for the By type pie's filter (MI-D20).
  final List<String> types;

  const MazamaLot(
      {required this.strain,
      required this.lot,
      this.tpe,
      this.psilocybin,
      this.psilocin,
      this.detected = const [],
      this.path,
      this.types = const []});

  /// The sheet's address on [baseUrl]; null when there is no sheet to open.
  Uri? url({String baseUrl = apiBaseUrl}) => path == null ? null : Uri.parse('$baseUrl$path');

  factory MazamaLot.fromJson(Map<String, Object?> j) {
    final strain = j['strain'];
    final lot = j['lot'];
    final detected = j['detected'] ?? const [];
    final nums = [j['tpe'], j['psilocybin'], j['psilocin']];
    final path = j['path'];
    final types = j['types'] ?? const [];
    if (strain is! String || lot is! String || detected is! List || detected.any((d) => d is! String) ||
        nums.any((n) => n != null && n is! num) || (path != null && path is! String) || types is! List ||
        types.any((t) => t is! String)) {
      throw MazamaInventoryError('unexpected response shape');
    }
    return MazamaLot(
        strain: strain,
        lot: lot,
        tpe: nums[0] as num?,
        psilocybin: nums[1] as num?,
        psilocin: nums[2] as num?,
        detected: detected.cast<String>(),
        path: path as String?,
        types: types.cast<String>());
  }

  Map<String, Object?> toJson() => {
        'strain': strain,
        'lot': lot,
        'tpe': tpe,
        'psilocybin': psilocybin,
        'psilocin': psilocin,
        'detected': detected,
        'types': types,
        'path': path
      };
}

/// The manufacturer's name, its mix cells and its lots, as route C12 answers. A server from before MI-R7 sends no
/// lots: the table is then empty, the pies as they were.
class MazamaInventory {
  final String name;
  final List<MixCell> cells;
  final List<MazamaLot> lots;

  const MazamaInventory({required this.name, required this.cells, this.lots = const []});

  factory MazamaInventory.fromJson(Map<String, Object?> j) {
    final name = j['name'];
    final cells = j['cells'];
    final lots = j['lots'] ?? const [];
    if (name is! String || cells is! List || cells.any((c) => c is! Map) || lots is! List || lots.any((l) => l is! Map)) {
      throw MazamaInventoryError('unexpected response shape');
    }
    return MazamaInventory(
        name: name,
        cells: [for (final c in cells) MixCell.fromJson(Map<String, Object?>.from(c as Map))],
        lots: [for (final l in lots) MazamaLot.fromJson(Map<String, Object?>.from(l as Map))]);
  }

  /// As route C12 sends it, so the copy kept on the phone (the mazama_inventory dataset) reads back through [fromJson].
  Map<String, Object?> toJson() => {
        'name': name,
        'cells': [for (final c in cells) c.toJson()],
        'lots': [for (final l in lots) l.toJson()],
      };
}

/// Mazama's mix (C12). Throws [MazamaInventoryError].
Future<MazamaInventory> fetchMazamaInventory({String baseUrl = apiBaseUrl, http.Client? client}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${mazamaInventoryPath()}');
    http.Response resp;
    try {
      resp = await c.get(uri, headers: appApiKeyHeaders).timeout(serverReadTimeout);
    } catch (ex) {
      throw MazamaInventoryError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode != 200) {
      throw MazamaInventoryError(describeServerError(resp.statusCode, resp.body),
          unreachable: isUnreachableStatus(resp.statusCode));
    }
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw MazamaInventoryError('the server did not answer with JSON');
    }
    if (body is! Map) throw MazamaInventoryError('unexpected response shape');
    return MazamaInventory.fromJson(Map<String, Object?>.from(body));
  } finally {
    if (shouldClose) c.close();
  }
}
