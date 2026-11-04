// The cart's cap and session on the phone
// are decided only by the shared core's dose.sale_limits over the lots the sale actually draws (bulk_sale.dart's
// cartDrawLimits, cart_page.dart's cartDoseCheck), never by the product's first-lot figure alone (PkprGroup's, which
// stays the line's tpeMg and price). The grid's cases: a first lot stronger than the lots drawn after it is
// allowed (or timed shorter) where its figure alone refused (or lengthened); a weaker first lot is still refused; two
// lines of one product; a line its lots can't cover; a bulk sell's copies each on their own draw.
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/cart_page.dart' show CartLine, cartDoseCheck;
import 'package:mazama_mobile/dose.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/packages_client.dart';
import 'package:mazama_mobile/selling.dart' show doseInitial, doseSecondary;

import 'support/core.dart';

const _over = ' mg psilocybin - more than the 50 mg limit per sale (mg TPE is not subject to this cap).';
const _unknown = "This sale holds a unit whose psilocybin isn't known (no weightPerUnit or analyteWeight), so it can't be "
    'sold here.';

/// A lot of PKPR-ab12c: [quantity] units of [weightPerUnit] g x [analyteWeight] mg/g, drawn in the order of [year]'s
/// expiry (the earlier year first).
Package _lot(int id, int quantity, double weightPerUnit, double analyteWeight, int year) => Package(
    productGuid: 'PKPR-ab12c',
    productType: 'Extract',
    id: id,
    weightPerUnit: weightPerUnit,
    analyteWeight: analyteWeight,
    quantity: quantity,
    expires: DateTime(year, 1, 31));

DoseLine _line(List<Package> lots, int qty, [String dose = doseInitial]) => (lots: lots, qty: qty, dose: dose);

List<List<(int, int)>> _ids(List<List<(Package, int)>> sale) => [
      for (final line in sale) [for (final (lot, take) in line) (lot.id, take)]
    ];

void main() {
  late final MazamaCore core = loadTestCore();

  /// What the cart's first-lot figure alone would say: every unit at the first lot's figures.
  SaleLimits firstLot(Package first, int qty) => saleLimits([
        [(record: doseFigures(first), qty: qty, dose: doseInitial)],
      ], core: core).single;

  group('DOSE-1: a single sale is held to the lots it draws, each its own figures', () {
    test('first lot strongest, the rest drawn from a weaker lot: allowed now, where the first-lot figure refused', () {
      // lot 1 (expires first): 2 units of 2.0 g x 12 mg/g = 24 mg; lot 2: 1.0 g x 1 mg/g. 3 units: 2 x 24 + 1 = 49 mg
      final lots = [_lot(1, 2, 2.0, 12.0, 2027), _lot(2, 10, 1.0, 1.0, 2028)];
      expect(firstLot(lots.first, 3).allowed, isFalse); // 72 mg on the first lot's figure: refused before
      final r = cartDrawLimits([_line(lots, 3)], 1, core: core);
      expect(_ids(r.perSale!.single), [
        [(1, 2), (2, 1)]
      ]);
      final v = r.limits.single;
      expect((v.psilocybinMgValue, v.allowed, v.error, v.sessionMinutes), (49.0, true, null, 360));
      final cart = cartDoseCheck([CartLine(group: PkprGroup(lots), qty: 3, priceCentsEach: 1000)], core: core);
      expect((cart.limits.allowed, cart.refusal), (true, null)); // Sell is offered
    });

    test('first lot strongest: the session is timed by the drawn total, shorter, and never shorter than it needs', () {
      // lot 1: 1 unit of 20 mg; lot 2: 1 mg a unit. 2 units: 21 mg drawn (4 hours), where the first lot alone said 40 (6)
      final lots = [_lot(1, 1, 1.0, 20.0, 2027), _lot(2, 10, 1.0, 1.0, 2028)];
      expect(firstLot(lots.first, 2).sessionMinutes, 360);
      final v = cartDrawLimits([_line(lots, 2)], 1, core: core).limits.single;
      expect((v.psilocybinMgValue, v.sessionMinutes, v.sessionMinutesInitial), (21.0, 240, 240));
      // exactly the core's minutes for what the sale's records send: 1 x 20 from lot 1, 1 x 1 from lot 2
      final sent = saleLimits([
        [
          (record: doseFigures(lots[0]), qty: 1, dose: doseInitial),
          (record: doseFigures(lots[1]), qty: 1, dose: doseInitial),
        ],
      ], core: core).single;
      expect(v.sessionMinutes, sent.sessionMinutes);
    });

    test('first lot weakest, the rest drawn from a stronger lot: still refused, saying it draws later lots', () {
      // lot 1: 2 units of 10 mg; lot 2: 2.0 g x 12 mg/g = 24 mg. 4 units: 2 x 10 + 2 x 24 = 68 mg (the first lot said 40)
      final lots = [_lot(1, 2, 1.0, 10.0, 2027), _lot(2, 10, 2.0, 12.0, 2028)];
      expect(firstLot(lots.first, 4).allowed, isTrue);
      final v = cartDrawLimits([_line(lots, 4)], 1, core: core).limits.single;
      expect((v.psilocybinMgValue, v.allowed), (68.0, false));
      final cart = cartDoseCheck([CartLine(group: PkprGroup(lots), qty: 4, priceCentsEach: 1000)], core: core);
      expect(cart.refusal, 'This sale draws later lots and would total 68.0$_over');
    });

    test("over the cap on its first lot alone: refused in the core's words (no later lot drawn)", () {
      final lots = [_lot(1, 10, 10.0, 9.0, 2027)];
      final cart = cartDoseCheck([CartLine(group: PkprGroup(lots), qty: 1, priceCentsEach: 900)], core: core);
      expect(cart.refusal, 'This sale would total 90.0$_over');
    });

    test('two lines of one product: counted as the sale draws and sends them, the second taking what the first left', () {
      // lot 1: 3 units of 5 mg; lot 2: 10 mg. Initial 2 (lot 1), secondary 2 (lot 1's last unit, then lot 2): 25 mg
      final lots = [_lot(1, 3, 1.0, 5.0, 2027), _lot(2, 10, 1.0, 10.0, 2028)];
      final r = cartDrawLimits([_line(lots, 2), _line(lots, 2, doseSecondary)], 1, core: core);
      expect(_ids(r.perSale!.single), [
        [(1, 2)],
        [(1, 1), (2, 1)],
      ]);
      final v = r.limits.single;
      expect((v.psilocybinMgValue, v.sessionMinutes, v.sessionMinutesInitial), (25.0, 300, 180));
    });

    test("two lines of one product its lots can't cover together: each line counted on its own from lot 1", () {
      // lot 1: 3 units of 10 mg; lot 2: 2 units of 20 mg; the lines need 6 of the 5. Each line on its own: 3 x 10 = 30
      final lots = [_lot(1, 3, 1.0, 10.0, 2027), _lot(2, 2, 1.0, 20.0, 2028)];
      final r = cartDrawLimits([_line(lots, 3), _line(lots, 3, doseSecondary)], 1, core: core);
      expect((r.perSale, r.shortLine, r.coreFailed), (null, 1, false)); // the sale is refused by the stock check
      final v = r.limits.single;
      expect((v.psilocybinMgValue, v.allowed), (60.0, false));
      expect(v.error, 'This sale would total 60.0$_over');
    });

    test("a line its lots can't cover counts every unit at the product's highest figure", () {
      // lot 1: 2 units of 5 mg; lot 2: 1 unit of 2.0 g x 10 mg/g = 20 mg. 4 units of the 3: 4 x 20 = 80 mg
      final r = cartDrawLimits([_line([_lot(1, 2, 1.0, 5.0, 2027), _lot(2, 1, 2.0, 10.0, 2028)], 4)], 1, core: core);
      expect((r.perSale, r.shortLine), (null, 0));
      expect((r.limits.single.psilocybinMgValue, r.limits.single.allowed), (80.0, false));
      // within the cap at the highest figure: 4 x 8 = 32 mg, timed so (the sale is still refused for its stock)
      final within = cartDrawLimits([_line([_lot(1, 2, 1.0, 5.0, 2027), _lot(2, 1, 1.0, 8.0, 2028)], 4)], 1, core: core);
      expect((within.limits.single.psilocybinMgValue, within.limits.single.sessionMinutes), (32.0, 300));
      // a lot of unknown potency is the highest there is: refused
      final unknown = cartDrawLimits([_line([_lot(1, 2, 1.0, 5.0, 2027), _lot(2, 1, 1.0, 0.0, 2028)], 4)], 1, core: core);
      expect(unknown.limits.single.error, _unknown);
    });

    test('a core that fails refuses the sale (DOSE-7)', () {
      final r = cartDrawLimits([_line([_lot(1, 3, 1.0, 5.0, 2027)], 1)], 1, core: _Failing());
      expect(r.coreFailed, isTrue);
      expect(identical(r.limits.single, SaleLimits.failed), isTrue);
      expect(r.limits.single.allowed, isFalse);
      // the cart: no figure and no cap words; pressing Sell refuses it with the draw's own words, nothing sent
      final cart = cartDoseCheck([CartLine(group: PkprGroup([_lot(1, 3, 1.0, 5.0, 2027)]), qty: 1, priceCentsEach: 100)],
          core: _Failing());
      expect((identical(cart.limits, SaleLimits.failed), cart.refusal), (true, null));
    });
  });

  group('DOSE-17: a bulk sell, every copy on its own draw', () {
    test('copy 2 draws a weaker lot, where the first-lot figure refused the cart: allowed, timed by the largest copy', () {
      // lot 1: 2 units of 2.0 g x 10 mg/g = 20 mg; lot 2: 10 mg. 3 units a copy: copy 1 2 x 20 + 10 = 50 mg (at the
      // limit, allowed), copy 2 3 x 10 = 30 mg; the first lot alone said 60
      final lots = [_lot(1, 2, 2.0, 10.0, 2027), _lot(2, 10, 1.0, 10.0, 2028)];
      expect(firstLot(lots.first, 3).allowed, isFalse);
      final r = cartDrawLimits([_line(lots, 3)], 2, core: core);
      expect([for (final v in r.limits) (v.psilocybinMgValue, v.allowed, v.sessionMinutes)], [(50.0, true, 360), (30.0, true, 300)]);
      expect(bulkCapRefusal(r.perSale!, core: core), isNull);
      // the timer and the kept dose take the largest copy's minutes
      expect(r.limits.map((v) => v.sessionMinutes!).reduce((a, b) => a > b ? a : b), 360);
    });

    test('a copy over the cap refuses the whole bulk sell, naming the copy', () {
      // lot 1: 3 units of 10 mg; lot 2: 24 mg. Copy 1 30 mg, copy 2 72 mg
      final lots = [_lot(1, 3, 1.0, 10.0, 2027), _lot(2, 9, 2.0, 12.0, 2028)];
      final r = cartDrawLimits([_line(lots, 3)], 2, core: core);
      expect([for (final v in r.limits) v.allowed], [false, false]);
      expect(r.limits[1].error, 'This sale would total 72.0$_over');
      expect(r.limits[0].error, 'copy 2 of 2 is refused: ${r.limits[1].error}');
      expect(bulkCapRefusal(r.perSale!, core: core), 'Sale 2 of 2 draws later lots and would total 72.0$_over');
    });

    test('copy 1 over the cap on its first lot alone: named, without "draws later lots"', () {
      final r = cartDrawLimits([_line([_lot(1, 10, 1.0, 20.0, 2027)], 3)], 2, core: core);
      expect(bulkCapRefusal(r.perSale!, core: core), 'Sale 1 of 2 would total 60.0$_over');
    });

    test('the largest copy is a later one: its minutes are the session', () {
      // lot 1: 3 units of 5 mg; lot 2: 12 mg. Copy 1 15 mg (4 hours), copy 2 36 mg (6 hours)
      final r = cartDrawLimits([_line([_lot(1, 3, 1.0, 5.0, 2027), _lot(2, 10, 1.0, 12.0, 2028)], 3)], 2, core: core);
      expect([for (final v in r.limits) (v.psilocybinMgValue, v.sessionMinutes)], [(15.0, 240), (36.0, 360)]);
    });

    test("copies the lots can't all cover: no draw, every copy counted as one sale's own lines", () {
      final r = cartDrawLimits([_line([_lot(1, 3, 1.0, 5.0, 2027)], 2)], 2, core: core);
      expect((r.perSale, r.shortLine), (null, 0));
      expect([for (final v in r.limits) v.psilocybinMgValue], [10.0, 10.0]);
    });
  });
}

/// A core whose draw fails (refused, never counted).
class _Failing implements CoreFunctions {
  @override
  Map<String, Object?> sellingAllocateSale(Map<String, Object?> input) => throw StateError('mazama_core is not loaded');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
