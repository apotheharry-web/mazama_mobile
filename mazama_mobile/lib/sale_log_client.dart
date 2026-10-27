// Reports a confirmed sale back to Mazama's own server - not for the sale itself (that already succeeded
// directly with the state system by the time this is called), purely for attribution: neither the state
// system's own sale records nor this mirror's sale_record table (built only from what the state gives it) have
// any notion of which worker on a shared center account actually made a given sale. See
// mazama_sales/src/mazama_sales/web/stock_pages.py's public_sale_log route, server-side, which is what this
// hits, and its own docstring for why that's a PUBLIC route gated by state_id the same as packages/label.
//
// Never sends a token: `request`/`response` here are exactly what buildSale (selling.dart) built and what
// sale.yaml's `sale` flow returned - the sale records themselves and the state's own reply, with no
// access_token/refresh_token in either one. Those travel only as this app's own Authorization header to the
// STATE system (sale.yaml), never as a field inside a sale record, so there's nothing to strip here - the
// server scrubs anything that looks like a credential anyway as a backstop (audit.scrub, server-side) in case
// that ever stops being true on either end.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

class SaleLogError implements ServerRequestError {
  @override
  final String message;

  /// The server's HTTP status when it answered, null when it couldn't be reached (the outbox keeps the log then).
  final int? status;
  @override
  final bool unreachable;
  SaleLogError(this.message, {this.status, this.unreachable = false});
  @override
  String toString() => message;
}

/// POSTs [apiBaseUrl]/p/sale-log/{stateId} with [workerEmail], [deviceId] (see
/// device_id.dart - this app's own install id, never a real hardware identifier) and the sale's own
/// [request]/[response], so Mazama's own server can log who made the sale and build up that worker+device
/// combination's own history of confirmed sales (used as a trust signal elsewhere - see
/// sale_failure_client.dart). Throws SaleLogError on anything but a clean 2xx - deliberately never a FlowError
/// or anything cart_page.dart's own sale-failure handling would recognize, since this is never the sale itself:
/// see CartPage._sell's own comment on why a failure here is logged and left at that, not retried, not
/// surfaced as a sale problem, and never allowed to undo the sale that already succeeded.
Future<void> postSaleLog(
  int stateId, {
  required String workerEmail,
  required String deviceId,
  required List<Map<String, Object?>> request,
  required Object? response,
  /// The outbox's id for this log (server_outbox.dart): a repeat of it is recorded once by the server (README R56).
  String? clientId,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${saleLogPath(stateId)}');
    http.Response resp;
    try {
      resp = await c.post(
        uri,
        headers: {...appApiKeyHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'workerEmail': workerEmail,
          'deviceId': deviceId,
          'request': request,
          'response': response,
          if (clientId != null) 'clientId': clientId,
        }),
      );
    } catch (ex) {
      throw SaleLogError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SaleLogError(describeServerError(resp.statusCode, resp.body),
          status: resp.statusCode, unreachable: isUnreachableStatus(resp.statusCode));
    }
  } finally {
    if (shouldClose) c.close();
  }
}
