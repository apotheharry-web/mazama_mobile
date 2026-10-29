// The guard for specs/foundations LS-R7: what the phone keeps goes through lib/local_store.dart (one SQLite database of
// documents per data folder) and the session's tokens through lib/secret_store.dart. A new file write anywhere else
// in lib/ fails here, naming the file and line. Like the server's security tests, it is never weakened to make a
// change pass: move the new data into LocalStore instead.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The calls that write a file, or make one to read or write.
final _fileWrite = RegExp(r'writeAsStringSync|writeAsBytesSync|writeAsString\(|writeAsBytes\(|\bFile\(|File\.fromUri\('
    r'|openWrite\(|openSync\(|copySync\(|\.copy\(|RandomAccessFile');

/// The files allowed to: LocalStore itself and its legacy import; session_store.dart (moving and deleting an older
/// build's session.json); the sign-in spec and host list, which stay files (plan P-D4); reconcile_page.dart (the image
/// it shares); and the debug pages (kDebugMode builds only).
bool _allowed(String path) {
  final name = path.split('/').last;
  return const {
        'lib/local_store.dart',
        'lib/local_store_import.dart',
        'lib/session_store.dart',
        'lib/login_spec_store.dart',
        'lib/login_hosts_store.dart',
        'lib/reconcile_page.dart',
      }.contains(path) ||
      RegExp(r'^debug_.*_page\.dart$').hasMatch(name);
}

List<File> _libFiles() => [
      for (final e in Directory('lib').listSync(recursive: true))
        if (e is File && e.path.endsWith('.dart')) e,
    ]..sort((a, b) => a.path.compareTo(b.path));

String _relative(File f) => f.path.replaceAll(Platform.pathSeparator, '/');

void main() {
  test('no file is written under lib/ outside LocalStore and the allowed files', () {
    final found = <String>[];
    for (final file in _libFiles()) {
      final path = _relative(file);
      if (_allowed(path)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue; // comments may name the calls
        if (_fileWrite.hasMatch(line)) found.add('$path:${i + 1}: ${line.trim()}');
      }
    }
    expect(found, isEmpty,
        reason: 'keep it in LocalStore (lib/local_store.dart) instead of a file:\n${found.join('\n')}');
  });

  test('the guard sees lib/ (it is run from the app folder) and would catch a file write', () {
    expect(_libFiles().map(_relative), contains('lib/cart_store.dart'));
    expect(_fileWrite.hasMatch("File('x').writeAsStringSync('y');"), isTrue);
    for (final call in ["File.fromUri(u)", "f.openWrite()", "f.openSync(mode: FileMode.write)", "f.copySync('b')", "RandomAccessFile r"]) {
      expect(_fileWrite.hasMatch(call), isTrue, reason: call);
    }
    expect(_allowed('lib/cart_store.dart'), isFalse);
    expect(_allowed('lib/debug_local_storage_page.dart'), isTrue);
  });

  test('on Android and iOS the session never reaches LocalStore', () {
    final secretStore = File('lib/secret_store.dart').readAsStringSync();
    final start = secretStore.indexOf('class PlatformSecretStore');
    expect(start, isNot(-1));
    final end = secretStore.indexOf('\n}\n', start);
    final platformClass = secretStore.substring(start, end);
    expect(platformClass, isNot(contains('LocalStore')));
    expect(platformClass, isNot(contains('File(')));
    // The phones' branch of secretStoreFor is the platform store, and only that.
    expect(secretStore, contains('Platform.isAndroid || Platform.isIOS ? const PlatformSecretStore() : DocumentSecretStore(dir)'));
    // SessionStore keeps the tokens only through its SecretStore. Its one LocalStore document is the non-secret install
    // marker (final review I-2): every LocalStore call there names that marker, and nothing else.
    final sessionStore = File('lib/session_store.dart').readAsLinesSync();
    final localCalls = [
      for (final l in sessionStore)
        if (RegExp(r'\blocal\.(read|write|delete|names|transaction)\(').hasMatch(l)) l.trim()
    ];
    expect(localCalls, isNotEmpty);
    for (final call in localCalls) {
      expect(call, matches(RegExp(r'^(if \()?local\.(read|write)\(installMarker[,)]')), reason: call);
    }
    expect(sessionStore.where((l) => l.contains('LocalStore.forDir(')).length, 1);
    expect(sessionStore.join('\n'), contains("local.write(installMarker, 'opened by this install; holds no secret')"));
  });
}
