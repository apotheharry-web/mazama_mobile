// stateDateIso (lib/state_date.dart): a state-site date as ISO, for the sales history's dateOfSale. MM/DD/YYYY with
// one-digit month or day, a time after a space ignored; ISO with or without a time; an impossible date is null, never
// rolled over.
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/state_date.dart';

void main() {
  test('MM/DD/YYYY, one-digit month and day allowed', () {
    expect(stateDateIso('05/27/2025'), '2025-05-27');
    expect(stateDateIso('6/5/2026'), '2026-06-05');
    expect(stateDateIso('12/1/2026'), '2026-12-01');
  });

  test('a time after a space is ignored', () {
    expect(stateDateIso('6/5/2026 10:00'), '2026-06-05');
    expect(stateDateIso('05/27/2025 3:14:00 PM'), '2025-05-27');
    expect(stateDateIso('  05/27/2025  '), '2025-05-27');
  });

  test('ISO with and without a time', () {
    expect(stateDateIso('2026-03-04'), '2026-03-04');
    expect(stateDateIso('2026-03-04T10:15:00Z'), '2026-03-04');
    expect(stateDateIso('2026-03-04 10:15:00'), '2026-03-04');
  });

  test('impossible dates are null, never rolled over', () {
    expect(stateDateIso('02/30/2026'), isNull);
    expect(stateDateIso('13/45/2026'), isNull);
    expect(stateDateIso('00/10/2026'), isNull);
    expect(stateDateIso('04/31/2026'), isNull);
    expect(stateDateIso('2026-02-30'), isNull);
  });

  test('02/29 only in a leap year', () {
    expect(stateDateIso('02/29/2024'), '2024-02-29');
    expect(stateDateIso('2/29/2000'), '2000-02-29');
    expect(stateDateIso('02/29/2025'), isNull);
    expect(stateDateIso('02/29/1900'), isNull);
  });

  test('anything else is null', () {
    expect(stateDateIso(null), isNull);
    expect(stateDateIso(''), isNull);
    expect(stateDateIso('May 27, 2025'), isNull);
    expect(stateDateIso('2025/05/27'), isNull);
  });
}
