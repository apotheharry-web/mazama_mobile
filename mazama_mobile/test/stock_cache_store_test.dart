// SP-R13: what the stock page keeps per center for when it can't reach everything (lib/stock_cache_store.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/sheets_client.dart';
import 'package:mazama_mobile/stock_cache_store.dart';
import 'package:mazama_mobile/stock_summary.dart';

late Directory _dir;

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_stock_cache_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));

  StockCacheStore store() => StockCacheStore(dataDir: () => _dir);

  test('nothing saved is all missing', () async {
    final c = await store().load(231);
    expect([c.par, c.mazamaLicenses, c.rows, c.rowsAt], [null, null, null, null]);
    expect(c.rowsMgMode, 'tpe');
  });

  test('par, licenses and rows round-trip per center, each saved on its own', () async {
    final at = DateTime.utc(2026, 10, 21, 9, 30);
    await store().savePar(231, const [ParLevel(strain: 'Golden Teacher', size: 25, par: 12)]);
    await store().saveMazamaLicenses(231, ['mf-1e72fc8f']);
    await store().saveRows(231, const [StockRow(productGuid: 'PKPR-a', id: 1, quantity: 3, mazama: true, description: 'GT 25 mg')],
        mgMode: 'psilocybin', at: at);

    final c = await store().load(231);
    expect(c.par!.single.toJson(), {'strain': 'Golden Teacher', 'size': 25, 'par': 12});
    expect(c.mazamaLicenses, ['mf-1e72fc8f']);
    expect(c.rows!.single.toJson(), const StockRow(productGuid: 'PKPR-a', id: 1, quantity: 3, mazama: true, description: 'GT 25 mg').toJson());
    expect(c.rowsMgMode, 'psilocybin');
    expect(c.rowsAt, at);

    final other = await store().load(183);
    expect(other.par, isNull);
    expect(other.rows, isNull);
  });

  test('a damaged file counts as nothing saved', () async {
    File('${_dir.path}/stock_cache_231.json').writeAsStringSync('{not json');
    final c = await store().load(231);
    expect(c.rows, isNull);
    File('${_dir.path}/stock_cache_231.json').writeAsStringSync('{"par": [1, 2], "rows": "x"}');
    final d = await store().load(231);
    expect(d.par, isNull);
    expect(d.rows, isNull);
  });

  test('the par columns chosen on this phone round-trip per center, sizes other than the strain sizes dropped', () async {
    expect((await store().loadParColumns(231)).added, isEmpty);
    await store().savePar(231, const [ParLevel(strain: 'Bluey', size: 5, par: 2)]);
    await store().saveParColumns(231, const ParColumns(added: {15}, removed: {25, 0}));
    final c = await store().loadParColumns(231);
    expect([c.added, c.removed], [{15}, {25, 0}]);
    expect((await store().load(231)).par!.single.par, 2); // kept beside the levels, not over them
    expect((await store().loadParColumns(183)).removed, isEmpty);
    expect(ParColumns.fromJson({'added': [-1, 7, 'x', 10], 'removed': 'nope'}).added, {10});
  });

  test('par and the sheets keep when the server sent them, across a fresh store (an app restart)', () async {
    final parAt = DateTime.utc(2026, 10, 20, 8);
    final sheetsAt = DateTime.utc(2026, 10, 21, 9, 30);
    await store().savePar(231, const [ParLevel(strain: 'Golden Teacher', size: 25, par: 12)], at: parAt);
    await store().saveSheets(
        231,
        const [
          ProductSheet(guid: 'HB-aaaa0001', name: 'GT 6.26', product: 'Whole Fungi', tested: 'Aug 27, 2026',
              path: '/p/lots/mazama/HB-aaaa0001', strains: ['Golden Teacher'], tpe: 8.64, detected: ['baeocystin'], types: ['DH']),
        ],
        at: sheetsAt);

    final c = await StockCacheStore(dataDir: () => _dir).load(231);
    expect(c.parAt, parAt);
    expect(c.par!.single.par, 12);
    expect(c.sheetsAt, sheetsAt);
    expect(c.sheets!.single.toJson(), {
      'guid': 'HB-aaaa0001',
      'name': 'GT 6.26',
      'product': 'Whole Fungi',
      'tested': 'Aug 27, 2026',
      'path': '/p/lots/mazama/HB-aaaa0001',
      'strains': ['Golden Teacher'],
      'tpe': 8.64,
      'psilocybin': null,
      'psilocin': null,
      'detected': ['baeocystin'],
      'types': ['DH'],
    });
    expect((await store().load(183)).sheets, isNull);
  });

  test('par kept without a time (an older build) has none; damaged sheets count as none', () async {
    await store().savePar(231, const [ParLevel(strain: 'Bluey', size: 5, par: 2)]);
    expect((await store().load(231)).parAt, isNull);
    File('${_dir.path}/stock_cache_231.json').writeAsStringSync('{"sheets": [{"guid": 5}], "sheetsAtMs": "x"}');
    final d = await store().load(231);
    expect(d.sheets, isNull);
    expect(d.sheetsAt, isNull);
  });
}
