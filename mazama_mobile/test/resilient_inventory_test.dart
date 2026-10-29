// resilient_inventory.dart has no Flutter dependency, but lives under test/ alongside everything else in this
// app - same reasoning as cart_store_test.dart/inventory_cache_store_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/enrichment_store.dart';
import 'package:mazama_mobile/inventory_cache_store.dart';
import 'package:mazama_mobile/merged_inventory.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/resilient_inventory.dart';
import 'package:mazama_mobile/session.dart';

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_resilient_inventory_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  InventoryCacheStore cacheStore() => InventoryCacheStore(dataDir: () => tempDir);

  final live = [Package(productGuid: 'PKPR-live1', productType: 'Extract', id: 1, weightPerUnit: 5, analyteWeight: 4.5, strain: 'GT', tpeMg: 23, quantity: 10)];
  final fromState = [Package(productGuid: 'PKPR-state', productType: 'Extract', id: 2, weightPerUnit: 5, analyteWeight: 4.5, tpeMg: 23, quantity: 7)];
  final cached = [Package(productGuid: 'PKPR-cache', productType: 'Extract', id: 3, weightPerUnit: 5, analyteWeight: 4.5, strain: 'GT', tpeMg: 23, quantity: 2)];

  final session = Session(accessToken: 'TOKEN', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600000);

  Never fail(String msg) => throw Exception(msg);

  ResilientInventory build({
    Future<List<Package>> Function(int)? base,
    Future<List<Package>> Function(int, {required String accessToken})? fetchFromState,
    InventoryCacheStore? cache,
    Session? Function()? session,
    DateTime Function()? now,
    Duration? maxAge,
    bool? enableStateFallback,
  }) =>
      ResilientInventory(
        base: base ?? (id) async => live,
        fetchFromState: fetchFromState ?? (id, {required accessToken}) async => fail('tier 2 should not be reached'),
        cache: cache ?? cacheStore(),
        session: session ?? (() => null),
        now: now ?? DateTime.now,
        maxAge: maxAge ?? const Duration(days: 3),
        enableStateFallback: enableStateFallback ?? true,
      );

  test('tier 1 success is used as-is and is reported as live, with no asOf', () async {
    final result = await build().fetch(225);
    expect(result.source, InventorySource.live);
    expect(result.packages, live);
    expect(result.asOf, isNull);
  });

  test('a successful tier-1 fetch is saved to the cache for a later outage', () async {
    final store = cacheStore();
    await build(cache: store).fetch(225);
    final cached = await store.load(225);
    expect(cached, isNotNull);
    expect(cached!.packages.single.productGuid, 'PKPR-live1');
  });

  test('tier 1 failure with a session falls back to tier 2 (state), which is used and reported as such', () async {
    final result = await build(
      base: (id) async => fail('tier 1 down'),
      fetchFromState: (id, {required accessToken}) async {
        expect(accessToken, 'TOKEN');
        return fromState;
      },
      session: () => session,
    ).fetch(225);
    expect(result.source, InventorySource.state);
    expect(result.packages, fromState);
    expect(result.asOf, isNull);
  });

  test('a successful tier-2 fetch is also saved to the cache', () async {
    final store = cacheStore();
    await build(
      base: (id) async => fail('tier 1 down'),
      fetchFromState: (id, {required accessToken}) async => fromState,
      session: () => session,
      cache: store,
    ).fetch(225);
    final cached = await store.load(225);
    expect(cached!.packages.single.productGuid, 'PKPR-state');
  });

  test('enableStateFallback: false skips tier 2 outright even with a session, same as no session at all', () async {
    final store = cacheStore();
    final now = DateTime.utc(2026, 10, 18, 12);
    await store.save(225, cached, now.subtract(const Duration(hours: 1)));
    final result = await build(
      base: (id) async => fail('tier 1 down'),
      // No fetchFromState override at all - build()'s own default throws if tier 2 is ever reached, so this
      // test fails loudly (via that default's own `fail(...)`) if enableStateFallback doesn't actually skip it.
      session: () => session,
      cache: store,
      now: () => now,
      enableStateFallback: false,
    ).fetch(225);
    expect(result.source, InventorySource.cache);
    expect(result.packages.map((p) => p.toJson()).toList(), cached.map((p) => p.toJson()).toList());
  });

  test('tier 1 failure with NO session skips tier 2 outright and goes straight to tier 3', () async {
    final store = cacheStore();
    final now = DateTime.utc(2026, 10, 18, 12);
    await store.save(225, cached, now.subtract(const Duration(hours: 1)));
    final result = await build(
      base: (id) async => fail('tier 1 down'),
      session: () => null,
      cache: store,
      now: () => now,
    ).fetch(225);
    expect(result.source, InventorySource.cache);
    // Not `expect(result.packages, cached)`: these came back through a real save/load round trip
    // (InventoryCacheStore serializes to JSON and reconstructs fresh Package instances via Package.fromJson),
    // and Package has no == override of its own - comparing field-for-field (toJson) is what this test
    // actually means by "the cached packages", not object identity with the literal list passed to save().
    expect(result.packages.map((p) => p.toJson()).toList(), cached.map((p) => p.toJson()).toList());
  });

  test('tier 1 and tier 2 both fail, a cache within maxAge is used and reported with its own age', () async {
    final store = cacheStore();
    final fetchedAt = DateTime.utc(2026, 10, 18, 9);
    final now = DateTime.utc(2026, 10, 18, 12); // 3 hours later
    await store.save(225, cached, fetchedAt);
    final result = await build(
      base: (id) async => fail('tier 1 down'),
      fetchFromState: (id, {required accessToken}) async => fail('tier 2 down'),
      session: () => session,
      cache: store,
      now: () => now,
    ).fetch(225);
    expect(result.source, InventorySource.cache);
    // See the previous test's own comment: Package has no == override, so this compares field-for-field
    // rather than object identity against the literal list passed to save().
    expect(result.packages.map((p) => p.toJson()).toList(), cached.map((p) => p.toJson()).toList());
    expect(result.asOf, fetchedAt);
  });

  test('a cache older than maxAge is not used - the original tier-1 error is rethrown instead', () async {
    final store = cacheStore();
    final fetchedAt = DateTime.utc(2026, 10, 15, 12);
    final now = DateTime.utc(2026, 10, 18, 13); // just over 3 days later
    await store.save(225, cached, fetchedAt);
    await expectLater(
      build(
        base: (id) async => fail('live is down right now'),
        fetchFromState: (id, {required accessToken}) async => fail('tier 2 down'),
        session: () => session,
        cache: store,
        now: () => now,
      ).fetch(225),
      throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('live is down right now'))),
    );
  });

  test('a cache exactly at maxAge is still used (the boundary is inclusive)', () async {
    final store = cacheStore();
    final fetchedAt = DateTime.utc(2026, 10, 15, 12);
    final now = fetchedAt.add(const Duration(days: 3)); // exactly 3 days later
    await store.save(225, cached, fetchedAt);
    final result = await build(
      base: (id) async => fail('live is down'),
      fetchFromState: (id, {required accessToken}) async => fail('state is down'),
      session: () => session,
      cache: store,
      now: () => now,
    ).fetch(225);
    expect(result.source, InventorySource.cache);
  });

  test('nothing cached at all, and tiers 1/2 both fail: the original tier-1 error is rethrown', () async {
    await expectLater(
      build(
        base: (id) async => fail('live is down'),
        fetchFromState: (id, {required accessToken}) async => fail('state is down'),
        session: () => session,
      ).fetch(225),
      throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('live is down'))),
    );
  });

  test('fetchPackages (the plain tear-off CartPage/StockPage use) returns just the package list', () async {
    final result = await build().fetchPackages(225);
    expect(result, live);
  });
  group("Mazama's last figures, filled into a state-only read", () {
    EnrichmentStore enrichmentStore() => EnrichmentStore(dataDir: () => tempDir);
    final t0 = DateTime.utc(2026, 10, 21, 15);
    final t1 = DateTime.utc(2026, 10, 22, 9);

    // The server's row: its strain and a COA-backed tpeMg of 8 (the state's own figure would be ceil(5 x 1.0) = 5).
    final serverRow = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1,
        strain: 'Golden Teacher', tpeMg: 8, quantity: 9);
    Package stateRow({int id = 101, double aw = 1}) => Package(
        productGuid: id == 101 ? 'PKPR-ab12c' : 'PKPR-ff99aa', productType: 'Extract', id: id, weightPerUnit: 5, analyteWeight: aw,
        tpeMg: (5 * aw).ceil(), quantity: 4);

    ResilientInventory withStore(EnrichmentStore es,
            {required Future<List<Package>> Function(int) base,
            Future<List<Package>> Function(int, {required String accessToken})? fetchFromState,
            DateTime Function()? now,
            InventoryCacheStore? cache}) =>
        ResilientInventory(
          base: base,
          enrichment: es,
          fetchFromState: fetchFromState ?? (id, {required accessToken}) async => fail('tier 2 should not be reached'),
          cache: cache ?? cacheStore(),
          session: () => session,
          now: now ?? DateTime.now,
        );

    test('a live answer is remembered; a later tier-2 read of the same package gets its strain and TPE back', () async {
      final es = enrichmentStore();
      await withStore(es, base: (id) async => [serverRow], now: () => t0).fetch(225);
      final result = await withStore(es,
              base: (id) async => fail('mazama down'),
              fetchFromState: (id, {required accessToken}) async => [stateRow(), stateRow(id: 102)],
              now: () => t1)
          .fetch(225);
      expect(result.source, InventorySource.state);
      final byId = {for (final p in result.packages) p.id: p};
      expect([byId[101]!.strain, byId[101]!.tpeMg, byId[101]!.quantity, byId[101]!.enrichedAt, byId[101]!.stateEstimate],
          ['Golden Teacher', 8, 4, t0, false]);
      // Never sent by the server: stays the state's estimate, marked.
      expect([byId[102]!.strain, byId[102]!.tpeMg, byId[102]!.stateEstimate], ['', 5, true]);
    });

    // SM-D31: the phone's own coa_core reading of the lab report, kept by phone_label.dart.
    PackageEnrichment phoneReading({double aw = 1}) => PackageEnrichment(
        productGuid: 'PKPR-ab12c', id: 101, weightPerUnit: 5, analyteWeight: aw, strain: 'Golden Teacher', tpeMg: 9,
        expires: null, seenAt: t0, source: EnrichmentSource.phone, tpeMgPerG: 1.75, psilocinMg: 2.69);

    test("the phone's reading fills a tier-2 read of the same package with the same weight and state potency", () async {
      final es = enrichmentStore();
      await es.rememberPhone([phoneReading()], t0);
      final result = await withStore(es,
              base: (id) async => fail('mazama down'),
              fetchFromState: (id, {required accessToken}) async => [stateRow(), stateRow(id: 102)],
              now: () => t1)
          .fetch(225);
      final byId = {for (final p in result.packages) p.id: p};
      expect([byId[101]!.tpeMg, byId[101]!.enrichedBy, byId[101]!.mgFigure], [9, EnrichmentSource.phone, MgFigure.tpe]);
      // nothing kept for it: the state's psilocybin, as mg psilocybin
      expect([byId[102]!.tpeMg, byId[102]!.mgFigure], [5, MgFigure.psilocybin]);
    });

    test("the phone's reading doesn't fill once the state potency changed", () async {
      final es = enrichmentStore();
      await es.rememberPhone([phoneReading()], t0);
      final result = await withStore(es,
              base: (id) async => fail('mazama down'),
              fetchFromState: (id, {required accessToken}) async => [stateRow(aw: 1.5)],
              now: () => t1)
          .fetch(225);
      expect([result.packages.single.tpeMg, result.packages.single.mgFigure], [8, MgFigure.psilocybin]);
    });

    test("the server's answer replaces the phone's reading, and wins on the next outage", () async {
      final es = enrichmentStore();
      await es.rememberPhone([phoneReading()], t0);
      await withStore(es, base: (id) async => [serverRow], now: () => t1).fetch(225);
      final result = await withStore(es,
              base: (id) async => fail('mazama down'),
              fetchFromState: (id, {required accessToken}) async => [stateRow()],
              now: () => t1.add(const Duration(hours: 1)))
          .fetch(225);
      expect([result.packages.single.tpeMg, result.packages.single.enrichedBy], [8, EnrichmentSource.server]);
    });

    test("a tier-2 read whose state potency changed since is not filled", () async {
      final es = enrichmentStore();
      await withStore(es, base: (id) async => [serverRow], now: () => t0).fetch(225);
      final result = await withStore(es,
              base: (id) async => fail('mazama down'),
              fetchFromState: (id, {required accessToken}) async => [stateRow(aw: 2)],
              now: () => t1)
          .fetch(225);
      expect([result.packages.single.tpeMg, result.packages.single.stateEstimate], [10, true]);
    });

    test('a cached tier-2 read keeps the filled values and their provenance', () async {
      final es = enrichmentStore();
      final cache = cacheStore();
      await withStore(es, base: (id) async => [serverRow], now: () => t0, cache: cache).fetch(225);
      await withStore(es,
              base: (id) async => fail('mazama down'),
              fetchFromState: (id, {required accessToken}) async => [stateRow(), stateRow(id: 102)],
              now: () => t1,
              cache: cache)
          .fetch(225);
      final kept = (await cache.load(225))!.packages;
      final byId = {for (final p in kept) p.id: p};
      expect([byId[101]!.tpeMg, byId[101]!.enrichedAt, byId[101]!.stateEstimate], [8, t0, false]);
      expect(byId[102]!.stateEstimate, isTrue);
    });

    group('merged tier 1', () {
      ResilientInventory mergedInv(EnrichmentStore es, MergedInventoryResult Function() answer, DateTime at) => ResilientInventory(
            merged: (id) async => answer(),
            enrichment: es,
            fetchFromState: (id, {required accessToken}) async => fail('tier 2 should not be reached'),
            cache: cacheStore(),
            session: () => session,
            now: () => at,
          );

      test("remembers the server's own rows (not the merged ones) and reports live", () async {
        final es = enrichmentStore();
        // The merged row carries the state's newer analyteWeight; what is remembered is the server's own row's.
        final mergedRow = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 2,
            strain: 'Golden Teacher', tpeMg: 8, quantity: 4);
        final result = await mergedInv(
            es, () => MergedInventoryResult(packages: [mergedRow], mazamaOk: true, stateOk: true, mazamaPackages: [serverRow]), t0)
            .fetch(225);
        expect(result.source, InventorySource.live);
        expect(result.packages.single.analyteWeight, 2);
        final known = await es.load(t0);
        expect(known[enrichmentKey('PKPR-ab12c', 101)]!.analyteWeight, 1);
      });

      test("specs/coa-upload: a live merge says which rows the server sent; a row only the state listed isn't one",
          () async {
        final mergedRow = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 2,
            strain: 'Golden Teacher', tpeMg: 8, quantity: 4);
        final stateOnly = Package(productGuid: 'PKPR-dd88ee', productType: 'Extract', id: 108, weightPerUnit: 5, analyteWeight: 2,
            quantity: 1, coaAvailable: false);
        final result = await mergedInv(
                enrichmentStore(),
                () => MergedInventoryResult(
                    packages: [mergedRow, stateOnly], mazamaOk: true, stateOk: true, mazamaPackages: [serverRow]),
                t0)
            .fetch(225);
        expect(result.serverKeys, {inventoryRowKey(mergedRow)});
        expect(result.serverKeys!.contains(inventoryRowKey(stateOnly)), isFalse);
        expect(inventoryRowKey(mergedRow), 'PKPR-ab12c#101');
      });

      test('only the state answered: reported as state, and filled where safe', () async {
        final es = enrichmentStore();
        await es.remember([serverRow], t0);
        final result = await mergedInv(
            es,
            () => MergedInventoryResult(packages: [stateRow(), stateRow(id: 102)], mazamaOk: false, stateOk: true, rawStateRecords: const []),
            t1)
            .fetch(225);
        expect(result.source, InventorySource.state);
        expect(result.serverKeys, isNull);
        final byId = {for (final p in result.packages) p.id: p};
        expect([byId[101]!.tpeMg, byId[101]!.stateEstimate], [8, false]);
        expect([byId[102]!.tpeMg, byId[102]!.stateEstimate], [5, true]);
      });
    });
  });

  // R87: stock read from the state system alone has no strip of its own (the app-wide banner says Mazama's server
  // can't be reached); a cached copy's strip still says when it holds state-only products.
  group('cachedEstimatesNote', () {
    final at = DateTime.utc(2026, 10, 21, 15);
    Package p(String guid, int id, {DateTime? enrichedAt, bool estimate = false}) => Package(
        productGuid: guid, productType: 'Extract', id: id, weightPerUnit: 5, analyteWeight: 1, tpeMg: 5,
        enrichedAt: enrichedAt, stateEstimate: estimate);

    test('cachedEstimatesNote flags a cached copy that holds state-only products', () {
      expect(cachedEstimatesNote([p('PKPR-a', 1, estimate: true)]),
          " For some products in it only the state's psilocybin is known, shown as mg psilocybin.");
      expect(cachedEstimatesNote([p('PKPR-a', 1, enrichedAt: at)]), '');
    });
  });
}
