// The phone's one background uploader of lab reports: every lot in a center's stock whose
// result Mazama's server doesn't have is sent, for both kinds of center, without holding up the load, the stock page or
// a sale.
//   - Who enqueues: coa_data_resolver.dart (a center the server doesn't track: the lots its batch lookup didn't return)
//     and cart_page.dart (a center the server tracks: the lots whose package says coaAvailable false). The cart's own
//     submission on a cart add (configured_coa_submit.dart, through server_link.dart) stays as it was.
//   - One per app (the engine's queue, server_link.dart's queueCoaUploads), not one per page: a second load of a center
//     adds only the lots that aren't already waiting or being sent.
//   - Paced to the server's budget for POST /p/coa-data/parse (routes.yaml coa_data_parse, coaDataParseRateLimitPerMinute): one start every
//     [coaUploadStartInterval] at most, [coaUploadMaxInFlight] in flight at most. Every start is on a timer, never
//     inside the enqueue call, so the load that enqueued always returns first.
//   - Each lot runs the existing chain (configured_coa_submit.dart's submitCoaForLot: GetPackagedProductInfo for one
//     package of the lot, the newest accepted potency PDF, DownloadDocument, POST /p/coa-data/parse) with the worker's
//     session as it is at send time.
//   - What the reply means:
//       200 with numbers: sent, and every caller that asked about the lot is told (the cart patches it in);
//       any other reply below 500 (202 queued, 202 held, 4xx refused) but 429 and 408: sent, nothing to patch;
//       429 (busy) or 408 (the server gave up reading the body): the run stops, the waiting lots are let go and none
//       is marked; the next load enqueues them again;
//       5xx or no connection (server_error.dart's rule), for a lot actually being sent: that lot is kept on the
//       catch-up list (catch_up_store.dart), as a cart add's would be, and only while the list has room, so these
//       never push out a cart add's lot; the waiting lots are let go, unmarked, and the next load enqueues them again.
//       While the tracker counts the server offline nothing starts and the waiting lots are let go the same way, so
//       the catch-up list (sent unpaced once the server answers) never fills up from here;
//       no potency PDF on file at the state, or the state's read failing: skipped, nothing remembered.
//   - Sent lots are remembered for [coaSentKeepFor] (as long as the server keeps them), at most [coaSentMaxLots], the
//     oldest dropped first, in the sync engine's sync_sent table (SyncQueue.markSent / wasSent). The waiting queue
//     itself is only in memory: the next load fills it again.
//   - The pacing, the queue and the replies' meaning live in the sync engine's queue (lib/sync/sync_queue.dart, its
//     paced lab reports); this file is the lot ([CoaUploadLot]), its sender ([labReportQueueSender]) and how the app
//     offers lots to the queue ([LabReportUploads]).
//   - Never in the demo: nothing is enqueued while demo mode is on, and the demo's cart and resolver never call
//     this at all (demo_backend.dart).
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api_contract.g.dart' show coaDataParseRateLimitPerMinute;
import 'catch_up_store.dart';
import 'coa_data_client.dart' show CoaData, CoaDataError;
import 'configured_coa_submit.dart' as configured_coa_submit;
import 'server_error.dart';
import 'sync/sync_queue.dart';

/// The least time between two uploads starting: the server's per-minute budget for /p/coa-data/parse spread evenly
/// (20 a minute: one every 3 s).
const coaUploadStartInterval = Duration(milliseconds: 60000 ~/ coaDataParseRateLimitPerMinute);

/// How many uploads may be under way at once.
const coaUploadMaxInFlight = 2;

/// How long a sent lot isn't sent again.
const coaSentKeepFor = Duration(hours: 24);

/// How many sent lots are remembered at most, the oldest dropped first.
const coaSentMaxLots = 2000;

/// One lot to send: its id, one package of it (GetPackagedProductInfo is keyed by a package id, never the lot's or the
/// center's), the center, and the state's psilocybin figure for it (the package's analyteWeight).
class CoaUploadLot {
  const CoaUploadLot({required this.lotGuid, required this.packageId, required this.stateId, this.statePsilocybin});

  final String lotGuid;
  final int packageId;
  final int stateId;
  final double? statePsilocybin;
}

/// Told when the server answered a lot's upload with its numbers.
typedef CoaLotResolved = void Function(String lotGuid, CoaData data);

/// Adds lots to the app's uploader ([LabReportUploads.enqueueCoaUploads]); [onResolved] is told about each one the
/// server answers with numbers.
typedef QueueCoaUploads = void Function(List<CoaUploadLot> lots, {CoaLotResolved? onResolved});

/// Sends one lot's report: the parsed result on a 200, null when the state has no potency PDF on file for it. Throws
/// otherwise ([ConfiguredCoaSubmitError], with the server's status when it answered).
typedef CoaLotSend = Future<CoaData?> Function(CoaUploadLot lot, CatchUpAuth auth);

/// The real sender: configured_coa_submit.dart's chain, whose upload goes through the server link.
Future<CoaData?> sendCoaLot(CoaUploadLot lot, CatchUpAuth auth) => configured_coa_submit.submitCoaForLot(
      lotGuid: lot.lotGuid,
      representativePackageId: lot.packageId,
      accessToken: auth.accessToken,
      workerEmail: auth.workerEmail,
      deviceId: auth.deviceId,
      statePsilocybin: lot.statePsilocybin,
    );

/// The HTTP status Mazama's server answered an upload with, from the error it raised; null when it didn't answer (no
/// connection) or the failure was the state system's.
int? coaReplyStatus(Object? error) {
  if (error is configured_coa_submit.ConfiguredCoaSubmitError) return error.status;
  if (error is CoaDataError) return error.status;
  return null;
}

/// Whether a failed upload still counts as sent: the server answered it below 500, and not with a 429 or a 408
/// (isNotNowStatus: nothing was taken).
bool countsAsSent(Object? error) {
  final status = coaReplyStatus(error);
  return status != null && status < 500 && !isNotNowStatus(status);
}

/// The engine's sender for a lab report, paced or kept: the lot's chain through [send] with the session current at send
/// time ([auth]). What each reply means is the file comment's.
QueueSender labReportQueueSender(CoaLotSend send, Future<CatchUpAuth?> Function() auth) => (item) async {
      final PendingCoaLot? lot;
      try {
        lot = PendingCoaLot.fromJson(jsonDecode(item.body));
      } on FormatException {
        return const Skipped();
      }
      if (lot == null) return const Skipped();
      CatchUpAuth? credentials;
      try {
        credentials = await auth();
      } catch (_) {
        credentials = null;
      }
      if (credentials == null) return const Busy(); // no usable session now: nothing can be sent
      try {
        final data = await send(
            CoaUploadLot(lotGuid: lot.lotGuid, packageId: lot.packageId, stateId: lot.stateId, statePsilocybin: lot.statePsilocybin),
            credentials);
        return data == null ? const Skipped() : Done(data); // null: no potency PDF on file at the state
      } catch (e) {
        if (isNotNowStatus(coaReplyStatus(e))) return const Busy();
        if (isServerUnreachable(e)) return Unreachable(error: '$e');
        if (countsAsSent(e)) return const Done(); // queued, held or refused: the server has its answer
        return const Skipped(); // the state system's read failing: not sent; the next load tries again
      }
    };

/// The background uploads on the engine's queue, as the app offers them.
extension LabReportUploads on SyncQueue {
  /// Adds [lots] to the paced uploads, leaving out any already waiting or being sent (whose [onResolved] is added to
  /// it), sent in the last [coaSentKeepFor], or waiting on the catch-up list. Returns at once; uploads start on a timer.
  /// Nothing in the demo (the queue's own rule). Never throws.
  void enqueueCoaUploads(List<CoaUploadLot> lots, {CoaLotResolved? onResolved}) {
    if (lots.isEmpty) return;
    final at = now().toUtc();
    try {
      offerLabReports(
        [
          for (final l in lots)
            (
              key: l.lotGuid,
              body: PendingCoaLot(
                      lotGuid: l.lotGuid, packageId: l.packageId, stateId: l.stateId, statePsilocybin: l.statePsilocybin, addedAt: at)
                  .toJson(),
            ),
        ],
        onDone: onResolved == null
            ? null
            : (item, value) {
                final lot = PendingCoaLot.fromJson(jsonDecode(item.body));
                if (lot != null && value is CoaData) onResolved(lot.lotGuid, value);
              },
      );
    } catch (e) {
      debugPrint('lab reports could not be queued for upload: $e');
    }
  }
}
