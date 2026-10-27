// What the server says about a service center before the cart opens (SM-16): whether it is configured there, and
// the cart's live settings - the tax a cart can add, the manufacturer agreement split, how many units one line may
// hold and how long a cart lives - which the server's nix sets (/p/center-status/{state_id}, C4 in
// mazama_modules/api/routes.yaml). The defaults both sides start from are mazama_modules/selling/rules.yaml ("cart");
// [CartSettings.fallback] is this app's copy of them, held to the vendored rules by test/center_status_client_test.dart,
// and is what the cart uses whenever the server can't be asked or is too old to send them.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

class CenterStatusError implements Exception {
  final String message;
  CenterStatusError(this.message);
  @override
  String toString() => message;
}

class CartSettings {
  /// A cart nobody has changed for this long is emptied (on the phone: a saved draft this old isn't restored).
  final int minutes;

  /// The tax a cart can add on top of its total price or price per mg.
  final int taxPercent;

  /// The manufacturer agreement: a cart's total is shared edibles + extracts : everything else as these weights.
  final int agreementEdible;
  final int agreementDried;

  /// The server holds back the same package sold again within this many seconds (the phone doesn't use it yet).
  final int dedupeSeconds;

  /// The most units one cart line may hold.
  final int maxUnitsPerLine;

  const CartSettings({
    required this.minutes,
    required this.taxPercent,
    required this.agreementEdible,
    required this.agreementDried,
    required this.dedupeSeconds,
    required this.maxUnitsPerLine,
  });

  /// rules.yaml's "cart" defaults (test/center_status_client_test.dart holds these to the vendored copy).
  static const fallback = CartSettings(
      minutes: 1080, taxPercent: 15, agreementEdible: 40, agreementDried: 90, dedupeSeconds: 20, maxUnitsPerLine: 999);

  Duration get life => Duration(minutes: minutes);

  /// The server's "cart" object; a missing or odd value falls back to [fallback]'s, one value at a time.
  factory CartSettings.fromJson(Object? json) {
    final j = json is Map ? json : const {};
    int pick(String key, int dflt, {int min = 0}) {
      final v = j[key];
      return v is int && v >= min ? v : dflt;
    }

    const f = fallback;
    return CartSettings(
      minutes: pick('minutes', f.minutes, min: 1),
      taxPercent: pick('tax_percent', f.taxPercent),
      agreementEdible: pick('agreement_edible', f.agreementEdible, min: 1),
      agreementDried: pick('agreement_dried', f.agreementDried, min: 1),
      dedupeSeconds: pick('dedupe_seconds', f.dedupeSeconds),
      maxUnitsPerLine: pick('max_units_per_line', f.maxUnitsPerLine, min: 1),
    );
  }
}

class CenterStatus {
  final bool configured;
  final CartSettings cart;

  /// SP-R8: the manufacturer license ids that count as Mazama's (lower-case, sorted), so the stock page can tell
  /// Mazama's product apart in state-only data when the server can't be reached (SP-R13). Empty from an older server.
  final List<String> mazamaLicenses;

  const CenterStatus({required this.configured, required this.cart, this.mazamaLicenses = const []});
}

List<String> _licenses(Object? json) {
  if (json is! List) return const [];
  return {for (final v in json) if (v is String && v.trim().isNotEmpty) v.trim().toLowerCase()}.toList()..sort();
}

/// GETs /p/center-status/{stateId}. Throws [CenterStatusError] on a network problem, a non-200 reply or a reply
/// that isn't the expected object; a caller that only needs the cart settings uses [CartSettings.fallback] then.
Future<CenterStatus> fetchCenterStatus(int stateId, {String baseUrl = apiBaseUrl, http.Client? client}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${centerStatusPath(stateId)}');
    http.Response resp;
    try {
      resp = await c.get(uri, headers: appApiKeyHeaders);
    } catch (ex) {
      throw CenterStatusError('cannot reach ${uri.host}: ${ex.runtimeType}');
    }
    if (resp.statusCode != 200) throw CenterStatusError(describeServerError(resp.statusCode, resp.body));
    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw CenterStatusError('the server did not answer with JSON');
    }
    if (body is! Map || body['configured'] is! bool) throw CenterStatusError('unexpected response shape');
    return CenterStatus(
      configured: body['configured'] as bool,
      cart: CartSettings.fromJson(body['cart']),
      mazamaLicenses: _licenses(body['mazamaLicenses']),
    );
  } finally {
    if (shouldClose) c.close();
  }
}

/// The cart settings for [stateId], or [CartSettings.fallback] when the server can't say - what CartPage uses.
Future<CartSettings> fetchCartSettings(int stateId) async {
  try {
    return (await fetchCenterStatus(stateId)).cart;
  } on CenterStatusError {
    return CartSettings.fallback;
  }
}
