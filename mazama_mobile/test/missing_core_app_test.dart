// CR-R3, CR-D2: an app that can't load the shared core shows one full-screen error, never a white screen, a crash or
// an app with parts missing (missing_core_app.dart, run by main()).
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/main.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/missing_core_app.dart';
import 'package:mazama_mobile/select_center_page.dart';

import 'support/core.dart';

void main() {
  testWidgets('test_app_without_the_core_shows_the_missing_part_screen', (tester) async {
    final w = startWidgetFor(loadCore: () => throw const MazamaCoreError('x'));
    expect(w, isA<MissingCoreApp>());
    await tester.pumpWidget(w);
    expect(find.text('This build is missing a part. Reinstall the app.'), findsOneWidget);
    expect(find.text('x'), findsOneWidget); // the error itself, in a debug build (tests run as one)
    expect(find.byType(SelectCenterPage), findsNothing);
    expect(find.byType(MazamaApp), findsNothing);
  });

  testWidgets('a loader that fails some other way shows the same screen', (tester) async {
    final w = startWidgetFor(loadCore: () => throw ArgumentError('no such symbol'));
    await tester.pumpWidget(w);
    expect(find.text(missingCoreMessage), findsOneWidget);
  });

  test('with the core, the app itself starts', () {
    final core = loadTestCore();
    expect(startWidgetFor(loadCore: () => core), isA<MazamaApp>());
  });

  test('a real load of a file that is not the library gives the missing-part screen', () {
    expect(startWidgetFor(loadCore: () => MazamaCore.load(path: 'pubspec.yaml')), isA<MissingCoreApp>());
  });
}
