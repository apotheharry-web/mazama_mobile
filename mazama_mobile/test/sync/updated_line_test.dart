// sync/updated_line.dart: the one age line a page shows for what it shows (specs/phone-sync PS-R7, PS-D5): "Updated just
// now" under a minute (and for any time in the future: a clock moved back), "Updated N min ago" under an hour, the time
// today, the date and time before that. The widget shows the oldest of its rows, and nothing while none is stored.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/sync/sync_tables.dart';
import 'package:mazama_mobile/sync/updated_line.dart';

DatasetRow _row(DateTime at) =>
    DatasetRow(name: 'par', key: '231', body: '[]', source: 'server', fetchedAt: at.toUtc());

void main() {
  // the phone's own time zone: these are local times, as the line shows them
  final now = DateTime(2026, 10, 30, 14, 30);

  test('the wording', () {
    expect(updatedLine(now, now), 'Updated just now');
    expect(updatedLine(now.subtract(const Duration(seconds: 59)), now), 'Updated just now');
    expect(updatedLine(now.subtract(const Duration(minutes: 1)), now), 'Updated 1 min ago');
    expect(updatedLine(now.subtract(const Duration(minutes: 59)), now), 'Updated 59 min ago');
    expect(updatedLine(DateTime(2026, 10, 30, 8, 5), now), 'Updated 8:05');
    expect(updatedLine(DateTime(2026, 10, 29, 14, 5), now), 'Updated Oct 29, 14:05');
    expect(updatedLine(DateTime(2025, 12, 31, 23, 59), now), 'Updated Dec 31, 23:59');
  });

  test('a time in the future reads as just now', () {
    expect(updatedLine(now.add(const Duration(minutes: 3)), now), 'Updated just now');
    expect(updatedLine(now.add(const Duration(days: 2)), now), 'Updated just now');
  });

  test('the same instant in UTC reads the same', () {
    expect(updatedLine(DateTime(2026, 10, 30, 8, 5).toUtc(), now), 'Updated 8:05');
  });

  testWidgets('the widget shows the oldest of its rows', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UpdatedLine(
          rows: [_row(now.subtract(const Duration(minutes: 2))), null, _row(now.subtract(const Duration(minutes: 7)))],
          now: () => now,
        ),
      ),
    ));
    expect(find.text('Updated 7 min ago'), findsOneWidget);
    expect(find.byKey(updatedLineKey), findsOneWidget);
  });

  testWidgets('nothing while no row is stored', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: UpdatedLine(rows: const [null, null], now: () => now))));
    expect(find.byKey(updatedLineKey), findsNothing);
    expect(find.textContaining('Updated'), findsNothing);
  });
}
