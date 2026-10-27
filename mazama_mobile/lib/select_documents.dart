// Which lab-report documents to read for a lot (SM-06; COA-R1, COA-D9, COA-D12), from a GetPackagedProductInfo
// reply: every non-deprecated .pdf document of an accepted Potency test, not already fetched, newest test first
// (undated last; equal dates keep the reply's order), each document once, at its newest test's date. The same rule
// as coa_core::select (the server's), held to the same cases (assets/shared/coa/corpus/select/cases.json). Native
// Dart rather than FFI, because resolving a lot's lab data must work without the library (it isn't built for iOS).
import 'api_contract.g.dart';

/// SM-D23: the one size cap for a lab-report PDF, on both sides (the server's /p/coa-data/parse limit, routes.yaml).
const labReportMaxBytes = coaDataParseMaxPdfBytes;

class SelectedDocument {
  final int docId;

  /// ISO date ("2026-03-04") of the test the document belongs to; null when the state gave no readable date.
  final String? date;
  const SelectedDocument(this.docId, this.date);
}

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

/// The documents to read, in order.
List<SelectedDocument> selectPotencyDocuments(Object? info, {Set<int> alreadyHave = const {}}) {
  if (info is! Map) return const [];
  final results = info['testResults'];
  if (results is! List) return const [];
  final found = <(int, SelectedDocument)>[]; // (reply order, document)
  for (final t in results) {
    if (t is! Map || t['test'] != 'Potency' || t['status'] != 'Accepted') continue;
    final completed = t['dateCompleted'];
    final date = completed is String ? stateDateIso(completed) : null;
    final manifest = t['testingManifest'];
    final docs = manifest is Map ? manifest['documents'] : null;
    if (docs is! List) continue;
    for (final d in docs) {
      if (d is! Map) continue;
      final id = d['id'];
      final ext = d['extension'];
      if (id is! int || ext is! String || ext.toLowerCase() != '.pdf') continue;
      if (d['deprecated'] == true || alreadyHave.contains(id)) continue;
      found.add((found.length, SelectedDocument(id, date)));
    }
  }
  // newest first, undated last, equal dates in the reply's order (the index makes the sort stable)
  found.sort((a, b) {
    final (ai, ad) = a;
    final (bi, bd) = b;
    if (ad.date != bd.date) {
      if (ad.date == null) return 1;
      if (bd.date == null) return -1;
      return bd.date!.compareTo(ad.date!); // ISO dates compare as text
    }
    return ai.compareTo(bi);
  });
  final out = <SelectedDocument>[];
  for (final (_, d) in found) {
    if (!out.any((o) => o.docId == d.docId)) out.add(d);
  }
  return out;
}
