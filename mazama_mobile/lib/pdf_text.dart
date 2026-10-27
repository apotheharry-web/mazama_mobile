// A lab report PDF's text layer as CoaText (mazama_modules/coa/schema/coa_text.schema.json), read with pdfium
// through pdfrx: what the shared reader (lib/coa_core_ffi.dart) parses on the phone. Plan 08 Task 7
// (specs/coa/08-phone-label-debug.md, "Phone text extraction").
//
// pdfium hands over characters with boxes; [groupWords] joins them into words the way the server's poppler words
// look, close enough for coa_core, whose line and column matching has tolerances. pdfium's boxes are each glyph's
// ink, not the font's box, so a '.' or '-' is small: a word continues while the next glyph sits on the word's
// line (its middle inside the word's height, or the word's middle inside the glyph's) and the gap to it is at most
// half that height. Tried on every corpus case with pdfium, a quarter of the height split "7.12" after its '.'.
//
// No OCR on the phone: a page without a text layer comes back with `source: none` and no words.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pdfrx/pdfrx.dart';

/// Names this extractor in CoaText's `extractor`.
const pdfTextExtractor = 'pdf_text.dart 1';

/// One character and its box in PDF points, origin at the top-left of the page (y grows downwards).
class PdfCharBox {
  final String ch;
  final double x0, y0, x1, y1;
  const PdfCharBox(this.ch, this.x0, this.y0, this.x1, this.y1);
}

/// pdfium couldn't be started or couldn't open the file as a PDF.
class PdfTextUnavailable implements Exception {
  final String message;
  const PdfTextUnavailable(this.message);
  @override
  String toString() => 'PdfTextUnavailable: $message';
}

double _r2(double v) => (v * 100).roundToDouble() / 100;

/// [chars] (in the PDF's reading order) as CoaText words: `{text, x0, y0, x1, y1, conf: null}`, a word's box the
/// union of its characters', rounded to 2 places and sorted by (y0, x0, x1, text). Whitespace ends a word, as do a
/// gap wider than half the word's height, a step back to the left, and a character on another line.
List<Map<String, Object?>> groupWords(List<PdfCharBox> chars) {
  final words = <_Word>[];
  _Word? cur;
  for (final c in chars) {
    if (c.ch.trim().isEmpty) {
      cur = null;
      continue;
    }
    final w = cur;
    if (w != null && w.takes(c)) {
      w.add(c);
    } else {
      words.add(cur = _Word(c));
    }
  }
  final out = [for (final w in words) w.toJson()];
  int cmp(Map<String, Object?> a, Map<String, Object?> b) {
    for (final k in const ['y0', 'x0', 'x1']) {
      final d = (a[k] as double).compareTo(b[k] as double);
      if (d != 0) return d;
    }
    return (a['text'] as String).compareTo(b['text'] as String);
  }

  return out..sort(cmp);
}

class _Word {
  final StringBuffer text;
  double x0, y0, x1, y1, lastX1;
  _Word(PdfCharBox c)
      : text = StringBuffer(c.ch),
        x0 = c.x0,
        y0 = c.y0,
        x1 = c.x1,
        y1 = c.y1,
        lastX1 = c.x1;

  /// [c] continues this word: on its line, and neither a wide gap nor a step back to the left away.
  bool takes(PdfCharBox c) {
    final h = math.max(y1 - y0, c.y1 - c.y0);
    final mid = (c.y0 + c.y1) / 2, wordMid = (y0 + y1) / 2;
    final sameLine = (mid >= y0 && mid <= y1) || (wordMid >= c.y0 && wordMid <= c.y1);
    return sameLine && c.x0 - lastX1 <= 0.5 * h && c.x0 >= lastX1 - 0.5 * h;
  }

  void add(PdfCharBox c) {
    text.write(c.ch);
    x0 = math.min(x0, c.x0);
    y0 = math.min(y0, c.y0);
    x1 = math.max(x1, c.x1);
    y1 = math.max(y1, c.y1);
    lastX1 = c.x1;
  }

  Map<String, Object?> toJson() =>
      {'text': text.toString(), 'x0': _r2(x0), 'y0': _r2(y0), 'x1': _r2(x1), 'y1': _r2(y1), 'conf': null};
}

/// pdfium's box for a character - points from the bottom-left of the page before its /Rotate, top > bottom - as
/// a box from the top-left of the page as shown, turned [quarterTurns] clockwise. [width] and [height] are the
/// page's size as shown (pdfrx's PdfPage.width/height). Poppler, and so the server's words, use the page as shown.
PdfCharBox charBoxTopLeft(String ch, double left, double top, double right, double bottom,
    {required int quarterTurns, required double width, required double height}) {
  final turns = quarterTurns & 3;
  final w0 = turns.isOdd ? height : width, h0 = turns.isOdd ? width : height; // the page before rotation
  return switch (turns) {
    0 => PdfCharBox(ch, left, h0 - top, right, h0 - bottom),
    1 => PdfCharBox(ch, bottom, left, top, right),
    2 => PdfCharBox(ch, w0 - right, bottom, w0 - left, top),
    _ => PdfCharBox(ch, h0 - top, w0 - right, h0 - bottom, w0 - left),
  };
}

/// The CoaText of [pdf]. [initialize] starts pdfium (the app's: pdfrx's Flutter initializer; tests pass pdfrx's
/// Dart one). Throws [PdfTextUnavailable] when pdfium can't start or the bytes don't open as a PDF.
Future<Map<String, Object?>> extractCoaText(Uint8List pdf, {Future<void> Function()? initialize}) async {
  final doc = await _open(pdf, initialize);
  try {
    final pages = <Map<String, Object?>>[];
    for (final (i, page) in doc.pages.indexed) {
      final raw = await page.loadText();
      final chars = <PdfCharBox>[];
      if (raw != null) {
        final codes = raw.fullText.runes.toList();
        final n = codes.length < raw.charRects.length ? codes.length : raw.charRects.length;
        for (var j = 0; j < n; j++) {
          final r = raw.charRects[j];
          chars.add(charBoxTopLeft(String.fromCharCode(codes[j]), r.left, r.top, r.right, r.bottom,
              quarterTurns: page.rotation.index, width: page.width, height: page.height));
        }
      }
      final words = groupWords(chars);
      pages.add({
        'index': i,
        'width': _r2(page.width),
        'height': _r2(page.height),
        'source': words.isEmpty ? 'none' : 'text_layer',
        'engine': 'pdfium',
        'words': words,
      });
    }
    return {
      'version': 1,
      'source_sha256': sha256.convert(pdf).toString(),
      'extractor': pdfTextExtractor,
      'pages': pages,
    };
  } finally {
    await doc.dispose();
  }
}

Future<PdfDocument> _open(Uint8List pdf, Future<void> Function()? initialize) async {
  try {
    if (initialize != null) {
      await initialize();
    } else {
      await pdfrxFlutterInitialize();
    }
    return await PdfDocument.openData(pdf, sourceName: 'coa-${sha256.convert(pdf)}');
  } catch (e) {
    // a missing pdfium library surfaces as an ArgumentError (an Error, not an Exception), so everything is caught
    throw PdfTextUnavailable('$e');
  }
}
