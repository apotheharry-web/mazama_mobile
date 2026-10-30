// Scan matching on the phone (local_scan_match.dart): the cart's stock and a label's lines turned into the shared
// core's input the way the server's public_scan_match builds it, and its answer into the ScanMatchResult the server's
// reply becomes. The matcher's own answers are held to the shared cases in mazama_core_test.dart; these check the
// adapting around it. CI builds the library and passes its path as MAZAMA_CORE_FFI_LIB (test/support/core.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/local_scan_match.dart';
import 'package:mazama_mobile/packages_client.dart';

import 'support/core.dart';

Package _pk(String guid, int id, String description, int quantity,
        {double weight = 0.5, double potency = 5, DateTime? expires}) =>
    Package(
      productGuid: guid,
      productType: 'Whole Fungi',
      id: id,
      weightPerUnit: weight,
      analyteWeight: potency,
      quantity: quantity,
      description: description,
      expires: expires,
    );

final _stock = [
  _pk('PKPR-579b4701', 1, 'Maztapec 5 mg TPE', 4),
  _pk('PKPR-579b4701', 2, 'Maztapec later', 2),
  _pk('PKPR-d0d0d0d0', 3, '', 3),
  _pk('PKPR-12345678', 4, 'Sold out', 0),
  _pk('PKPR-aaaa0001', 5, 'Bluey x', 1, weight: 1.0),
  _pk('PKPR-aaaa0001', 6, 'Golden Teacher 5 mg', 2, potency: 7.25, expires: DateTime(2027, 6, 1)),
];

void main() {
  test('a core that can\'t answer gives no local match: the cart keeps the server\'s error', () {
    expect(localScanMatchWith(_FailingCore(), _stock, ['Lot: 579b4701']), isNull);
  });

  group('through the library', () {
    late final MazamaCore core = loadTestCore();

    test('a lot number is named by its first record, with the units of all its records', () {
      final r = localScanMatchWith(core, _stock, ['Lot: 579b4731'])!;
      expect(r.guesses, isEmpty);
      final m = r.matches.single;
      expect([m.guid, m.name, m.dist, m.line, m.stock, m.sellable], ['PKPR-579b4701', 'Maztapec 5 mg TPE', 1, 'Lot: 579b4731', 6, true]);
    });

    test('a package with no name is shown by its id, as the server shows it', () {
      expect(localScanMatchWith(core, _stock, ['Lot: d0d0d0d0'])!.matches.single.name, 'PKPR-d0d0d0d0');
    });

    test('a match with no units left is found but not sellable, as the server says', () {
      final m = localScanMatchWith(core, _stock, ['Lot: 12345678'])!.matches.single;
      expect([m.guid, m.stock, m.sellable], ['PKPR-12345678', 0, false]);
    });

    test('with no lot number, guesses are named by the record they fit and counted over the package', () {
      final r = localScanMatchWith(core, _stock, ['Golden Teacher', 'Net wt: 0.50 g', 'Best by 2027-06-01'])!;
      expect(r.matches, isEmpty);
      // every 0.50 g package fits the weight; the sold-out one isn't offered (it can't be sold)
      expect([for (final g in r.guesses) (g.guid, g.name, g.score, g.stock)], [
        ('PKPR-aaaa0001', 'Golden Teacher 5 mg', 7, 3),
        ('PKPR-579b4701', 'Maztapec 5 mg TPE', 3, 6),
        ('PKPR-d0d0d0d0', 'PKPR-d0d0d0d0', 3, 3),
      ]);
      expect(r.guesses.first.why, ['net weight 0.50 g', 'best by 2027-06-01', 'name has golden, teacher']);
    });

    test('typed text gets no guesses, as on the server', () {
      final r = localScanMatchWith(core, _stock, ['Golden Teacher', 'Net wt: 0.50 g'], typed: true)!;
      expect([r.matches, r.guesses], [isEmpty, isEmpty]);
    });

    test('typed text trusts two misread characters, as on the server', () {
      expect(localScanMatchWith(core, _stock, ['d0d0d0e1'], typed: true)!.matches.single.dist, 2);
      expect(localScanMatchWith(core, _stock, ['xx d0d0d0e1'])!.matches, isEmpty);
    });

    test('only the lines and characters the server would read are matched', () {
      final past60 = [for (var i = 0; i < 60; i++) 'nothing', 'Lot: 579b4701'];
      expect(localScanMatchWith(core, _stock, past60)!.matches, isEmpty);
      expect(localScanMatchWith(core, _stock, ['${'x' * 200}579b4701'])!.matches, isEmpty);
      expect(localScanMatchWith(core, _stock, ['${'x' * 78}579b4701'])!.matches, isEmpty); // past the matcher's 80
      expect(localScanMatchWith(core, _stock, ['${'x' * 60}579b4701'])!.matches.single.guid, 'PKPR-579b4701');
      expect(localScanMatchWith(core, _stock, ['${'x' * 10} 579b4701'])!.matches.single.guid, 'PKPR-579b4701');
    });

    test('an empty stock matches nothing', () {
      final r = localScanMatchWith(core, const [], ['Lot: 579b4701', 'Net wt: 0.50 g'])!;
      expect([r.matches, r.guesses], [isEmpty, isEmpty]);
    });
  });
}

/// A core whose every answer is an error.
class _FailingCore implements CoreFunctions {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw const MazamaCoreError('no');
}
