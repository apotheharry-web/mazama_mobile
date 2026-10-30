// specs/phone-sync PS-R8: the demo's sync engine. Its datasets come from the demo's own invented data (DemoBackend,
// assets/demo/demo.json), stored with source `demo` in the demo's own database (its data folder: specs/foundations
// P-D2, one database per folder, never mazama.db in the app's folder); its queue never sends (every sender answers
// Skipped) and never takes an upload or a lab report (CU-R6), and its server tracker never probes anything.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../local_store.dart';
import '../server_health.dart';
import '../sync/sync_datasets.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_queue.dart';
import 'demo_backend.dart';

/// The engine for [demo] (the file comment).
SyncEngine demoEngine(DemoBackend demo, {DateTime Function()? now, StartTimer? startTimer}) {
  Future<bool> answers() async => true;
  final health = startTimer == null ? ServerHealth(probe: answers) : ServerHealth(probe: answers, startTimer: startTimer);
  LocalStore store;
  try {
    store = LocalStore.forDir(demo.dataDir);
  } catch (e) {
    // The demo folder's database can't be opened (disk full, read-only): the demo still starts, its datasets in memory
    // for this run (as ServerLink.standard does for the app's own).
    debugPrint("the demo's local store could not be opened, its datasets are kept in memory: $e");
    store = LocalStore.inMemory();
  }
  final engine = SyncEngine(
    store: store,
    health: health,
    senders: {for (final k in QueueKind.values) k: (item) async => const Skipped()},
    now: now,
    startTimer: startTimer,
    isDemo: () => true,
  );
  int center(String key) => int.tryParse(key) ?? (throw ArgumentError.value(key, 'key', 'not a center id'));
  ({String body, String source}) demoBody(Object? json) => (body: jsonEncode(json), source: sourceDemo);
  engine.register(Dataset.par, (key) async => demoBody([for (final l in await demo.fetchParLevels(center(key))) l.toJson()]));
  engine.register(
      Dataset.sheets, (key) async => demoBody([for (final s in await demo.fetchProductSheets(center(key))) s.toJson()]));
  engine.register(Dataset.mazamaInventory, (key) async => demoBody((await demo.fetchMazamaInventory()).toJson()));
  engine.register(Dataset.recentSales,
      (key) async => demoBody(await demo.fetchSalesRecords(center(key), accessToken: demo.session.accessToken)));
  engine.register(
      Dataset.licenses,
      (key) async => demoBody([
            for (final l in await demo.fetchLicenses(demo.session.accessToken))
              {'id': l.id, 'licenseId': l.licenseId, 'licenseName': l.licenseName, 'licenseType': l.licenseType}
          ]));
  engine.register(
      Dataset.centerStock,
      (key) async => demoBody({
            'packages': [for (final p in await demo.fetchPackages(center(key))) p.toJson()],
            'source': sourceDemo,
          }));
  return engine;
}
