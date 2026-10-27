// reconcile_page.dart: the state's figures beside a worker's count. Here only what each row says its mg is (SM-D31):
// mg TPE, or - for a product read from the state system with no TPE known - mg psilocybin.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/reconcile_page.dart';

final _center = License(id: 231, licenseId: 'SC-b1c7379a', licenseName: 'Bendable Service Center', licenseType: 'ServiceCenter');

void main() {
  testWidgets("each row's state record says mg TPE, or mg psilocybin when only the state's psilocybin is known", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ReconcilePage(
        center: _center,
        fetchPackages: (id) async => [
          Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5, tpeMg: 23,
              quantity: 10, stateEstimate: true),
          Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0,
              strain: 'Enigma', tpeMg: 95, quantity: 3),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text("State record: 10 · 23mg psilocybin each (the state's figure; no TPE known)"), findsOneWidget);
    expect(find.text('State record: 3 · 95mg TPE each'), findsOneWidget);
  });
}
