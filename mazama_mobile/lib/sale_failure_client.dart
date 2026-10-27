// Reports a sale the phone app TRIED to make but couldn't even get a sign-in for - specifically, CartPage._sell
// catching a SessionExpired while trying to renew or re-authenticate against the state system. Nothing was
// sold; nothing was recorded anywhere but here. This exists so that attempt isn't silently lost the moment the
// worker gets bounced back to the sign-in screen - it's a candidate for the server owner to review once
// whatever broke the state's sign-in is fixed (see mazama_sales' web/stock_pages.py's public_sale_failure
// route, server-side, and its /sale-review page), never something this app or that server resubmits to the
// state automatically. See sale_log_client.dart's own file comment for the parallel case (a sale that DID
// succeed) and why deviceId is sent here too: it's the same worker+device pairing a reviewer can cross-
// reference against that worker's own history of confirmed sales, as a trust signal.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

class SaleFailureError implements ServerRequestError {
  @override
  final String message;

  /// The server's HTTP status when it answered, null when it couldn't be reached (the outbox keeps the report then).
  final int? status;
  @override
  final bool unreachable;
  SaleFailureError(this.message, {this.status, this.unreachable = false});
  @override
  String toString() => message;
}

/// POSTs [apiBaseUrl]/p/sale-failure/{stateId} with [workerEmail], [deviceId], [reason]
/// (the SessionExpired message that stopped this sale, already scrubbed of credentials by session.dart/
/// flow_runner.dart before it ever reaches here) and the sale records that were never sent. Throws
/// SaleFailureError on anything but a clean 2xx - deliberately never anything CartPage._sell's own sign-in
/// redirect would treat as a reason to change course: see CartPage._queueFailedSale's own comment on why this
/// is fire-and-forget and never blocks or alters the trip back to sign-in.
Future<void> postSaleFailure(
  int stateId, {
  required String workerEmail,
  required String deviceId,
  required String reason,
  required List<Map<String, Object?>> request,
  /// The outbox's id for this report (server_outbox.dart): a repeat of it is recorded once by the server (README R56).
  String? clientId,
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${saleFailurePath(stateId)}');
    http.Response resp;
    try {
      resp = await c.post(
        uri,
        headers: {...appApiKeyHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'workerEmail': workerEmail,
          'deviceId': deviceId,
          'reason': reason,
          'request': request,
          if (clientId != null) 'clientId': clientId,
        }),
      );
    } catch (ex) {
      throw SaleFailureError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SaleFailureError(describeServerError(resp.statusCode, resp.body),
          status: resp.statusCode, unreachable: isUnreachableStatus(resp.statusCode));
    }
  } finally {
    if (shouldClose) c.close();
  }
}
