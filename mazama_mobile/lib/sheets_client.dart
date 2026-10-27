// The product information sheets of a center's stock, for the stock page's "Product information sheets" bar
// (specs/stock-page SP-D11, SP-R16): GET /p/sheets/{state_id} (C13), the same list as the center's public page on the
// server, each with the path of its public sheet page and the strains of the center's packages made from it.
// Contract: ../mazama_modules/api/routes.yaml, schema sheets.response, vendored example at assets/shared/api/examples/
// (test/sheets_client_test.dart).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'mazama_inventory_client.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;
import 'stock_summary.dart';

/// A sheets request that failed; [message] is the server's own `detail` when it sent one. [unreachable]: the server
/// couldn't be reached (server_error.dart's rule).
class SheetsError implements ServerRequestError {
  @override
  final String message;
  @override
  final bool unreachable;
  SheetsError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}

/// One harvest batch's or process lot's product information sheet.
class ProductSheet {
  final String guid;
  final String name;
  final String product;
  final String tested;

  /// Its public page on the server ("/p/lots/mazama/HB-…"); null when there is none to open (demo mode).
  final String? path;

  /// The strains of the center's in-stock packages made from it, as /p/packages names them; "" = not known.
  final List<String> strains;

  /// Its lab figures in mg per gram, null when unknown, and the minor analytes found (the stock page's lot table,
  /// SP-D18); a server from before SP-D18 sends none.
  final num? tpe;
  final num? psilocybin;
  final num? psilocin;
  final List<String> detected;

  /// The type codes of the center's in-stock packages made from it (FD, DH, CH, ..., '' unknown), for the By type
  /// pie's filter (SP-D18).
  final List<String> types;

  const ProductSheet({
    required this.guid,
    required this.name,
    required this.product,
    required this.tested,
    required this.path,
    required this.strains,
    this.tpe,
    this.psilocybin,
    this.psilocin,
    this.detected = const [],
    this.types = const [],
  });

  factory ProductSheet.fromJson(Map<String, Object?> j) {
    final strains = j['strains'];
    final detected = j['detected'] ?? const [];
    final types = j['types'] ?? const [];
    final nums = [j['tpe'], j['psilocybin'], j['psilocin']];
    if (j['guid'] is! String || strains is! List || strains.any((s) => s is! String) || detected is! List ||
        detected.any((d) => d is! String) || types is! List || types.any((t) => t is! String) ||
        nums.any((n) => n != null && n is! num)) {
      throw SheetsError('unexpected response shape');
    }
    return ProductSheet(
      guid: j['guid'] as String,
      name: (j['name'] as String?) ?? '',
      product: (j['product'] as String?) ?? '',
      tested: (j['tested'] as String?) ?? '',
      path: j['path'] as String?,
      strains: strains.cast<String>(),
      tpe: nums[0] as num?,
      psilocybin: nums[1] as num?,
      psilocin: nums[2] as num?,
      detected: detected.cast<String>(),
      types: types.cast<String>(),
    );
  }

  Map<String, Object?> toJson() => {
        'guid': guid,
        'name': name,
        'product': product,
        'tested': tested,
        'path': path,
        'strains': strains,
        'tpe': tpe,
        'psilocybin': psilocybin,
        'psilocin': psilocin,
        'detected': detected,
        'types': types,
      };

  /// Whether this sheet is for [strain], as the stock page names strains: ignoring case, an unknown one ("") being
  /// "Unknown" (stock_summary.dart's rule).
  bool isFor(String strain) {
    final want = strain.toLowerCase();
    return strains.any((s) => (s.isEmpty ? 'Unknown' : s).toLowerCase() == want);
  }

  /// The address of its page on [baseUrl] (the server the app talks to), or null.
  Uri? url({String baseUrl = apiBaseUrl}) => path == null ? null : Uri.parse('$baseUrl$path');
}

/// SP-D18: the stock page's lot table rows, one per sheet and name it is counted under on the stock pies: an edible
/// lot under its product ("Chocolate", as the pies name edibles, ED-D1), anything else under each of its strains ("" =
/// Unknown). A lot made into a strain and an edible is a row under each. Sorted by name, then lot id.
List<MazamaLot> sheetLotRows(List<ProductSheet> sheets) {
  final rows = <MazamaLot>[];
  for (final s in sheets) {
    final names = <String>[];
    void add(String n) {
      if (!names.any((m) => m.toLowerCase() == n.toLowerCase())) names.add(n);
    }

    final edibles = [for (final t in s.types) if (stockEdibles[t] != null) stockEdibles[t]!];
    if (s.types.isEmpty || edibles.length < s.types.length) {
      for (final st in (s.strains.isEmpty ? const [''] : s.strains)) {
        add(st);
      }
    }
    edibles.forEach(add);
    for (final n in names) {
      rows.add(MazamaLot(
          strain: n,
          lot: s.guid,
          tpe: s.tpe,
          psilocybin: s.psilocybin,
          psilocin: s.psilocin,
          detected: s.detected,
          path: s.path,
          types: s.types));
    }
  }
  String key(MazamaLot l) => (l.strain.isEmpty ? 'Unknown' : l.strain).toLowerCase();
  rows.sort((a, b) {
    final c = key(a).compareTo(key(b));
    return c != 0 ? c : a.lot.toLowerCase().compareTo(b.lot.toLowerCase());
  });
  return rows;
}

/// The center's sheets (C13). Throws [SheetsError].
Future<List<ProductSheet>> fetchProductSheets(int stateId, {String baseUrl = apiBaseUrl, http.Client? client}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${sheetsPath(stateId)}');
    http.Response resp;
    try {
      resp = await c.get(uri, headers: appApiKeyHeaders).timeout(serverReadTimeout);
    } catch (ex) {
      throw SheetsError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode != 200) {
      throw SheetsError(describeServerError(resp.statusCode, resp.body), unreachable: isUnreachableStatus(resp.statusCode));
    }
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw SheetsError('the server did not answer with JSON');
    }
    final sheets = body is Map ? body['sheets'] : null;
    if (sheets is! List || sheets.any((s) => s is! Map)) throw SheetsError('unexpected response shape');
    return [for (final s in sheets) ProductSheet.fromJson(Map<String, Object?>.from(s as Map))];
  } finally {
    if (shouldClose) c.close();
  }
}
