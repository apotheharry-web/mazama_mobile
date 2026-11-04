// par_columns.dart: the par table's columns chosen on this phone, per center, in their own document.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/local_store.dart';
import 'package:mazama_mobile/par_columns.dart';

late Directory _dir;

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('mazama_par_columns_test_'));
  tearDown(() {
    LocalStore.debugCloseAll();
    _dir.deleteSync(recursive: true);
  });

  ParColumnsStore store() => ParColumnsStore(dataDir: () => _dir);

  test('the columns chosen round-trip per center, sizes other than the strain sizes dropped', () async {
    expect((await store().load(231)).added, isEmpty);
    await store().save(231, const ParColumns(added: {15}, removed: {25, 0}));
    final c = await store().load(231);
    expect([c.added, c.removed], [{15}, {25, 0}]);
    expect((await store().load(183)).removed, isEmpty);
    expect(ParColumns.fromJson({'added': [-1, 7, 'x', 10], 'removed': 'nope'}).added, {10});
  });

  test('kept in the database, not in a file', () async {
    await store().save(231, const ParColumns(added: {15}));
    expect(File('${_dir.path}/par_columns_231.json').existsSync(), isFalse);
    expect(LocalStore.forDir(_dir).read(parColumnsDocument(231)), isNotNull);
  });

  test('a damaged copy counts as nothing chosen', () async {
    LocalStore.forDir(_dir).write(parColumnsDocument(231), '{not json');
    final c = await store().load(231);
    expect([c.added, c.removed], [<int>{}, <int>{}]);
  });
}
