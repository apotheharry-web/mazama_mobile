// The phone's one background uploader of lab reports (specs/coa-upload, CU-R1..R6): every lot in a center's stock whose
// result Mazama's server doesn't have is sent, for both kinds of center, without holding up the load, the stock page or
// a sale.
//   - Who enqueues: coa_data_resolver.dart (a center the server doesn't track: the lots its batch lookup didn't return)
//     and cart_page.dart (a center the server tracks: the lots whose package says coaAvailable false). The cart's own
//     submission on a cart add (configured_coa_submit.dart, through server_link.dart) stays as it was.
//   - One per app ([ServerLink.coaUploads]), not one per page: a second load of a center adds only the lots that aren't
//     already waiting or being sent (CU-R2).
//   - Paced to the server's budget for C6 (routes.yaml coa_data_parse, coaDataParseRateLimitPerMinute): one start every
//     [coaUploadStartInterval] at most, [coaUploadMaxInFlight] in flight at most. Every start is on a timer, never
//     inside the enqueue call, so the load that enqueued always returns first.
//   - Each lot runs the existing chain (configured_coa_submit.dart's submitCoaForLot: GetPackagedProductInfo for one
//     package of the lot, the newest accepted potency PDF, DownloadDocument, POST /p/coa-data/parse) with the worker's
//     session as it is at send time.
//   - What the reply means (CU-R3, CU-R4):
//       200 with numbers: sent, and every caller that asked about the lot is told (the cart patches it in);
//       any other reply below 500 (202 queued, 202 held, 4xx refused): sent, nothing to patch;
//       429: busy - the run stops, the waiting lots are let go and none is marked; the next load enqueues them again;
//       5xx or no connection (server_error.dart's rule), for a lot actually being sent: that lot is kept on the
//       catch-up list (catch_up_store.dart), as a cart add's would be, and only while the list has room, so these
//       never push out a cart add's lot; the waiting lots are let go, unmarked, and the next load enqueues them again.
//       While the tracker counts the server offline nothing starts and the waiting lots are let go the same way, so
//       the catch-up list (sent unpaced once the server answers) never fills up from here;
//       no potency PDF on file at the state, or the state's read failing: skipped, nothing remembered.
//   - Sent lots are remembered for [coaSentKeepFor] (CU-D2, the server's own SH-D3), at most [coaSentMaxLots], the
//     oldest dropped first, in coa_sent.json beside the catch-up file ([CoaSentStore]). The waiting queue itself is
//     only in memory: the next load fills it again.
//   - Never in the demo (CU-R6): nothing is enqueued while demo mode is on, and the demo's cart and resolver never call
//     this at all (demo_backend.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api_contract.g.dart' show coaDataParseRateLimitPerMinute;
import 'catch_up_store.dart';
import 'coa_data_client.dart' show CoaData, CoaDataError;
import 'configured_coa_submit.dart' as configured_coa_submit;
import 'demo/demo_banner.dart' show demoModeOn;
import 'local_store.dart';
import 'server_error.dart';
import 'server_health.dart';
import 'session_store.dart' show defaultSessionDataDir;

/// The least time between two uploads starting: the server's per-minute budget for /p/coa-data/parse spread evenly
/// (20 a minute: one every 3 s).
const coaUploadStartInterval = Duration(milliseconds: 60000 ~/ coaDataParseRateLimitPerMinute);

/// How many uploads may be under way at once.
const coaUploadMaxInFlight = 2;

/// How long a sent lot isn't sent again (CU-D2).
const coaSentKeepFor = Duration(hours: 24);

/// How many sent lots are remembered at most, the oldest dropped first (CU-R3).
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

/// Adds lots to the app's uploader ([CoaUploader.enqueue]); [onResolved] is told about each one the server answers
/// with numbers.
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

/// Whether a failed upload still counts as sent (CU-R3): the server answered it below 500 and it wasn't a 429.
bool countsAsSent(Object? error) {
  final status = coaReplyStatus(error);
  return status != null && status < 500 && status != 429;
}

/// Where the sent lots are kept (the coa_sent.json document, beside the catch-up one in the folder's LocalStore).
class CoaSentStore {
  const CoaSentStore({Directory Function()? dataDir}) : dataDir = dataDir ?? defaultSessionDataDir;

  /// Overridable for tests, as the other stores.
  final Directory Function() dataDir;

  static const _name = 'coa_sent.json';

  /// Lot id (lower case) to when it was sent, oldest first; empty when nothing is kept or it can't be read.
  Map<String, DateTime> load() {
    try {
      final text = LocalStore.forDir(dataDir()).read(_name)?.body;
      if (text == null) return <String, DateTime>{};
      final d = jsonDecode(text);
      final lots = d is Map ? d['lots'] : null;
      if (lots is! List) return <String, DateTime>{};
      final entries = <MapEntry<String, DateTime>>[];
      for (final l in lots) {
        if (l is! Map) continue;
        final guid = l['lotGuid'], at = l['sentAtMs'];
        if (guid is! String || guid.isEmpty || at is! int) continue;
        entries.add(MapEntry(guid.toLowerCase(), DateTime.fromMillisecondsSinceEpoch(at, isUtc: true)));
      }
      entries.sort((a, b) => a.value.compareTo(b.value));
      return Map<String, DateTime>.fromEntries(entries);
    } on FileSystemException {
      return <String, DateTime>{};
    } on FormatException {
      return <String, DateTime>{};
    }
  }

  void save(Map<String, DateTime> sent) {
    LocalStore.forDir(dataDir()).write(_name, jsonEncode({
      'lots': [
        for (final e in sent.entries) {'lotGuid': e.key, 'sentAtMs': e.value.millisecondsSinceEpoch},
      ],
    }));
  }
}

/// The lots this phone sent lately (CU-R3): none is sent again for [keepFor]; at most [maxLots] are kept, the oldest
/// dropped first. Read from [store] on first use, so making one touches no file.
class CoaSentMemory {
  CoaSentMemory(
      {this.store = const CoaSentStore(), this.now = DateTime.now, this.keepFor = coaSentKeepFor, this.maxLots = coaSentMaxLots});

  final CoaSentStore store;
  final DateTime Function() now;
  final Duration keepFor;
  final int maxLots;

  Map<String, DateTime>? _sent;

  Map<String, DateTime> get _lots => _sent ??= _load();

  Map<String, DateTime> _load() {
    try {
      return store.load();
    } catch (_) {
      return <String, DateTime>{};
    }
  }

  /// How many lots are remembered (expired ones included until the next [markSent]).
  int get length => _lots.length;

  /// Whether [lotGuid] (any case) was sent less than [keepFor] ago.
  bool wasSent(String lotGuid) {
    final at = _lots[lotGuid.toLowerCase()];
    return at != null && now().toUtc().difference(at) < keepFor;
  }

  /// Remembers [lotGuid] as sent now.
  void markSent(String lotGuid) {
    final key = lotGuid.toLowerCase();
    if (key.isEmpty) return;
    final lots = _lots;
    final at = now().toUtc();
    lots.remove(key);
    lots.removeWhere((_, sentAt) => at.difference(sentAt) >= keepFor);
    lots[key] = at;
    while (lots.length > maxLots) {
      lots.remove(lots.keys.first);
    }
    try {
      store.save(lots);
    } catch (e) {
      debugPrint('the sent lab reports could not be saved (kept in memory until the next write): $e');
    }
  }
}

Timer _realTimer(Duration delay, void Function() callback) => Timer(delay, callback);

bool _demoModeIsOn() => demoModeOn.value;

class CoaUploader {
  CoaUploader({
    required this.health,
    required this.catchUp,
    required this.auth,
    CoaSentMemory? sent,
    this.send = sendCoaLot,
    this.now = DateTime.now,
    this.startTimer = _realTimer,
    this.isDemo = _demoModeIsOn,
    this.startInterval = coaUploadStartInterval,
    this.maxInFlight = coaUploadMaxInFlight,
  }) : sent = sent ?? CoaSentMemory(now: now);

  final ServerHealth health;

  /// Where a lot goes when the server can't be reached (CU-R4).
  final CatchUpWork catchUp;

  /// The worker's session as it is now, and this install's id (server_link.dart's savedSessionAuth); null when there is
  /// no usable session (nothing is sent then: the next load enqueues the lots again).
  final Future<CatchUpAuth?> Function() auth;
  final CoaSentMemory sent;
  final CoaLotSend send;
  final DateTime Function() now;
  final StartTimer startTimer;

  /// True in demo mode (CU-R6): nothing is enqueued or started.
  final bool Function() isDemo;
  final Duration startInterval;
  final int maxInFlight;

  final _queue = <CoaUploadLot>[];

  /// Who to tell about each lot waiting or being sent, by lot id in lower case.
  final _listeners = <String, List<CoaLotResolved>>{};
  final _inFlight = <String>{};
  DateTime? _lastStart;
  Timer? _timer;
  bool _disposed = false;

  /// How many lots wait to start.
  int get waiting => _queue.length;

  /// How many uploads are under way.
  int get inFlight => _inFlight.length;

  /// Nothing waiting and nothing under way.
  bool get idle => _queue.isEmpty && _inFlight.isEmpty;

  /// Whether [lotGuid] (any case) is waiting or being sent: the cart's own submission on a cart add skips it, so the
  /// same report isn't downloaded twice at once.
  bool isPending(String lotGuid) => _listeners.containsKey(lotGuid.toLowerCase());

  /// Adds [lots] to the queue, leaving out any already waiting or being sent (whose [onResolved] is added to it), sent
  /// in the last [CoaSentMemory.keepFor], or waiting on the catch-up list. Returns at once; uploads start on a timer.
  void enqueue(List<CoaUploadLot> lots, {CoaLotResolved? onResolved}) {
    if (_disposed || isDemo() || lots.isEmpty) return;
    final kept = {for (final l in catchUp.lots) l.lotGuid.toLowerCase()};
    for (final lot in lots) {
      final key = lot.lotGuid.toLowerCase();
      if (key.isEmpty) continue;
      final listeners = _listeners[key];
      if (listeners != null) {
        if (onResolved != null) listeners.add(onResolved);
        continue;
      }
      if (kept.contains(key) || sent.wasSent(key)) continue;
      _queue.add(lot);
      _listeners[key] = [if (onResolved != null) onResolved];
    }
    _schedule();
  }

  /// Starts the next upload's timer when one may start: the rest of [startInterval] since the last start, or none.
  void _schedule() {
    if (_disposed || _timer != null || _queue.isEmpty || _inFlight.length >= maxInFlight) return;
    final last = _lastStart;
    var wait = last == null ? Duration.zero : startInterval - now().difference(last);
    if (wait.isNegative) wait = Duration.zero;
    _timer = startTimer(wait, () {
      _timer = null;
      _startNext();
    });
  }

  void _startNext() {
    if (_disposed) return;
    if (isDemo()) {
      _letGo();
      return;
    }
    if (health.offline) {
      // The server can't be reached: the waiting lots are let go, unmarked; the next load enqueues them again (CU-R4).
      _letGo();
      return;
    }
    while (_queue.isNotEmpty && _inFlight.length < maxInFlight) {
      final lot = _queue.removeAt(0);
      final key = lot.lotGuid.toLowerCase();
      if (sent.wasSent(key)) {
        _listeners.remove(key); // sent meanwhile (a cart add): nothing to start
        continue;
      }
      _inFlight.add(key);
      _lastStart = now();
      unawaited(_upload(lot, key));
      break;
    }
    _schedule();
  }

  Future<void> _upload(CoaUploadLot lot, String key) async {
    try {
      CatchUpAuth? credentials;
      try {
        credentials = await auth();
      } catch (_) {
        credentials = null;
      }
      if (credentials == null) {
        _letGo(); // no usable session now: nothing can be sent; the next load enqueues the lots again
        return;
      }
      if (_disposed) return;
      CoaData? data;
      try {
        data = await send(lot, credentials);
      } catch (e) {
        _failed(lot, key, e);
        return;
      }
      if (data == null) return; // no potency PDF on file at the state: skipped, as before
      sent.markSent(key);
      if (_disposed) return;
      for (final listener in [...?_listeners[key]]) {
        try {
          listener(lot.lotGuid, data);
        } catch (e) {
          debugPrint('a lab report listener failed (the upload itself went through): $e');
        }
      }
    } finally {
      _inFlight.remove(key);
      _listeners.remove(key);
      _schedule();
    }
  }

  void _failed(CoaUploadLot lot, String key, Object error) {
    final status = coaReplyStatus(error);
    if (status == 429) {
      _letGo(); // busy: this run stops, nothing is marked; the next load enqueues the lots again (CU-R4)
      return;
    }
    if (isServerUnreachable(error)) {
      // A 5xx or no connection: this lot is sent again once the server answers (CU-R4); the rest wait for a later load.
      _keepForLater(lot);
      _letGo();
      return;
    }
    if (countsAsSent(error)) {
      sent.markSent(key); // queued, held or refused: the server has its answer (CU-R3)
    }
    // Anything else (the state system's read failing): not sent; the next load tries again.
  }

  void _keepForLater(CoaUploadLot lot) {
    // Never at the cost of a cart add's lot: the list drops its oldest when full, so a lot from here waits only in room.
    if (catchUp.lots.length >= catchUp.maxLots) return;
    try {
      catchUp.addCoaLot(lotGuid: lot.lotGuid, packageId: lot.packageId, stateId: lot.stateId, statePsilocybin: lot.statePsilocybin);
    } catch (e) {
      debugPrint('a lab report could not be kept for later: $e');
    }
  }

  /// Lets go of every waiting lot (those under way finish).
  void _letGo() {
    for (final lot in _queue) {
      _listeners.remove(lot.lotGuid.toLowerCase());
    }
    _queue.clear();
    _timer?.cancel();
    _timer = null;
  }

  /// The app is closing: nothing more starts. The sent memory and the catch-up list are on disk already.
  void dispose() {
    _letGo();
    _disposed = true;
  }
}
