// SP-R18: a rule about a state record is the shared core's (records.judge, selling.sellable), not a read of the
// record's flags in Dart. This guard fails when a lib/ file reads zeroOut, locked, flagged, pendingTransfer or
// failedTest from a map (`r['zeroOut']`, `r.containsKey('locked')`), or lists two or more of those keys, one of them
// zeroOut, pendingTransfer or failedTest (a loop over the key names), naming the file and line. Comments are not
// code; a key written into a map (`'zeroOut': false`) is not a read. The server's twin is
// mazama_sales/tests/unit/test_recordrules_guard.py. Never weaken it to make a change pass: ask the core instead.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _keys = ['zeroOut', 'locked', 'flagged', 'pendingTransfer', 'failedTest'];

/// Not words: "locked" and "flagged" are also hold names and ordinary text.
const _recordOnly = ['zeroOut', 'pendingTransfer', 'failedTest'];

/// The files that build or trim records rather than judge them, each with why.
const _allowed = {
  // StockRow's JSON shape, the row the core's stock rules read (its round trip, never a decision)
  'lib/stock_summary.dart',
  // the keys a record is trimmed to before the core judges it (_readKeys)
  'lib/sellability.dart',
  // the demo's own invented records: it writes them, and leaves its locked one out of /p/packages as the server does
  'lib/demo/demo_backend.dart',
};

final _keyAlt = _keys.join('|');
final _read = RegExp('''\\[\\s*['"]($_keyAlt)['"]\\s*\\]|containsKey\\(\\s*['"]($_keyAlt)['"]''');
final _keyLiteral = RegExp('''['"]($_keyAlt)['"]''');

/// [line] up to a `//` comment outside a string literal.
String _code(String line) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
    } else if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '/' && i + 1 < line.length && line[i + 1] == '/') {
      return line.substring(0, i);
    }
  }
  return line;
}

/// The lines of [source] that read a guarded key, as "line: text".
List<String> _reads(String source) {
  final out = <String>[];
  for (final (i, line) in source.split('\n').indexed) {
    final code = _code(line);
    final listed = {for (final m in _keyLiteral.allMatches(code)) m.group(1)!};
    // a key put into a map literal ('zeroOut': x) is a write: drop those before counting a list of keys
    final written = {for (final m in RegExp('''['"]($_keyAlt)['"]\\s*:''').allMatches(code)) m.group(1)!};
    final names = listed.difference(written);
    if (_read.hasMatch(code) || (names.length >= 2 && names.any(_recordOnly.contains))) out.add('${i + 1}: ${line.trim()}');
  }
  return out;
}

void main() {
  test('no lib/ file outside the allowed ones reads a record flag', () {
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || _allowed.contains(path)) continue;
      found.addAll([for (final r in _reads(f.readAsStringSync())) '$path:$r']);
    }
    expect(found, isEmpty, reason: 'ask the core (records.judge, selling.sellable) instead:\n${found.join('\n')}');
  });

  test('the allowed files exist', () {
    for (final f in _allowed) {
      expect(File(f).existsSync(), isTrue, reason: f);
    }
  });

  test('the guard sees each form of a read, and not a comment, a string or a write', () {
    expect(_reads("final z = r['zeroOut'] == true;"), hasLength(1));
    expect(_reads('if (record["locked"] != true) {}'), hasLength(1));
    expect(_reads("if (r.containsKey('failedTest')) {}"), hasLength(1));
    expect(_reads("for (final k in const ['zeroOut', 'flagged']) {}"), hasLength(1));
    expect(_reads("final x = 1; // r['zeroOut']"), isEmpty);
    expect(_reads("const t = 'locked, flagged or pending a transfer';"), isEmpty);
    expect(_reads("final m = {'zeroOut': false, 'locked': false, 'pendingTransfer': false};"), isEmpty);
    expect(_reads("final u = 'https://example.com'; final z = r['pendingTransfer'];"), hasLength(1));
  });
}
