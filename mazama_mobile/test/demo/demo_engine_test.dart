// demo/demo_engine.dart (specs/phone-sync PS-R8): the demo's datasets come from its own invented data, with source
// demo, in the demo's own database; it never sends anything and never queues an upload or a lab report.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/demo/demo_backend.dart';
import 'package:mazama_mobile/demo/demo_engine.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';
import 'package:mazama_mobile/sync/sync_queue.dart';

import '../fake_timers.dart';

void main() {
  late Directory demoDir, appDir;
  setUp(() {
    demoDir = Directory.systemTemp.createTempSync('mazama_demo_engine_test_');
    appDir = Directory.systemTemp.createTempSync('mazama_demo_engine_app_');
  });
  tearDown(() {
    LocalStore.debugCloseAll();
    demoDir.deleteSync(recursive: true);
    appDir.deleteSync(recursive: true);
  });

  DemoBackend demo() => DemoBackend(
        jsonDecode(File('assets/demo/demo.json').readAsStringSync()) as Map<String, Object?>,
        File('assets/demo/label.png').readAsBytesSync(),
        dataDir: demoDir,
      );

  test("the demo's datasets come from its assets", () async {
    final d = demo();
    final e = demoEngine(d, startTimer: FakeTimers().start);
    addTearDown(e.dispose);
    final id = '$demoStateId';
    for (final (ds, key) in [
      (Dataset.par, id),
      (Dataset.sheets, id),
      (Dataset.mazamaInventory, ''),
      (Dataset.recentSales, id),
      (Dataset.licenses, ''),
      (Dataset.centerStock, id),
    ]) {
      await e.refresh(ds, key);
      final row = e.datasets.read(ds, key);
      expect(row, isNotNull, reason: ds.stored);
      expect([row!.source, row.lastError], [sourceDemo, null], reason: ds.stored);
    }
    final stock = jsonDecode(e.datasets.read(Dataset.centerStock, id)!.body) as Map;
    expect((stock['packages'] as List).length, (await d.fetchPackages(demoStateId)).length);
    final licenses = jsonDecode(e.datasets.read(Dataset.licenses, '')!.body) as List;
    expect((licenses.single as Map)['id'], d.center.id);
  });

  test('the demo never sends or queues an upload or lab report', () async {
    final e = demoEngine(demo(), startTimer: FakeTimers().start);
    addTearDown(e.dispose);
    e.queue.add(QueueKind.inventorySnapshot, '$demoStateId', {'records': []});
    e.queue.add(QueueKind.salesSnapshot, '$demoStateId', {'records': []});
    e.queue.add(QueueKind.labReport, 'HB-aaaa0001', {'lotGuid': 'HB-aaaa0001'});
    for (final k in ['inventory_snapshot', 'sales_snapshot', 'lab_report']) {
      expect(e.queue.tables.items(k), isEmpty, reason: k);
    }
    e.wake();
    e.onForeground();
    await pumpEventQueue();
    expect(e.queue.waitingReports, 0);
  });

  test("a demo folder whose database can't be opened still gives an engine (in memory), so the demo starts", () async {
    final blocked = File('${demoDir.path}/not-a-folder')..writeAsStringSync('x');
    final d = DemoBackend(
      jsonDecode(File('assets/demo/demo.json').readAsStringSync()) as Map<String, Object?>,
      File('assets/demo/label.png').readAsBytesSync(),
      dataDir: Directory(blocked.path),
    );
    final e = demoEngine(d, startTimer: FakeTimers().start);
    addTearDown(e.dispose);
    await e.refresh(Dataset.par, '$demoStateId');
    expect(e.datasets.read(Dataset.par, '$demoStateId')!.source, sourceDemo);
  });

  test('the demo uses its own database, never mazama.db in the app folder', () async {
    final e = demoEngine(demo(), startTimer: FakeTimers().start);
    addTearDown(e.dispose);
    await e.refresh(Dataset.par, '$demoStateId');
    expect(File('${demoDir.path}/$localStoreFileName').existsSync(), isTrue);
    expect(File('${appDir.path}/$localStoreFileName').existsSync(), isFalse);
    expect(Datasets.forDir(() => appDir).read(Dataset.par, '$demoStateId'), isNull);
    expect(Datasets.forDir(() => demoDir).read(Dataset.par, '$demoStateId')!.source, sourceDemo);
  });
}
