// SM-17: which lot (state package record) a unit of a product is drawn from (packages_client.dart drawOrder,
// allocateLots, PkprGroup), held to the cases the server's own Python computed (../mazama_modules/selling/gen.py ->
// selling.py draw_order / allocate), vendored here at assets/shared/selling/vectors/allocate.json. SM-D29: the
// earliest expiry first; a lot with no known date after every dated one; then the smaller lot; then the lower id. A
// quantity beyond every lot is refused, never spilled onto the last lot.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/packages_client.dart';

final _cases = jsonDecode(File('assets/shared/selling/vectors/allocate.json').readAsStringSync()) as Map<String, Object?>;

List<Package> _lots(Map<String, Object?> c) => [
      for (final l in (c['lots'] as List).cast<Map<String, Object?>>())
        Package(
          productGuid: 'PKPR-ab12c',
          productType: 'Extract',
          id: l['id'] as int,
          weightPerUnit: 1,
          analyteWeight: 1,
          quantity: l['quantity'] as int,
          expires: l['expires'] == null ? null : DateTime.parse(l['expires'] as String),
        ),
    ];

void main() {
  final cases = (_cases['cases'] as List).cast<Map<String, Object?>>();
  test('there are enough cases, and one beyond every lot', () {
    expect(cases.length, greaterThanOrEqualTo(10));
    expect(cases.any((c) => c['takes'] == null), isTrue);
  });
  for (final c in cases) {
    test(c['name'] as String, () {
      expect([for (final l in drawOrder(_lots(c))) l.id], c['order']);
      if (_lots(c).isNotEmpty) {
        expect([for (final l in PkprGroup(_lots(c)).lots) l.id], c['order']); // a cart line's lots, in draw order
      }
      final got = allocateLots(_lots(c), c['qty'] as int);
      expect(got == null ? null : [for (final (lot, n) in got) [lot.id, n]], c['takes']);
    });
  }

  test("/p/packages' expiry date is read, and a reply without one is undated", () {
    final p = Package.fromJson({'productGuid': 'PKPR-ab12c', 'id': 1, 'quantity': 2, 'expires': '2027-03-01'});
    expect(p.expires, DateTime(2027, 3, 1));
    expect(Package.fromJson(p.toJson()).expires, DateTime(2027, 3, 1)); // survives a saved cart
    expect(Package.fromJson({'productGuid': 'PKPR-ab12c', 'id': 1}).expires, isNull);
  });
}
