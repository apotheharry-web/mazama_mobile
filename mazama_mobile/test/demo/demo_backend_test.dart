// Demo mode (specs/demo-mode DM-R1, DM-R2, DM-D4, DM-D5): the demo backend's invented data and answers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/demo/demo_backend.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/selling.dart';
import 'package:mazama_mobile/stock_summary.dart';

late Directory _dir;

DemoBackend _demo() => DemoBackend(
      jsonDecode(File('assets/demo/demo.json').readAsStringSync()) as Map<String, Object?>,
      File('assets/demo/label.png').readAsBytesSync(),
      dataDir: _dir,
    );

/// Every string anywhere in [v].
Iterable<String> _strings(Object? v) sync* {
  if (v is String) yield v;
  if (v is Map) {
    for (final e in v.entries) {
      yield* _strings(e.key);
      yield* _strings(e.value);
    }
  }
  if (v is List) {
    for (final e in v) {
      yield* _strings(e);
    }
  }
}

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_demo_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

  test('DM-D5: every id is a demo id, and the licenses are invented', () async {
    final demo = _demo();
    final packages = await demo.fetchPackages(demoStateId);
    final raw = await demo.fetchRawPackagesFromState(demoStateId, accessToken: 'x');
    expect(raw, hasLength(12));
    for (final r in raw) {
      expect((r as Map)['productGuid'], startsWith('PKPR-DEMO'));
      expect(r['manufacturerLicenseId'], startsWith('MF-DEMO'));
    }
    expect(packages.every((p) => p.productGuid.startsWith('PKPR-DEMO')), isTrue);
    expect(demo.center.licenseId, 'SC-DEMO0001');
    expect(demo.center.id, demoStateId);
    // None of the demo's ids or licenses appears in the app's real-shaped fixtures.
    final fixture = File('assets/shared/contracts/vectors/packaged_product.json').readAsStringSync();
    expect(fixture.contains('DEMO'), isFalse);
    // No real strain from the shared spellings appears in the demo.
    final demoText = _strings(jsonDecode(File('assets/demo/demo.json').readAsStringSync())).join('\n').toLowerCase();
    for (final real in ['golden teacher', 'penis envy', 'albino', 'b+', 'mazatapec', 'enigma']) {
      expect(demoText.contains(real), isFalse, reason: real);
    }
  });

  test('DM-R2: an expired and a locked package, two makers, a par shortfall, a lab report each', () async {
    final demo = _demo();
    final packages = await demo.fetchPackages(demoStateId);
    final raw = [for (final r in await demo.fetchRawPackagesFromState(demoStateId, accessToken: 'x')) r as Map];
    expect(packages.where((p) => p.expired), hasLength(1));
    expect(raw.where((r) => r['locked'] == true), hasLength(1));
    expect(packages.any((p) => p.productGuid == raw.firstWhere((r) => r['locked'] == true)['productGuid']), isFalse,
        reason: '/p/packages leaves the locked one out, as the server does');
    expect(raw.map((r) => r['manufacturerLicenseId']).toSet(), hasLength(2));
    expect(packages.where((p) => p.mazama).length, inInclusiveRange(1, packages.length - 1));
    expect(await demo.fetchMazamaLicenses(demoStateId), ['mf-demo0001']);
    final sizes = packages.map((p) => stockSizeKey(p.description)).toSet();
    expect(sizes, containsAll(['25', '20', '15', '10', '5', 'other']));
    final summary = summarize([for (final p in packages) p.toStockRow()], 'tpe');
    final table = parTable(summary, await demo.fetchParLevels(demoStateId));
    expect(table['short_total'] as num, greaterThan(0));
    for (final p in packages) {
      expect(demo.coaFor(p.productGuid), isNotNull, reason: p.productGuid);
      expect(await demo.fetchLabel(demoStateId, p.productGuid), isNotEmpty);
    }
    expect((await demo.fetchCartSettings(demoStateId)).taxPercent, 15);
    expect(await demo.centerIsConfigured(demoStateId), isTrue);
  });

  test('DM-D4: a sale through the sale client is confirmed and leaves the demo stock as it was', () async {
    final demo = _demo();
    final before = [for (final p in await demo.fetchPackages(demoStateId)) '${p.productGuid} ${p.quantity}'];
    final saleSpec = FlowSpec.fromYaml(File('assets/flows/sale.yaml').readAsStringSync());
    final records = [
      {'productGuid': 'PKPR-DEMO0001', 'id': 990001, 'quantity': 2},
      {'productGuid': 'PKPR-DEMO0002', 'id': 990002, 'quantity': 1},
    ];
    final client = demo.saleClient();
    final result = await runFlow(saleSpec, 'sale', {'access_token': demo.session.accessToken, 'records': records}, client: client);
    expect(looksLikeConfirmedSale(result['created'], records.length), isTrue);
    final after = [for (final p in await demo.fetchPackages(demoStateId)) '${p.productGuid} ${p.quantity}'];
    expect(after, before);
    // Anything else asked of the sale client is refused, never sent anywhere.
    expect((await client.get(Uri.parse('https://example.invalid/anything'))).statusCode, 404);
  });

  test('MI-R7: the demo mix has lots for the lot table, each strain one of the mix\'s, with tags and an unknown value',
      () async {
    final inv = await _demo().fetchMazamaInventory();
    expect(inv.lots, isNotEmpty);
    final strains = {for (final c in inv.cells) c.strain};
    expect(inv.lots.every((l) => strains.contains(l.strain)), isTrue);
    expect(inv.lots.any((l) => l.detected.isNotEmpty), isTrue);
    expect(inv.lots.any((l) => l.psilocin == null), isTrue);
  });

  test('par saved is read back by the same backend; a null par removes one', () async {
    final demo = _demo();
    final saved = await demo.saveParLevels(demoStateId, workerEmail: 'guest', deviceId: 'd', levels: const [
      ParLevel(strain: 'Starlit Meadow', size: 25, par: 30),
      ParLevel(strain: 'Copper Fern', size: 5, par: null),
      ParLevel(strain: 'Velvet Moss', size: 0, par: 2),
    ]);
    final read = await demo.fetchParLevels(demoStateId);
    expect(read.map((l) => l.toJson()), saved.map((l) => l.toJson()));
    final byKey = {for (final l in read) '${l.strain}|${l.size}': l.par};
    expect(byKey['Starlit Meadow|25'], 30);
    expect(byKey.containsKey('Copper Fern|5'), isFalse);
    expect(byKey['Velvet Moss|0'], 2);
    expect(byKey['Quiet Harbor|10'], 12); // unlisted levels stay
  });

  test('the scan matcher finds a demo id in the lines', () async {
    final demo = _demo();
    final r = await demo.scanMatch(demoStateId, ['Lot: demo0003', 'nothing here']);
    expect(r.matches.single.guid, 'PKPR-DEMO0003');
    expect((await demo.scanMatch(demoStateId, ['PKPR-abc123'])).matches, isEmpty);
  });

  test('another center is not the demo', () async {
    await expectLater(_demo().fetchPackages(231), throwsA(anything));
  });
}
