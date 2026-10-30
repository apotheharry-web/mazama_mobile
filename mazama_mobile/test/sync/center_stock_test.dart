// sync/center_stock.dart: a center's stock as the cart loads it (specs/phone-sync phase 3), held to
// resilient_inventory_test.dart's tiers with the one change Q3 makes: kept stock is handed back at any age, with its
// time. Invented fixtures (this folder is published).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/enrichment_store.dart';
import 'package:mazama_mobile/inventory_cache_store.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/merged_inventory.dart' show MergedInventoryError;
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/sync/center_stock.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mazama_center_stock_test_'));
  tearDown(() {
    LocalStore.debugCloseAll();
    dir.deleteSync(recursive: true);
  });

  final t0 = DateTime.utc(2026, 10, 21, 15);
  final session = Session(accessToken: 'TOKEN', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600000);
  final serverRow = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1,
      strain: 'Golden Teacher', tpeMg: 8, quantity: 9);
  Map<String, Object?> record(int id, {num quantity = 4}) => {
        'id': id, 'productGuid': 'PKPR-ab12c', 'productType': 'Extract', 'weightPerUnit': 5, 'analyteWeight': 1, 'quantity': quantity,
      };
  Never fail(String why) => throw Exception(why);

  InventoryCacheStore cache() => InventoryCacheStore(dataDir: () => dir);
  EnrichmentStore enrichment() => EnrichmentStore(dataDir: () => dir);

  CenterStock build({
    Future<List<Package>> Function(int)? server,
    Future<List<Object?>> Function(int, {required String accessToken})? state,
    Future<List<Package>> Function(int, {required String accessToken})? fromState,
    void Function(int, List<Object?>)? onStateRead,
    bool enableStateFallback = true,
    DateTime Function()? now,
  }) =>
      CenterStock(
        fetchServer: server ?? (id) async => fail('mazama down'),
        fetchRawState: state ?? (id, {required accessToken}) async => fail('state down'),
        fetchFromState: fromState ?? (id, {required accessToken}) async => fail('tier 2 down'),
        cache: cache(),
        session: () => session,
        enrichment: enrichment(),
        onStateRead: onStateRead,
        enableStateFallback: enableStateFallback,
        now: now ?? () => t0,
      );

  test("both answered: the join, live, the server's keys, kept as merged; the state's read handed on", () async {
    final reads = <List<Object?>>[];
    final r = await build(
      server: (id) async => [serverRow],
      state: (id, {required accessToken}) async => [record(101, quantity: 3)],
      onStateRead: (id, raw) => reads.add(raw),
    ).fetch(231);
    expect(r.source, InventorySource.live);
    expect([r.packages.single.quantity, r.packages.single.tpeMg], [3, 8]);
    expect(r.serverKeys, {'PKPR-ab12c#101'});
    expect(reads.single.single, isA<Map>());
    await pumpEventQueue();
    final kept = Datasets.forDir(() => dir).read(Dataset.centerStock, '231')!;
    expect([kept.source, kept.fetchedAt], [sourceMerged, t0]);
    expect((await enrichment().load(t0)).keys, [enrichmentKey('PKPR-ab12c', 101)]); // the server's own row remembered
  });

  test('only the state answered: state, filled from what was remembered', () async {
    await enrichment().remember([serverRow], t0);
    final r = await build(state: (id, {required accessToken}) async => [record(101), {...record(102), 'productGuid': 'PKPR-ff99aa'}])
        .fetch(231);
    expect(r.source, InventorySource.state);
    expect(r.serverKeys, isNull);
    final byId = {for (final p in r.packages) p.id: p};
    expect([byId[101]!.tpeMg, byId[101]!.stateEstimate], [8, false]);
    expect(byId[102]!.stateEstimate, isTrue);
    await pumpEventQueue();
    expect(Datasets.forDir(() => dir).read(Dataset.centerStock, '231')!.source, sourceState);
  });

  test('both failed: the state fallback (tier 2), filled the same way', () async {
    await enrichment().remember([serverRow], t0);
    final r = await build(fromState: (id, {required accessToken}) async => [
          Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, tpeMg: 5, quantity: 4),
        ]).fetch(231);
    expect(r.source, InventorySource.state);
    expect(r.packages.single.tpeMg, 8);
  });

  test('enableStateFallback false skips tier 2', () async {
    var called = false;
    await expectLater(
        build(
          enableStateFallback: false,
          fromState: (id, {required accessToken}) async {
            called = true;
            return const [];
          },
        ).fetch(231),
        throwsA(isA<MergedInventoryError>()));
    expect(called, isFalse);
  });

  test('nothing answered: the kept stock at any age, with its time (Q3)', () async {
    final old = t0.subtract(const Duration(days: 40));
    await cache().save(231, [serverRow], old);
    final r = await build().fetch(231);
    expect(r.source, InventorySource.cache);
    expect(r.asOf, old);
    expect(r.packages.single.strain, 'Golden Teacher');
  });

  test("nothing answered and nothing kept: the first step's error, in merged_inventory.dart's words", () async {
    await expectLater(
        build().fetch(231),
        throwsA(isA<MergedInventoryError>()
            .having((e) => e.message, 'message', allOf(contains('both inventory sources failed'), contains('mazama down')))));
  });

  // Moved here with InventoryFetch from resilient_inventory_test.dart (Task 10).
  test("a row's key is its PKPR and record id, as the merge joins them", () {
    expect(inventoryRowKey(serverRow), 'PKPR-ab12c#101');
  });

  // R87: stock read from the state system alone has no strip of its own (the app-wide banner says Mazama's server
  // can't be reached); a kept copy's strip still says when it holds state-only products.
  test('cachedEstimatesNote flags a kept copy that holds state-only products', () {
    Package p({DateTime? enrichedAt, bool estimate = false}) => Package(
        productGuid: 'PKPR-a', productType: 'Extract', id: 1, weightPerUnit: 5, analyteWeight: 1, tpeMg: 5,
        enrichedAt: enrichedAt, stateEstimate: estimate);
    expect(cachedEstimatesNote([p(estimate: true)]),
        " For some products in it only the state's psilocybin is known, shown as mg psilocybin.");
    expect(cachedEstimatesNote([p(enrichedAt: DateTime.utc(2026, 10, 21, 15))]), '');
  });

  test('fetchPackages gives the packages alone', () async {
    expect(await build(server: (id) async => [serverRow]).fetchPackages(231), [same(serverRow)]);
  });

  group('the engine\'s center_stock refresher (phase 4)', () {
    test('a load the state and the server answered: the cart\'s body shape, merged', () async {
      final refresh = centerStockRefresher(() async => build(
            server: (id) async => [serverRow],
            state: (id, {required accessToken}) async => [record(101, quantity: 3)],
          ));
      final got = await refresh('231');
      expect(got.source, sourceMerged);
      final body = jsonDecode(got.body) as Map;
      expect([body['source'], (body['packages'] as List).single['quantity']], [sourceMerged, 3]);
      // and InventoryCacheStore reads the same body back (review M2)
      Datasets.forDir(() => dir).put(Dataset.centerStock, '231', got.body, source: got.source, at: t0);
      expect((await cache().load(231))!.packages.single.quantity, 3);
    });

    test("the server alone is 'server'; the state alone is 'state'", () async {
      expect((await centerStockRefresher(() async => build(server: (id) async => [serverRow]))('231')).source, sourceServer);
      expect(
          (await centerStockRefresher(() async => build(state: (id, {required accessToken}) async => [record(101)]))('231'))
              .source,
          sourceState);
    });

    test('a load that fell back to the kept copy, or had no session, fails: nothing is stamped as read again', () async {
      await cache().save(231, [serverRow], t0.subtract(const Duration(days: 2)));
      await expectLater(centerStockRefresher(() async => build())('231'), throwsA(isA<StateError>()));
      await expectLater(centerStockRefresher(() async => null)('231'), throwsA(isA<StateError>()));
      await expectLater(centerStockRefresher(() async => build())('x'), throwsA(isA<ArgumentError>()));
    });
  });
}
