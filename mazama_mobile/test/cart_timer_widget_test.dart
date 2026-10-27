import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/cart_page.dart' show sessionTimerMaxAge;
import 'package:mazama_mobile/cart_timer_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 10, 22, 14, 0);
  final ms = now.millisecondsSinceEpoch;

  group('cartTimerSnapshot', () {
    test('lists only carts whose timer is running, in the carts list order', () {
      final snap = cartTimerSnapshot(center: 'Mazama Eugene', now: now, carts: [
        (id: 'main', name: 'Cart 1', start: now.subtract(const Duration(minutes: 5)), dose: null),
        (id: 'cb', name: 'Cart 2', start: null, dose: (psilocybinMg: 20.0, booster: false)),
        (id: 'cc', name: 'Rosa', start: now.subtract(const Duration(minutes: 1)), dose: null),
      ]);
      expect(snap['version'], 1);
      expect(snap['center'], 'Mazama Eugene');
      expect(snap['maxAgeMs'], sessionTimerMaxAge.inMilliseconds);
      final carts = snap['carts'] as List;
      expect([for (final c in carts) (c as Map)['name']], ['Cart 1', 'Rosa']);
    });

    test('a timer with a dose ends at the session length for that dose (MC-D14)', () {
      final start = now.subtract(const Duration(minutes: 10));
      final snap = cartTimerSnapshot(center: 'C', now: now, carts: [
        // 20 mg: 4 hours (sessionTable); booster carried through for the "w/ booster" label.
        (id: 'main', name: 'Cart 1', start: start, dose: (psilocybinMg: 20.0, booster: true)),
      ]);
      expect((snap['carts'] as List).single, {
        'id': 'main',
        'name': 'Cart 1',
        'startMs': start.millisecondsSinceEpoch,
        'endMs': start.add(const Duration(hours: 4)).millisecondsSinceEpoch,
        'booster': true,
      });
    });

    test('no dose, or a dose the table has no length for, counts up (no endMs)', () {
      final start = now.subtract(const Duration(minutes: 3));
      final snap = cartTimerSnapshot(center: 'C', now: now, carts: [
        (id: 'main', name: 'A', start: start, dose: null),
        (id: 'cb', name: 'B', start: start, dose: (psilocybinMg: 80.0, booster: false)), // over the 50 mg table
      ]);
      for (final c in snap['carts'] as List) {
        expect((c as Map).containsKey('endMs'), isFalse, reason: '${c['name']}');
        expect(c['booster'], isFalse);
      }
    });

    test('a timer past sessionTimerMaxAge is left out, as the carts list treats it as not running', () {
      final snap = cartTimerSnapshot(center: 'C', now: now, carts: [
        (id: 'main', name: 'Old', start: now.subtract(sessionTimerMaxAge), dose: null),
        (id: 'cb', name: 'Fresh', start: now.subtract(sessionTimerMaxAge - const Duration(seconds: 1)), dose: null),
      ]);
      expect([for (final c in snap['carts'] as List) (c as Map)['name']], ['Fresh']);
    });

    test('writtenMs records when the snapshot was made', () {
      final snap = cartTimerSnapshot(center: 'C', now: now, carts: const []);
      expect(snap['writtenMs'], ms);
      expect(snap['carts'], isEmpty);
    });
  });

  group('CartTimerWidget', () {
    test('publish sends the snapshot as JSON on "update"', () async {
      final channel = MethodChannel('mazama/cart_timer_widget_test_1');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final snap = cartTimerSnapshot(center: 'C', now: now, carts: [
        (id: 'main', name: 'Cart 1', start: now, dose: null),
      ]);
      await CartTimerWidget(channel: channel).publish(snap);
      expect(calls.single.method, 'update');
      expect(jsonDecode(calls.single.arguments as String), jsonDecode(jsonEncode(snap)));
    });

    test('clear sends "clear"', () async {
      final channel = MethodChannel('mazama/cart_timer_widget_test_2');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      await CartTimerWidget(channel: channel).clear();
      expect(calls, ['clear']);
    });

    test('no native side (tests, a platform without the widget) and native errors are swallowed', () async {
      // No handler at all: MissingPluginException.
      await CartTimerWidget(channel: const MethodChannel('mazama/cart_timer_widget_test_3')).publish(const {});
      final failing = MethodChannel('mazama/cart_timer_widget_test_4');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(failing, (call) async => throw PlatformException(code: 'NO_GROUP'));
      await CartTimerWidget(channel: failing).publish(const {});
      await CartTimerWidget(channel: failing).clear();
    });
  });
}
