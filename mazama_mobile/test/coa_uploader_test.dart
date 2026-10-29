// coa_uploader.dart: the phone's one background uploader of lab reports (specs/coa-upload CU-R1..R6) - paced to the
// server's budget, no cap per load, one queue for the app, the 24-hour sent memory, what each reply means, and never in
// the demo. Fake clock, fake timers and a fake sender throughout: no real time, no network.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/api_contract.g.dart' show coaDataParseRateLimitPerMinute;
import 'package:mazama_mobile/catch_up_store.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/coa_uploader.dart';
import 'package:mazama_mobile/configured_coa_submit.dart';
import 'package:mazama_mobile/demo/demo_banner.dart' show demoModeOn;
import 'package:mazama_mobile/server_health.dart';

import 'fake_timers.dart';

late Directory _dir;

CoaData _data(String guid, {String strain = 'Golden Teacher'}) =>
    CoaData(guid: guid, strain: strain, psilocybin: 10, psilocin: 1, baeocystin: 0, norbaeocystin: 0, norpsilocin: 0, tpe: 11.4);

CoaUploadLot _lot(String guid, {int packageId = 1, int stateId = 231, double? psi}) =>
    CoaUploadLot(lotGuid: guid, packageId: packageId, stateId: stateId, statePsilocybin: psi);

void main() {
  late FakeTimers timers;
  late ServerHealth health;
  late CatchUpWork catchUp;
  late DateTime clock;
  late bool demo;
  late CatchUpAuth? auth;

  /// Every send, in order: the lot, when it started, the token it used, and the completer that finishes it.
  late List<({String guid, DateTime at, String token, Completer<CoaData?> done})> sends;

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('mazama_coa_uploader_test_');
    timers = FakeTimers();
    health = ServerHealth(probe: () async => false, startTimer: timers.start);
    catchUp = CatchUpWork(
      health: health,
      store: CatchUpStore(dataDir: () => _dir),
      submitCoa: (lot, a) async => true,
      uploadSnapshot: (s) async {},
      auth: () async => auth,
    );
    clock = DateTime.utc(2026, 10, 27, 18);
    demo = false;
    auth = const CatchUpAuth(accessToken: 'NOW-TOKEN', workerEmail: 'w@example.com', deviceId: 'D-1');
    sends = [];
  });
  tearDown(() {
    catchUp.dispose();
    health.dispose();
    _dir.deleteSync(recursive: true);
  });

  CoaSentMemory memory({int maxLots = coaSentMaxLots}) =>
      CoaSentMemory(store: CoaSentStore(dataDir: () => _dir), now: () => clock, maxLots: maxLots);

  CoaUploader uploader({CoaSentMemory? sent, bool Function()? isDemo}) => CoaUploader(
        health: health,
        catchUp: catchUp,
        auth: () async => auth,
        sent: sent ?? memory(),
        now: () => clock,
        startTimer: timers.start,
        isDemo: isDemo ?? () => demo,
        send: (lot, a) {
          final done = Completer<CoaData?>();
          sends.add((guid: lot.lotGuid, at: clock, token: a.accessToken, done: done));
          return done.future;
        },
      );

  /// Fires whatever start timer is waiting, then lets the started uploads reach the sender.
  Future<void> fire() async {
    timers.fireAll();
    await pumpEventQueue();
  }

  /// Finishes the send of [guid] with [data] (null: no PDF), or fails it with [error].
  Future<void> finish(String guid, {CoaData? data, Object? error}) async {
    final s = sends.lastWhere((s) => s.guid == guid);
    if (error != null) {
      s.done.completeError(error);
    } else {
      s.done.complete(data);
    }
    await pumpEventQueue();
  }

  test('the pace is the server budget for C6: one start every 3 s', () {
    expect(coaUploadStartInterval, const Duration(minutes: 1) ~/ coaDataParseRateLimitPerMinute);
    expect(coaUploadStartInterval, const Duration(seconds: 3));
    expect(coaUploadMaxInFlight, 2);
    expect(coaSentKeepFor, const Duration(hours: 24));
    expect(coaSentMaxLots, 2000);
  });

  test('pacing: no more than one start every 3 s, at most 2 in flight', () async {
    final u = uploader();
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1'), _lot('HB-2'), _lot('HB-3'), _lot('HB-4')]);
    expect(sends, isEmpty); // enqueue never starts anything itself: the first start is on a timer
    expect(timers.pendingDelays, [Duration.zero]);

    await fire();
    expect([for (final s in sends) s.guid], ['HB-1']);
    expect(timers.pendingDelays, [const Duration(seconds: 3)]); // the next start waits out the interval

    clock = clock.add(const Duration(seconds: 1));
    await fire(); // a timer fired early by the test still starts only one
    expect([for (final s in sends) s.guid], ['HB-1', 'HB-2']);
    expect(u.inFlight, 2);
    expect(timers.pendingDelays, isEmpty); // two in flight: nothing more is scheduled

    clock = clock.add(const Duration(seconds: 1));
    await finish('HB-1', data: _data('HB-1'));
    expect(u.inFlight, 1);
    expect(timers.pendingDelays, [const Duration(seconds: 2)]); // 3 s after HB-2 started

    clock = clock.add(const Duration(seconds: 2));
    await fire();
    expect([for (final s in sends) s.guid], ['HB-1', 'HB-2', 'HB-3']);
    expect(timers.pendingDelays, isEmpty);
    expect(sends.map((s) => s.token).toSet(), {'NOW-TOKEN'}); // the session as it is at send time
  });

  test('no cap of 20: every lot of a load is sent', () async {
    final u = uploader();
    addTearDown(u.dispose);
    u.enqueue([for (var i = 0; i < 25; i++) _lot('HB-$i', packageId: i)]);
    var maxInFlight = 0;
    for (var round = 0; round < 100 && !u.idle; round++) {
      await fire();
      if (u.inFlight > maxInFlight) maxInFlight = u.inFlight;
      clock = clock.add(coaUploadStartInterval);
      for (final s in [...sends]) {
        if (!s.done.isCompleted) await finish(s.guid, error: ConfiguredCoaSubmitError('queued', status: 202));
      }
    }
    expect(sends, hasLength(25));
    expect(sends.map((s) => s.guid).toSet(), hasLength(25));
    expect(maxInFlight, lessThanOrEqualTo(2));
    for (var i = 1; i < sends.length; i++) {
      expect(sends[i].at.difference(sends[i - 1].at), greaterThanOrEqualTo(coaUploadStartInterval));
    }
  });

  test('dedupe across two loads: only lots not already waiting or in flight are added; each caller is told', () async {
    final u = uploader();
    addTearDown(u.dispose);
    final first = <String>[], second = <String>[];
    u.enqueue([_lot('HB-1'), _lot('HB-2')], onResolved: (g, d) => first.add(g));
    await fire(); // HB-1 in flight, HB-2 waiting
    u.enqueue([_lot('hb-1'), _lot('HB-2'), _lot('HB-3')], onResolved: (g, d) => second.add(g));
    expect(u.waiting, 2); // HB-2 and HB-3
    expect(timers.active, hasLength(1)); // one run, not a second one

    await finish('HB-1', data: _data('HB-1'));
    for (var i = 0; i < 5 && !u.idle; i++) {
      await fire();
      for (final s in [...sends]) {
        if (!s.done.isCompleted) await finish(s.guid, data: _data(s.guid));
      }
    }
    expect([for (final s in sends) s.guid], ['HB-1', 'HB-2', 'HB-3']);
    expect(first, ['HB-1', 'HB-2']);
    expect(second, ['HB-1', 'HB-2', 'HB-3']); // told about the lots it shared with the first load too
  });

  test('a status below 500 marks a lot sent; it is not sent again for 24 hours', () async {
    final sent = memory();
    final u = uploader(sent: sent);
    addTearDown(u.dispose);
    final replies = <String, Object?>{
      'HB-200': null, // answered with numbers
      'HB-202': ConfiguredCoaSubmitError('the server answered HTTP 202', status: 202), // queued, or held
      'HB-400': ConfiguredCoaSubmitError('Not a PDF.', status: 400),
      'HB-422': ConfiguredCoaSubmitError("this lot isn't in the PDF", status: 422),
    };
    u.enqueue([for (final g in replies.keys) _lot(g)]);
    for (final e in replies.entries) {
      await fire();
      if (e.value == null) {
        await finish(e.key, data: _data(e.key));
      } else {
        await finish(e.key, error: e.value);
      }
    }
    expect([for (final s in sends) s.guid], replies.keys.toList());
    for (final g in replies.keys) {
      expect(sent.wasSent(g), isTrue, reason: g);
      expect(sent.wasSent(g.toLowerCase()), isTrue, reason: 'any case');
    }
    expect(catchUp.lots, isEmpty);

    u.enqueue([for (final g in replies.keys) _lot(g)]);
    expect(u.waiting, 0);
    expect(timers.active, isEmpty);

    clock = clock.add(const Duration(hours: 24, seconds: 1));
    u.enqueue([_lot('HB-202')]);
    expect(u.waiting, 1); // a day later it may go again
  });

  test('the sent memory: kept across restarts for 24 hours, at most 2,000 lots, the oldest dropped first', () {
    final m = memory();
    m.markSent('HB-a');
    clock = clock.add(const Duration(hours: 1));
    m.markSent('HB-b');
    final again = memory(); // a restart: read from the file
    expect(again.wasSent('hb-A'), isTrue);
    expect(again.wasSent('HB-b'), isTrue);
    expect(again.wasSent('HB-c'), isFalse);
    clock = clock.add(const Duration(hours: 23, minutes: 1));
    expect(again.wasSent('HB-a'), isFalse); // 24 h and a minute
    expect(again.wasSent('HB-b'), isTrue);
    again.markSent('HB-c'); // drops the expired one from the file
    expect(memory().length, 2);

    final capped = memory(maxLots: 3);
    for (final g in ['HB-1', 'HB-2', 'HB-3', 'HB-4']) {
      clock = clock.add(const Duration(seconds: 1));
      capped.markSent(g);
    }
    final read = memory(maxLots: 3);
    expect(read.length, 3);
    expect(read.wasSent('HB-1'), isFalse); // the oldest went first
    expect([for (final g in ['HB-2', 'HB-3', 'HB-4']) read.wasSent(g)], [true, true, true]);

    expect(CoaSentMemory(store: CoaSentStore(dataDir: () => _dir)).maxLots, coaSentMaxLots);
  });

  test('the cap at its real size: the 2,001st lot drops the oldest', () {
    // Seeded in one file write: 2,000 lots sent one second apart, the oldest first.
    final seed = <String, DateTime>{
      for (var i = 0; i < coaSentMaxLots; i++) 'hb-$i': clock.subtract(Duration(seconds: coaSentMaxLots - i)),
    };
    CoaSentStore(dataDir: () => _dir).save(seed);
    final m = memory();
    expect(m.length, coaSentMaxLots);
    m.markSent('HB-new');
    expect(m.length, coaSentMaxLots);
    expect(m.wasSent('hb-0'), isFalse);
    expect(m.wasSent('hb-1'), isTrue);
    expect(m.wasSent('HB-new'), isTrue);
  });

  test('a 5xx or no connection puts the lot being sent on the catch-up list; the waiting lots are let go, unmarked',
      () async {
    final sent = memory();
    final u = uploader(sent: sent);
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1', packageId: 101, psi: 4.5), _lot('HB-2', packageId: 102), _lot('HB-3')]);
    await fire();
    await finish('HB-1', error: ConfiguredCoaSubmitError('the server answered HTTP 503', status: 503, unreachable: true));
    expect([for (final l in catchUp.lots) (l.lotGuid, l.packageId, l.stateId, l.statePsilocybin)], [('HB-1', 101, 231, 4.5)]);
    expect(u.idle, isTrue); // HB-2 and HB-3 let go: the next load enqueues them again
    expect(timers.active, isEmpty);
    expect([for (final s in sends) s.guid], ['HB-1']);

    u.enqueue([_lot('HB-1'), _lot('HB-2', packageId: 102)]); // the next load
    expect(u.waiting, 1); // HB-1 waits on the catch-up list: not sent a second time
    await fire();
    await finish('HB-2', error: ConfiguredCoaSubmitError('cannot reach sales.mazamamushrooms.com', unreachable: true));
    expect([for (final l in catchUp.lots) l.lotGuid], ['HB-1', 'HB-2']);
    expect(sent.wasSent('HB-1'), isFalse);
    expect(sent.wasSent('HB-2'), isFalse);
    expect(sent.wasSent('HB-3'), isFalse);
  });

  test("a full catch-up list takes no lot from the uploader, so a cart add's lot is never pushed out", () async {
    catchUp.dispose();
    catchUp = CatchUpWork(
      health: health,
      store: CatchUpStore(dataDir: () => _dir),
      maxLots: 2,
      submitCoa: (lot, a) async => true,
      uploadSnapshot: (s) async {},
      auth: () async => auth,
    );
    // two cart adds' lots already wait for the server
    catchUp.addCoaLot(lotGuid: 'HB-cart1', packageId: 1, stateId: 231);
    catchUp.addCoaLot(lotGuid: 'HB-cart2', packageId: 2, stateId: 231);
    final u = uploader();
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1')]);
    await fire();
    await finish('HB-1', error: ConfiguredCoaSubmitError('the server answered HTTP 502', status: 502, unreachable: true));
    expect([for (final l in catchUp.lots) l.lotGuid], ['HB-cart1', 'HB-cart2']);
  });

  test('while the tracker counts the server offline nothing starts and the waiting lots are let go, unmarked', () async {
    final sent = memory();
    final u = uploader(sent: sent);
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1'), _lot('HB-2')]);
    health.markUnreachable();
    await fire();
    expect(sends, isEmpty);
    expect(catchUp.lots, isEmpty); // never filled in bulk from here
    expect(u.idle, isTrue);
    expect(sent.wasSent('HB-1'), isFalse);
    health.markReachable();
    u.enqueue([_lot('HB-1'), _lot('HB-2')]); // the next load
    expect(u.waiting, 2);
  });

  test('isPending: a lot waiting or being sent, in any case; not once it is done', () async {
    final u = uploader();
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1'), _lot('HB-2')]);
    expect([u.isPending('hb-1'), u.isPending('HB-2'), u.isPending('HB-3')], [true, true, false]);
    await fire();
    expect(u.isPending('HB-1'), isTrue); // in flight
    await finish('HB-1', data: _data('HB-1'));
    expect(u.isPending('HB-1'), isFalse);
  });

  test('a 429 stops the run without marking the lot; the next load picks the lots up again', () async {
    final sent = memory();
    final u = uploader(sent: sent);
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1'), _lot('HB-2'), _lot('HB-3')]);
    await fire();
    await finish('HB-1', error: ConfiguredCoaSubmitError('Too many requests', status: 429));
    expect(u.waiting, 0);
    expect(timers.active, isEmpty);
    await fire();
    expect([for (final s in sends) s.guid], ['HB-1']);
    expect(sent.wasSent('HB-1'), isFalse);
    expect(catchUp.lots, isEmpty);

    u.enqueue([_lot('HB-1'), _lot('HB-2'), _lot('HB-3')]); // the next load
    expect(u.waiting, 3);
    await fire();
    expect([for (final s in sends) s.guid], ['HB-1', 'HB-1']);
  });

  test('a lot with no PDF on file is skipped: not marked, not kept, the queue goes on', () async {
    final sent = memory();
    final u = uploader(sent: sent);
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1'), _lot('HB-2')]);
    await fire();
    await finish('HB-1'); // null: the state has no accepted potency PDF for it
    await fire();
    expect([for (final s in sends) s.guid], ['HB-1', 'HB-2']);
    expect(sent.wasSent('HB-1'), isFalse);
    expect(catchUp.lots, isEmpty);
    await finish('HB-2', data: _data('HB-2'));
    u.enqueue([_lot('HB-1')]); // a later load asks again
    expect(u.waiting, 1);
  });

  test("a failure of the state system's own read is not counted as sent", () async {
    final sent = memory();
    final u = uploader(sent: sent);
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1')]);
    await fire();
    await finish('HB-1', error: ConfiguredCoaSubmitError('the state system answered HTTP 401'));
    expect(sent.wasSent('HB-1'), isFalse);
    expect(catchUp.lots, isEmpty);
  });

  test('a lot sent meanwhile (a cart add) is not started', () async {
    final sent = memory();
    final u = uploader(sent: sent);
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1'), _lot('HB-2')]);
    sent.markSent('HB-1');
    await fire();
    expect([for (final s in sends) s.guid], ['HB-2']);
  });

  test('a lot resolved later is passed to the callback with its numbers', () async {
    final u = uploader();
    addTearDown(u.dispose);
    final got = <(String, String)>[];
    u.enqueue([_lot('HB-1')], onResolved: (g, d) => got.add((g, d.strain)));
    await fire();
    expect(got, isEmpty);
    await finish('HB-1', data: _data('HB-1', strain: 'Blue Meanie'));
    expect(got, [('HB-1', 'Blue Meanie')]);
  });

  test('no usable session: nothing is sent, the waiting lots are let go', () async {
    auth = null;
    final u = uploader();
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1'), _lot('HB-2')]);
    await fire();
    expect(sends, isEmpty);
    expect(u.idle, isTrue);
    expect(catchUp.lots, isEmpty);
  });

  test('demo mode never uploads', () async {
    demo = true;
    final u = uploader();
    addTearDown(u.dispose);
    u.enqueue([_lot('HB-1')]);
    expect(u.waiting, 0);
    expect(timers.active, isEmpty);

    // the default check reads the app's demo flag
    demoModeOn.value = true;
    addTearDown(() => demoModeOn.value = false);
    final real = CoaUploader(
        health: health,
        catchUp: catchUp,
        auth: () async => auth,
        sent: memory(),
        startTimer: timers.start,
        send: (lot, a) async => fail('the demo sent a lab report'));
    addTearDown(real.dispose);
    real.enqueue([_lot('HB-1')]);
    expect(real.waiting, 0);
    expect(timers.active, isEmpty);
  });

  test('dispose: nothing more starts', () async {
    final u = uploader();
    u.enqueue([_lot('HB-1'), _lot('HB-2')]);
    u.dispose();
    await fire();
    expect(sends, isEmpty);
    u.enqueue([_lot('HB-3')]);
    expect(u.waiting, 0);
  });

  test('which errors count as sent', () {
    expect(countsAsSent(ConfiguredCoaSubmitError('x', status: 202)), isTrue);
    expect(countsAsSent(CoaDataError('x', status: 409)), isTrue);
    expect(countsAsSent(ConfiguredCoaSubmitError('x', status: 429)), isFalse);
    expect(countsAsSent(ConfiguredCoaSubmitError('x', status: 502, unreachable: true)), isFalse);
    expect(countsAsSent(ConfiguredCoaSubmitError('x', unreachable: true)), isFalse);
    expect(countsAsSent(Exception('x')), isFalse);
  });
}
