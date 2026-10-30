// SM-06: which lab-report documents the phone reads for a lot (COA-R1), held to the shared cases
// (assets/shared/coa/corpus/select/cases.json, vendored from mazama_modules/coa/corpus/select/), the same ones
// mazama_core and the server run. The rule is the core's (coa.select_documents, specs/core row 2): the phone only
// calls it. And the one 2 MB size cap (SM-D23).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/api_contract.g.dart';
import 'package:mazama_mobile/select_documents.dart';

import 'support/core.dart';

void main() {
  final cases = ((jsonDecode(File('assets/shared/coa/corpus/select/cases.json').readAsStringSync()) as Map)['cases'] as List)
      .cast<Map<String, Object?>>();

  test('there are cases', () => expect(cases.length, greaterThanOrEqualTo(15)));

  for (final c in cases) {
    test('case: ${c['name']}', () {
      final have = (c['already_have'] as List).cast<int>().toSet();
      final got = selectPotencyDocuments(c['info'], alreadyHave: have, core: loadTestCore())
          .map((d) => {'doc_id': d.docId, 'date': d.date})
          .toList();
      expect(got, c['documents']);
    });
  }

  test('the size cap is the one the server enforces', () {
    expect(labReportMaxBytes, coaDataParseMaxPdfBytes);
    expect(labReportMaxBytes, 2000000);
  });
}
