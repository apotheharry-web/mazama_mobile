// What a sale record looks like when it's sent to the state system, and the dates it may carry: the shared core's
// rules (mazama_core::selling::sale), the same ones the server sends with (selling.py and
// salejobs.py call them through the core's Python binding). Nothing of the rules is written here: these are thin calls
// that fail closed. Held to the golden vectors (../../mazama_modules/selling/vectors/ sale_record.json, sale_date.json
// and sale_cases.json, the cases the owner approved; test/selling_vectors_test.dart,
// test/sale_cases_vectors_test.dart).
//
// Fails closed: when the core can't answer, no record is built (StateError: nothing is sent), no date is
// accepted, and a reply is never taken as proof of a sale (it may have been recorded).
import 'mazama_core.dart';

const doseInitial = 'initial';
const doseSecondary = 'secondary';

CoreFunctions _core(CoreFunctions? core) => core ?? MazamaCore.instance;

/// The core refused to build a sale's record: [message] is its words. Nothing is sent.
class SaleRefused implements Exception {
  final String message;
  const SaleRefused(this.message);
  @override
  String toString() => message;
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _day(String iso) {
  final p = iso.split('-').map(int.parse).toList();
  return DateTime.utc(p[0], p[1], p[2]);
}

/// The same string the server's pacific_midnight_utc returns: "2026-10-11T07:00:00.000Z" (the 2007 US rule).
/// StateError when the core can't answer.
String pacificMidnightUtc(DateTime date, {CoreFunctions? core}) {
  try {
    final utc = _core(core).sellingPacificMidnight({'date': _ymd(date)})['utc'];
    if (utc is String) return utc;
  } catch (_) {
    // below: no answer
  }
  throw StateError("mazama_core couldn't work out Pacific midnight");
}

/// The record the state system's own web page sends to CreateSalesRecords, for [qty] units of [item] at [priceCents]
/// each: the core's (selling.build_sale), [item]'s values passed through as given. Throws [SaleRefused] with
/// the core's words when [item] lacks what a sale copies or the price each or quantity is out of bounds,
/// StateError when the core can't answer (nothing is sent either way).
Map<String, Object?> buildSale(
  Map<String, Object?> item,
  int priceCents,
  DateTime saleDate, {
  String dose = doseInitial,
  int qty = 1,
  CoreFunctions? core,
}) {
  Map<String, Object?> reply;
  try {
    reply = _core(core).sellingBuildSale(
        {'item': item, 'price_cents': priceCents, 'sale_date': _ymd(saleDate), 'dose': dose, 'qty': qty});
  } catch (e) {
    throw StateError("mazama_core couldn't build the sale's record ($e)");
  }
  final record = reply['record'], refusal = reply['refusal'];
  if (refusal is String && record == null) throw SaleRefused(refusal);
  if (refusal == null && record is Map) return Map<String, Object?>.from(record);
  throw StateError('mazama_core answered a sale record with ${reply.keys.toList()}');
}

/// Whether [created] (sale.yaml's own `created` output: the state's copy of every record just submitted) proves the
/// sale for the [expectedCount] records sent: one object back per record, every saleNumber the same text that isn't
/// blank or the same whole number above 0 (the core's selling.sale_proof, as the server's).
/// False when the core can't answer: a reply this phone can't read may still have been recorded.
bool looksLikeConfirmedSale(Object? created, int expectedCount, {CoreFunctions? core}) =>
    saleNumberOf(created, expectedCount, core: core) != null;

/// The sale number [created] proves, or null (see [looksLikeConfirmedSale]).
String? saleNumberOf(Object? created, int expectedCount, {CoreFunctions? core}) {
  try {
    final n = _core(core).sellingSaleProof({'reply': created, 'sent': expectedCount})['sale_number'];
    return n is String && n.isNotEmpty ? n : null;
  } catch (_) {
    return null;
  }
}

/// Throws a FormatException('bad') for anything that isn't a date in a form the server's parse_sale_date reads, or
/// FormatException('future') for a date after [today] - the core's rule (selling.parse_sale_date), held to
/// sale_date.json. How far back a date may go is [checkSaleDate]'s. StateError when the core can't answer.
DateTime parseSaleDate(String text, DateTime today, {CoreFunctions? core}) {
  Map<String, Object?> reply;
  try {
    reply = _core(core).sellingParseSaleDate({'text': text, 'today': _ymd(today)});
  } catch (e) {
    throw StateError("mazama_core couldn't read the sale date ($e)");
  }
  final date = reply['date'], error = reply['error'];
  if (error == 'bad' || error == 'future') throw FormatException(error as String);
  if (error == null && date is String) return _day(date);
  throw StateError('mazama_core answered a sale date with ${reply.keys.toList()}');
}

/// Null when a sale may be dated [date]; 'future' after [today], 'too_old' more than 365 days back: the core's
/// selling.check_sale_date. 'unchecked' when the core can't answer (refused).
String? checkSaleDate(DateTime date, DateTime today, {CoreFunctions? core}) {
  try {
    final reply = _core(core).sellingCheckSaleDate({'date': _ymd(date), 'today': _ymd(today)});
    final e = reply['error'];
    if (e == null && reply['date'] is String) return null;
    if (e == 'future' || e == 'too_old') return e as String;
  } catch (_) {
    // below
  }
  return 'unchecked';
}

/// The days a sale may be dated for [today] (the Pacific date of now): from 365 days back to today, the bound
/// [checkSaleDate] holds, as the date pickers offer them (the core's selling.sale_date_bounds), as date-only
/// DateTimes. StateError when the core can't answer.
({DateTime earliest, DateTime latest}) saleDateBounds(DateTime today, {CoreFunctions? core}) {
  try {
    final reply = _core(core).sellingSaleDateBounds({'today': _ymd(today)});
    final earliest = reply['earliest'], latest = reply['latest'];
    if (earliest is String && latest is String) return (earliest: _day(earliest), latest: _day(latest));
  } catch (_) {
    // below: no answer
  }
  throw StateError("mazama_core couldn't work out the days a sale may be dated");
}

/// The words for [checkSaleDate]'s answer.
String saleDateRefusal(String why) => switch (why) {
      'future' => "The sale date can't be in the future.",
      'too_old' => "A sale can't be dated more than 365 days back.",
      _ => "This phone can't check the sale date (its shared core failed), so the sale was never attempted.",
    };

/// The Pacific date of [now] (a sale's default date and the date pickers' last day, whatever the device's own
/// zone), as a date-only DateTime. StateError when the core can't answer.
DateTime pacificToday(DateTime now, {CoreFunctions? core}) {
  final u = now.toUtc();
  final text = '${_ymd(u)}T${u.hour.toString().padLeft(2, '0')}:${u.minute.toString().padLeft(2, '0')}:'
      '${u.second.toString().padLeft(2, '0')}Z';
  try {
    final d = _core(core).sellingToday({'now': text})['date'];
    if (d is String) return _day(d);
  } catch (_) {
    // below
  }
  throw StateError("mazama_core couldn't work out today's Pacific date");
}

/// A state-site date as ISO ("2026-05-27"): MM/DD/YYYY (a one-digit month or day allowed, anything after a space
/// ignored) or ISO YYYY-MM-DD (a time after it ignored); an impossible date is null. The core's
/// selling.parse_state_date. Null when the core can't answer.
String? stateDateIso(String? s, {CoreFunctions? core}) {
  if (s == null) return null;
  try {
    final d = _core(core).sellingParseStateDate({'text': s})['date'];
    return d is String ? d : null;
  } catch (_) {
    return null;
  }
}
