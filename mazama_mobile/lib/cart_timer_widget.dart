// The home-screen widget's half on the Dart side (specs/multi-cart MC-D15): the carts' running session timers, as one
// small JSON snapshot handed to the native widget over a plain MethodChannel - Android's CartTimersWidget.kt, iOS's
// CartTimers widget extension. Same reasoning as text_scanner.dart for a hand-written channel rather than a pub.dev
// plugin: nothing new to fetch from the registry, and each side is a few dozen lines.
//
// A home-screen widget can't run Dart, so the snapshot holds moments, not durations: each running timer's start and,
// when its dose gives a session length, when that session ends. The widget counts from those with the platform's own
// live timer text (Android Chronometer, SwiftUI Text(_, style: .timer)), so it keeps ticking while the app is closed
// and is only re-sent when a timer, a cart's lines or the list of carts changes (CartPage._publishTimerWidget).
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cart_page.dart' show sessionTimerMaxAge;
import 'cart_pricing.dart' show minSessionDuration;

/// The snapshot's format. The native readers ignore a snapshot whose version they don't know.
const cartTimerSnapshotVersion = 1;

/// One cart as the widget is told about it: [start] null when its timer isn't running; [dose] what its session is
/// timed against (its lines, or what it last sold - CartPage._cartSummaries, MC-D14), null when there's none.
typedef CartTimerSource = ({String id, String name, DateTime? start, ({double psilocybinMg, bool booster})? dose});

/// What the widget shows for [center] at [now]: every cart in [carts] whose timer is running, in that order. A timer
/// past sessionTimerMaxAge is left out, as the carts list leaves it out. `endMs` is there only when the session table
/// gives the dose a length (the "w/ booster" figure, every dose counted, as sessionTimeLeftText), so the widget counts
/// down to it and then shows how long it's over; without it the widget counts up, as the carts list's "elapsed".
/// `maxAgeMs` lets the native side drop a timer once it ages out with the app closed.
Map<String, Object?> cartTimerSnapshot({
  required String center,
  required List<CartTimerSource> carts,
  required DateTime now,
}) {
  final out = <Map<String, Object?>>[];
  for (final c in carts) {
    final start = c.start;
    if (start == null || now.difference(start) >= sessionTimerMaxAge) continue;
    final dose = c.dose;
    final length = dose == null ? null : minSessionDuration(dose.psilocybinMg);
    out.add({
      'id': c.id,
      'name': c.name,
      'startMs': start.millisecondsSinceEpoch,
      if (length != null) 'endMs': start.add(length).millisecondsSinceEpoch,
      'booster': length != null && dose!.booster,
    });
  }
  return {
    'version': cartTimerSnapshotVersion,
    'center': center,
    'maxAgeMs': sessionTimerMaxAge.inMilliseconds,
    'writtenMs': now.millisecondsSinceEpoch,
    'carts': out,
  };
}

/// Sends snapshots to the native widget. Never throws: the widget is a convenience, and a phone (or a test) with no
/// native side to answer just has no widget to update.
class CartTimerWidget {
  /// Overridable for tests, as scanLabelText's channel.
  final MethodChannel channel;

  const CartTimerWidget({this.channel = const MethodChannel('mazama/cart_timer_widget')});

  /// Replaces what the widget shows with [snapshot] (cartTimerSnapshot).
  Future<void> publish(Map<String, Object?> snapshot) => _call('update', jsonEncode(snapshot));

  /// Empties the widget: the worker signed out.
  Future<void> clear() => _call('clear', null);

  Future<void> _call(String method, Object? arg) async {
    try {
      await channel.invokeMethod<void>(method, arg);
    } on MissingPluginException {
      // No native widget here (a widget test, or a platform the widget isn't built for).
    } on PlatformException catch (e) {
      debugPrint('could not update the cart timers widget (nothing the worker is doing is affected): $e');
    }
  }
}
