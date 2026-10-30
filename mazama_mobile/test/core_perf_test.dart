// CR-R6 (specs/core): the hot paths through the core stay within budget on CI's machine: a stock summary and its pies
// over 2,000 rows (row 8), and a scan match over 500 packages (row 1). Only the core call is timed (its input map is
// built once, outside the timer; the call's own JSON encode and decode are in). The budget is CR-R6's 20 ms with
// headroom for a debug (JIT) run in a shared bundle beside five others: 100 ms, the median of five runs after one to
// warm up. The core measures about 5 ms for the summary alone (release, the review of Task 14): a regression to a
// per-row or quadratic cost still fails it.
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/mazama_core.dart';
import 'package:mazama_mobile/stock_summary.dart';

import 'support/core.dart';

const _budgetMs = 100;

int _medianMs(void Function() f) {
  f();
  final runs = <int>[];
  for (var i = 0; i < 5; i++) {
    final sw = Stopwatch()..start();
    f();
    runs.add(sw.elapsedMicroseconds);
  }
  runs.sort();
  return (runs[runs.length ~/ 2] / 1000).ceil();
}

void main() {
  late MazamaCore core;
  setUpAll(() => core = loadTestCore());

  final strains = ['Golden Teacher', 'Penis Envy', 'Bluey', 'Avery', 'Mazatec', 'Huautla', 'Ecuador', 'Tidal Wave'];
  final rows = [
    for (var i = 0; i < 2000; i++)
      StockRow(
        productGuid: 'PKPR-${i.toString().padLeft(4, '0')}', id: i, quantity: 1 + i % 9, mazama: i.isEven,
        strain: strains[i % strains.length], description: '${strains[i % strains.length]} ${[25, 20, 15, 10, 5][i % 5]} mg TPE DH',
        unitMgTpe: 24.5 + i % 7, weightPerUnit: 1.2, analyteWeight: 9.1, type: i % 13 == 0 ? 'CH' : 'DH'),
  ];

  test('a stock summary and its pies over 2,000 rows', () {
    final input = {'rows': [for (final r in rows) r.toJson()], 'mg_mode': 'tpe'};
    final summary = core.stockSummarize(input);
    final ms = _medianMs(() => core.stockPies({'summary': core.stockSummarize(input)}));
    expect(summary['total'], greaterThan(0));
    expect(ms, lessThanOrEqualTo(_budgetMs), reason: '$ms ms');
  });

  test('a scan match over 500 packages', () {
    final packages = [
      for (var i = 0; i < 500; i++)
        {
          'guid': 'PKPR-${i.toString().padLeft(4, '0')}',
          'records': [
            {'weightPerUnit': 1.2, 'analyteWeight': 9.1, 'description': '${strains[i % strains.length]} 25 mg TPE DH (2027-08-31)',
             'quantity': 3, 'expires': '2027-08-31'},
          ],
        },
    ];
    final input = {'texts': ['GOLDEN TEACHER', '25 mg TPE', 'Net wt 1.2 g', 'Best by 2027-08-31'], 'packages': packages};
    final ms = _medianMs(() => core.scanClosest(input));
    expect(ms, lessThanOrEqualTo(_budgetMs), reason: '$ms ms');
  });
}
