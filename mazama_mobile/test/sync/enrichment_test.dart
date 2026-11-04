// sync/enrichment.dart: what Mazama's server last sent per package (the enrichment dataset), and the rule for filling
// it back into a read from the state system alone.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/sync/enrichment.dart';
import 'package:mazama_mobile/sync/sync_datasets.dart';

/// What is kept in [dir]: the enrichment dataset's body, null when none.
String? _kept(Directory dir) => Datasets.forDir(() => dir).read(Dataset.enrichment, '')?.body;

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_enrichment_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  // A fresh handle on the folder's database each time, as a page or the engine has.
  Datasets store() => Datasets.forDir(() => Directory('${tempDir.path}/nested'));

  final seenAt = DateTime.utc(2026, 10, 21, 15, 30);

  // As the server sends it: its canonical strain, its tpeMg from a COA override (8, above the state's 5 x 1.0 = 5).
  Package served({int id = 101, double wpu = 5.0, double aw = 1.0, int tpe = 8, String strain = 'Golden Teacher'}) => Package(
      productGuid: 'PKPR-ab12c', productType: 'Extract', id: id, weightPerUnit: wpu, analyteWeight: aw, strain: strain, tpeMg: tpe,
      quantity: 9, expires: DateTime(2027, 3, 1));

  // As state_packages_client.dart maps the state's own record: strain from the name (here none), tpeMg = ceil(5 x 1.0).
  Package fromState({int id = 101, double wpu = 5.0, double aw = 1.0, int qty = 4, String guid = 'PKPR-ab12c'}) => Package(
      productGuid: guid, productType: 'Extract', id: id, weightPerUnit: wpu, analyteWeight: aw, tpeMg: (wpu * aw).ceil(),
      quantity: qty, lotGuid: 'HB-1234abcd');

  group('the enrichment dataset', () {
    test('nothing stored: nothing kept', () {
      expect(keptEnrichment(store(), seenAt), isEmpty);
    });

    test("remembered then read back: each package's strain, tpeMg, expiry, inputs and when it was seen", () {
      rememberServerFigures(store(), [served()], seenAt);
      final known = keptEnrichment(store(), seenAt.add(const Duration(hours: 1)));
      final e = known[enrichmentKey('PKPR-ab12c', 101)]!;
      expect([e.productGuid, e.id, e.weightPerUnit, e.analyteWeight, e.strain, e.tpeMg], ['PKPR-ab12c', 101, 5.0, 1.0, 'Golden Teacher', 8]);
      expect(e.expires, DateTime(2027, 3, 1));
      expect(e.seenAt, seenAt);
      expect(jsonDecode(_kept(Directory('${tempDir.path}/nested'))!)['version'], 1);
    });

    test('a later answer replaces the same package and keeps the others, whatever center sent them', () {
      rememberServerFigures(store(), [served(id: 101), served(id: 102, tpe: 12)], seenAt);
      rememberServerFigures(store(), [served(id: 101, tpe: 9)], seenAt.add(const Duration(days: 1)));
      final known = keptEnrichment(store(), seenAt.add(const Duration(days: 1)));
      expect(known[enrichmentKey('PKPR-ab12c', 101)]!.tpeMg, 9);
      expect(known[enrichmentKey('PKPR-ab12c', 102)]!.tpeMg, 12);
    });

    test('a row with no known potency (tpeMg 0) is not kept', () {
      rememberServerFigures(store(), [served(tpe: 0)], seenAt);
      expect(keptEnrichment(store(), seenAt), isEmpty);
    });

    test('bounded: at most maxEntries are kept, the most recently seen', () {
      for (var i = 0; i < 5; i++) {
        rememberServerFigures(store(), [served(id: 200 + i)], seenAt.add(Duration(minutes: i)), maxEntries: 3);
      }
      final known = keptEnrichment(store(), seenAt.add(const Duration(hours: 1)));
      expect(known.keys.toSet(), {enrichmentKey('PKPR-ab12c', 202), enrichmentKey('PKPR-ab12c', 203), enrichmentKey('PKPR-ab12c', 204)});
      final kept = jsonDecode(_kept(Directory('${tempDir.path}/nested'))!) as Map;
      expect((kept['entries'] as List).length, 3);
      expect(enrichmentMaxEntries, 2000);
    });

    test('bounded: entries older than maxAge are not handed back, and are dropped on the next write', () {
      expect(enrichmentMaxAge, const Duration(days: 30));
      rememberServerFigures(store(), [served(id: 101)], seenAt);
      expect(keptEnrichment(store(), seenAt.add(const Duration(days: 31))), isEmpty);
      rememberServerFigures(store(), [served(id: 102)], seenAt.add(const Duration(days: 31)));
      final kept = jsonDecode(_kept(Directory('${tempDir.path}/nested'))!) as Map;
      expect([for (final e in kept['entries'] as List) (e as Map)['id']], [102]);
    });

    test('a damaged or foreign copy reads as nothing kept, and the next write replaces it', () {
      for (final body in ['{"version": 1, "entries": [{"productGuid": 3}', '{"version": 99, "entries": []}', '[]']) {
        store().put(Dataset.enrichment, '', body, source: sourceServer, at: seenAt);
        expect(keptEnrichment(store(), seenAt), isEmpty, reason: body);
        rememberServerFigures(store(), [served()], seenAt);
        expect(keptEnrichment(store(), seenAt).keys, [enrichmentKey('PKPR-ab12c', 101)], reason: body);
      }
    });
  });

  group("README R64: the server's label input is kept for a read from the state alone", () {
    final input = <String, Object?>{
      'package': {'pkpr': 'PKPR-ab12c', 'weight_per_unit': 5.0},
      'section': {'uid': 'HB-1234abcd'},
      'settings': {'shelf_months': 12, 'fd_months': 24, 'shelf_days': null, 'fd_days': null},
    };
    Package servedWith(Map<String, Object?>? li) => Package(
        productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 1.0, strain: 'Golden Teacher',
        tpeMg: 8, quantity: 9, expires: DateTime(2027, 3, 1), labelInput: li);

    test('remembered with the rest, and filled back in while the weight and potency still match', () {
      rememberServerFigures(store(), [servedWith(input)], seenAt);
      final known = keptEnrichment(store(), seenAt);
      expect(known.values.single.labelInput, input);
      expect(applyEnrichment([fromState()], known).single.labelInput, input);
      expect(applyEnrichment([fromState(wpu: 6.0)], known).single.labelInput, isNull); // changed: not this record's any more
    });

    test('an entry kept without one, or from a reply with none, has none', () {
      rememberServerFigures(store(), [servedWith(null)], seenAt);
      final known = keptEnrichment(store(), seenAt);
      expect(known.values.single.labelInput, isNull);
      expect(applyEnrichment([fromState()], known).single.labelInput, isNull);
    });
  });

  group('applyEnrichment', () {
    Map<String, PackageEnrichment> knownFrom(Package p) => {
          PackageEnrichment.keyOf(p): PackageEnrichment(
              productGuid: p.productGuid, id: p.id, weightPerUnit: p.weightPerUnit, analyteWeight: p.analyteWeight,
              strain: p.strain, tpeMg: p.tpeMg, expires: p.expires, seenAt: seenAt),
        };

    test("the same package with unchanged weight and state potency gets the server's strain, tpeMg and expiry", () {
      final out = applyEnrichment([fromState()], knownFrom(served())).single;
      expect(out.strain, 'Golden Teacher');
      expect(out.tpeMg, 8); // the server's figure as it sent it, not the state's 5
      expect(out.expires, DateTime(2027, 3, 1));
      expect(out.enrichedAt, seenAt);
      expect(out.stateEstimate, isFalse);
      // Everything else is the state read's own.
      expect([out.quantity, out.lotGuid, out.weightPerUnit, out.analyteWeight], [4, 'HB-1234abcd', 5.0, 1.0]);
      expect(out.coaAvailable, isTrue);
    });

    test('a changed weightPerUnit leaves the package as the state gave it, marked as an estimate', () {
      final out = applyEnrichment([fromState(wpu: 5.5)], knownFrom(served())).single;
      expect([out.strain, out.tpeMg, out.expires, out.enrichedAt], ['', 6, null, null]);
      expect(out.stateEstimate, isTrue);
    });

    test("a changed state potency (analyteWeight) leaves it as the state gave it - the old TPE may be wrong", () {
      final out = applyEnrichment([fromState(aw: 2.0)], knownFrom(served())).single;
      expect([out.strain, out.tpeMg, out.enrichedAt], ['', 10, null]);
      expect(out.stateEstimate, isTrue);
    });

    test('a package the server never sent stays an estimate, and nothing is rescaled from a sibling record', () {
      final out = applyEnrichment([fromState(id: 999)], knownFrom(served(id: 101))).single;
      expect([out.strain, out.tpeMg, out.enrichedAt], ['', 5, null]);
      expect(out.stateEstimate, isTrue);
    });

    test("a remembered tpeMg below the state's own figure is not trusted", () {
      final out = applyEnrichment([fromState()], knownFrom(served(tpe: 4))).single;
      expect(out.tpeMg, 5);
      expect(out.stateEstimate, isTrue);
    });

    test('an empty remembered strain keeps the name-read strain, and is still filled for TPE', () {
      final p = Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5, analyteWeight: 1, strain: 'GT', tpeMg: 5);
      final out = applyEnrichment([p], knownFrom(served(strain: ''))).single;
      expect([out.strain, out.tpeMg, out.stateEstimate], ['GT', 8, false]);
    });

    test('the marks survive a cached copy (Package.toJson / fromJson)', () {
      // another product (a record of the same product left unfilled would leave the whole product on the state's figures)
      final filled = applyEnrichment([fromState(), fromState(id: 999, guid: 'PKPR-cd34e')], knownFrom(served()));
      final back = [for (final p in filled) Package.fromJson(p.toJson())];
      expect([back[0].enrichedAt, back[0].stateEstimate], [seenAt, false]);
      expect([back[1].enrichedAt, back[1].stateEstimate], [null, true]);
      // A row the server sent carries neither key, as before.
      expect(served().toJson().containsKey('enrichedAtMs'), isFalse);
      expect(served().toJson().containsKey('stateEstimate'), isFalse);
    });
  });

  // The phone's own mazama_core reading of a lab report, kept beside the server's figures.
  group("the phone's reading of a lab report", () {
    // mazama_core's TPE 1.75 mg/g for the record (state psilocybin 1.0 + factor x psilocin), so 5 g x 1.75 = 8.75 -> 9 mg.
    PackageEnrichment reading({int id = 101, double wpu = 5.0, double aw = 1.0, int tpe = 9, DateTime? at}) => PackageEnrichment(
        productGuid: 'PKPR-ab12c', id: id, weightPerUnit: wpu, analyteWeight: aw, strain: 'Golden Teacher', tpeMg: tpe,
        expires: null, seenAt: at ?? seenAt, source: EnrichmentSource.phone, tpeMgPerG: 1.75, psilocinMg: 2.69);

    test('rememberPhoneReadings round-trips the reading, its source, TPE per gram and psilocin', () {
      rememberPhoneReadings(store(), [reading()], seenAt);
      final e = keptEnrichment(store(), seenAt)[enrichmentKey('PKPR-ab12c', 101)]!;
      expect([e.source, e.tpeMg, e.tpeMgPerG, e.psilocinMg, e.weightPerUnit, e.analyteWeight, e.strain],
          [EnrichmentSource.phone, 9, 1.75, 2.69, 5.0, 1.0, 'Golden Teacher']);
      // a server entry with no source key reads as the server's
      expect(PackageEnrichment.fromJson({'productGuid': 'G', 'id': 1, 'weightPerUnit': 1, 'analyteWeight': 1, 'strain': '',
        'tpeMg': 3, 'seenAtMs': 0})!.source, EnrichmentSource.server);
    });

    test("never replaces the server's figures for the same weight and state potency", () {
      final s = store();
      rememberServerFigures(s, [served()], seenAt);
      rememberPhoneReadings(s, [reading(at: seenAt.add(const Duration(days: 1)))], seenAt.add(const Duration(days: 1)));
      final e = keptEnrichment(s, seenAt.add(const Duration(days: 1)))[enrichmentKey('PKPR-ab12c', 101)]!;
      expect([e.source, e.tpeMg], [EnrichmentSource.server, 8]);
    });

    test("replaces the server's figures that were for another state potency", () {
      final s = store();
      rememberServerFigures(s, [served(aw: 0.9)], seenAt);
      rememberPhoneReadings(s, [reading()], seenAt);
      final e = keptEnrichment(s, seenAt)[enrichmentKey('PKPR-ab12c', 101)]!;
      expect([e.source, e.tpeMg, e.analyteWeight], [EnrichmentSource.phone, 9, 1.0]);
    });

    test("the server's figures replace the phone's when they arrive", () {
      final s = store();
      rememberPhoneReadings(s, [reading()], seenAt);
      rememberServerFigures(s, [served()], seenAt.add(const Duration(hours: 1)));
      final e = keptEnrichment(s, seenAt.add(const Duration(hours: 1)))[enrichmentKey('PKPR-ab12c', 101)]!;
      expect([e.source, e.tpeMg, e.tpeMgPerG], [EnrichmentSource.server, 8, null]);
    });

    test('a reading with no mg TPE is not kept', () {
      rememberPhoneReadings(store(), [reading(tpe: 0)], seenAt);
      expect(keptEnrichment(store(), seenAt), isEmpty);
    });

    test('fills a state read when weight and state potency match, marked as the phone\'s', () {
      final out = applyEnrichment([fromState()], {PackageEnrichment.keyOf(fromState()): reading()}).single;
      expect([out.tpeMg, out.strain, out.stateEstimate, out.enrichedAt, out.enrichedBy, out.mgFigure],
          [9, 'Golden Teacher', false, seenAt, EnrichmentSource.phone, MgFigure.tpe]);
      expect(tpeProvenanceNote(PkprGroup([out])), " (this phone's reading of the lab report on ${formatEnrichmentDate(seenAt)})");
      // and the mark survives a cached copy
      final back = Package.fromJson(out.toJson());
      expect([back.enrichedBy, back.enrichedAt], [EnrichmentSource.phone, seenAt]);
    });

    test("doesn't fill when the weight or the state potency changed: then only the state's psilocybin, as mg psilocybin", () {
      for (final changed in [fromState(wpu: 5.5), fromState(aw: 1.2)]) {
        final out = applyEnrichment([changed], {PackageEnrichment.keyOf(changed): reading()}).single;
        expect([out.tpeMg, out.stateEstimate, out.enrichedAt, out.mgFigure], [changed.tpeMg, true, null, MgFigure.psilocybin]);
        expect(PkprGroup([out]).mgLabel, 'mg psilocybin');
      }
    });
  });

  group('mg figure', () {
    test("a server row and a filled row are mg TPE; a state-only one is mg psilocybin, and so is its whole product", () {
      expect([served().mgFigure, PkprGroup([served()]).mgLabel], [MgFigure.tpe, 'mg TPE']);
      final known = {
        PackageEnrichment.keyOf(served()): PackageEnrichment(productGuid: 'PKPR-ab12c', id: 101, weightPerUnit: 5, analyteWeight: 1,
            strain: 'GT', tpeMg: 8, expires: DateTime(2027, 3, 1), seenAt: seenAt),
      };
      // record 101 could be filled, record 102 (same product) can't: the product stays on the state's figures throughout,
      // so the one mg it is shown and priced by is the state's psilocybin, labelled as such
      final out = applyEnrichment([fromState(), fromState(id: 102, qty: 2)], known);
      expect([for (final p in out) p.tpeMg], [5, 5]);
      expect([for (final p in out) p.stateEstimate], [true, true]);
      expect(out.first.strain, 'GT'); // what is kept for record 101 besides its mg still shows
      expect(out.first.expires, DateTime(2027, 3, 1)); // and still orders the draw
      final g = PkprGroup(out);
      expect([g.mgFigure, g.mgLabel, g.tpeMg], [MgFigure.psilocybin, 'mg psilocybin', 5]);
      expect(mgFigureLabel(MgFigure.tpe), 'mg TPE');
    });
  });

  group('tpeProvenanceNote', () {
    test("says estimate, Mazama's dated figure, or nothing for a live row", () {
      final filled = applyEnrichment([fromState()], {
        PackageEnrichment.keyOf(served()): PackageEnrichment(
            productGuid: 'PKPR-ab12c', id: 101, weightPerUnit: 5, analyteWeight: 1, strain: 'GT', tpeMg: 8, expires: null, seenAt: seenAt),
      });
      final estimate = applyEnrichment([fromState()], const {});
      expect(tpeProvenanceNote(PkprGroup(estimate)), " (the state's figure; no TPE known)");
      expect(tpeProvenanceNote(PkprGroup(filled)), " (Mazama's figure from ${formatEnrichmentDate(seenAt)})");
      expect(tpeProvenanceNote(PkprGroup([served()])), '');
      // One estimated lot makes the whole PKPR an estimate.
      expect(groupIsEstimate(PkprGroup([...filled, ...applyEnrichment([fromState(id: 102)], const {})])), isTrue);
    });

    test('formatEnrichmentDate is a plain month day, year', () {
      expect(formatEnrichmentDate(DateTime(2026, 10, 21, 12)), 'Oct 21, 2026');
    });
  });
}
