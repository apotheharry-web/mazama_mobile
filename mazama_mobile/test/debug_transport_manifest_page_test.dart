import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/debug_transport_manifest_page.dart';
import 'package:mazama_mobile/session.dart';

Session _session() => Session(
    accessToken: 'TOKEN', refreshToken: 'REFRESH', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

/// A center's manifest list as the state system answers it: two with an uploaded PDF, the newest with none, so
/// "newest" and "newest that carries a PDF" are different entries.
List<Object?> _manifests() => [
      {'id': 10, 'dateOfDeparture': '2026-06-02', 'documents': <Object?>[]},
      {'id': 9, 'dateOfDeparture': '2026-05-20', 'documents': [{'id': 200, 'name': 'Manifest9.pdf', 'extension': '.pdf'}]},
      {'id': 7, 'dateOfDeparture': '2026-05-01', 'documents': [{'id': 100, 'name': 'Manifest7.pdf', 'extension': '.pdf'}]},
    ];

Widget _page({
  int? initialStateId,
  Object? Function()? manifests,
  ManifestFetch? fetchManifests,
  DocumentFetch? fetchDocument,
}) =>
    MaterialApp(
      home: DebugTransportManifestPage(
        session: _session(),
        initialStateId: initialStateId,
        fetchManifests: fetchManifests ?? (stateId, {required accessToken}) async => manifests?.call() ?? _manifests(),
        fetchDocument: fetchDocument ?? (docId, {required accessToken}) async => Uint8List.fromList([1, 2, 3]),
        pdfView: (pdf) => Text('PDF-VIEW-${pdf.length}'),
      ),
    );

void main() {
  testWidgets('the newest manifest that carries a PDF is fetched, with the typed id and the session token', (tester) async {
    int? manifestsId, documentId;
    String? manifestsToken, documentToken;
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchManifests: (stateId, {required accessToken}) async {
        manifestsId = stateId;
        manifestsToken = accessToken;
        return _manifests();
      },
      fetchDocument: (docId, {required accessToken}) async {
        documentId = docId;
        documentToken = accessToken;
        return Uint8List.fromList([1, 2, 3]);
      },
    ));

    await tester.tap(find.text('Fetch newest manifest PDF'));
    await tester.pumpAndSettle();

    expect(manifestsId, 225);
    expect(manifestsToken, 'TOKEN');
    // manifest 10 is newer but has no PDF, so 9's document (200) is the one to pull
    expect(documentId, 200);
    expect(documentToken, 'TOKEN');
    expect(find.text('PDF for manifest 9 (3 bytes)'), findsOneWidget);
    // the viewer sits below a 600 px test screen, under the manifest list
    await tester.scrollUntilVisible(find.text('PDF-VIEW-3'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('PDF-VIEW-3'), findsOneWidget);
  });

  testWidgets('every manifest is listed, newest first, with its documents', (tester) async {
    await tester.pumpWidget(_page(initialStateId: 225));

    await tester.tap(find.text('Fetch newest manifest PDF'));
    await tester.pumpAndSettle();

    expect(find.textContaining('3 manifest(s), newest first'), findsOneWidget);
    expect(find.text('Manifest 10 - 2026-06-02'), findsOneWidget);
    expect(find.text('Manifest 9 - 2026-05-20'), findsOneWidget);
    expect(find.text('Manifest 7 - 2026-05-01'), findsOneWidget);
    expect(find.textContaining('no PDF'), findsOneWidget); // only manifest 10 has none
    expect(tester.getTopLeft(find.text('Manifest 10 - 2026-06-02')).dy,
        lessThan(tester.getTopLeft(find.text('Manifest 7 - 2026-05-01')).dy));
  });

  testWidgets('tapping another manifest row fetches that manifest PDF instead', (tester) async {
    int? documentId;
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchDocument: (docId, {required accessToken}) async {
        documentId = docId;
        return Uint8List.fromList([9]);
      },
    ));

    await tester.tap(find.text('Fetch newest manifest PDF'));
    await tester.pumpAndSettle();
    expect(documentId, 200);

    await tester.ensureVisible(find.text('Manifest 7 - 2026-05-01'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manifest 7 - 2026-05-01'));
    await tester.pumpAndSettle();

    expect(documentId, 100);
    await tester.scrollUntilVisible(find.text('PDF for manifest 7 (1 bytes)'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('PDF for manifest 7 (1 bytes)'), findsOneWidget);
  });

  testWidgets('a non-numeric state id refuses rather than crashing', (tester) async {
    var fetched = false;
    await tester.pumpWidget(_page(fetchManifests: (stateId, {required accessToken}) async {
      fetched = true;
      return _manifests();
    }));

    await tester.tap(find.text('Fetch newest manifest PDF'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a numeric state id first.'), findsOneWidget);
    expect(fetched, isFalse);
  });

  testWidgets('a center with no manifest that carries a PDF says so, and fetches nothing', (tester) async {
    var fetched = false;
    await tester.pumpWidget(_page(
      initialStateId: 225,
      manifests: () => [
        {'id': 10, 'dateOfDeparture': '2026-06-02', 'documents': <Object?>[]},
      ],
      fetchDocument: (docId, {required accessToken}) async {
        fetched = true;
        return Uint8List.fromList([1]);
      },
    ));

    await tester.tap(find.text('Fetch newest manifest PDF'));
    await tester.pumpAndSettle();

    expect(find.text('None of these manifests carries a PDF document.'), findsOneWidget);
    expect(fetched, isFalse);
  });

  testWidgets('a fetch failure is shown, not swallowed', (tester) async {
    await tester.pumpWidget(_page(
      initialStateId: 225,
      fetchManifests: (stateId, {required accessToken}) async => throw Exception('state unreachable'),
    ));

    await tester.tap(find.text('Fetch newest manifest PDF'));
    await tester.pumpAndSettle();

    expect(find.textContaining('state unreachable'), findsOneWidget);
  });
}
