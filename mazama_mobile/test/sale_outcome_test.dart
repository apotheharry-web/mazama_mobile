// SM-12: the phone decides "not sent" vs "uncertain" from where the request failed (FlowError.stage) and the
// status the state answered with (FlowError.status), the same rule as mazama_sales' StateSession._write - never
// from the wording of the message. Every case both apps share, end to end from the request to the outcome, is in
// assets/shared/flows/contracts/write_outcomes.json (write_outcomes_test.dart); these are the classifier's own edges.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/sale_outcome.dart';

FlowError _e({FlowStage? stage, int? status, String message = 'x'}) => FlowError(message, stage: stage, status: status);

void main() {
  test('a failure before anything left the phone is notSent', () {
    expect(classifySaleFailure(_e(stage: FlowStage.connect)), SaleOutcome.notSent);
  });

  test('a failure after the request may have gone out is uncertain - the reported double-sale bug', () {
    // A connection reset or a timeout after sending used to read as "cannot reach ..." and so as notSent.
    expect(classifySaleFailure(_e(stage: FlowStage.send, message: 'cannot reach psilocybin.oregon.gov: SocketException')),
        SaleOutcome.uncertain);
  });

  test('the edges of the 4xx range: 499 is refused, 500 is not', () {
    expect(classifySaleFailure(_e(stage: FlowStage.response, status: 499)), SaleOutcome.notSent);
    expect(classifySaleFailure(_e(stage: FlowStage.response, status: 500)), SaleOutcome.uncertain);
  });

  test('a 4xx whose body was then cut off is still notSent: the status already says it was refused', () {
    expect(classifySaleFailure(_e(stage: FlowStage.response, status: 400)), SaleOutcome.notSent);
  });

  test('a message that merely mentions a 4xx is not trusted without a status', () {
    expect(classifySaleFailure(_e(message: 'the state system refused the sale: HTTP 400')), SaleOutcome.uncertain);
  });

  test('too many redirects (a response-stage 3xx) is uncertain', () {
    // Only GET/HEAD are followed, so a sale never gets here; the classifier still calls a 3xx answer uncertain.
    expect(classifySaleFailure(_e(stage: FlowStage.response, status: 302, message: 'too many redirects (more than 10)')),
        SaleOutcome.uncertain);
  });

  test('a failure with no stage at all defaults to uncertain - the safer mistake to make', () {
    expect(classifySaleFailure(_e()), SaleOutcome.uncertain);
  });

  // SL-R8 review: the runner follows redirects itself, but never a POST's. A sale the state answered with a redirect
  // has reached it and may be recorded; following it would let the next hop's connect error or 4xx read as notSent.
  for (final code in [301, 302, 303, 307, 308]) {
    test('the real sale flow answered $code is uncertain, and nothing more is sent', () async {
      final saleSpec = FlowSpec.fromYaml(File('assets/flows/sale.yaml').readAsStringSync());
      final calls = <http.Request>[];
      final client = MockClient((req) async {
        calls.add(req);
        if (calls.length == 1) {
          return http.Response('', code, headers: {'location': 'https://psilocybin.oregon.gov/gone'});
        }
        // What a followed redirect would meet: a refusal, which on its own would classify as notSent.
        return http.Response('', 404);
      });
      try {
        await runFlow(saleSpec, 'sale', {
          'access_token': 'TOKEN',
          'records': [
            {'id': 0}
          ]
        }, client: client);
        fail('expected a FlowError');
      } on FlowError catch (ex) {
        expect((ex.stage, ex.status), (FlowStage.response, code));
        expect(classifySaleFailure(ex), SaleOutcome.uncertain);
      }
      expect(calls.length, 1);
    });
  }
}
