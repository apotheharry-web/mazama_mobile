import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/debug_tools_page.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/session_store.dart';
import 'temp_app_data_dir.dart';

Session _session() => Session(
    accessToken: 'TOKEN', refreshToken: 'REFRESH', email: 'worker@example.com', expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000);

final _dummySpec = FlowSpec(const {}, const {});

void main() {
  useTempAppDataDir();
  testWidgets('lists every debug tool, and tapping one opens its own page', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DebugToolsPage(
        session: _session(),
        spec: _dummySpec,
        sessionStore: SessionStore(dataDir: () => Directory.systemTemp.createTempSync()),
        initialStateId: 225,
      ),
    ));

    expect(find.text('Launch cart by state id'), findsOneWidget);
    expect(find.text('Background features'), findsOneWidget);
    expect(find.text('State data browser'), findsOneWidget);
    expect(find.text('Local storage'), findsOneWidget);
    expect(find.text('Adhoc-COA diagnostics'), findsOneWidget);
    expect(find.text('COA → label (on phone)'), findsOneWidget);
    expect(find.text('Server link'), findsOneWidget);
    // listed right after the Adhoc-COA diagnostics it complements
    expect(tester.getTopLeft(find.text('COA → label (on phone)')).dy,
        greaterThan(tester.getTopLeft(find.text('Adhoc-COA diagnostics')).dy));

    await tester.tap(find.text('Background features'));
    await tester.pumpAndSettle();
    expect(find.text('Background features (debug)'), findsOneWidget);
  });

  testWidgets('the COA → label entry opens that page with the selected center filled in', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DebugToolsPage(
        session: _session(),
        spec: _dummySpec,
        sessionStore: SessionStore(dataDir: () => Directory.systemTemp.createTempSync()),
        initialStateId: 229,
      ),
    ));
    // The page is a scrolling list; with the server link entry added, this one sits below a 600 px test screen.
    await tester.ensureVisible(find.text('COA → label (on phone)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('COA → label (on phone)'));
    await tester.pumpAndSettle();
    expect(find.text('COA → label (debug)'), findsOneWidget);
    expect(find.text('229'), findsOneWidget);
  });

  testWidgets('lists the Sign-in files page last, and tapping it opens that page', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DebugToolsPage(
        session: _session(),
        spec: _dummySpec,
        sessionStore: SessionStore(dataDir: () => Directory.systemTemp.createTempSync()),
        initialStateId: 225,
      ),
    ));
    // the list is lazy: scroll until the last entry is built and on screen
    await tester.scrollUntilVisible(find.text('Sign-in files'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign-in files'));
    await tester.pumpAndSettle();
    expect(find.text('Sign-in files (debug)'), findsOneWidget);
  });
}
