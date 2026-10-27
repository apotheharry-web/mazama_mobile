// The swipeable pie spot (lib/swipe_pies.dart) inside a page view, as on the center home. Seen on a phone: swiping
// on the pies moved the whole screen to the next page instead of changing the pie. A finger moves a few pixels at a
// time, and the page view (with the device's own, smaller touch slop on Android) claimed the drag first; a test's
// single big drag hid it. These drags move a few pixels per frame, with an Android-like touch slop and the default.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/swipe_pies.dart';

class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int pie = 0;
  final pages = PageController(initialPage: 1);

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageView(
        controller: pages,
        children: [
          const Center(child: Text('left page')),
          ListView(
            children: [
              const Text('middle page'),
              SwipePies(
                key: const ValueKey('pies'),
                index: pie,
                onIndex: (i) => setState(() => pie = i),
                dots: const [(key: ValueKey('dot-a'), label: 'A'), (key: ValueKey('dot-b'), label: 'B')],
                build: (i) => SizedBox(height: 240, child: Center(child: Text(i == 0 ? 'card A' : 'card B'))),
              ),
              for (var i = 0; i < 30; i++) Text('row $i'),
            ],
          ),
          const Center(child: Text('right page')),
        ],
      );
}

Widget _app(double? touchSlop) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(gestureSettings: DeviceGestureSettings(touchSlop: touchSlop)),
          child: const Scaffold(body: _Host()),
        ),
      ),
    );

/// A finger's drag: [by] in steps of 3 pixels, a frame apart, each event timed as a finger's would be.
Future<void> _drag(WidgetTester tester, Offset by) async {
  final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('pies'))));
  final steps = (by.distance / 3).ceil();
  for (var i = 1; i <= steps; i++) {
    await g.moveBy(by / steps.toDouble(), timeStamp: Duration(milliseconds: 16 * i));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up(timeStamp: Duration(milliseconds: 16 * (steps + 1)));
  await tester.pumpAndSettle();
}

void main() {
  for (final slop in <double?>[8, null]) {
    final label = slop == null ? 'default touch slop' : 'touch slop $slop (Android-like)';

    testWidgets('$label: a finger swipe on the pies changes the pie, not the page', (tester) async {
      await tester.pumpWidget(_app(slop));
      expect(find.text('card A'), findsOneWidget);

      await _drag(tester, const Offset(-200, 0));
      expect(find.text('card B'), findsOneWidget);
      expect(find.text('middle page'), findsOneWidget);

      await _drag(tester, const Offset(200, 0));
      expect(find.text('card A'), findsOneWidget);
      expect(find.text('middle page'), findsOneWidget);
    });

    testWidgets('$label: past either end the swipe moves the page', (tester) async {
      await tester.pumpWidget(_app(slop));
      await _drag(tester, const Offset(500, 0)); // already on the first card: the page view takes it (past halfway)
      expect(find.text('left page'), findsOneWidget);
    });

    testWidgets('$label: from the last card a swipe on towards the next page moves the page', (tester) async {
      await tester.pumpWidget(_app(slop));
      await _drag(tester, const Offset(-200, 0));
      expect(find.text('card B'), findsOneWidget);
      await _drag(tester, const Offset(-500, 0));
      expect(find.text('right page'), findsOneWidget);
    });

    testWidgets('$label: a mostly vertical drag scrolls, and leaves the pie alone', (tester) async {
      await tester.pumpWidget(_app(slop));
      final before = tester.getTopLeft(find.text('row 5')).dy;
      await _drag(tester, const Offset(-12, -150));
      expect(find.text('card A'), findsOneWidget);
      expect(find.text('row 5'), findsOneWidget); // still the middle page
      expect(tester.getTopLeft(find.text('row 5')).dy, lessThan(before));
    });
  }
}
