// PDF text for the shared reader: pdfium's characters grouped into words (CoaText, coa_text.schema.json), plan 08
// Task 7. The real lab reports are this app's vendored copies (assets/shared/coa/corpus/real/, tool/sync_flows.sh).
// The corpus test needs the shared reader (COA_CORE_FFI_LIB, built by CI's coa-ffi-build) and pdfium on the host
// (pdfrx downloads it on first use); without either it skips and says why.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/coa_core_ffi.dart';
import 'package:mazama_mobile/pdf_text.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxInitialize;

/// Characters of one line at baseline [top], 10 pt tall, 6 pt wide each, starting at [x] (a space is a gap char).
List<PdfCharBox> _line(String s, {double x = 10, double top = 100, double advance = 6, double width = 6}) => [
      for (var i = 0; i < s.length; i++)
        PdfCharBox(s[i], x + i * advance, top, x + i * advance + width, top + 10),
    ];

List<String> _texts(List<Map<String, Object?>> words) => [for (final w in words) w['text'] as String];

const _real = 'assets/shared/coa/corpus/real';

void main() {
  test('groupWords splits on spaces and gaps', () {
    final words = groupWords([..._line('Psilocybin 9.54'), ..._line('mg/g', x: 200)]);
    expect(_texts(words), ['Psilocybin', '9.54', 'mg/g']);
    expect(words[0]['x0'], 10.0);
    expect(words[0]['x1'], 10.0 + 9 * 6 + 6);
    expect(words[0]['y0'], 100.0);
    expect(words[0]['y1'], 110.0);
    expect(words[0]['conf'], isNull);
  });

  test('groupWords keeps a word with tight kerning together', () {
    // 0.5 pt gaps between letters: well under a quarter of the 10 pt height
    expect(_texts(groupWords(_line('UID:', advance: 6.5))), ['UID:']);
  });

  test('groupWords splits where the gap is wider than half the height', () {
    // pdfium's boxes are the glyphs' ink, so a narrow glyph such as '.' leaves a wide gap inside a word: on the
    // corpus, a quarter of the height split "7.12" in two; half of it splits only real gaps (6 pt here)
    expect(_texts(groupWords(_line('ND0.0990', advance: 12))), ['N', 'D', '0', '.', '0', '9', '9', '0']);
    expect(_texts(groupWords(_line('7.12', advance: 9))), ['7.12']);
  });

  test('groupWords keeps a short glyph on the same line in the word (the hyphen of HB-)', () {
    final chars = [..._line('HB'), PdfCharBox('-', 22.5, 104, 25.5, 105.5), ..._line('2222', x: 26)];
    expect(_texts(groupWords(chars)), ['HB-2222']);
  });

  test('groupWords splits on a line change', () {
    expect(_texts(groupWords([..._line('Sample:'), ..._line('Shakti', x: 52, top: 112)])), ['Sample:', 'Shakti']);
  });

  test('groupWords sorts words top to bottom, then left to right, and rounds to 2 places', () {
    final words = groupWords([..._line('second', top: 120.004), ..._line('b', x: 100.123), ..._line('a')]);
    expect(_texts(words), ['a', 'b', 'second']);
    expect(words[1]['x0'], 100.12);
    expect(words[2]['y0'], 120.0);
  });

  test('a page without characters has no words', () {
    expect(groupWords(const []), isEmpty);
    expect(groupWords(_line('   ')), isEmpty);
  });

  group('charBoxTopLeft turns pdfium\'s box (bottom-left origin, unrotated page) into top-left points on the page as shown', () {
    // a 612 x 792 portrait page; the box: left 100, top 700, right 110, bottom 690 in the unrotated page
    List<double> box(int turns) {
      final b = charBoxTopLeft('x', 100, 700, 110, 690, quarterTurns: turns,
          width: turns.isOdd ? 792 : 612, height: turns.isOdd ? 612 : 792);
      return [b.x0, b.y0, b.x1, b.y1];
    }

    test('unrotated', () => expect(box(0), [100, 92, 110, 102]));
    test('a quarter turn clockwise (/Rotate 90)', () => expect(box(1), [690, 100, 700, 110]));
    test('a half turn', () => expect(box(2), [502, 690, 512, 700]));
    test('three quarter turns', () => expect(box(3), [92, 502, 102, 512]));

    test('the rotated footer of rcl-2505144 page 9 lands where poppler puts it', () {
      // pdfium's box for the "P" of "Page 9 of 14" on that /Rotate 90 page (792 x 612 as shown); poppler: x0 703.65, y0 583.68
      final b = charBoxTopLeft('P', 583.7, 709.8, 591.0, 704.6, quarterTurns: 1, width: 792, height: 612);
      expect([b.x0, b.y0, b.x1, b.y1], [704.6, 583.7, 709.8, 591.0]);
    });
  });

  test('extractCoaText reads every real corpus PDF like the server', () async {
    final core = CoaCore.tryLoad(path: Platform.environment['COA_CORE_FFI_LIB']);
    if (core == null) {
      markTestSkipped('COA_CORE_FFI_LIB is not set (CI sets it after building coa_core_ffi)');
      return;
    }
    if (!Directory(_real).existsSync() && !File('../mazama_modules/vendored.txt').existsSync()) {
      // the public copy of this app (specs/public-app PA-R5): the real lab reports are not published
      markTestSkipped('$_real is not in this copy of the app');
      return;
    }
    final cases = Directory(_real).listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
    expect(cases, hasLength(greaterThanOrEqualTo(4)), reason: 'vendored real cases: run tool/sync_flows.sh');
    for (final dir in cases) {
      final pdf = File('${dir.path}/source.pdf').readAsBytesSync();
      Map<String, Object?> text;
      try {
        text = await extractCoaText(pdf,
            initialize: () => pdfrxInitialize(tmpPath: '${Directory.systemTemp.path}/pdfrx.cache'));
      } on PdfTextUnavailable catch (e) {
        markTestSkipped('pdfium is not available on this host: ${e.message}');
        return;
      }
      final server = jsonDecode(File('${dir.path}/text.server.json').readAsStringSync()) as Map;
      expect(text['version'], 1);
      expect(text['source_sha256'], server['source_sha256'], reason: '${dir.path}: hash of the same bytes');
      expect(text['extractor'], pdfTextExtractor);
      final pages = (text['pages'] as List).cast<Map<String, Object?>>();
      expect(pages.length, (server['pages'] as List).length, reason: '${dir.path}: page count');
      for (final p in pages) {
        expect(p['engine'], 'pdfium');
        expect(p['source'], anyOf('text_layer', 'none'));
        for (final w in (p['words'] as List).cast<Map>()) {
          // every word on its page as shown (a rotated page once came out with y0 below 0)
          expect((w['y0'] as num) >= -1 && (w['x0'] as num) >= -1, isTrue, reason: '${dir.path} page ${p['index']}: $w');
          expect((w['y1'] as num) <= (p['height'] as num) + 1 && (w['x1'] as num) <= (p['width'] as num) + 1, isTrue,
              reason: '${dir.path} page ${p['index']}: $w');
        }
      }

      final got = core.parse(jsonEncode(text));
      final sections = (got['sections'] as List).cast<Map<String, Object?>>();
      final ofRecord = (got['of_record'] as Map).cast<String, Object?>();
      final want = ((jsonDecode(File('${dir.path}/expected.json').readAsStringSync()) as Map)['lots'] as Map)
          .cast<String, Object?>();
      expect(want, isNotEmpty, reason: dir.path);
      for (final MapEntry(key: uid, value: lot as Map) in want.entries) {
        final i = ofRecord[uid.toLowerCase()];
        expect(i, isNotNull, reason: '${dir.path}: $uid is not of record in pdfium\'s parse');
        final s = sections[i as int];
        if (lot.containsKey('status')) expect(s['status'], lot['status'], reason: '${dir.path}: $uid status');
        if (lot['psilocybin'] case final Map want0) {
          final got0 = (s['analytes'] as Map)['psilocybin'] as Map;
          expect([got0['kind'], got0['value']], [want0['kind'], want0['value']], reason: '${dir.path}: $uid psilocybin');
        }
      }
    }
  });
}
