// SP-R12: the stock page's pies (lib/stock_pie.dart) draw the slices stock_summary.dart's pies() gives, in the
// server's colours (mazama_sales/src/mazama_sales/web/static/app.css .f-* classes), and report taps by name.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/stock_pie.dart';

/// Records the drawing calls a painter makes; everything else is ignored.
class _RecordingCanvas implements Canvas {
  final arcs = <({double start, double sweep, Color color})>[];
  final circles = <({Offset center, double radius, Color color})>[];

  @override
  void drawArc(Rect rect, double startAngle, double sweepAngle, bool useCenter, Paint paint) {
    if (paint.style == PaintingStyle.fill) arcs.add((start: startAngle, sweep: sweepAngle, color: paint.color));
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    if (paint.style == PaintingStyle.fill) circles.add((center: c, radius: radius, color: paint.color));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Map<String, Object?> _slice(String name, num value, String slot) => {'name': name, 'value': value, 'slot': slot, 'pct': 0};

/// Every slot the server's pies use, from the vendored golden vectors (strain pies, strain rows, size pies).
Set<String> _vectorSlots() {
  final slots = <String>{};
  void slices(Object? pie) {
    if (pie is! Map) return;
    for (final s in pie['slices'] as List) {
      slots.add((s as Map)['slot'] as String);
    }
  }

  final cases = jsonDecode(File('assets/shared/stock/vectors/pies.json').readAsStringSync()) as List;
  for (final c in cases) {
    final p = (c as Map)['pies'] as Map;
    slices(p['units']);
    slices(p['mg']);
    for (final r in p['rows'] as List) {
      slots.add((r as Map)['slot'] as String);
      for (final sp in r['size_pies'] as List) {
        slices(sp);
      }
    }
  }
  return slots;
}

void main() {
  test('draws one arc per slice', () {
    final canvas = _RecordingCanvas();
    StockPiePainter(slices: [_slice('A', 3, 's1'), _slice('B', 1, 's2')]).paint(canvas, const Size(100, 100));
    expect(canvas.circles, isEmpty);
    expect(canvas.arcs, hasLength(2));
    // From the top, clockwise, as the server's SVG: A takes three quarters, B the last quarter.
    expect(canvas.arcs[0].start, closeTo(-math.pi / 2, 1e-9));
    expect(canvas.arcs[0].sweep, closeTo(1.5 * math.pi, 1e-9));
    expect(canvas.arcs[1].start, closeTo(math.pi, 1e-9));
    expect(canvas.arcs[1].sweep, closeTo(0.5 * math.pi, 1e-9));
    expect(canvas.arcs[0].color.toARGB32(), stockSlotColor('s1').toARGB32()); // Paint stores 32-bit colour: compare as ARGB
    expect(canvas.arcs[1].color.toARGB32(), stockSlotColor('s2').toARGB32()); // Paint stores 32-bit colour: compare as ARGB
  });

  test('a slice of 0 draws nothing and an empty pie draws nothing', () {
    final canvas = _RecordingCanvas();
    StockPiePainter(slices: [_slice('A', 2, 's1'), _slice('B', 0, 's2'), _slice('C', 2, 's3')])
        .paint(canvas, const Size(100, 100));
    expect(canvas.arcs, hasLength(2));
    final empty = _RecordingCanvas();
    StockPiePainter(slices: const []).paint(empty, const Size(100, 100));
    expect(empty.arcs, isEmpty);
    expect(empty.circles, isEmpty);
  });

  test('a single slice draws a full circle', () {
    final canvas = _RecordingCanvas();
    StockPiePainter(slices: [_slice('Only', 5, 'c')], strainSlot: 's3').paint(canvas, const Size(100, 100));
    expect(canvas.arcs, isEmpty);
    expect(canvas.circles, hasLength(1));
    expect(canvas.circles.single.center, const Offset(50, 50));
    expect(canvas.circles.single.radius, closeTo(48, 1e-9));
    // "c" is the strain's own colour (one serving size only).
    expect(canvas.circles.single.color.toARGB32(), stockSlotColor('s3').toARGB32()); // Paint stores 32-bit colour: compare as ARGB
  });

  testWidgets('tapping a slice reports its name', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: StockPie(
            slices: [_slice('Right half', 1, 's1'), _slice('Left half', 1, 's2')],
            size: 200,
            onTapSlice: tapped.add,
          ),
        ),
      ),
    ));
    final centre = tester.getCenter(find.byType(StockPie));
    await tester.tapAt(centre + const Offset(50, 0));
    await tester.tapAt(centre + const Offset(-50, 10));
    await tester.tapAt(centre + const Offset(0, -99.5)); // outside the drawn radius (98): nothing
    expect(tapped, ['Right half', 'Left half']);
  });

  test('the slice under a point', () {
    final slices = [_slice('A', 1, 's1'), _slice('B', 1, 's2'), _slice('C', 2, 's3')];
    const size = Size(100, 100);
    // A: top to 3 o'clock, B: 3 to 6 o'clock, C: the left half.
    expect(stockPieSliceAt(slices, size, const Offset(70, 30)), 'A');
    expect(stockPieSliceAt(slices, size, const Offset(70, 70)), 'B');
    expect(stockPieSliceAt(slices, size, const Offset(20, 50)), 'C');
    expect(stockPieSliceAt(slices, size, const Offset(1, 1)), isNull);
    expect(stockPieSliceAt([_slice('Only', 3, 'c')], size, const Offset(40, 60)), 'Only');
  });

  test('every server slot has a colour', () {
    final slots = _vectorSlots();
    expect(slots, containsAll(['s1', 'oth', 'c']), reason: 'the vectors cover strain, other and one-size slots');
    for (final slot in slots) {
      expect(stockSlots, contains(slot), reason: 'no colour for slot "$slot"');
    }
    expect(stockSlots, containsAll(['s1', 's2', 's3', 's4', 's5', 's6', 's7', 'oth', 'd25', 'd20', 'd15', 'd10', 'd5', 'db', 'dm', 'dx', 'c']));
    expect(slots, containsAll(['db', 'dm']), reason: 'the vectors cover the edible classes (specs/edibles)');
    final strainColours = {for (var i = 1; i <= 7; i++) stockSlotColor('s$i')};
    expect(strainColours, hasLength(7), reason: 'seven distinct strain colours');
  });

  test('colours are app.css\'s', () {
    // .viz light palette.
    expect(stockSlotColor('s1'), const Color(0xFF2A78D6));
    expect(stockSlotColor('s7'), const Color(0xFF4A3AA7));
    expect(stockSlotColor('oth'), const Color(0xFF898781));
    expect(stockSlotColor('dx'), const Color(0xFF898781));
    // Dark palette.
    expect(stockSlotColor('s1', brightness: Brightness.dark), const Color(0xFF3987E5));
    expect(stockSlotColor('oth', brightness: Brightness.dark), const Color(0xFF898781));
    // Sizes are shades of the strain's colour (.strainrow: color-mix in srgb): d15 is the colour itself,
    // d25 = 55% colour + 45% black, d5 = 42% colour + 58% white.
    expect(stockSlotColor('d15', strainSlot: 's2'), const Color(0xFFEB6834));
    expect(stockSlotColor('c', strainSlot: 's2'), const Color(0xFFEB6834));
    // #2a78d6 x 0.55 = (23.1, 66, 117.7) -> (23, 66, 118).
    expect(stockSlotColor('d25', strainSlot: 's1'), const Color(0xFF174276));
    // #2a78d6 x 0.42 + 255 x 0.58 = (165.54, 198.3, 238.02) -> (166, 198, 238).
    expect(stockSlotColor('d5', strainSlot: 's1'), const Color(0xFFA6C6EE));
    // Dark: d25 = 45% colour + 55% white. #3987e5 -> (166.1, 200.9, 243.3) -> (166, 201, 243).
    expect(stockSlotColor('d25', strainSlot: 's1', brightness: Brightness.dark), const Color(0xFFA6C9F3));
    // specs/edibles: Booster = 68% colour + 32% black, Microdose = 52% colour + 48% white (.strainrow --db / --dm).
    // #2a78d6 x 0.68 = (28.56, 81.6, 145.52) -> (29, 82, 146).
    expect(stockSlotColor('db', strainSlot: 's1'), const Color(0xFF1D5292));
    // #2a78d6 x 0.52 + 255 x 0.48 = (144.24, 184.8, 233.68) -> (144, 185, 234).
    expect(stockSlotColor('dm', strainSlot: 's1'), const Color(0xFF90B9EA));
    // An unknown slot falls back to the "other" grey rather than failing to draw.
    expect(stockSlotColor('zz'), const Color(0xFF898781));
  });
}
