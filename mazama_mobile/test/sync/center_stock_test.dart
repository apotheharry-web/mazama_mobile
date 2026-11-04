// sync/center_stock.dart: a center's stock as the cart loads it, step by step, and
// kept stock handed back at any age, with its
// time. Invented fixtures (this folder is published).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/sync/enrichment.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/sync/center_stock.dart';
import 'package:mazama_mobile/sync/stock_merge.dart' show StockMergeError;
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

  // A fresh handle on the folder's database each time, as the cart and the engine each have.
  Datasets datasets() => Datasets.forDir(() => dir);

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
        datasets: datasets(),
        session: () => session,
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
    expect(keptEnrichment(datasets(), t0).keys, [enrichmentKey('PKPR-ab12c', 101)]); // the server's own row remembered
  });

  test('only the state answered: state, filled from what was remembered', () async {
    rememberServerFigures(datasets(), [serverRow], t0);
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
    rememberServerFigures(datasets(), [serverRow], t0);
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
        throwsA(isA<StockMergeError>()));
    expect(called, isFalse);
  });

  test('nothing answered: the kept stock at any age, with its time (Q3)', () async {
    final old = t0.subtract(const Duration(days: 40));
    keepCenterStock(datasets(), 231, [serverRow], old);
    final r = await build().fetch(231);
    expect(r.source, InventorySource.cache);
    expect(r.asOf, old);
    expect(r.packages.single.strain, 'Golden Teacher');
  });

  test("nothing answered and nothing kept: the first step's error, in the merge's words", () async {
    await expectLater(
        build().fetch(231),
        throwsA(isA<StockMergeError>()
            .having((e) => e.message, 'message', allOf(contains('both inventory sources failed'), contains('mazama down')))));
  });

  // Moved here with InventoryFetch from resilient_inventory_test.dart.
  test("a row's key is its PKPR and record id, as the merge joins them", () {
    expect(inventoryRowKey(serverRow), 'PKPR-ab12c#101');
  });

  // Stock read from the state system alone has no strip of its own (the app-wide banner says Mazama's server
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
      // and keptCenterStock reads the same body back
      datasets().put(Dataset.centerStock, '231', got.body, source: got.source, at: t0);
      expect(keptCenterStock(datasets(), 231)!.packages.single.quantity, 3);
    });

    test("the server alone is 'server'; the state alone is 'state'", () async {
      expect((await centerStockRefresher(() async => build(server: (id) async => [serverRow]))('231')).source, sourceServer);
      expect(
          (await centerStockRefresher(() async => build(state: (id, {required accessToken}) async => [record(101)]))('231'))
              .source,
          sourceState);
    });

    test('a load that fell back to the kept copy, or had no session, fails: nothing is stamped as read again', () async {
      keepCenterStock(datasets(), 231, [serverRow], t0.subtract(const Duration(days: 2)));
      await expectLater(centerStockRefresher(() async => build())('231'), throwsA(isA<StateError>()));
      await expectLater(centerStockRefresher(() async => null)('231'), throwsA(isA<StateError>()));
      await expectLater(centerStockRefresher(() async => build())('x'), throwsA(isA<ArgumentError>()));
    });
  });

  group('the center_stock dataset (keepCenterStock, keptCenterStock)', () {
    final packages = [
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5, strain: 'Golden Teacher', tpeMg: 5, quantity: 10),
      Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0, strain: 'Enigma', tpeMg: 90, quantity: 3),
    ];
    final fetchedAt = DateTime.utc(2026, 10, 18, 12, 0);

    test('nothing kept: null', () {
      expect(keptCenterStock(datasets(), 231), isNull);
    });

    test('kept then read back: every package field and the time exactly', () {
      keepCenterStock(datasets(), 231, packages, fetchedAt);
      final restored = keptCenterStock(datasets(), 231)!;
      expect(restored.fetchedAt, fetchedAt);
      expect(restored.packages, hasLength(2));
      expect([restored.packages[0].productGuid, restored.packages[0].strain, restored.packages[0].tpeMg], ['PKPR-ab12c', 'Golden Teacher', 5]);
      expect(restored.packages[1].quantity, 3);
    });

    test('a newer read replaces the copy; an older one finishing last does not', () {
      keepCenterStock(datasets(), 231, packages, fetchedAt);
      keepCenterStock(datasets(), 231, [packages.first], fetchedAt.add(const Duration(hours: 1)));
      expect(keptCenterStock(datasets(), 231)!.packages, hasLength(1));
      keepCenterStock(datasets(), 231, packages, fetchedAt);
      expect(keptCenterStock(datasets(), 231)!.fetchedAt, fetchedAt.add(const Duration(hours: 1)));
    });

    test("each center's stock is its own", () {
      keepCenterStock(datasets(), 231, packages, fetchedAt);
      keepCenterStock(datasets(), 183, [packages.first], fetchedAt);
      expect(keptCenterStock(datasets(), 231)!.packages, hasLength(2));
      expect(keptCenterStock(datasets(), 183)!.packages, hasLength(1));
      expect(keptCenterStock(datasets(), 999), isNull);
      expect(keptCenterStock(Datasets.forDir(() => Directory('${dir.path}/other')), 231), isNull);
    });

    test('the body says where it came from, as the row does', () {
      keepCenterStock(datasets(), 231, packages, fetchedAt, source: sourceState);
      final row = datasets().read(Dataset.centerStock, '231')!;
      expect([row.source, row.fetchedAt, (jsonDecode(row.body) as Map)['source']], [sourceState, fetchedAt, sourceState]);
    });

    test('a damaged copy reads as nothing kept', () {
      for (final body in ['not json{{{', '{"packages": 3}', '{"packages": [1]}', '[]']) {
        datasets().put(Dataset.centerStock, '231', body, source: sourceMerged, at: fetchedAt);
        expect(keptCenterStock(datasets(), 231), isNull, reason: body);
        expect(centerStockPackages(body), isNull, reason: body);
      }
    });
  });
}
