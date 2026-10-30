// The one age line a page shows for what it shows (specs/phone-sync PS-R7, PS-D5): "Updated just now", "Updated 2 min
// ago", "Updated 8:05" (today), "Updated Oct 28, 14:05" (before), from the datasets' fetched_at_ms, the oldest of them
// when a page shows several. It is shown whether or not the server can be reached: it is not an outage notice (the
// app-wide banner is the only one, README R87). A time in the future (the phone's clock moved back) reads as just now,
// never as a negative age.
import 'package:flutter/material.dart';

import 'sync_tables.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// The age line for data read at [fetchedAt], seen at [now], in the phone's own time.
String updatedLine(DateTime fetchedAt, DateTime now) {
  final at = fetchedAt.toLocal(), here = now.toLocal();
  final age = here.difference(at);
  if (age < const Duration(minutes: 1)) return 'Updated just now'; // a future time included
  if (age < const Duration(hours: 1)) return 'Updated ${age.inMinutes} min ago';
  final time = '${at.hour}:${at.minute.toString().padLeft(2, '0')}';
  if (at.year == here.year && at.month == here.month && at.day == here.day) return 'Updated $time';
  return 'Updated ${_months[at.month - 1]} ${at.day}, $time';
}

/// [at] in the phone's own time, as the banner writes it (server_link.dart): "Oct 21, 2026 at 6:05 AM". (Moved here
/// from server_offline.dart, specs/phone-sync Task 10.)
String formatAsOf(DateTime at) {
  final t = at.toLocal();
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  return '${_months[t.month - 1]} ${t.day}, ${t.year} at $hour:$minute ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Finds the line in tests.
const updatedLineKey = ValueKey('updated-line');

/// One small line with the age of the oldest of [rows]; nothing while none is stored.
class UpdatedLine extends StatelessWidget {
  const UpdatedLine({super.key, required this.rows, this.now}) : at = null;

  /// The line for data read at [at] (nothing while it is null), for a page that keeps its own read time.
  const UpdatedLine.at(this.at, {super.key, this.now}) : rows = const [];

  final List<DatasetRow?> rows;

  /// A read time of the page's own, counted with [rows].
  final DateTime? at;

  /// The clock; overridable for tests.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    DateTime? oldest = at;
    for (final r in rows) {
      if (r == null) continue;
      if (oldest == null || r.fetchedAt.isBefore(oldest)) oldest = r.fetchedAt;
    }
    if (oldest == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        updatedLine(oldest, (now ?? DateTime.now)()),
        key: updatedLineKey,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
