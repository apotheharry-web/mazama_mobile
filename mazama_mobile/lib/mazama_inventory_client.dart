// Mazama's own stock mix for the Mazama inventory page: GET /p/mazama-inventory,
// the manufacturer's public page mix summed per strain and type. Contract: ../mazama_modules/api/routes.yaml, schema
// mazama_inventory.response, vendored example at assets/shared/api/examples/ (test/mazama_inventory_client_test.dart).
import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'server_error.dart';
import 'server_request.dart';
import 'stock_mix.dart';

/// A request for Mazama's mix that failed; [message] is the server's own `detail` when it sent one. [unreachable]: the
/// server couldn't be reached (server_error.dart's rule).
class MazamaInventoryError extends ServerFailure {
  MazamaInventoryError(super.message, {super.status, super.unreachable});
}

/// One batch or lot behind Mazama's stock, for the page's lot table: its potency in mg per gram (null when
/// unknown) and the minor analytes its lab report found.
class MazamaLot {
  final String strain;
  final String lot;
  final num? tpe;
  final num? psilocybin;
  final num? psilocin;
  final List<String> detected;

  /// Its public product information sheet on the server ("/p/lots/mazama/HB-…"); null when the public may not
  /// see one, the server doesn't send it, or in demo mode.
  final String? path;

  /// The type codes of what is held of it (FD, DH, WF, LOT, ..., '' unknown), for the By type pie's filter.
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

/// The manufacturer's name, its mix cells and its lots, as GET /p/mazama-inventory answers. A server that sends no
/// lots: the table is then empty, the pies drawn as usual.
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

  /// As GET /p/mazama-inventory sends it, so the copy kept on the phone (the mazama_inventory dataset) reads back through [fromJson].
  Map<String, Object?> toJson() => {
        'name': name,
        'cells': [for (final c in cells) c.toJson()],
        'lots': [for (final l in lots) l.toJson()],
      };
}

/// Mazama's mix. Throws [MazamaInventoryError].
Future<MazamaInventory> fetchMazamaInventory({String baseUrl = apiBaseUrl, http.Client? client}) =>
    serverRequest('$baseUrl${mazamaInventoryPath()}',
        error: MazamaInventoryError.new, timeout: serverReadTimeout, client: client, read: (resp) {
      final body = serverJson(resp, MazamaInventoryError.new);
      if (body is! Map) throw MazamaInventoryError('unexpected response shape');
      return MazamaInventory.fromJson(Map<String, Object?>.from(body));
    });
