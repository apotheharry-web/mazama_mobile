// Classifies a failed `sale` flow run (assets/flows/sale.yaml): whether it's actually safe to let the worker just try
// again, or whether the state system may already have recorded the sale, so resubmitting risks reporting it twice - a
// real problem for a legal sale record, not a cosmetic one.
//
// The rule is the shared core's (selling.sale_outcome), the same one the server's
// StateSession._write asks for CreateSalesRecords: this only turns the FlowError's own `stage`, `status` and
// `bodyIncomplete` (flow_runner.dart) into the event the core judges, never the wording of its message. Only
// a connection that never opened (FlowStage.connect) or a 4xx whose body arrived in full is "not sent"; a 4xx whose
// body was cut off proves nothing. When the core can't answer, the answer is uncertain, never notSent.
import 'flow/flow_runner.dart';
import 'mazama_core.dart';

enum SaleOutcome {
  /// Nothing was recorded for sure: the connection never opened, or the state system answered with a 4xx read in full.
  /// Safe to retry.
  notSent,

  /// Everything else: a reset, a closed connection or no answer within the timeout after the request may have gone
  /// out, a 5xx, a reply cut off, a 200 the flow or looksLikeConfirmedSale rejected, or anything this hasn't
  /// specifically ruled safe. Resubmitting risks reporting the same sale twice.
  uncertain,
}

/// The event [e] is, in the core's terms (flows/contracts/write_outcomes.json's kinds).
Map<String, Object?> saleFailureEvent(FlowError e) {
  if (e.stage == FlowStage.connect) return {'kind': 'connect_refused'};
  final status = e.status;
  if (e.stage == FlowStage.response && status != null) {
    // a check that rejected a reply read in full: its status is the answer (a 200's body didn't prove the sale)
    return e.bodyIncomplete ? {'kind': 'reply_cut_off', 'status': status} : {'kind': 'reply', 'status': status, 'body': ''};
  }
  if (e.stage == FlowStage.send) return {'kind': 'reset_after_send'};
  return {'kind': 'unclassified'};
}

SaleOutcome classifySaleFailure(FlowError e, {CoreFunctions? core}) {
  try {
    final o = (core ?? MazamaCore.instance).sellingSaleOutcome({'event': saleFailureEvent(e), 'sent': 1})['outcome'];
    // Deliberately the default, not notSent: wrongly telling a worker "nothing happened, try again" when the state
    // system actually filed it is the worse mistake to make here.
    return o == 'not_sent' ? SaleOutcome.notSent : SaleOutcome.uncertain;
  } catch (_) {
    return SaleOutcome.uncertain;
  }
}
