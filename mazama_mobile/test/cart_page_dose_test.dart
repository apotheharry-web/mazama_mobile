// The cap on the cart page: the cap is the shared core's (dose.dart). The sale check reads
// the state again and refuses a sale, or a bulk sale's copy, whose state figures moved since the cart was priced (in
// the core's check_sale words, before the cap on those figures), nothing sent; a unit of unknown potency refuses the cart, with the core's words.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/flow/flow_runner.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/state_packages_client.dart';

import 'flow/fake_state.dart';
import 'cart_page_test_support.dart';

/// A figure the state changed since the cart was priced is refused before the cap is reached
/// (the server's worker does the same); the cap still runs on the state's figures as just read when they are unchanged.
const _changed = "PKPR-d00d1: the state's record changed since the sale was priced (analyteWeight); nothing was sent.";


void main() {
  // as in cart_page_sell_test.dart: rootBundle's cache outlives a test, so it is cleared after each
  tearDown(() => rootBundle.clear());

  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_cart_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  late final FlowSpec loginSpec = FlowSpec.fromYaml(File('assets/flows/login.yaml').readAsStringSync());

  Package lot(int id, int quantity, double analyteWeight, {bool confirmed = true}) => Package(
      productGuid: 'PKPR-d00d1', productType: 'Extract', id: id, weightPerUnit: 1.0, analyteWeight: analyteWeight,
      strain: 'Golden Teacher', tpeMg: 10, quantity: quantity, confirmed: confirmed);

  Map<String, Object?> record(int id, double analyteWeight, int quantity) => {
        'id': id, 'productGuid': 'PKPR-d00d1', 'productType': 'Extract', 'weightPerUnit': 1.0, 'analyteWeight': analyteWeight,
        'quantity': quantity, 'serviceCenterId': 231, 'zeroOut': false, 'locked': false, 'flagged': false,
        'pendingTransfer': false,
      };

  /// The cart on [lots] (the state not read at load, answering [reread] after), 3 units of PKPR-d00d1 in it.
  Future<FakeState> open(WidgetTester tester, List<Package> lots, Future<List<Object?>> Function() reread) async {
    final fake = FakeState();
    final login = await runFlow(loginSpec, 'login', {'email': fakeEmail, 'password': fakePassword}, client: fake.client());
    fake.data['CreateSalesRecords/false'] = [{'id': 9001, 'saleNumber': 'S-1'}];
    var loaded = false;
    await tester.pumpWidget(cartPage(
      fetchPackages: (id) async => [...inventory, ...lots],
      fetchRawPackagesFromState: (id, {required accessToken}) async {
        if (!loaded) throw StatePackagesError('not read at load in this test');
        return reread();
      },
      session: freshSession(accessToken: login['access_token'] as String),
      saleSpec: Future.value(realSaleSpec),
      httpClientFactory: fake.client,
    ));
    await tester.pumpAndSettle();
    loaded = true;
    await addLine(tester, pkpr: 'd00d1', qty: '3', price: '10.00');
    return fake;
  }

  testWidgets("DOSE-8: a sale the state's figures now put over the cap is refused, nothing sent", (tester) async {
    // 30 mg on the phone's figures (an upload the server's sync hasn't seen); the state now says 20 mg/g: 60 mg
    final fake = await open(tester, [lot(301, 3, 10.0, confirmed: false)], () async => [record(301, 20.0, 3)]);
    expect(find.textContaining('mg limit per sale'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm sale'));
    await tester.pumpAndSettle();

    expect(fake.posted, isEmpty);
    expect(find.text('The sale was not sent'), findsOneWidget);
    expect(find.textContaining(_changed), findsOneWidget); // the state's figures were read again before anything was sent
    expect(find.text('Nothing in the cart yet.'), findsNothing);
  });

  testWidgets("DOSE-8, DOSE-17: a bulk sale's copy the state's figures now put over the cap refuses them all", (tester) async {
    // copy 1 takes lot 301, copy 2 lot 302 (30 mg each on the phone's figures); the state now has lot 302 at 20 mg/g
    final fake = await open(tester, [lot(301, 3, 10.0), lot(302, 10, 10.0)],
        () async => [record(301, 10.0, 3), record(302, 20.0, 10)]);
    await tester.longPress(find.byKey(const Key('cartsButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('mg limit per sale'), findsNothing); // both copies within the cap as the phone has them
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm 2 sales'));
    await tester.pumpAndSettle();

    expect(fake.posted, isEmpty);
    expect(find.text('The sales were not sent'), findsOneWidget);
    expect(find.textContaining(_changed), findsOneWidget); // lot 302's figure as the state has it now, before any copy is sent
  });

  testWidgets("DOSE-5: a unit of unknown potency refuses the cart with the core's words, and no total is shown",
      (tester) async {
    await open(tester, [lot(301, 3, 0.0)], () async => [record(301, 0.0, 3)]);
    expect(
        find.text("This sale holds a unit whose psilocybin isn't known (no weightPerUnit or analyteWeight), so it can't be "
            'sold here.'),
        findsOneWidget);
    expect(find.textContaining('mg psilocybin not known'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell')).onPressed, isNull);
  });
}
