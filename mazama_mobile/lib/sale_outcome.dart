// Classifies a failed `sale` flow run (assets/flows/sale.yaml) the same way the real server's own
// StateSession._write does (mazama_sales/src/mazama_sales/state/client.py's NotSent vs SendUncertain
// exceptions): whether it's actually safe to let the worker just try again, or whether the state system may
// already have recorded the sale, so resubmitting risks reporting it twice - a real problem for a legal sale
// record, not a cosmetic one.
//
// SM-12: this reads the FlowError's own `stage` and `status` (flow_runner.dart), never the wording of its
// message. It used to match "cannot reach ..." in the message, which flow_runner.dart wrote for *every*
// transport failure - including a connection reset or a hang after the sale had already been sent - so the
// phone told the worker "not sent, safe to try again" for a sale the state may well have recorded.
import 'flow/flow_runner.dart';

enum SaleOutcome {
  /// Nothing was recorded for sure: the connection never opened (FlowStage.connect - the Dart equivalent of
  /// client.py's httpx.ConnectError, which _write treats as NotSent), or the state system answered with a 4xx
  /// (also NotSent in client.py: a request that reached the server and was flatly rejected before anything was
  /// recorded). Safe to retry.
  notSent,

  /// Everything else: a reset, a closed connection or no answer within the timeout after the request may have
  /// gone out (FlowStage.send), a 5xx, a 200 the flow or looksLikeConfirmedSale rejected, or any failure this
  /// hasn't specifically ruled safe. The sale may have been recorded even though this device never got a usable
  /// confirmation - resubmitting risks reporting the same sale twice, so this blocks a casual retry outright,
  /// not just warns about it.
  uncertain,
}

SaleOutcome classifySaleFailure(FlowError e) {
  if (e.stage == FlowStage.connect) return SaleOutcome.notSent;
  final status = e.status;
  if (e.stage == FlowStage.response && status != null && status >= 400 && status < 500) return SaleOutcome.notSent;
  // Deliberately the default, not notSent: wrongly telling a worker "nothing happened, try again" when the state
  // system actually filed it is the worse mistake to make here.
  return SaleOutcome.uncertain;
}
