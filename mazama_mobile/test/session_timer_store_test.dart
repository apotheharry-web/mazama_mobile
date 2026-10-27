// SessionTimerStore itself has no Flutter dependency (plain dart:io, like SessionStore/CartStore) but lives
// under test/ alongside everything else in this app - same reasoning as cart_store_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/session_timer_store.dart';

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mazama_session_timer_store_test_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  // Nested one level down from tempDir, so `save` is also proving it creates the directory itself
  // (`create(recursive: true)`) rather than assuming it already exists - same reasoning as cart_store_test.
  SessionTimerStore store() => SessionTimerStore(dataDir: () => Directory('${tempDir.path}/nested'));

  final start = DateTime(2026, 1, 1, 9, 30);

  test('load returns null when nothing has been saved yet', () async {
    expect(await store().load(231), isNull);
  });

  test('save then load round-trips the exact start time', () async {
    final s = store();
    await s.save(231, start);
    expect(await s.load(231), start);
  });

  test('a second save overwrites the first, not appends', () async {
    final s = store();
    await s.save(231, start);
    await s.save(231, start.add(const Duration(minutes: 10)));
    expect(await s.load(231), start.add(const Duration(minutes: 10)));
  });

  test('a timer saved for one center is not returned when loading for a different center', () async {
    final s = store();
    await s.save(231, start);
    expect(await s.load(999), isNull);
  });

  test('clear removes a saved timer, and is a no-op if nothing was ever saved', () async {
    final s = store();
    await s.save(231, start);
    await s.clear();
    expect(await s.load(231), isNull);
    await s.clear(); // must not throw even though there is nothing left to delete
  });

  test('a corrupted file on disk reads back as null, not a crash', () async {
    final s = store();
    await s.save(231, start); // creates the directory for us
    await File('${tempDir.path}/nested/session_timer.json').writeAsString('not json{{{');
    expect(await s.load(231), isNull);
  });

  test('a file missing startMillis reads back as null', () async {
    final s = store();
    await Directory('${tempDir.path}/nested').create(recursive: true);
    await File('${tempDir.path}/nested/session_timer.json').writeAsString('{"centerId": 231}');
    expect(await s.load(231), isNull);
  });

  test('two independent stores pointed at different directories do not see each other\'s data', () async {
    final a = SessionTimerStore(dataDir: () => Directory('${tempDir.path}/a'));
    final b = SessionTimerStore(dataDir: () => Directory('${tempDir.path}/b'));
    await a.save(231, start);
    expect(await b.load(231), isNull);
  });

  test('each cart keeps its own timer; the first cart is the old session_timer.json (specs/multi-cart MC-R1)', () async {
    final s = store();
    final other = start.add(const Duration(minutes: 7));
    await s.save(231, start);
    await s.save(231, other, cartId: 'c2');
    expect(await s.load(231), start);
    expect(await s.load(231, cartId: 'c2'), other);
    await s.clear(cartId: 'c2');
    expect(await s.load(231, cartId: 'c2'), isNull);
    expect(await s.load(231), start);
    expect(File('${tempDir.path}/nested/session_timer.json').existsSync(), isTrue);
  });

  test('a cart remembers the dose it sold until its timer is cleared (specs/multi-cart MC-D14)', () async {
    final s = store();
    final t0 = DateTime(2026, 10, 22, 9);
    await s.saveSoldDose(231, 45, booster: true, cartId: 'c2', now: () => t0);
    expect(await s.loadSoldDose(231, cartId: 'c2'), (psilocybinMg: 45.0, booster: true));
    expect(await s.loadSoldDose(231), isNull); // another cart's
    expect(await s.loadSoldDose(232, cartId: 'c2'), isNull); // another center's
    expect(
        await s.loadSoldDose(231, cartId: 'c2', maxAge: const Duration(hours: 8), now: () => t0.add(const Duration(hours: 9))),
        isNull);
    await s.save(231, start, cartId: 'c2');
    await s.clear(cartId: 'c2');
    expect(await s.loadSoldDose(231, cartId: 'c2'), isNull);
  });
}
