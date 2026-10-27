// Sends the lines of text this phone's own native OCR (text_scanner.dart - Apple's Vision framework on iOS,
// Google ML Kit's text recognition on Android) recognized off a label straight to Mazama's own server, so the
// matcher runs against the center's live inventory as the server's mirror has it (src/mazama_sales/web/
// stock_pages.py's public_scan_match route). The matcher itself is coa_core's (mazama_modules/coa/coa_core/src/
// scan.rs), which the server runs through its Python binding. The cart already holds its own copy of the center's
// stock, so when this call can't get an answer from the server (ScanMatchError.serverUnavailable) CartPage runs the
// same coa_core matcher on the phone through the FFI against that copy instead (local_scan_match.dart); it is never
// re-implemented in Dart. See the route's own docstring for the matching rules (an exact lot number, a couple of
// misread characters trusted only on a "Lot:" line or on typed text, and a best-effort guess from
// weight/potency/strain/date when no lot number is found at all).
//
// PUBLIC and keyed by stateId, no per-worker login, for the same reason as packages_client.dart/
// label_client.dart: no worker ever signs in to this server, only to the state system. It still sends the
// whole-app shared secret every /p/ call sends (app_api_key.dart).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

class ScanMatchError implements Exception {
  final String message;

  /// The server's HTTP status when it answered with an error, null when it couldn't be reached or its reply
  /// wasn't one of its own (not JSON: a proxy's or captive portal's page).
  final int? status;
  ScanMatchError(this.message, {this.status});

  /// The server couldn't give an answer just now - unreachable, failing (5xx), timed out (408) or busy (429) - as
  /// opposed to refusing the request itself (any other 4xx: a bad request, an unknown center, a wrong app key),
  /// which matching on the phone instead would only hide. CartPage matches locally only in this case.
  bool get serverUnavailable {
    final s = status;
    return s == null || s >= 500 || s == 408 || s == 429;
  }

  @override
  String toString() => message;
}

/// One hit from the matcher's find_ids (coa_core's scan::find_ids) - an actual lot number found in the recognized
/// text, best first.
class ScanMatch {
  final String guid;
  final String name;
  final int dist;
  final String line;
  final int stock;
  final bool sellable;

  ScanMatch({required this.guid, required this.name, required this.dist, required this.line, required this.stock, required this.sellable});

  static ScanMatch? fromJson(Map<String, Object?> j) {
    final guid = j['guid'];
    final name = j['name'];
    final dist = j['dist'];
    final line = j['line'];
    final stock = j['stock'];
    final sellable = j['sellable'];
    if (guid is! String || name is! String || dist is! num || line is! String || stock is! num || sellable is! bool) return null;
    return ScanMatch(guid: guid, name: name, dist: dist.toInt(), line: line, stock: stock.toInt(), sellable: sellable);
  }
}

/// One best-effort suggestion from the matcher's closest (coa_core's scan::closest) - offered only when nothing
/// matched an actual lot number.
class ScanGuess {
  final String guid;
  final String name;
  final int score;
  final List<String> why;
  final int stock;

  ScanGuess({required this.guid, required this.name, required this.score, required this.why, required this.stock});

  static ScanGuess? fromJson(Map<String, Object?> j) {
    final guid = j['guid'];
    final name = j['name'];
    final score = j['score'];
    final why = j['why'];
    final stock = j['stock'];
    if (guid is! String || name is! String || score is! num || why is! List || stock is! num) return null;
    return ScanGuess(guid: guid, name: name, score: score.toInt(), why: why.map((e) => e.toString()).toList(), stock: stock.toInt());
  }
}

class ScanMatchResult {
  final List<ScanMatch> matches;
  final List<ScanGuess> guesses;
  ScanMatchResult({required this.matches, required this.guesses});
}

/// POSTs [apiBaseUrl]/p/scan-match/{stateId} with the recognized [lines] (and whether the
/// worker actually typed them, [typed] - see the server route's own docstring for why that changes how much a
/// misread character is trusted) and returns what it matched or, failing that, its best guesses. Throws
/// ScanMatchError on anything but a clean 200 (with the status when the server answered).
Future<ScanMatchResult> scanMatch(
  int stateId,
  List<String> lines, {
  bool typed = false,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${scanMatchPath(stateId)}');
    http.Response resp;
    try {
      resp = await c.post(uri, headers: {...appApiKeyHeaders, 'Content-Type': 'application/json'},
                         // The server reads only the first scanMatchMaxLines lines, scanMatchMaxLineChars characters
                         // of each (routes.yaml): send no more than that.
                         body: jsonEncode({
                           'lines': [
                             for (final l in lines.take(scanMatchMaxLines))
                               l.length > scanMatchMaxLineChars ? l.substring(0, scanMatchMaxLineChars) : l
                           ],
                           'typed': typed,
                         }));
    } catch (ex) {
      throw ScanMatchError('cannot reach ${uri.host}: ${ex.runtimeType}');
    }
    if (resp.statusCode != 200) {
      throw ScanMatchError(describeServerError(resp.statusCode, resp.body), status: resp.statusCode);
    }
    final Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw ScanMatchError('the server did not answer with JSON');   // a proxy's error page, say (SM-22)
    }
    if (body is! Map<String, Object?>) throw ScanMatchError('the server sent back something unexpected.');
    final matches = (body['matches'] as List? ?? [])
        .whereType<Map>()
        .map((m) => ScanMatch.fromJson(Map<String, Object?>.from(m)))
        .whereType<ScanMatch>()
        .toList();
    final guesses = (body['guesses'] as List? ?? [])
        .whereType<Map>()
        .map((g) => ScanGuess.fromJson(Map<String, Object?>.from(g)))
        .whereType<ScanGuess>()
        .toList();
    return ScanMatchResult(matches: matches, guesses: guesses);
  } finally {
    if (shouldClose) c.close();
  }
}
