// Which lab-report documents to read for a lot (SM-06; COA-R1, COA-D9, COA-D12), from a GetPackagedProductInfo
// reply: every non-deprecated .pdf document of an accepted Potency test, not already fetched, newest test first
// (undated last; equal dates keep the reply's order), each document once, at its newest test's date. The rule is
// mazama_core::coa::select (coa.select_documents), the one the server runs, held to the shared cases
// (assets/shared/coa/corpus/select/cases.json); the phone only calls it (specs/core row 2, FM-04).
import 'api_contract.g.dart';
import 'mazama_core.dart';

/// SM-D23: the one size cap for a lab-report PDF, on both sides (the server's /p/coa-data/parse limit, routes.yaml).
const labReportMaxBytes = coaDataParseMaxPdfBytes;

class SelectedDocument {
  final int docId;

  /// ISO date ("2026-03-04") of the test the document belongs to; null when the state gave no readable date.
  final String? date;
  const SelectedDocument(this.docId, this.date);
}

/// The documents to read, in order. [core] defaults to this app's ([MazamaCore.instance]).
List<SelectedDocument> selectPotencyDocuments(Object? info, {Set<int> alreadyHave = const {}, CoreFunctions? core}) {
  final reply = (core ?? MazamaCore.instance).coaSelectDocuments({'info': info, 'already_have': alreadyHave.toList()});
  final out = <SelectedDocument>[];
  for (final d in reply) {
    final id = d is Map ? d['doc_id'] : null, date = d is Map ? d['date'] : null;
    if (id is! int || (date != null && date is! String)) {
      throw MazamaCoreError('coa.select_documents gave an unexpected document: $d');
    }
    out.add(SelectedDocument(id, date as String?));
  }
  return out;
}
