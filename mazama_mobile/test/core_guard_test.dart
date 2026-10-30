// CR-R3, CR-D2: the core is part of every build, so nothing in the app keeps a path for its absence, and no test
// skips for want of it (test/support/core.dart fails instead).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dart(String dir) =>
    Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));

void main() {
  test('no file under lib/ keeps an "isn\'t built" path or the old core\'s names', () {
    const banned = ['tryLoad', "isn't built", 'coaCoreMissingMessage', 'COA_CORE', 'coa_core'];
    final found = <String>[];
    for (final f in _dart('lib')) {
      final text = f.readAsStringSync();
      for (final b in banned) {
        if (text.contains(b)) found.add('${f.path}: $b');
      }
    }
    expect(found, isEmpty);
  });

  test('document choice stays the core\'s: no Dart copy of the rule or its date regexes comes back (specs/core row 2)', () {
    // stateDateIso parses the sales history's dates (state_date.dart) until the sale-date rules move (row 7)
    final decl = RegExp(r'''(String\?\s+stateDateIso\s*\(|\b_mdy\s*=|\b_iso\s*=)''');
    final found = [
      for (final f in _dart('lib'))
        if (f.path != 'lib/state_date.dart' && decl.hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(found, isEmpty);
    final select = File('lib/select_documents.dart').readAsStringSync();
    expect(select, isNot(contains('RegExp')));
    expect(select, isNot(contains("['testResults']")));
    expect(select, contains('coaSelectDocuments'));
  });

  test('the stock rules stay the core\'s: the Dart ports\' helpers are gone (specs/core row 8)', () {
    final decl = RegExp(r'''(class _Strain\b|\b(_strainPie|_sizePie|_mixPie|_breakdown|_stableSorted|roundTo2|stockPercent)\s*(<[^>]*>)?\()''');
    final found = [
      for (final path in ['lib/stock_summary.dart', 'lib/stock_mix.dart'])     // the pages draw their own pies
        for (final m in decl.allMatches(File(path).readAsStringSync())) '$path: ${m.group(0)}',
    ];
    expect(found, isEmpty);
    expect(File('lib/stock_summary.dart').readAsStringSync(), contains('stockSummarize'));
    expect(File('lib/stock_mix.dart').readAsStringSync(), contains('.stockMix('));
  });

  test('the order form\'s lines stay the core\'s: the page builds no lines of its own (specs/core row 9)', () {
    final page = File('lib/order_form_page.dart').readAsStringSync();
    expect(page, isNot(contains('byKey')));
    expect(page, contains('orderFormLines('));
    expect(File('lib/order_lines.dart').readAsStringSync(), contains('stockOrderForm'));
  });

  test('which records and licenses the phone can use stays the core\'s: no rule of its own comes back (specs/core row 10)', () {
    final records = File('lib/state_records.dart').readAsStringSync();
    expect(records, contains('recordsPackageKeys'));
    expect(records, isNot(contains('wholeNumber(record')));
    final licenses = File('lib/licenses_client.dart').readAsStringSync();
    expect(licenses, contains('recordsServiceCenters'));
    expect(licenses, isNot(contains('seen.add')));
    expect(licenses, isNot(contains("'Service center")));
  });

  test('no test skips for want of the core library', () {
    final skip = RegExp(r'''(skip:|markTestSkipped\()[^\n]*(CORE_FFI_LIB|mazama_core|coa_core|library)''');
    final found = [
      for (final f in _dart('test'))
        if (!f.path.endsWith('core_guard_test.dart') && skip.hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(found, isEmpty);
  });
}
