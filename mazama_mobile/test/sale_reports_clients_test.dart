// R56: the clients of the writes the outbox and catch-up work send say when Mazama's server couldn't be reached (their
// `unreachable`, server_error.dart's rule) and the status when it answered, so a refusal is kept as a dead letter and
// an outage is waited out.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/inventory_upload_client.dart';
import 'package:mazama_mobile/sale_failure_client.dart';
import 'package:mazama_mobile/sale_log_client.dart';
import 'package:mazama_mobile/server_error.dart';

void main() {
  final down = http_testing.MockClient((_) async => throw const SocketException('down'));
  final bad = http_testing.MockClient((_) async => http.Response('{"detail": "deviceId is required."}', 400));
  final gateway = http_testing.MockClient((_) async => http.Response('<html>502</html>', 502));

  Future<Object?> err(Future<Object?> Function() f) async {
    try {
      await f();
    } catch (e) {
      return e;
    }
    return null;
  }

  test('sale log', () async {
    Future<Object?> send(http.Client c) => postSaleLog(231, workerEmail: 'w', deviceId: 'd', request: const [{}], response: null, client: c);
    expect(isServerUnreachable(await err(() => send(down))), isTrue);
    expect(isServerUnreachable(await err(() => send(gateway))), isTrue);
    final refused = await err(() => send(bad)) as SaleLogError;
    expect([refused.unreachable, refused.status, refused.message], [false, 400, 'deviceId is required.']);
  });

  test('failed-sale report', () async {
    Future<Object?> send(http.Client c) =>
        postSaleFailure(231, workerEmail: 'w', deviceId: 'd', reason: 'r', request: const [{}], client: c);
    expect(isServerUnreachable(await err(() => send(down))), isTrue);
    final refused = await err(() => send(bad)) as SaleFailureError;
    expect([refused.unreachable, refused.status], [false, 400]);
  });

  test('inventory upload and lab-report reads', () async {
    expect(isServerUnreachable(await err(() => uploadInventorySnapshot(231, const [], workerEmail: 'w', deviceId: 'd', client: down))),
        isTrue);
    expect(isServerUnreachable(await err(() => uploadInventorySnapshot(231, const [], workerEmail: 'w', deviceId: 'd', client: bad))),
        isFalse);
    expect(isServerUnreachable(await err(() => fetchCoaDataBatch(['HB-1'], client: gateway))), isTrue);
    expect(isServerUnreachable(await err(() => fetchCoaDataBatch(['HB-1'], client: bad))), isFalse);
  });
}
