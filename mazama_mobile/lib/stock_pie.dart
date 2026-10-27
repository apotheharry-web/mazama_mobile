// SP-R12: a pie of the slices stock_summary.dart's pies() gives ({"name", "value", "slot", "pct"}), drawn with a
// CustomPainter (no chart package) the way the server's charts.pie_svg draws them: from the top, clockwise, one
// full circle when there is a single slice, coloured by slot exactly as the server's
// mazama_sales/src/mazama_sales/web/static/app.css .f-* classes.
//
// Slots: s1..s7 (a strain by rank), oth ("Other (n strains)"), and a strain's serving-size pie's d25..d5, db / dm
// (an edible's Booster / Microdose, specs/edibles), dx (other size) and c (one size only). The size slots are shades of their strain's colour, as app.css's
// `.strainrow` color-mix rules make them, so they need that strain's slot ([strainSlot]).
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Every slot stockSlotColor knows (the server's pies never use another).
const Set<String> stockSlots = {
  's1', 's2', 's3', 's4', 's5', 's6', 's7', 'oth', //
  'd25', 'd20', 'd15', 'd10', 'd5', 'db', 'dm', 'dx', 'c',
};

// app.css `.viz` (light) and its prefers-color-scheme: dark override, as 0xRRGGBB.
const Map<String, int> _light = {
  's1': 0x2a78d6, 's2': 0xeb6834, 's3': 0x1baf7a, 's4': 0xeda100, 's5': 0xe87ba4, 's6': 0x008300, 's7': 0x4a3aa7,
  'oth': 0x898781, 'dx': 0x898781,
};
const Map<String, int> _dark = {
  's1': 0x3987e5, 's2': 0xd95926, 's3': 0x199e70, 's4': 0xc98500, 's5': 0xd55181, 's6': 0x008300, 's7': 0x9085e9,
  'oth': 0x898781, 'dx': 0x898781,
};

// app.css `.strainrow`: each size as color-mix(in srgb, <strain colour>, <black or white> <p>%).
// (mix with white?, share of black/white). d15 is the strain colour itself.
const Map<String, (bool, double)> _lightSizes = {
  'd25': (false, 0.45), 'd20': (false, 0.22), 'd15': (false, 0.0), 'd10': (true, 0.32), 'd5': (true, 0.58),
  'db': (false, 0.32), 'dm': (true, 0.48),
};
const Map<String, (bool, double)> _darkSizes = {
  'd25': (true, 0.55), 'd20': (true, 0.30), 'd15': (false, 0.0), 'd10': (false, 0.25), 'd5': (false, 0.48),
  'db': (true, 0.40), 'dm': (false, 0.38),
};

int _mix(int rgb, bool white, double share) {
  final to = white ? 255 : 0;
  int ch(int shift) {
    final c = (rgb >> shift) & 0xff;
    return (c * (1 - share) + to * share).round();
  }

  return (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

/// The colour of a pie slot, as the server's web page draws it. Size slots (d25..d5, c) are shades of
/// [strainSlot]'s colour; an unknown slot is drawn in the "other" grey rather than failing.
Color stockSlotColor(String slot, {String strainSlot = 's1', Brightness brightness = Brightness.light}) {
  final palette = brightness == Brightness.dark ? _dark : _light;
  final other = palette['oth']!;
  int rgb;
  if (palette.containsKey(slot)) {
    rgb = palette[slot]!;
  } else {
    final base = palette[strainSlot] ?? other;
    if (slot == 'c') {
      rgb = base;
    } else {
      final shade = (brightness == Brightness.dark ? _darkSizes : _lightSizes)[slot];
      rgb = shade == null ? other : _mix(base, shade.$1, shade.$2);
    }
  }
  return Color(0xff000000 | rgb);
}

num _value(Map<String, Object?> s) => (s['value'] as num?) ?? 0;

/// Each slice's (start angle, sweep) in radians, from the top clockwise; slices of 0 or less get no angle.
List<(Map<String, Object?>, double, double)> _angles(List<Map<String, Object?>> slices) {
  num total = 0;
  for (final s in slices) {
    final v = _value(s);
    if (v > 0) total += v;
  }
  if (total <= 0) return const [];
  final out = <(Map<String, Object?>, double, double)>[];
  var a0 = -math.pi / 2;
  for (final s in slices) {
    final v = _value(s);
    if (v <= 0) continue;
    final sweep = 2 * math.pi * v / total;
    out.add((s, a0, sweep));
    a0 += sweep;
  }
  return out;
}

/// The radius the pie is drawn at in [size] (2 px inside the edge, as the server's SVG).
double _radius(Size size) => math.max(0.0, size.shortestSide / 2 - 2);

/// The name of the slice under [point] in a pie of [size], or null outside the pie.
String? stockPieSliceAt(List<Map<String, Object?>> slices, Size size, Offset point) {
  final d = point - size.center(Offset.zero);
  if (d.distance > _radius(size)) return null;
  final angles = _angles(slices);
  if (angles.isEmpty) return null;
  // The angle from the top, clockwise, in [0, 2pi).
  var a = math.atan2(d.dy, d.dx) + math.pi / 2;
  if (a < 0) a += 2 * math.pi;
  for (final (s, start, sweep) in angles) {
    final from = start + math.pi / 2;
    if (a >= from && a < from + sweep) return s['name'] as String?;
  }
  return angles.last.$1['name'] as String?; // a rounding hair short of 2pi
}

class StockPiePainter extends CustomPainter {
  StockPiePainter({required this.slices, this.strainSlot = 's1', this.brightness = Brightness.light});

  final List<Map<String, Object?>> slices;
  final String strainSlot;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final angles = _angles(slices);
    if (angles.isEmpty) return;
    final centre = size.center(Offset.zero);
    final r = _radius(size);
    Paint fill(Map<String, Object?> s) => Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true
      ..color = stockSlotColor((s['slot'] as String?) ?? 'oth', strainSlot: strainSlot, brightness: brightness);
    if (angles.length == 1) {
      canvas.drawCircle(centre, r, fill(angles.single.$1));
      return;
    }
    final rect = Rect.fromCircle(center: centre, radius: r);
    for (final (s, start, sweep) in angles) {
      canvas.drawArc(rect, start, sweep, true, fill(s));
    }
  }

  @override
  bool shouldRepaint(StockPiePainter old) =>
      old.slices != slices || old.strainSlot != strainSlot || old.brightness != brightness;
}

/// A pie of [slices] ({"name", "value", "slot", "pct"}) [size] pixels square; tapping a slice calls [onTapSlice]
/// with its name. [strainSlot] colours a serving-size pie in its strain's shades.
class StockPie extends StatelessWidget {
  const StockPie({super.key, required this.slices, this.size = 160, this.onTapSlice, this.strainSlot = 's1', this.label});

  final List<Map<String, Object?>> slices;
  final double size;
  final void Function(String name)? onTapSlice;
  final String strainSlot;

  /// What a screen reader says for the pie (the key beside it repeats the numbers).
  final String? label;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final pie = CustomPaint(
      size: Size.square(size),
      painter: StockPiePainter(slices: slices, strainSlot: strainSlot, brightness: brightness),
    );
    final tap = onTapSlice;
    final child = tap == null
        ? pie
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final name = stockPieSliceAt(slices, Size.square(size), d.localPosition);
              if (name != null) tap(name);
            },
            child: pie,
          );
    return Semantics(label: label, image: true, child: SizedBox.square(dimension: size, child: child));
  }
}
