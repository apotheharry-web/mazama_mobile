// Reports a sale the phone app TRIED to make that it could not confirm: every failure in CartPage._sell and its bulk
// sale (a sign-in that couldn't be renewed, a refusal, a 5xx or timeout, a 200 that didn't look like a sale). Some of
// these were surely not sent; others may be on the state's records already (SALE-15), and the report says which in
// its `outcome` field (saleFailureOutcome below). This exists so that attempt isn't silently lost the moment the
// worker dismisses the dialog or is bounced back to the sign-in screen - it's a candidate for the center's staff to
// review (see mazama_sales' web/stock_pages.py's public_sale_failure
// route, server-side, and its /sale-review page), never something this app or that server resubmits to the
// state automatically. See sale_log_client.dart's own file comment for the parallel case (a sale that DID
// succeed) and why deviceId is sent here too: it's the same worker+device pairing a reviewer can cross-
// reference against that worker's own history of confirmed sales, as a trust signal.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'sale_outcome.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;

/// SALE-15: the report's `outcome` field, 'not_sent' or 'uncertain', worked out from [reason] as CartPage builds it:
/// every failure there is reported with its SaleOutcome as a leading tag ('[notSent] ...', or after a bulk sale's own
/// tag, '[bulk 2 of 3] [notSent] ...'). Only that leading notSent tag means not sent; anything else, including a reason
/// with no tag at all, is 'uncertain' (the state may have recorded the sale), which is how the server also counts a
/// report without the field. The tag is matched only at the start, so nothing the state wrote into the rest of the
/// reason can make a sale look not sent.
String saleFailureOutcome(String reason) =>
    RegExp('^(\\[bulk [0-9]+ of [0-9]+\\] )?\\[${SaleOutcome.notSent.name}\\] ').hasMatch(reason) ? 'not_sent' : 'uncertain';

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
/// (why the sale didn't go through, already scrubbed of credentials by session.dart/flow_runner.dart before it ever
/// reaches here), its outcome (saleFailureOutcome: whether the sale was surely not sent) and the sale records the
/// phone tried to send. Throws
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
          'outcome': saleFailureOutcome(reason),
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
