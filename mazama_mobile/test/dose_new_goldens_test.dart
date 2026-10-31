// G3b of specs/core Task 11 (row 5): the phone's cap after the move, measured for the replay diff
// (specs/core/replay/replay_dose.py --phone-new-dump). Over the replay's generated grid (test/fixtures/dose_grid.json.gz,
// written by `replay_dose.py --write-grid`: generated values only, no production data) every sale is answered the way
// the phone sells it: each lot through Package.fromJson (a lot it can't read fails the list, so the product is refused
// whatever it draws: DOSE-18), the sale drawn with allocateBulkSales over its lines and `copies` copies (a draw that
// can't cover them is the phone's own stock refusal), drawnSaleLimitLines, then saleLimits (one copy) or bulkSaleLimits
// (DOSE-17), one verdict per copy as the replay writes it ({total, error, minutes, minutes_initial}). The replay requires
// `phone-new (G3b dump) differs from proposed: 0` (a total compared by its value: the phone holds its figures as doubles,
// so an integer figure 10 reaches the core as 10.0).
//
// Every run prints the answers into the test log (CI can't set an environment variable, so there is no switch), gzipped
// and base64 in numbered lines of 1,000 characters (about 70 for the grid: well inside the last 3,000 lines of CI's
// mobile-test log) between `DOSE-NEW-DUMP BEGIN grid_sha256=... sales=... chunks=...` and `DOSE-NEW-DUMP END`; the
// BEGIN line's sha256 is the grid's JSON (unzipped), so a dump is only read against the grid it was made from. To turn
// a mobile-test log into the replay's --phone-new-dump file, from the repository root (each command line below without
// its leading "//   "):
//
//   grep -oE 'DOSE-NEW-DUMP BEGIN .*' LOG      # check grid_sha256 against `gunzip -c mazama_mobile/test/fixtures/dose_grid.json.gz | sha256sum`
//   grep -oE 'DOSE-NEW-DUMP [0-9]+ [A-Za-z0-9+/=]+' LOG | sort -n -k2 | cut -d' ' -f3 | tr -d '\n' \
//     | base64 -d | gunzip > phone-new-dump.json
//   python3 -c 'import gzip,json,sys; g=json.load(gzip.open(sys.argv[1])); d=json.load(open(sys.argv[2]))
//   assert [s["name"] for s in d["sales"]] == [s["name"] for s in g["limits"]]
//   assert all(len(s["answers"]) == c["copies"] for s, c in zip(d["sales"], g["limits"]))' \
//     mazama_mobile/test/fixtures/dose_grid.json.gz phone-new-dump.json
//
// The same test checks every verdict's shape, so the code it measures stays runnable.
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/bulk_sale.dart';
import 'package:mazama_mobile/dose.dart';
import 'package:mazama_mobile/packages_client.dart';

const _grid = 'test/fixtures/dose_grid.json.gz';
const _gridSha256 = 'bb43f2483c3fdd9e4130ed2d626c608da6f242a0a545a4051e377201cc080354'; // the grid's JSON, unzipped
const _chunk = 1000;

/// replay_dose.py's markers for the two refusals that aren't the core's answer for a draw.
const _unusable = "This sale's psilocybin can't be worked out (a unit's weightPerUnit or analyteWeight is not a usable "
    'number), so it can\'t be sold here.';
const _short = "not enough units in its lots for every line (the phone's own stock check: nothing is sent)";

Map<String, Object?> _refused(String why) => {'total': null, 'error': why, 'minutes': null, 'minutes_initial': null};

/// One grid sale ([products], each `{lots, qty, dose}`, sold [copies] times) as the phone answers it: a verdict per copy.
List<Map<String, Object?>> answer(List<Map<String, Object?>> products, int copies) {
  final lines = <BulkLine>[];
  try {
    for (final p in products) {
      lines.add((lots: [for (final l in p['lots'] as List) Package.fromJson((l as Map).cast<String, Object?>())], qty: p['qty'] as int));
    }
  } catch (_) {
    return List.filled(copies, _refused(_unusable)); // DOSE-18: the product list fails, nothing of it sells
  }
  final draw = allocateBulkSales(lines, copies).perSale;
  if (draw == null) return List.filled(copies, _refused(_short));
  final sales = drawnSaleLimitLines(draw, [for (final p in products) p['dose'] as String]);
  final verdicts = copies == 1 ? saleLimits(sales) : bulkSaleLimits(sales);
  return [for (final v in verdicts) v.toVerdict()];
}

void main() {
  final bytes = File(_grid).readAsBytesSync();
  final text = utf8.decode(gzip.decode(bytes));
  final grid = jsonDecode(text) as Map<String, Object?>;
  final sales = (grid['limits'] as List).cast<Map<String, Object?>>();

  test('the grid is the one the replay wrote', () {
    expect(sha256.convert(utf8.encode(text)).toString(), _gridSha256);
    expect(sales.length, 3864);
  });

  test('every grid sale is answered, one well-formed verdict per copy, and printed into the log', () {
    final out = <Map<String, Object?>>[];
    for (final s in sales) {
      final copies = s['copies'] as int;
      final got = answer((s['products'] as List).cast<Map<String, Object?>>(), copies);
      expect(got.length, copies, reason: '${s['name']}');
      for (final v in got) {
        expect(v.keys.toSet(), {'total', 'error', 'minutes', 'minutes_initial'}, reason: '${s['name']}');
        expect(v['error'] == doseCoreFailedReason, isFalse, reason: '${s['name']}: the core failed');
      }
      out.add({'name': s['name'], 'answers': got});
    }
    final packed = base64.encode(gzip.encode(utf8.encode(jsonEncode({'sales': out}))));
    final chunks = [for (var i = 0; i < packed.length; i += _chunk) packed.substring(i, min(i + _chunk, packed.length))];
    // ignore: avoid_print
    print('DOSE-NEW-DUMP BEGIN grid_sha256=$_gridSha256 sales=${out.length} chunks=${chunks.length}');
    for (var i = 0; i < chunks.length; i++) {
      // ignore: avoid_print
      print('DOSE-NEW-DUMP $i ${chunks[i]}');
    }
    // ignore: avoid_print
    print('DOSE-NEW-DUMP END');
    expect(chunks.length, lessThan(1000), reason: "the dump must stay inside the mobile-test log's last 3,000 lines");
  });
}
