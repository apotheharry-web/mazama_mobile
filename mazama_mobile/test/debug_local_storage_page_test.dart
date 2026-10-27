import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_page.dart';
import 'package:mazama_mobile/cart_store.dart';
import 'package:mazama_mobile/debug_local_storage_page.dart';
import 'package:mazama_mobile/device_id.dart';
import 'package:mazama_mobile/inventory_cache_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/session_store.dart';

late Directory _tempDir;

void main() {
  setUp(() => _tempDir = Directory.systemTemp.createTempSync('mazama_local_storage_test_'));
  tearDown(() => _tempDir.deleteSync(recursive: true));

  Directory Function() dir() => () => _tempDir;

  testWidgets('shows nothing-stored for every section on a fresh install, except device id (always created)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DebugLocalStoragePage(
        initialStateId: 225,
        sessionStore: SessionStore(dataDir: dir()),
        cartStore: CartStore(dataDir: dir()),
        inventoryCacheStore: InventoryCacheStore(dataDir: dir()),
        deviceIdStore: DeviceIdStore(dataDir: dir()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing stored'), findsNWidgets(3)); // session, cart, inventory cache
    expect(find.textContaining('Loading...'), findsNothing);
  });

  testWidgets('shows a saved session, cart draft and inventory cache, and clear buttons remove each', (tester) async {
    final sessionStore = SessionStore(dataDir: dir());
    final cartStore = CartStore(dataDir: dir());
    final inventoryCacheStore = InventoryCacheStore(dataDir: dir());

    await sessionStore.save({'email': 'worker@example.com', 'expires_at_ms': 123, 'access_token': 'T', 'refresh_token': 'R'});
    await cartStore.save(225, [
      CartLine(group: PkprGroup([Package(productGuid: 'PKPR-a', productType: 'Extract', id: 1, weightPerUnit: 5, analyteWeight: 4.5, quantity: 10)]), qty: 2, priceCentsEach: 500),
    ]);
    await inventoryCacheStore.save(
      225,
      [Package(productGuid: 'PKPR-a', productType: 'Extract', id: 1, weightPerUnit: 5, analyteWeight: 4.5, quantity: 10)],
      DateTime.utc(2026, 1, 1),
    );

    await tester.pumpWidget(MaterialApp(
      home: DebugLocalStoragePage(
        initialStateId: 225,
        sessionStore: sessionStore,
        cartStore: cartStore,
        inventoryCacheStore: inventoryCacheStore,
        deviceIdStore: DeviceIdStore(dataDir: dir()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('worker@example.com'), findsOneWidget);
    expect(find.textContaining('PKPR-a x2@500c'), findsOneWidget);
    expect(find.textContaining('1 package(s) for center 225'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear session (forces a real sign-in on next app start)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear cart draft'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear inventory cache'));
    await tester.pumpAndSettle();

    expect(await sessionStore.load(), isNull);
    expect(await cartStore.load(225), isNull);
    expect(await inventoryCacheStore.load(225), isNull);
  });

  testWidgets('reset device id produces a different, newly-saved id', (tester) async {
    final deviceIdStore = DeviceIdStore(dataDir: dir());
    final original = await deviceIdStore.idOrCreate();

    await tester.pumpWidget(MaterialApp(
      home: DebugLocalStoragePage(
        sessionStore: SessionStore(dataDir: dir()),
        cartStore: CartStore(dataDir: dir()),
        inventoryCacheStore: InventoryCacheStore(dataDir: dir()),
        deviceIdStore: deviceIdStore,
      ),
    ));
    await tester.pumpAndSettle();
    // the device id section is the last item of a lazily built list, below the 800x600 test screen: scroll to it
    // (the page's own list, not the Scrollable inside each TextField)
    await tester.scrollUntilVisible(find.widgetWithText(OutlinedButton, 'Reset device id (simulates a fresh install)'), 200,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    expect(find.text(original), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reset device id (simulates a fresh install)'));
    await tester.pumpAndSettle();

    final after = await deviceIdStore.idOrCreate();
    expect(after, isNot(original));
    expect(find.text(after), findsOneWidget);
  });

  testWidgets('changing the state id field reloads the cart draft and inventory cache for the new center', (tester) async {
    final cartStore = CartStore(dataDir: dir());
    await cartStore.save(999, [
      CartLine(group: PkprGroup([Package(productGuid: 'PKPR-z', productType: 'Extract', id: 9, weightPerUnit: 5, analyteWeight: 4.5, quantity: 1)]), qty: 1, priceCentsEach: 100),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: DebugLocalStoragePage(
        initialStateId: 225,
        sessionStore: SessionStore(dataDir: dir()),
        cartStore: cartStore,
        inventoryCacheStore: InventoryCacheStore(dataDir: dir()),
        deviceIdStore: DeviceIdStore(dataDir: dir()),
      ),
    ));
    await tester.pumpAndSettle();
    // the cart draft's message (the inventory cache's own "Nothing stored for center 225." is there too)
    expect(find.textContaining('Nothing stored for center 225 (either empty'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Service center state id (for the cart draft / inventory cache below)'), '999');
    await tester.pumpAndSettle();

    expect(find.textContaining('PKPR-z x1@100c'), findsOneWidget);
  });
}
