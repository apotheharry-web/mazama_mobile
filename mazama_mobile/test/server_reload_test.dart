// lib/server_reload.dart: a page that shows a kept copy reloads once the server answers again (and only then), Retry
// asks the server first when it is counted unreachable and reloads once, and the failed-load message offers Retry or
// the page's own action. The pages' own tests (center_stock_page, mazama_inventory_page, order_par_page) hold it there.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/server_health.dart';
import 'package:mazama_mobile/server_reload.dart';

import 'fake_timers.dart';

class _Page extends StatefulWidget {
  const _Page({required this.health, required this.kept, required this.reloads});

  final ServerHealth? health;
  final bool kept;
  final List<bool> reloads;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> with ServerReload<_Page> {
  @override
  ServerHealth? get serverHealth => widget.health;

  @override
  bool get showingKeptCopy => widget.kept;

  @override
  void reload({required bool cameBack}) => widget.reloads.add(cameBack);

  @override
  void initState() {
    super.initState();
    listenForServer();
  }

  @override
  void dispose() {
    stopListeningForServer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LoadFailed(message: 'Nothing loaded', onRetry: retry);
}

void main() {
  testWidgets('the server answering again reloads a page showing a kept copy, once', (tester) async {
    final health = ServerHealth(probe: () async => true, startTimer: FakeTimers().start);
    final reloads = <bool>[];
    health.markUnreachable();
    await tester.pumpWidget(MaterialApp(home: _Page(health: health, kept: true, reloads: reloads)));
    health.markReachable();
    health.markReachable(); // no news: still online
    expect(reloads, [true]);
  });

  testWidgets('a page showing fresh figures is not reloaded', (tester) async {
    final health = ServerHealth(probe: () async => true, startTimer: FakeTimers().start);
    final reloads = <bool>[];
    health.markUnreachable();
    await tester.pumpWidget(MaterialApp(home: _Page(health: health, kept: false, reloads: reloads)));
    health.markReachable();
    expect(reloads, isEmpty);
  });

  testWidgets('Retry asks the server first when it is counted unreachable, and reloads once', (tester) async {
    var probes = 0;
    final health = ServerHealth(probe: () async => ++probes > 0, startTimer: FakeTimers().start);
    final reloads = <bool>[];
    health.markUnreachable();
    await tester.pumpWidget(MaterialApp(home: _Page(health: health, kept: true, reloads: reloads)));
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(probes, 1);
    expect(health.online, isTrue);
    expect(reloads, [false]); // Retry's own reload, not a second one for the server coming back
  });

  testWidgets('without a tracker Retry just reloads; the message shows the action given instead of Retry',
      (tester) async {
    final reloads = <bool>[];
    await tester.pumpWidget(MaterialApp(home: _Page(health: null, kept: true, reloads: reloads)));
    expect(find.text('Nothing loaded'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    expect(reloads, [false]);
    await tester.pumpWidget(MaterialApp(
        home: LoadFailed(message: 'x', onRetry: () {}, action: const TextButton(onPressed: null, child: Text('Sign in again')))));
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Sign in again'), findsOneWidget);
  });

  testWidgets('a notice shows its text', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PageNotice('Kept on this phone'))));
    expect(find.text('Kept on this phone'), findsOneWidget);
  });
}
