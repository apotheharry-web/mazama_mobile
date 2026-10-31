// DOSE-8 (specs/core row 5, I10): before a sale the phone reads the state again whenever a lot it draws is only a phone's
// upload (/p/packages' `confirmed` false), whatever the age of its stock, and checks the cap again on the state's figures
// (cart_page.dart's _recheckOldStock / _recheckBulkStock; the widget tests are in cart_page_dose_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/packages_client.dart';

Package _lot(int id, {bool confirmed = true}) => Package(
    productGuid: 'PKPR-ab12c', productType: 'Extract', id: id, weightPerUnit: 1.0, analyteWeight: 10.0, quantity: 5, confirmed: confirmed);

void main() {
  test('confirmed lots the state vouched for recently are not read again (SM-25, as before)', () {
    expect(stockRecheckNeeded([_lot(1), _lot(2)], stateVouches: true, lotVouched: (_) => false), isFalse);
    expect(stockRecheckNeeded([_lot(1), _lot(2)], stateVouches: false, lotVouched: (_) => true), isFalse);
    expect(stockRecheckNeeded([_lot(1), _lot(2)], stateVouches: false, lotVouched: (l) => l.id == 1), isTrue);
    expect(stockRecheckNeeded(const [], stateVouches: false, lotVouched: (_) => true), isTrue);
  });

  test('a lot that is only a phone\'s upload is always read again, however fresh the stock', () {
    expect(stockRecheckNeeded([_lot(1), _lot(2, confirmed: false)], stateVouches: true, lotVouched: (_) => true), isTrue);
  });

  test('/p/packages\' confirmed: false only when the server says so; an older server\'s rows count as confirmed', () {
    final base = {'productGuid': 'PKPR-ab12c', 'id': 1, 'weightPerUnit': 1.0, 'analyteWeight': 10.0, 'quantity': 5};
    expect(Package.fromJson({...base, 'confirmed': false}).confirmed, isFalse);
    expect(Package.fromJson({...base, 'confirmed': true}).confirmed, isTrue);
    expect(Package.fromJson(base).confirmed, isTrue);
    // kept through a saved cart: written only when false
    expect(Package.fromJson(Package.fromJson({...base, 'confirmed': false}).toJson()).confirmed, isFalse);
    expect(Package.fromJson(base).toJson().containsKey('confirmed'), isFalse);
  });
}
