// SM-12, through the shared case table: every case in assets/shared/flows/contracts/write_outcomes.json (vendored
// from ../mazama_modules/flows/contracts/ by tool/sync_flows.sh) ends the same way on the phone as on the server
// (mazama_sales/tests/state/test_write_outcomes.py).
//
// - outcome: what the cart makes of it: runFlow on the vendored sale.yaml, then classifySaleFailure for a FlowError
//   or looksLikeConfirmedSale for the reply (SM-D2: one record per record sent, one non-blank sale number).
// - flow_error: the FlowError's stage and status, which the server's interpreter must match.
//
// Failures only package:http and dart:io can produce (a wrapped SocketException, a reply cut off part way through
// its body, a body that never finishes) stay in flow/flow_runner_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/sale_outcome.dart';
import 'package:mazama_mobile/selling.dart';

final Map<String, Object?> _table =
    jsonDecode(File('assets/shared/flows/contracts/write_outcomes.json').readAsStringSync()) as Map<String, Object?>;
final List<Map<String, Object?>> _cases = (_table['cases'] as List).cast<Map<String, Object?>>();
final FlowSpec _saleSpec = FlowSpec.fromYaml(File('assets/flows/sale.yaml').readAsStringSync());

/// A client whose send() does what the case says.
class _Scripted extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) _send;
  _Scripted(this._send);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _send(request);
}

/// What dart:io / package:http throw for each transport event (the same errors flow_runner_test.dart uses).
Object _error(String kind) => switch (kind) {
      'dns_failure' => const SocketException("Failed host lookup: 'psilocybin.oregon.gov'",
          osError: OSError('No address associated with hostname', 7)),
      'connect_refused' =>
        SocketException('Connection refused', osError: OSError('Connection refused', Platform.isIOS || Platform.isMacOS ? 61 : 111)),
      'tls_failure' => const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
      'reset_after_send' => const SocketException('Connection reset by peer', osError: OSError('Connection reset by peer', 104)),
      'closed_before_headers' => http.ClientException('Connection closed before full header was received'),
      _ => throw ArgumentError('no transport error for event kind $kind'),
    };

http.Client _client(Map<String, Object?> event) {
  final kind = event['kind'] as String;
  if (kind == 'reply') {
    return _Scripted((req) async =>
        http.StreamedResponse(Stream.value(utf8.encode(event['body'] as String)), event['status'] as int, request: req));
  }
  if (kind == 'timeout') return _Scripted((req) => Completer<http.StreamedResponse>().future); // never answers
  return _Scripted((req) => Future.error(_error(kind)));
}

List<Map<String, Object?>> _records(int n) => [for (var i = 0; i < n; i++) {'id': i, 'productGuid': 'PKPR-$i'}];

/// Runs the case the way cart_page.dart sends a sale: (outcome, sale number, the FlowError if the flow failed).
Future<(String, String?, FlowError?)> _run(Map<String, Object?> c) async {
  final sent = c['sent'] as int;
  final inputs = <String, Object?>{
    'access_token': 'TOKEN-SM12',
    'records': _records(sent),
    // A short limit so the "no answer" case ends in milliseconds; the spec's own 60 s is checked in flow_runner_test.dart.
    if ((c['event'] as Map)['kind'] == 'timeout') 'timeout_seconds': '0.05',
  };
  try {
    final result = await runFlow(_saleSpec, 'sale', inputs, client: _client((c['event'] as Map).cast<String, Object?>()));
    final created = result['created'];
    if (!looksLikeConfirmedSale(created, sent)) return ('uncertain', null, null);
    return ('recorded', ((created as List).first as Map)['saleNumber'].toString(), null);
  } on FlowError catch (ex) {
    final outcome = switch (classifySaleFailure(ex)) { SaleOutcome.notSent => 'not_sent', SaleOutcome.uncertain => 'uncertain' };
    return (outcome, null, ex);
  }
}

void main() {
  test('the table covers every kind of end', () {
    expect(_cases.length, greaterThanOrEqualTo(20));
    expect(_cases.map((c) => c['outcome']).toSet(), {'not_sent', 'uncertain', 'recorded'});
    expect(_cases.map((c) => (c['event'] as Map)['kind']).toSet(),
        {'dns_failure', 'connect_refused', 'tls_failure', 'timeout', 'reset_after_send', 'closed_before_headers', 'reply'});
    expect(_cases.map((c) => c['name']).toSet().length, _cases.length);
  });

  for (final c in _cases) {
    test('case: ${c['name']}', () async {
      final (outcome, number, error) = await _run(c);
      expect((outcome, number), (c['outcome'], c['sale_number']));
      final want = c['flow_error'] as Map?;
      if (want == null) {
        expect(error, isNull);
      } else {
        expect(error, isNotNull);
        expect((error!.stage?.name, error.status), (want['stage'], want['status']));
        expect(error.message, isNot(contains('TOKEN-SM12')));
      }
    });
  }
}
