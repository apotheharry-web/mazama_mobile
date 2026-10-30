// A state-site date as ISO, for the sales history the phone reads from the state (sales_page.dart's recent sales,
// sales_upload_client.dart's newest-first cut). Moved unchanged out of select_documents.dart when document choice
// went to the core (specs/core row 2, Task 8); the sale-date rules move to the core with specs/core row 7.

final _headEnd = RegExp(r'[ T]');
final _mdy = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$');
final _iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// A state-site date as ISO: MM/DD/YYYY (one-digit month or day allowed; anything after a space ignored) or ISO
/// YYYY-MM-DD (a time after it ignored). An impossible date (13/45/2026, 02/30/2026) is null, never rolled over.
String? stateDateIso(String? s) {
  if (s == null) return null;
  final head = s.trim().split(_headEnd).first;
  int y, m, d;
  final a = _mdy.firstMatch(head), b = _iso.firstMatch(head);
  if (a != null) {
    (m, d, y) = (int.parse(a.group(1)!), int.parse(a.group(2)!), int.parse(a.group(3)!));
  } else if (b != null) {
    (y, m, d) = (int.parse(b.group(1)!), int.parse(b.group(2)!), int.parse(b.group(3)!));
  } else {
    return null;
  }
  if (m < 1 || m > 12 || d < 1) return null;
  final day = DateTime.utc(y, m, d);
  if (day.year != y || day.month != m || day.day != d) return null; // DateTime rolls 02/30 over to March
  return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
}
