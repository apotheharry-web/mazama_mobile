// An order for Mazama from the Mazama inventory page's order form (specs/mazama-inventory MI-D6..D9, MI-R5, MI-R6):
// POST /p/orders/{state_id} (C14), stored and audited on the server as the worker on this install's device id.
// Contract: ../mazama_modules/api/routes.yaml, schemas order.*, vendored examples at assets/shared/api/examples/
// (test/order_client_test.dart).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'app_api_key.dart';
import 'server_error.dart';
import 'server_link_client.dart' show serverClient;
import 'stock_summary.dart';

/// The kinds a strain's line can be ordered as (MI-D8), code -> the word the form shows; the server takes the codes.
/// An edible product's line is of its own kind (CH, GM, HN: stockProductCode, specs/edibles ED-A6), never one of these.
const Map<String, String> orderKinds = {'FD': 'Freeze dried', 'DH': 'Dehydrated', 'HG': 'Homogenized'};

/// A line's size in words: "25 mg", "Booster" / "Microdose" (an edible's class, specs/edibles ED-D2), "Other size".
String orderSizeLabel(int size) => size == 0 ? 'Other size' : (size < 0 ? stockSizeWord(size) : '$size mg');

/// An order that failed; [message] is the server's own `detail` when it sent one (shown to the worker as is).
/// [unreachable]: the server couldn't be reached (server_error.dart's rule): nothing was stored, try again later.
class OrderError implements ServerRequestError {
  @override
  final String message;
  @override
  final bool unreachable;
  OrderError(this.message, {this.unreachable = false});
  @override
  String toString() => message;
}

/// One line: [quantity] units of [strain] at [size] mg (0 = other sizes), as [type] (FD, DH or HG); or of an edible
/// product (Chocolate, Gummy, Honey) as Booster (-1), Microdose (-2) or other (0), of its own type (CH, GM, HN).
class OrderLine {
  final String strain;
  final int size;
  final String type;
  final int quantity;

  const OrderLine({required this.strain, required this.size, required this.type, required this.quantity});

  factory OrderLine.fromJson(Map<String, Object?> j) => OrderLine(
        strain: j['strain'] as String,
        size: j['size'] as int,
        type: j['type'] as String,
        quantity: j['quantity'] as int,
      );

  Map<String, Object?> toJson() => {'strain': strain, 'size': size, 'type': type, 'quantity': quantity};
}

/// The order as the server stored it: its number, lines (strain names in their canonical spelling) and notes.
class OrderReceipt {
  final int id;
  final String center;
  final List<OrderLine> lines;
  final String note;

  const OrderReceipt({required this.id, required this.center, required this.lines, this.note = ''});
}

/// Sends [lines] and the worker's [note] (MI-D10, at most orderMaxNoteChars) as [workerEmail] on [deviceId] (C14).
/// Throws [OrderError] with the server's message when it refuses the order; nothing is stored then.
Future<OrderReceipt> submitOrder(
  int stateId, {
  required String workerEmail,
  required String deviceId,
  required List<OrderLine> lines,
  String note = '',
  String baseUrl = apiBaseUrl,
  http.Client? client,
}) async {
  final c = client ?? serverClient();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse('$baseUrl${orderPath(stateId)}');
    http.Response resp;
    try {
      resp = await c.post(uri,
          headers: {...appApiKeyHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'workerEmail': workerEmail,
            'deviceId': deviceId,
            'lines': [for (final l in lines) l.toJson()],
            'note': note,
          }));
    } catch (ex) {
      throw OrderError('cannot reach ${uri.host}: ${ex.runtimeType}', unreachable: true);
    }
    if (resp.statusCode != 201) {
      throw OrderError(describeServerError(resp.statusCode, resp.body), unreachable: isUnreachableStatus(resp.statusCode));
    }
    try {
      final body = jsonDecode(resp.body) as Map<String, Object?>;
      return OrderReceipt(
        id: body['id'] as int,
        center: body['center'] as String,
        lines: [for (final l in body['lines'] as List) OrderLine.fromJson(Map<String, Object?>.from(l as Map))],
        note: (body['note'] as String?) ?? '',
      );
    } catch (_) {
      // Stored, but the reply can't be read: say so plainly rather than as a failure the worker might resend.
      throw OrderError('the order was sent, but the server\'s answer could not be read');
    }
  } finally {
    if (shouldClose) c.close();
  }
}
