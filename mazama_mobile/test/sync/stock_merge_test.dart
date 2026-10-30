// sync/stock_merge.dart: PS-R5's one rule for a center's stock, held to today's cases (resilient_inventory_test.dart's
// tiers 1-2 and its fill of a state-only read, merged_inventory_test.dart's join), same inputs and the same packages.
// Invented fixtures (this folder is published).
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/coa_data_client.dart';
import 'package:mazama_mobile/enrichment_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/sync/stock_merge.dart';

/// A raw state record (GetPackagedProducts), sellable.
Map<String, Object?> _record(int id, {String guid = 'PKPR-ab12c', double aw = 1, num quantity = 4, String? lot}) => {
      'id': id,
      'productGuid': guid,
      'productType': 'Extract',
      'weightPerUnit': 5,
      'analyteWeight': aw,
      'quantity': quantity,
      if (lot != null) 'harvestBatchGuid': lot,
    };

void main() {
  final t0 = DateTime.utc(2026, 10, 21, 15);

  // The server's row: its strain and a COA-backed tpeMg of 8 (the state's own figure would be ceil(5 x 1.0) = 5).
  final serverRow = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1,
      strain: 'Golden Teacher', tpeMg: 8, quantity: 9);

  PackageEnrichment kept({double aw = 1, int tpeMg = 8, EnrichmentSource source = EnrichmentSource.server}) =>
      PackageEnrichment(
          productGuid: 'PKPR-ab12c', id: 101, weightPerUnit: 5, analyteWeight: aw, strain: 'Golden Teacher', tpeMg: tpeMg,
          expires: null, seenAt: t0, source: source);

  Map<String, PackageEnrichment> known(PackageEnrichment e) => {e.key: e};

  group('only the server answered (tier 1)', () {
    test("its rows are used as they are, remembered, and are the server's keys", () {
      final r = mergeStock(stateRecords: null, serverRows: [serverRow], enrichment: const {}, configured: true);
      expect(r.source, stockFromServer);
      expect(r.packages.single, same(serverRow));
      expect(r.remember.single, same(serverRow));
      expect(r.serverKeys, {'PKPR-ab12c#101'});
    });

    test('nothing answered: an error, nothing made up', () {
      expect(() => mergeStock(stateRecords: null, serverRows: null, enrichment: const {}, configured: true),
          throwsA(isA<StockMergeError>()));
      expect(() => mergeStock(stateRecords: null, serverRows: null, enrichment: const {}, configured: false),
          throwsA(isA<StockMergeError>()));
    });
  });

  group('only the state answered: filled where safe (tier 2)', () {
    test('a kept server figure fills the same package; one never sent stays the state estimate, marked', () {
      final r = mergeStock(
          stateRecords: [_record(101), _record(102, guid: 'PKPR-ff99aa')],
          serverRows: null,
          enrichment: known(kept()),
          configured: true);
      expect(r.source, stockFromState);
      expect(r.remember, isEmpty);
      expect(r.serverKeys, isNull);
      final byId = {for (final p in r.packages) p.id: p};
      expect([byId[101]!.strain, byId[101]!.tpeMg, byId[101]!.quantity, byId[101]!.enrichedAt, byId[101]!.stateEstimate],
          ['Golden Teacher', 8, 4, t0, false]);
      expect([byId[102]!.strain, byId[102]!.tpeMg, byId[102]!.stateEstimate], ['', 5, true]);
      expect([byId[101]!.coaAvailable, byId[101]!.labelAvailable], [false, false]); // the server was never asked
    });

    test("the phone's reading fills a package with the same weight and state potency", () {
      final r = mergeStock(
          stateRecords: [_record(101), _record(102, guid: 'PKPR-ff99aa')],
          serverRows: null,
          enrichment: known(kept(tpeMg: 9, source: EnrichmentSource.phone)),
          configured: true);
      final byId = {for (final p in r.packages) p.id: p};
      expect([byId[101]!.tpeMg, byId[101]!.enrichedBy, byId[101]!.mgFigure], [9, EnrichmentSource.phone, MgFigure.tpe]);
      expect([byId[102]!.tpeMg, byId[102]!.mgFigure], [5, MgFigure.psilocybin]);
    });

    test("the phone's reading doesn't fill once the state potency changed", () {
      final r = mergeStock(
          stateRecords: [_record(101, aw: 1.5)],
          serverRows: null,
          enrichment: known(kept(tpeMg: 9, source: EnrichmentSource.phone)),
          configured: true);
      expect([r.packages.single.tpeMg, r.packages.single.mgFigure], [8, MgFigure.psilocybin]);
    });

    test('a read whose state potency changed since is not filled', () {
      final r = mergeStock(stateRecords: [_record(101, aw: 2)], serverRows: null, enrichment: known(kept()), configured: true);
      expect([r.packages.single.tpeMg, r.packages.single.stateEstimate], [10, true]);
    });

    test('a changed weight ignores the remembered figure', () {
      final r = mergeStock(
          stateRecords: [
            {..._record(101), 'weightPerUnit': 6}
          ],
          serverRows: null,
          enrichment: known(kept()),
          configured: true);
      expect([r.packages.single.tpeMg, r.packages.single.stateEstimate], [6, true]);
    });

    test('a record the state may not sell is left out (SM-10)', () {
      final r = mergeStock(
          stateRecords: [
            _record(101),
            {..._record(102), 'locked': true},
          ],
          serverRows: null,
          enrichment: const {},
          configured: true);
      expect([for (final p in r.packages) p.id], [101]);
    });
  });

  group('both answered: the join (merged_inventory.dart)', () {
    test("a record both sides know keeps the server's expiry date; one only the state knows has none", () {
      final r = mergeStock(
        stateRecords: [_record(101), _record(102, quantity: 2)],
        serverRows: [
          Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, quantity: 4,
              expires: DateTime(2027, 3, 1)),
        ],
        enrichment: const {},
        configured: true,
      );
      expect(r.source, stockFromBoth);
      final byId = {for (final p in r.packages) p.id: p};
      expect(byId[101]!.expires, DateTime(2027, 3, 1));
      expect(byId[102]!.expires, isNull);
      expect([for (final (lot, n) in allocateLots(r.packages, 5)!) (lot.id, n)], [(101, 4), (102, 1)]);
    });

    test("SP-D10: a joined row keeps the server's mazama, expired, mg TPE and name, with the state's exact quantity", () {
      final server = [
        Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, quantity: 9,
            mazama: true, expired: true, unitMgTpe: 4.992, description: 'GT 5 mg TPE EX (2026-01-01)'),
      ];
      final r = mergeStock(
        stateRecords: [_record(101, quantity: 2.5), _record(102, guid: 'PKPR-zz', quantity: 2)],
        serverRows: server,
        enrichment: const {},
        configured: true,
      );
      final p = r.packages.firstWhere((p) => p.id == 101);
      expect([p.mazama, p.expired, p.unitMgTpe, p.description], [true, true, 4.992, 'GT 5 mg TPE EX (2026-01-01)']);
      expect(p.exactQuantity, 2.5);
      expect(p.quantity, 2);
      final stateOnly = r.packages.firstWhere((p) => p.id == 102);
      expect([stateOnly.mazama, stateOnly.unitMgTpe, stateOnly.description], [false, null, '']);
      expect([stateOnly.coaAvailable, stateOnly.labelAvailable], [false, false]);
      expect(r.remember, same(server)); // the server's own rows, never the joined ones
    });

    test("README R64: a joined row keeps the server's label input; one only the state knows has none", () {
      final input = <String, Object?>{'package': {'pkpr': 'PKPR-ab12c'}, 'section': null, 'settings': <String, Object?>{}};
      final r = mergeStock(
        stateRecords: [_record(101), _record(102, quantity: 2)],
        serverRows: [
          Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, quantity: 4,
              labelInput: input),
        ],
        enrichment: const {},
        configured: true,
      );
      final byId = {for (final p in r.packages) p.id: p};
      expect(byId[101]!.labelInput, input);
      expect(byId[102]!.labelInput, isNull);
    });

    test("the state's live count wins over the server's, and its newer weights; the server's figures stay", () {
      final r = mergeStock(
          stateRecords: [_record(101, aw: 2, quantity: 3)], serverRows: [serverRow], enrichment: const {}, configured: true);
      final p = r.packages.single;
      expect([p.quantity, p.analyteWeight, p.strain, p.tpeMg], [3, 2.0, 'Golden Teacher', 8]);
      expect(r.remember.single.analyteWeight, 1); // what is remembered is the server's own row
    });

    test("specs/coa-upload: the server's keys are its rows; a row only the state listed isn't one", () {
      final r = mergeStock(
          stateRecords: [_record(101), _record(108, guid: 'PKPR-dd88ee', quantity: 1)],
          serverRows: [serverRow],
          enrichment: const {},
          configured: true);
      expect(r.serverKeys, {'PKPR-ab12c#101'});
      expect(stockRowKey(r.packages.last), 'PKPR-dd88ee#108');
    });

    test("a row only the server lists is gone from the state's live list: not carried", () {
      final r = mergeStock(
          stateRecords: [_record(101)],
          serverRows: [serverRow, Package(productGuid: 'PKPR-gone', productType: 'Extract', id: 999, weightPerUnit: 5, analyteWeight: 1)],
          enrichment: const {},
          configured: true);
      expect([for (final p in r.packages) p.id], [101]);
    });

    test("PS-R5: a product only the state lists is the state's estimate, marked; a lot of a joined product is not", () {
      final r = mergeStock(
          stateRecords: [_record(101), _record(102, quantity: 2), _record(108, guid: 'PKPR-dd88ee', quantity: 1)],
          serverRows: [serverRow],
          enrichment: known(kept()), // not used while the server answers: marked, never filled
          configured: true);
      final byId = {for (final p in r.packages) p.id: p};
      expect([byId[108]!.stateEstimate, byId[108]!.mgFigure, byId[108]!.tpeMg, byId[108]!.enrichedAt],
          [true, MgFigure.psilocybin, 5, null]);
      expect([byId[108]!.coaAvailable, byId[108]!.labelAvailable], [false, false]);
      // PKPR-ab12c is shown by its joined record's server figure (PkprGroup's first lot): its other lot stays unmarked
      expect([byId[101]!.stateEstimate, byId[102]!.stateEstimate], [false, false]);
    });

    test("a lot only the state lists, of a joined product, is marked stateOnly with its own figure; the product's is unchanged", () {
      final dated = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1,
          strain: 'Golden Teacher', tpeMg: 8, quantity: 9, expires: DateTime(2027, 3, 1));
      final r = mergeStock(
          stateRecords: [_record(101), _record(102, aw: 1.2, quantity: 2), _record(108, guid: 'PKPR-dd88ee', quantity: 1)],
          serverRows: [dated],
          enrichment: const {},
          configured: true);
      final byId = {for (final p in r.packages) p.id: p};
      // its own figure: the state's psilocybin, ceil(5 x 1.2) = 6
      expect([byId[102]!.stateOnly, byId[102]!.stateEstimate, byId[102]!.tpeMg], [true, false, 6]);
      expect(byId[101]!.stateOnly, false);
      expect(byId[108]!.stateOnly, false); // a product only the state lists is a stateEstimate, as before
      // the product as the cart shows, prices and caps it: the joined lot's figure and potency (first in draw order)
      final g = groupByPkpr(r.packages).firstWhere((g) => g.productGuid == 'PKPR-ab12c');
      expect([g.tpeMg, g.mgFigure, g.analyteWeight, g.quantity], [8, MgFigure.tpe, 1.0, 6]);
      expect(g.stateOnlyNote, 'includes 2 unit(s) known only by the state: 6 mg psilocybin each');
    });

    test('kept figures are not used while the server answers', () {
      final r = mergeStock(
          stateRecords: [_record(101)],
          serverRows: [serverRow],
          enrichment: known(kept(tpeMg: 9, source: EnrichmentSource.phone)),
          configured: true);
      expect([r.packages.single.tpeMg, r.packages.single.enrichedAt], [8, null]);
    });
  });

  group('an unconfigured center (coa_data_resolver.dart)', () {
    test("the state's records with the batch lookup's figures by lot; a lot it doesn't have keeps the state's", () {
      final r = mergeStock(
        stateRecords: [_record(101, lot: 'HB-aaaa0001'), _record(102, lot: 'HB-bbbb0002')],
        serverRows: null,
        enrichment: const {},
        configured: false,
        coaData: {
          'hb-AAAA0001': CoaData(guid: 'hb-AAAA0001', strain: 'Golden Teacher', baeocystin: 0, norbaeocystin: 0, norpsilocin: 0, tpe: 1.75),
        },
      );
      expect(r.source, stockFromState);
      expect(r.remember, isEmpty);
      final byId = {for (final p in r.packages) p.id: p};
      expect([byId[101]!.strain, byId[101]!.tpeMg], ['Golden Teacher', 9]); // ceil(5 x 1.75)
      expect([byId[102]!.strain, byId[102]!.tpeMg], ['', 5]);
    });

    test('no server rows are used, even if given', () {
      final r = mergeStock(stateRecords: [_record(101)], serverRows: [serverRow], enrichment: const {}, configured: false);
      expect([r.packages.single.tpeMg, r.source], [5, stockFromState]);
    });
  });
}
