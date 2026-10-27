import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/debug_state_data_page.dart';
import 'package:mazama_mobile/licenses_client.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/session.dart';

Session _session() => Session(
    accessToken: 'TOKEN', refreshToken: 'REFRESH', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

Widget _page({
  int? initialStateId,
  Future<List<License>> Function(String)? fetchApplicableLicenses,
  Future<List<Package>> Function(int)? fetchPackages,
  Future<List<Package>> Function(int, {required String accessToken})? fetchPackagesFromState,
}) =>
    MaterialApp(
      home: DebugStateDataPage(
        session: _session(),
        initialStateId: initialStateId,
        fetchApplicableLicenses: fetchApplicableLicenses ?? (accessToken) async => throw Exception('no fixture'),
        fetchPackages: fetchPackages ?? (stateId) async => throw Exception('no fixture'),
        fetchPackagesFromState: fetchPackagesFromState ?? (stateId, {required accessToken}) async => throw Exception('no fixture'),
      ),
    );

void main() {
  testWidgets('fetch licenses shows every license unfiltered, with the access token used', (tester) async {
    String? tokenUsed;
    await tester.pumpWidget(_page(fetchApplicableLicenses: (accessToken) async {
      tokenUsed = accessToken;
      return [
        License(id: 231, licenseId: 'L-231', licenseName: 'Bendable Service Center', licenseType: 'ServiceCenter'),
        License(id: 294, licenseId: 'L-294', licenseName: 'Mazama Mushrooms LLC', licenseType: 'Manufacturer'),
      ];
    }));

    await tester.tap(find.text('Fetch licenses'));
    await tester.pumpAndSettle();

    expect(tokenUsed, 'TOKEN');
    expect(find.textContaining('Bendable Service Center'), findsOneWidget);
    expect(find.textContaining('Manufacturer'), findsOneWidget); // not filtered out, unlike SelectCenterPage
    expect(find.textContaining('2 result(s)'), findsOneWidget);
  });

  testWidgets('fetch mazama packages and fetch state packages both use the typed state id, independently', (tester) async {
    int? mazamaCalledWith;
    int? stateCalledWith;
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchPackages: (stateId) async {
        mazamaCalledWith = stateId;
        return [Package(productGuid: 'PKPR-a', productType: 'Extract', id: 1, weightPerUnit: 5, analyteWeight: 4.5, quantity: 3)];
      },
      fetchPackagesFromState: (stateId, {required accessToken}) async {
        stateCalledWith = stateId;
        return [];
      },
    ));

    await tester.tap(find.text('Fetch mazama packages'));
    await tester.pumpAndSettle();
    expect(mazamaCalledWith, 225);
    expect(find.textContaining('PKPR-a'), findsOneWidget);

    // the first fetch's results push this button below the 800x600 test screen: scroll to it, as a person would
    await tester.ensureVisible(find.text('Fetch state packages'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch state packages'));
    await tester.pumpAndSettle();
    expect(stateCalledWith, 225);
    expect(find.textContaining('No packages at the state system'), findsOneWidget);
  });

  testWidgets('an error from either packages fetch is shown, not swallowed', (tester) async {
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchPackages: (stateId) async => throw Exception('mazama unreachable'),
    ));

    await tester.tap(find.text('Fetch mazama packages'));
    await tester.pumpAndSettle();

    expect(find.textContaining('mazama unreachable'), findsOneWidget);
  });

  testWidgets('a non-numeric state id refuses the packages fetches rather than crashing', (tester) async {
    await tester.pumpWidget(_page());
    await tester.tap(find.text('Fetch mazama packages'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a numeric state id'), findsOneWidget);
  });
}
