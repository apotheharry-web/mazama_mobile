import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/enrichment_store.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/features.g.dart';
import 'package:mazama_mobile/stock_page.dart';
import 'package:mazama_mobile/sync/updated_line.dart';

import 'features_off.dart';

final _center = License(id: 231, licenseId: 'SC-b1c7379a', licenseName: 'Bendable Service Center', licenseType: 'ServiceCenter');

// Deliberately out of alphabetical/productType order and out of PKPR order, so a passing sort assertion below
// actually proves something.
final _inventory = [
  Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0, strain: 'Enigma', tpeMg: 90, quantity: 3),
  Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5, strain: 'Golden Teacher', tpeMg: 5, quantity: 10),
  Package(productGuid: 'PKPR-ab99c', productType: 'Extract', id: 103, weightPerUnit: 5.0, analyteWeight: 2.0, strain: 'Maztapec', tpeMg: 3, quantity: 7),
];

Widget _stockPage(
        {required Future<List<Package>> Function(int) fetchPackages,
        Map<String, Feature> featureTable = features,
        Future<DateTime?> Function(int stateId)? readAt,
        DateTime Function()? now}) =>
    MaterialApp(
        home: StockPage(
            center: _center,
            fetchPackages: fetchPackages,
            featureTable: featureTable,
            readAt: readAt,
            now: now ?? DateTime.now));

void main() {
  testWidgets('shows a spinner, then every package sorted by type then PKPR, with its quantity and mg TPE', (tester) async {
    await tester.pumpWidget(_stockPage(fetchPackages: (id) async {
      expect(id, 231);
      return _inventory;
    }));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Bendable Service Center stock'), findsOneWidget);
    // Each package's own ListTile shows its PKPR, not its product type - the type is only ever shown once per
    // group, in the bold _TypeHeader row above it (see stock_page.dart's _rows/_TypeHeader), not repeated on
    // every tile. So the sort order this test cares about (type, then PKPR, breaking the type tie) shows up
    // here as the PKPR order across tiles, not as the tile titles themselves.
    final titles = tester.widgetList<ListTile>(find.byType(ListTile)).map((t) => (t.title as Text).data).toList();
    // ab12c, ab99c (both Extract, PKPR order breaks the tie), then ff99aa (Whole Fungi) - type order first.
    expect(titles, ['PKPR-ab12c', 'PKPR-ab99c', 'PKPR-ff99aa']);
    // The two type headers themselves appear in that same type order, each exactly once (not once per package).
    final typeHeaders = find.text('Extract').evaluate().length;
    expect(typeHeaders, 1);
    expect(find.text('Whole Fungi'), findsOneWidget);
    expect(find.textContaining('PKPR-ab12c'), findsOneWidget);
    expect(find.textContaining('Golden Teacher'), findsOneWidget);
    expect(find.textContaining('5mg TPE each'), findsOneWidget);
    expect(find.text('10\nin stock'), findsOneWidget);
  });

  // SM-D31: what each row's figure is, and where it came from, when stock was read from the state system alone.
  testWidgets("a state-only product shows mg psilocybin; a filled one mg TPE with whose figure it is", (tester) async {
    final at = DateTime.utc(2026, 10, 21, 15);
    await tester.pumpWidget(_stockPage(fetchPackages: (id) async => [
          Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 101, weightPerUnit: 5.0, analyteWeight: 4.5, tpeMg: 23,
              quantity: 10, stateEstimate: true),
          Package(productGuid: 'PKPR-ab99c', productType: 'Extract', id: 103, weightPerUnit: 5.0, analyteWeight: 2.0, tpeMg: 12,
              quantity: 7, enrichedAt: at, enrichedBy: EnrichmentSource.phone),
          Package(productGuid: 'PKPR-ff99aa', productType: 'Whole Fungi', id: 102, weightPerUnit: 10.0, analyteWeight: 9.0, tpeMg: 95,
              quantity: 3, enrichedAt: at),
        ]));
    await tester.pumpAndSettle();
    final date = formatEnrichmentDate(at);
    expect(find.text("23mg psilocybin each (the state's figure; no TPE known)"), findsOneWidget);
    expect(find.text("12mg TPE each (this phone's reading of the lab report on $date)"), findsOneWidget);
    expect(find.text("95mg TPE each (Mazama's figure from $date)"), findsOneWidget);
  });

  testWidgets('a fetch failure shows the error and Retry reloads', (tester) async {
    int calls = 0;
    await tester.pumpWidget(_stockPage(fetchPackages: (id) async {
      calls++;
      if (calls == 1) throw PackagesError('no network');
      return _inventory;
    }));
    await tester.pumpAndSettle();

    expect(find.textContaining('Stock did not load'), findsOneWidget);
    expect(find.textContaining('no network'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stock did not load'), findsNothing);
    expect(find.text('Whole Fungi'), findsOneWidget);
  });

  testWidgets('multiple lots of the same PKPR show as one line with the summed quantity', (tester) async {
    // Two separate lots/transfers of PKPR-ab12c (same productGuid, different id/quantity - exactly what the
    // server's own public_packages sends when a center has more than one) should never appear as two rows; a
    // worker browsing stock has no reason to know a lot exists at all, only the PKPR's true total.
    final withASecondLot = [
      ..._inventory,
      Package(productGuid: 'PKPR-ab12c', productType: 'Extract', id: 104, weightPerUnit: 5.0, analyteWeight: 4.5, quantity: 6),
    ];
    await tester.pumpWidget(_stockPage(fetchPackages: (id) async => withASecondLot));
    await tester.pumpAndSettle();

    expect(find.textContaining('PKPR-ab12c'), findsOneWidget); // one row, not two
    expect(find.text('16\nin stock'), findsOneWidget); // 10 + 6, summed across both lots
  });

  testWidgets('an empty center says so plainly', (tester) async {
    await tester.pumpWidget(_stockPage(fetchPackages: (id) async => const []));
    await tester.pumpAndSettle();
    expect(find.text('Nothing in stock.'), findsOneWidget);
  });

  testWidgets('searching filters by product type or PKPR, case-insensitively, and an empty result says so', (tester) async {
    await tester.pumpWidget(_stockPage(fetchPackages: (id) async => _inventory));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'whole');
    await tester.pumpAndSettle();
    expect(find.text('Whole Fungi'), findsOneWidget);
    expect(find.text('Extract'), findsNothing);

    await tester.enterText(find.byType(TextField), 'PKPR-ab99c');
    await tester.pumpAndSettle();
    expect(find.text('Extract'), findsOneWidget);
    // Scoped to the result list, not the whole screen: the search field itself echoes back exactly
    // 'PKPR-ab99c' as you type it, so an unscoped find.textContaining here matches both that field and the
    // one matching ListTile's subtitle, and findsOneWidget fails with "Found 2".
    expect(find.descendant(of: find.byType(ListView), matching: find.textContaining('PKPR-ab99c')), findsOneWidget);
    expect(find.descendant(of: find.byType(ListView), matching: find.textContaining('PKPR-ab12c')), findsNothing);

    await tester.enterText(find.byType(TextField), 'nothing matches this');
    await tester.pumpAndSettle();
    expect(find.textContaining('No match for'), findsOneWidget);
  });

  group('pull to refresh', () {
    // The owner's rule: this PKPR list is the one page where pulling down re-downloads the inventory.
    Future<void> pull(WidgetTester tester) async {
      await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
    }

    testWidgets('re-downloads the inventory, keeping the search and the selection', (tester) async {
      var calls = 0;
      await tester.pumpWidget(_stockPage(fetchPackages: (id) async {
        calls++;
        return calls == 1
            ? _inventory
            : [
                ..._inventory,
                Package(productGuid: 'PKPR-ab55e', productType: 'Extract', id: 105, weightPerUnit: 5.0, analyteWeight: 4.5, strain: 'Enigma', tpeMg: 5, quantity: 2),
              ];
      }));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'extract');
      await tester.pumpAndSettle();
      await tester.tap(find.text('PKPR-ab12c'));
      await tester.pumpAndSettle();
      expect(find.text('PKPR-ab55e'), findsNothing);

      await pull(tester);
      expect(calls, 2);
      expect(find.text('PKPR-ab55e'), findsOneWidget); // the new download, still filtered by the search
      expect(find.text('PKPR-ff99aa'), findsNothing);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'PKPR-ab12c')).selected, isTrue);
      expect(find.text('Add 1'), findsOneWidget);
    });

    testWidgets('a failed refresh keeps the list on screen and says so', (tester) async {
      var calls = 0;
      await tester.pumpWidget(_stockPage(fetchPackages: (id) async {
        calls++;
        if (calls == 2) throw PackagesError('no network');
        return _inventory;
      }));
      await tester.pumpAndSettle();

      await pull(tester);
      expect(calls, 2);
      expect(find.text('PKPR-ab12c'), findsOneWidget);
      expect(find.textContaining('Stock did not refresh: '), findsOneWidget);
      expect(find.textContaining('no network'), findsOneWidget);
    });

    testWidgets('works on an empty center too', (tester) async {
      var calls = 0;
      await tester.pumpWidget(_stockPage(fetchPackages: (id) async {
        calls++;
        return calls == 1 ? const [] : _inventory;
      }));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in stock.'), findsOneWidget);

      await pull(tester);
      expect(calls, 2);
      expect(find.text('PKPR-ab12c'), findsOneWidget);
    });
  });

  // specs/features FR-3: the reconcile page is reached only while reconcile is on for the license's type.
  testWidgets('the reconcile button shows while reconcile is on, and is hidden when it is off', (tester) async {
    await tester.pumpWidget(_stockPage(fetchPackages: (id) async => _inventory));
    await tester.pumpAndSettle();
    expect(find.text('Reconcile inventory with state'), findsOneWidget);

    await tester.pumpWidget(_stockPage(fetchPackages: (id) async => _inventory, featureTable: featuresWithOff(['reconcile'])));
    await tester.pumpAndSettle();
    expect(find.text('Reconcile inventory with state'), findsNothing);
    expect(find.text('Extract'), findsOneWidget); // the stock list itself is unchanged
  });

  // specs/phone-sync Task 8b Step 8 (PS-R7, PS-D5): the list's age, from when the stock it shows was read (the cart
  // passes the center_stock dataset's time), asked again after each download.
  group('the stock list shows its age', () {
    final now = DateTime.utc(2026, 10, 30, 12);

    testWidgets('from the time of the stock it shows, again after a pull-down', (tester) async {
      var readAt = now.subtract(const Duration(minutes: 20));
      final asked = <int>[];
      await tester.pumpWidget(_stockPage(
        fetchPackages: (id) async => _inventory,
        readAt: (id) async {
          asked.add(id);
          return readAt;
        },
        now: () => now,
      ));
      expect(find.byKey(updatedLineKey), findsNothing); // nothing shown yet
      await tester.pumpAndSettle();
      expect(find.text('Updated 20 min ago'), findsOneWidget);
      expect(asked, [231]);
      readAt = now;
      await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(find.text('Updated just now'), findsOneWidget);
      expect(asked, [231, 231]);
    });

    testWidgets('none with no time known, or when the time cannot be read; the list shows either way', (tester) async {
      await tester.pumpWidget(_stockPage(fetchPackages: (id) async => _inventory, readAt: (id) async => null));
      await tester.pumpAndSettle();
      expect(find.byKey(updatedLineKey), findsNothing);
      expect(find.text('PKPR-ab12c'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_stockPage(fetchPackages: (id) async => _inventory, readAt: (id) async => throw StateError('no db')));
      await tester.pumpAndSettle();
      expect(find.byKey(updatedLineKey), findsNothing);
      expect(find.text('PKPR-ab12c'), findsOneWidget);
    });
  });
}
