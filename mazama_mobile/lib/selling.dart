// The Dart twin of mazama_sales/src/mazama_sales/selling.py: what a sale record looks like when it's sent to
// the state system. This stays hand-written here, not in a shared/flows/*.yaml spec, because it's this app's
// own business logic (price math, Pacific-midnight date conversion, dose split) rather than state-system wire
// protocol that drifts the way B2C's login endpoints do - see shared/flows/sale.yaml's own file comment for
// that distinction. It builds the `records` value sale.yaml's `sale` flow sends as-is.
//
// pacificMidnightUtc deliberately doesn't depend on a timezone package (this sandbox had no network path to
// verify a real published version number against, and a correctness-critical conversion for an official state
// submission isn't the place to guess one): US daylight saving - 2nd Sunday of March to 1st Sunday of November,
// a fixed rule unchanged since the Energy Policy Act of 2005 - is simple enough to hand-roll exactly, and this
// was checked against Python's real zoneinfo('America/Los_Angeles') for every single day across 2024-2028 (0
// mismatches) before being ported.
//
// SM-11: held to golden vectors generated from selling.py itself (../../mazama_modules/selling/vectors/
// sale_record.json and sale_date.json; test/selling_vectors_test.dart), so the phone and the server send the same
// record for the same sale: one record per lot with its quantity (SM-D5), empty notes (SM-D4), the same date
// forms (SM-D6), Pacific midnight around every DST switch 2024-2030.

const doseInitial = 'initial';
const doseSecondary = 'secondary';

DateTime _nthWeekday(int year, int month, int weekday, int n) {
  var d = DateTime.utc(year, month, 1);
  final delta = (weekday - d.weekday) % 7;
  d = d.add(Duration(days: delta));
  return d.add(Duration(days: 7 * (n - 1)));
}

/// Pacific midnight of [date] (year/month/day only - any time-of-day on it is ignored), as a UTC DateTime.
/// 07:00Z in daylight time, 08:00Z in standard time - same as pacific_midnight_utc in selling.py.
DateTime pacificMidnightLocalAsUtc(DateTime date) {
  final dstStart = _nthWeekday(date.year, 3, DateTime.sunday, 2); // 2nd Sunday of March
  final dstEnd = _nthWeekday(date.year, 11, DateTime.sunday, 1); // 1st Sunday of November
  final day = DateTime.utc(date.year, date.month, date.day);
  final isDst = day.isAfter(dstStart) && !day.isAfter(dstEnd);
  final offsetHours = isDst ? -7 : -8;
  return day.subtract(Duration(hours: offsetHours));
}

/// The same string pacific_midnight_utc returns: "2026-10-11T07:00:00.000Z".
String pacificMidnightUtc(DateTime date) {
  final u = pacificMidnightLocalAsUtc(date);
  String p2(int n) => n.toString().padLeft(2, '0');
  String p4(int n) => n.toString().padLeft(4, '0');
  return '${p4(u.year)}-${p2(u.month)}-${p2(u.day)}T${p2(u.hour)}:${p2(u.minute)}:${p2(u.second)}.000Z';
}

/// The record the state system's own web page sends to CreateSalesRecords, for [qty] units of [item] at
/// [priceCents] each. [item] is one row from the public /p/packages/{state_id} endpoint - needs productGuid,
/// productType, id, weightPerUnit, analyteWeight, and serviceCenterId (cart_page.dart adds the selected center's).
/// Field-for-field the same shape as selling.py's build_sale, including the fields the state ignores on
/// create (id, isRefund, dateCreated, saleNumber - all blank/zero, same as the real web page sends).
Map<String, Object?> buildSale(
  Map<String, Object?> item,
  int priceCents,
  DateTime saleDate, {
  String dose = doseInitial,
  int qty = 1,
}) {
  final price = priceCents / 100;
  return {
    'id': 0,
    'productGuid': item['productGuid'],
    'productGroup': item['productType'],
    'productId': item['id'],
    'numberSold': qty,
    // From whole cents, so there is no binary rounding to disagree about: the same value as selling.py's
    // round(price * qty, 2) in every case (sale_record.json; checked over every price to $1,000 x 59 units).
    'productCost': priceCents * qty / 100,
    'dateOfSale': pacificMidnightUtc(saleDate),
    'weightPerUnit': item['weightPerUnit'],
    'analyteWeight': item['analyteWeight'],
    'deleted': false,
    'deletedBy': null,
    'dateDeleted': null,
    'reasonDeleted': null,
    'notes': '', // SM-D4: empty on both sides, never the description
    'serviceCenterId': item['serviceCenterId'],
    'changes': null,
    'wasteOuts': <Object?>[],
    'isRefund': '',
    'dateCreated': '',
    'saleNumber': '',
    'costEach': price,
    'initialDose': dose == doseInitial ? qty : 0,
    'secondaryDose': dose == doseSecondary ? qty : 0,
  };
}

/// A defensive check that [created] (sale.yaml's own `created` output - normally the state's own copy of every
/// record just submitted, each given the same real saleNumber since they all went up in one request - see that
/// file's own comment) actually looks like a confirmed sale for every one of the [expectedCount] records just
/// sent, not just some other non-empty body. flow_runner.dart's own `then_require: truthy` check only confirms
/// the response wasn't empty - which would also pass for some other non-empty-but-wrong body (a changed
/// response shape, or a logical-error payload that happens to be non-empty) if the state system's own API ever
/// drifted. CartPage._sell runs this second, shape-aware check before ever treating a 200 response as an
/// actually-confirmed sale and clearing the cart over it.
///
/// The same three checks as the server's salejobs.py, and the same outcome when one fails (SM-D2: "may have
/// been recorded" on both sides): one record back per record sent, every one with a non-blank saleNumber, and
/// all of them the *same* saleNumber, since they went up in one request.
bool looksLikeConfirmedSale(Object? created, int expectedCount) {
  if (created is! List || created.length != expectedCount || created.isEmpty) return false;
  final numbers = created.map((r) => r is Map ? (r['saleNumber']?.toString() ?? '') : '').toSet();
  return numbers.length == 1 && numbers.single.isNotEmpty;
}

final _dateDashed = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _dateCompact = RegExp(r'^(\d{4})(\d{2})(\d{2})$');
final _weekDashed = RegExp(r'^(\d{4})-W(\d{2})(?:-(\d))?$');
final _weekCompact = RegExp(r'^(\d{4})W(\d{2})(\d)?$');

bool _isLeap(int y) => y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);

/// The date [text] names, in exactly the forms Python's date.fromisoformat reads, or null. SM-D6: `2026-10-20`,
/// `20261020`, `2026-W43` (its Monday), `2026W43`, `2026-W43-2`, `2026W432` - not ordinal dates, times or spaces.
/// `\d` here is ASCII digits only, as in Python's parser.
DateTime? _isoDate(String text) {
  var m = _dateDashed.firstMatch(text) ?? _dateCompact.firstMatch(text);
  if (m != null) {
    final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
    if (y < 1 || mo < 1 || mo > 12 || d < 1) return null;
    final date = DateTime.utc(y, mo, d);
    return date.month == mo && date.day == d ? date : null; // rejects 2026-02-30 rather than rolling it over
  }
  m = _weekDashed.firstMatch(text) ?? _weekCompact.firstMatch(text);
  if (m == null) return null;
  final y = int.parse(m.group(1)!), week = int.parse(m.group(2)!);
  final day = m.group(3) == null ? 1 : int.parse(m.group(3)!);
  if (y < 1 || day < 1 || day > 7 || week < 1 || week > 53) return null;
  if (week == 53) {
    // A year has an ISO week 53 when it starts on a Thursday, or on a Wednesday in a leap year.
    final jan1 = DateTime.utc(y, 1, 1).weekday;
    if (!(jan1 == DateTime.thursday || (jan1 == DateTime.wednesday && _isLeap(y)))) return null;
  }
  final jan4 = DateTime.utc(y, 1, 4);
  final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
  return week1Monday.add(Duration(days: (week - 1) * 7 + (day - 1)));
}

/// Throws a FormatException('bad') for anything that isn't a date in a form the server's parse_sale_date reads
/// (see _isoDate), or FormatException('future') for a date after [today] - the same two cases selling.py
/// distinguishes, same messages to match on. Held to mazama_modules/selling/vectors/sale_date.json.
DateTime parseSaleDate(String text, DateTime today) {
  final date = _isoDate(text);
  if (date == null) throw const FormatException('bad');
  final todayDate = DateTime.utc(today.year, today.month, today.day);
  if (date.isAfter(todayDate)) throw const FormatException('future');
  return date;
}
