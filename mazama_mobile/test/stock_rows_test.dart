// SP-R13, SP-D6: the stock page's rows from the state alone (stockRowsFromState) and the order the page's data
// comes in: the server, else the state (partial, mg psilocybin), else the last rows drawn here (lib/stock_rows.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/reply_store.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/par_client.dart';
import 'package:mazama_mobile/session.dart';
import 'package:mazama_mobile/stock_cache_store.dart';
import 'package:mazama_mobile/stock_rows.dart';
import 'package:mazama_mobile/stock_summary.dart';

Map<String, Object?> _record({
  Object? id = 6600,
  String guid = 'PKPR-aaaa0001',
  String license = 'MF-1e72fc8f',
  String name = 'GT 5 mg TPE CH (2027-02-03)',
  Object? quantity = 10,
  Object? weight = 0.5,
  Object? analyte = 10.0,
  bool zeroOut = false,
}) =>
    {
      'id': id,
      'productGuid': guid,
      'manufacturerLicenseId': license,
      'description': name,
      'quantity': quantity,
      'weightPerUnit': weight,
      'analyteWeight': analyte,
      'zeroOut': zeroOut,
      'productType': 'Edible Psilocybin Product',
    };

final _today = DateTime(2026, 10, 21);

/// One sellable record and one each locked, flagged and pending a transfer (sellability.dart's conditions), plus one
/// with nothing on hand.
List<Map<String, Object?>> _mixedRecords() => [
      _record(id: 1, guid: 'PKPR-ok'),
      {..._record(id: 2, guid: 'PKPR-locked'), 'locked': true, 'reasonLocked': 'Recall'},
      {..._record(id: 3, guid: 'PKPR-flagged'), 'flagged': true},
      {..._record(id: 4, guid: 'PKPR-moving'), 'pendingTransfer': true},
      _record(id: 5, guid: 'PKPR-empty', zeroOut: true),
    ];

late Directory _dir;

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_stock_rows_test_'));
  tearDown(() => _dir.deleteSync(recursive: true));
  StockCacheStore cache() => StockCacheStore(dataDir: () => _dir);
  ReplyStore replies() => ReplyStore(dataDir: () => _dir);

  group('state rows', () {
    test('licence decides mazama', () {
      final records = [_record(id: 1), _record(id: 2, license: 'MF-other')];
      final rows = stockRowsFromState(records, {'mf-1e72fc8f'}, _today);
      expect(rows.map((r) => r.mazama), [true, false]); // MF-1E72FC8F matched lower-case
      // No license configured on the server: it counts every package as Mazama's, and so does the phone.
      expect(stockRowsFromState(records, <String>{}, _today).map((r) => r.mazama), [true, true]);
      // Never fetched: none is known to be Mazama's.
      expect(stockRowsFromState(records, null, _today).map((r) => r.mazama), [false, false]);
    });

    test('a type nothing names comes from what it was made from (HB- dehydrated, PL- homogenized), as the server does',
        () {
      Map<String, Object?> rec(int id, String name, {String type = 'Whole Fungi', String? hb, String? pl}) => {
            ..._record(id: id, name: name),
            'productType': type,
            if (hb != null) 'harvestBatchGuid': hb,
            if (pl != null) 'processLotGuid': pl,
          };
      final rows = stockRowsFromState([
        rec(1, 'GT 3.5g', hb: 'HB-3449c265'), // seen: dehydrated packages filled "Other type" on By type
        rec(2, 'GT 3.5g', pl: 'PL-1a2b3c4d'),
        rec(3, 'GT 25 mg TPE FD (2027-01-01)', hb: 'HB-3449c265'), // the name's code wins
        rec(4, 'GT chocolate 5 mg', pl: 'PL-1a2b3c4d'), // so does an edible word
        rec(5, 'GT 3.5g', type: 'Freeze Dried Fungi', hb: 'HB-3449c265'), // and a kind word in the type
        rec(6, 'GT 3.5g'), // no source: whole fungi
        rec(7, 'GT 3.5g', type: ''), // nothing at all: unknown
      ], {'mf-1e72fc8f'}, _today);
      expect(rows.map(stockTypeOf), ['DH', 'HG', 'FD', 'CH', 'FD', 'WF', '']);
    });

    test('name date decides expired', () {
      final rows = stockRowsFromState([
        _record(id: 1, name: 'GT 5 mg (2026-10-20)'), // yesterday: expired
        _record(id: 2, name: 'GT 5 mg (2026-10-21)'), // today: its last good day
        _record(id: 3, name: 'GT 5 mg'), // no date: not expired
        _record(id: 4, name: 'GT 5 mg (2026-02-30)'), // not a date
      ], {'mf-1e72fc8f'}, _today);
      expect(rows.map((r) => r.expired), [true, false, false, false]);
    });

    test("the name's date is the server's: a trailing (YYYY-MM-DD) after the dose", () {
      expect(nameDate('GT 5 mg TPE CH (2027-02-03)'), DateTime.utc(2027, 2, 3));
      expect(nameDate('GT 5 mg TPE CH ( 2027-02-03 ) '), DateTime.utc(2027, 2, 3));
      expect(nameDate('GT 2020-01-01 batch 5 mg (2027-02-03)'), DateTime.utc(2027, 2, 3)); // the last one, not the first
      expect(nameDate('GT 5 mg (2027-02-03) extra'), isNull); // not at the end
      expect(nameDate('GT 5 mg 2027-02-03'), isNull); // not in brackets
      expect(nameDate('Gift box (2027-02-03)'), isNull); // no dose: the server can't read the name
      expect(nameDate('5 mg (2027-02-03)'), isNull); // no strain before the dose
      expect(nameDate(null), isNull);
    });

    test('missing weight or analyte counts units and 0 mg', () {
      final rows = stockRowsFromState([
        _record(id: 1, quantity: 4, weight: 0.5, analyte: 10.0, name: 'GT 5 mg'),
        _record(id: 2, quantity: 3, weight: null, analyte: 10.0, name: 'GT 5 mg'),
        _record(id: 3, quantity: 2, weight: 0.5, analyte: null, name: 'GT 5 mg'),
      ], {'mf-1e72fc8f'}, _today);
      final s = summarize(filterRows(rows, 'all')['counted'] as List<StockRow>, 'psilocybin');
      expect(s['total'], 9);
      expect(s['mg_total'], 20.0); // only 4 x 0.5 x 10
      expect(rows.every((r) => r.unitMgTpe == null), isTrue);
    });

    test('rows carry the record\'s id, PKPR, name and a strain when one can be read', () {
      final rows = stockRowsFromState([
        _record(id: '6612', quantity: 2.5),
        _record(id: 'x'), // skipped, as the server skips it
      ], {'mf-1e72fc8f'}, _today, strainOf: (name) => name!.startsWith('GT') ? 'Golden Teacher' : '');
      expect(rows, hasLength(1));
      final r = rows.single;
      expect([r.id, r.productGuid, r.description, r.quantity, r.strain], [6612, 'PKPR-aaaa0001', 'GT 5 mg TPE CH (2027-02-03)', 2.5, 'Golden Teacher']);
      expect(stockRowsFromState([_record()], null, _today).single.strain, ''); // no name reader: unknown
    });
  });

  group('SP-D9: what the server would not sell', () {
    test("state rows leave out locked, flagged and pending-transfer records; they come back held, in the server's words", () {
      final rows = stockRowsFromState(_mixedRecords(), {'mf-1e72fc8f'}, _today);
      expect(rows.map((r) => r.productGuid), ['PKPR-ok']);
      final held = heldBackFromState(_mixedRecords(), {'mf-1e72fc8f'}, _today);
      expect([for (final h in held) '${h.row.productGuid}: ${h.reason}'], [
        'PKPR-locked: locked (Recall)',
        'PKPR-flagged: flagged (no reason)',
        'PKPR-moving: pending transfer',
      ]); // nothing on hand is in neither list
      expect(held.first.row.quantity, 10);
    });
  });

  group('loadCenterStock', () {
    Package served(String guid, int id, {int quantity = 5, String description = 'GT 25 mg', double? unitMgTpe = 25}) => Package(
        productGuid: guid, productType: 'Edible', id: id, weightPerUnit: 1, analyteWeight: 25, strain: 'Golden Teacher', tpeMg: 25,
        quantity: quantity, mazama: true, unitMgTpe: unitMgTpe, description: description);
    Future<List<Package>> down() async => throw PackagesError('cannot reach sales.mazamamushrooms.com');
    Future<List<Object?>> stateDown() async => throw Exception('no state');

    test('online: the lots the server returned, with the state\'s live quantities, in mg TPE; kept', () async {
      final load = await loadCenterStock(
        stateId: 231,
        fetchServerPackages: () async => [served('PKPR-a', 1), served('PKPR-gone', 2)],
        fetchStateRecords: () async => [
          _record(id: 1, guid: 'PKPR-a', quantity: 3.5), // the state's quantity wins, fraction and all
          _record(id: 9, guid: 'PKPR-locked'), // a lot the server left out (SP-D9): not counted
        ],
        fetchMazamaLicenses: () async => ['mf-1e72fc8f'],
        cache: cache(),
        now: () => DateTime.utc(2026, 10, 21, 9),
      );
      expect([load.mgMode, load.partial, load.drawnAt, load.notSetUp], ['tpe', false, null, false]);
      expect(load.rows.map((r) => '${r.productGuid} ${r.quantity}'), ['PKPR-a 3.5']); // PKPR-gone: the state no longer has it
      final r = load.rows.single;
      expect([r.mazama, r.unitMgTpe, r.description, r.strain], [true, 25, 'GT 25 mg', 'Golden Teacher']); // the server's word
      final saved = await cache().load(231);
      expect(saved.mazamaLicenses, ['mf-1e72fc8f']);
      expect(saved.rows!.single.productGuid, 'PKPR-a');
      expect(saved.rowsAt, DateTime.utc(2026, 10, 21, 9));
    });

    test('the state unreachable: the server\'s own rows and quantities', () async {
      final load = await loadCenterStock(
        stateId: 231,
        fetchServerPackages: () async => [served('PKPR-a', 1, quantity: 7)],
        fetchStateRecords: stateDown,
        fetchMazamaLicenses: () async => [],
        cache: cache(),
      );
      expect([load.mgMode, load.partial], ['tpe', false]);
      expect(load.rows.single.quantity, 7);
    });

    test('the server unreachable: the state\'s records, partial, in mg psilocybin, with the kept licenses', () async {
      await cache().saveMazamaLicenses(231, ['mf-1e72fc8f']);
      final load = await loadCenterStock(
        stateId: 231,
        fetchServerPackages: down,
        fetchStateRecords: () async => [_record(id: 1), _record(id: 2, license: 'MF-other'), 'junk'],
        fetchMazamaLicenses: () async => throw Exception('down'),
        cache: cache(),
        now: () => _today,
      );
      expect([load.mgMode, load.partial, load.drawnAt, load.notSetUp], ['psilocybin', true, null, false]);
      expect(load.rows.map((r) => r.mazama), [true, false]);
      expect((await cache().load(231)).rowsMgMode, 'psilocybin');
      expect((await cache().load(231)).mazamaLicenses, ['mf-1e72fc8f']); // a failed fetch keeps the last list
    });

    test("a center the server hasn't set up (404) is not 'unreachable', and its licenses are still fetched", () async {
      final load = await loadCenterStock(
        stateId: 231,
        fetchServerPackages: () async => throw PackagesError('no service center with id 231', status: 404),
        fetchStateRecords: () async => [_record(id: 1), _record(id: 2, license: 'MF-other')],
        fetchMazamaLicenses: () async => ['mf-1e72fc8f'],
        cache: cache(),
        now: () => _today,
      );
      expect([load.notSetUp, load.partial, load.mgMode], [true, true, 'psilocybin']);
      expect(load.rows.map((r) => r.mazama), [true, false]); // the licenses fetched this time
      expect((await cache().load(231)).mazamaLicenses, ['mf-1e72fc8f']);
    });

    test('server unreachable: locked, flagged and pending-transfer records are held back, not counted', () async {
      final load = await loadCenterStock(
        stateId: 231,
        fetchServerPackages: down,
        fetchStateRecords: () async => _mixedRecords(),
        fetchMazamaLicenses: () async => [],
        cache: cache(),
        now: () => _today,
      );
      expect(load.rows.map((r) => r.productGuid), ['PKPR-ok']);
      expect(load.heldBack.map((h) => h.reason), ['locked (Recall)', 'flagged (no reason)', 'pending transfer']);
    });

    test('not set up (404): the same', () async {
      final load = await loadCenterStock(
        stateId: 231,
        fetchServerPackages: () async => throw PackagesError('no service center with id 231', status: 404),
        fetchStateRecords: () async => _mixedRecords(),
        fetchMazamaLicenses: () async => [],
        cache: cache(),
        now: () => _today,
      );
      expect(load.notSetUp, isTrue);
      expect(load.rows.map((r) => r.productGuid), ['PKPR-ok']);
      expect(load.heldBack.map((h) => h.row.productGuid), ['PKPR-locked', 'PKPR-flagged', 'PKPR-moving']);
    });

    test('online: the state\'s held-back records are listed too (the server left them out)', () async {
      final load = await loadCenterStock(
        stateId: 231,
        fetchServerPackages: () async => [served('PKPR-ok', 1)],
        fetchStateRecords: () async => _mixedRecords(),
        fetchMazamaLicenses: () async => [],
        cache: cache(),
        now: () => _today,
      );
      expect(load.rows.map((r) => r.productGuid), ['PKPR-ok']);
      expect(load.heldBack.map((h) => h.reason), ['locked (Recall)', 'flagged (no reason)', 'pending transfer']);
      expect([load.serverQuantities, load.signInNeeded], [false, false]);
    });

    test("online with an expired state sign-in: the server's quantities, and a request to sign in again", () async {
      final load = await loadCenterStock(
        stateId: 231,
        fetchServerPackages: () async => [served('PKPR-a', 1, quantity: 7)],
        fetchStateRecords: () async => throw SessionExpired('please sign in again'),
        fetchMazamaLicenses: () async => [],
        cache: cache(),
      );
      expect([load.partial, load.serverQuantities, load.signInNeeded], [false, true, true]);
      expect(load.rows.single.quantity, 7);
      // The state merely unreachable: the server's quantities, no sign-in.
      final other = await loadCenterStock(
          stateId: 231, fetchServerPackages: () async => [served('PKPR-a', 1)], fetchStateRecords: stateDown, fetchMazamaLicenses: () async => [], cache: cache());
      expect([other.serverQuantities, other.signInNeeded], [true, false]);
    });

    test('nothing reachable: the last rows drawn here, with their time', () async {
      final at = DateTime.utc(2026, 10, 21, 6);
      await cache().saveRows(231, [served('PKPR-s', 1).toStockRow()], mgMode: 'tpe', at: at);
      final load = await loadCenterStock(
        stateId: 231,
        fetchServerPackages: down,
        fetchStateRecords: stateDown,
        fetchMazamaLicenses: () async => [],
        cache: cache(),
      );
      expect([load.mgMode, load.partial, load.drawnAt, load.signInNeeded], ['tpe', true, at, false]);
      expect(load.rows.single.productGuid, 'PKPR-s');
    });

    test('nothing reachable and nothing drawn before is StockUnavailable', () async {
      await expectLater(
        loadCenterStock(stateId: 231, fetchServerPackages: down, fetchStateRecords: stateDown, fetchMazamaLicenses: () async => [], cache: cache()),
        throwsA(isA<StockUnavailable>().having((e) => '$e', 'text',
            "The state system can't be reached, and this phone hasn't drawn this center's stock before.")),
      );
    });

    test('an expired state sign-in asks for a new one, with or without charts kept', () async {
      Future<List<Object?>> expired() async => throw SessionExpired('please sign in again');
      await expectLater(
        loadCenterStock(stateId: 231, fetchServerPackages: down, fetchStateRecords: expired, fetchMazamaLicenses: () async => [], cache: cache()),
        throwsA(isA<StockSignInNeeded>()),
      );
      await cache().saveRows(231, [served('PKPR-s', 1).toStockRow()], mgMode: 'tpe', at: DateTime.utc(2026, 10, 21));
      final load = await loadCenterStock(
          stateId: 231, fetchServerPackages: down, fetchStateRecords: expired, fetchMazamaLicenses: () async => [], cache: cache());
      expect([load.signInNeeded, load.partial], [true, true]);
    });
  });

  group('loadCenterPar', () {
    test('from the server, kept with when; unreachable the kept copy with that time; with no copy the error', () async {
      const levels = [ParLevel(strain: 'Golden Teacher', size: 25, par: 12)];
      final at = DateTime.utc(2026, 10, 21, 9, 30);
      final fresh = await loadCenterPar(stateId: 231, fetchPar: () async => levels, replies: replies(), now: () => at);
      expect(fresh.value.single.par, 12);
      expect(fresh.fromCache, isFalse);
      expect(replies().load('par/231')!.at, at); // the app's reply store (README R56)

      final offline = await loadCenterPar(
          stateId: 231, fetchPar: () async => throw ParError('cannot reach x: SocketException', unreachable: true), replies: replies());
      expect(offline.value.single.strain, 'Golden Teacher');
      expect(offline.fromCache, isTrue);
      expect(offline.cachedAt, at);

      await expectLater(
        loadCenterPar(stateId: 183, fetchPar: () async => throw ParError('down', unreachable: true), replies: replies(), legacy: cache()),
        throwsA(isA<ParError>()),
      );
    });

    test("unreachable with only an older build's copy (stock_cache_store.dart): that copy, with its time", () async {
      final at = DateTime.utc(2026, 10, 20, 8);
      await cache().savePar(231, const [ParLevel(strain: 'Golden Teacher', size: 25, par: 12)], at: at);
      final offline = await loadCenterPar(
          stateId: 231, fetchPar: () async => throw ParError('down', unreachable: true), replies: replies(), legacy: cache());
      expect([offline.value.single.par, offline.fromCache, offline.cachedAt], [12, true, at]);
    });

    test("the server's own refusal (4xx) is an error even with a copy kept", () async {
      await cache().savePar(231, const [ParLevel(strain: 'Golden Teacher', size: 25, par: 12)]);
      await expectLater(
        loadCenterPar(stateId: 231, fetchPar: () async => throw ParError('No such service center.'), replies: replies(), legacy: cache()),
        throwsA(isA<ParError>().having((e) => e.message, 'message', 'No such service center.')),
      );
    });
  });
}
