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
    // stateDateIso is the core's since row 7 (selling.dart's thin call to selling.parse_state_date): no date regex is left
    final decl = RegExp(r'''(\b_mdy\s*=|\b_iso\s*=|\b_headEnd\s*=)''');
    final found = [
      for (final f in _dart('lib'))
        if (decl.hasMatch(f.readAsStringSync())) f.path,
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

  test('what may be sold stays the core\'s: no Dart copy of the rule comes back (specs/core row 4)', () {
    final rule = File('lib/sellability.dart').readAsStringSync();
    expect(rule, contains('sellingSellable'));
    for (final gone in ['_truthy', '_py(', 'no units remaining', 'package is locked', 'package is flagged', 'pending transfer', 'is num']) {
      expect(rule, isNot(contains(gone)), reason: gone);
    }
    // nor anywhere else under lib/
    final found = [
      for (final f in _dart('lib'))
        for (final w in ['no units remaining (system reports', 'package has a pending transfer'])
          if (f.readAsStringSync().contains(w)) '${f.path}: $w',
    ];
    expect(found, isEmpty);
  });

  test('pricing, the cart and the draw order stay the core\'s: no Dart copy of the rule comes back (specs/core row 6)', () {
    final pricing = File('lib/pricing.dart').readAsStringSync();
    final cart = File('lib/cart_pricing.dart').readAsStringSync();
    final packages = File('lib/packages_client.dart').readAsStringSync();
    final page = File('lib/cart_page.dart').readAsStringSync();
    expect(pricing, contains('sellingParsePrice'));
    expect(cart, allOf(contains('sellingPriceCart'), contains('sellingLinePrice'), contains('sellingGroupOf'), contains('sellingShareTotal')));
    expect(packages, contains('sellingAllocate'));
    for (final gone in ['_priceRe', 'RegExp(', 'padRight(3', 'int.parse(', 'rest.runes', '~/ 200']) {
      expect(pricing, isNot(contains(gone)), reason: 'pricing.dart: $gone');
    }
    for (final gone in ['_roundHalfUpDiv', 'remainders', 'numerators', '~/ sum', 'toLowerCase()', '.sort(', '(2 * cents + qty)']) {
      expect(cart, isNot(contains(gone)), reason: 'cart_pricing.dart: $gone');
    }
    // drawOrder's comparator
    for (final gone in ['a.stateOnly != b.stateOnly', 'ae.compareTo(be)', 'a.quantity.compareTo(b.quantity)', 'final take = left <']) {
      expect(packages, isNot(contains(gone)), reason: 'packages_client.dart: $gone');
    }
    // the line dialog prices through the core
    for (final gone in ['perMgPriceCentsEach(', 'perMgRateToCents(', 'toCents(']) {
      expect(page, isNot(contains(gone)), reason: 'cart_page.dart: $gone');
    }
  });

  test('the cap and unit mg stay the core\'s: no Dart copy of the rule comes back (specs/core row 5)', () {
    final rule = File('lib/dose.dart').readAsStringSync();
    expect(rule, allOf(contains('doseUnitMg'), contains('doseCeilMg'), contains('doseSaleLimits')));
    final gone = ['maxAnalyteMgPerSale', 'sessionTable', 'totalAnalyteMg', 'mgNoise', 'minSessionDuration', 'analyteCapError',
        'analyteMgPerUnit', 'SessionRow(', 'cartPsilocybinMg', 'tpePerGram', '- 1e-9'];
    final found = [
      for (final f in _dart('lib'))
        for (final w in gone)
          if (f.readAsStringSync().contains(w)) '${f.path}: $w',
    ];
    expect(found, isEmpty);
    // the over-cap words are the core's: the phone only says which sale they are about
    final words = [
      for (final f in _dart('lib'))
        if (f.readAsStringSync().contains('mg limit per sale')) f.path,
    ];
    expect(words, isEmpty);
  });

  test('a sale\'s record, date, draw, check and outcome stay the core\'s: no Dart copy comes back (specs/core row 7)', () {
    expect(File('lib/state_date.dart').existsSync(), isFalse);
    final gone = ['_nthWeekday', '_isoDate', '_dateDashed', '_dateCompact', '_weekDashed', '_weekCompact', 'pacificMidnightLocalAsUtc',
        'final take = need < have', 'left[lot.id] = have - take'];
    final found = [
      for (final f in _dart('lib'))
        for (final w in gone)
          if (f.readAsStringSync().contains(w)) '${f.path}: $w',
    ];
    expect(found, isEmpty);
    final selling = File('lib/selling.dart').readAsStringSync();
    expect(selling, allOf(contains('sellingBuildSale'), contains('sellingSaleProof'), contains('sellingParseSaleDate'),
        contains('sellingCheckSaleDate'), contains('sellingPacificMidnight'), contains('sellingToday'), contains('sellingParseStateDate')));
    for (final w in ["'saleNumber'", 'RegExp(', 'Duration(hours', '.toSet()', "'productCost'", "'costEach'"]) {
      expect(selling, isNot(contains(w)), reason: 'selling.dart: $w');
    }
    expect(File('lib/sale_outcome.dart').readAsStringSync(), allOf(contains('sellingSaleOutcome'), isNot(contains('>= 400'))));
    expect(File('lib/bulk_sale.dart').readAsStringSync(), contains('sellingAllocateSale'));
    expect(File('lib/cart_page.dart').readAsStringSync(), allOf(contains('sellingCheckSale'), isNot(contains('saleLineRefusal('))));
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
