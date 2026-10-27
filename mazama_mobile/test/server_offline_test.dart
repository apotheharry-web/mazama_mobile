// What the phone does with Mazama's own pages while Mazama's server can't be reached (lib/server_offline.dart): a read
// keeps each reply with when, and shows that copy (with its date) only when the server can't be reached; a 4xx, or no
// copy kept, is the error as before.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/par_client.dart';
import 'package:mazama_mobile/server_offline.dart';

void main() {
  final at = DateTime.utc(2026, 10, 21, 13, 5);

  group('readWithCache', () {
    test('a reply is kept, stamped with the clock in UTC, and returned as fresh', () async {
      final kept = <(String, DateTime)>[];
      final read = await readWithCache<String>(
        fetch: () async => 'reply',
        save: (v, t) async => kept.add((v, t)),
        load: () async => fail('nothing is read back while the server answers'),
        now: () => at.toLocal(),
      );
      expect(read.value, 'reply');
      expect(read.fromCache, isFalse);
      expect(read.cachedAt, isNull);
      expect(kept.single.$1, 'reply');
      expect(kept.single.$2, at);
      expect(kept.single.$2.isUtc, isTrue);
    });

    test('a copy that cannot be kept still returns the reply', () async {
      final read = await readWithCache<String>(
          fetch: () async => 'reply', save: (v, t) async => throw const FileSystemException('full'), load: () async => null);
      expect(read.value, 'reply');
    });

    test('unreachable: the copy kept, with its time', () async {
      final read = await readWithCache<String>(
        fetch: () async => throw ParError('cannot reach x: SocketException', unreachable: true),
        save: (v, t) async => fail('nothing new to keep'),
        load: () async => ServerRead.cached('old', at),
      );
      expect(read.value, 'old');
      expect(read.fromCache, isTrue);
      expect(read.cachedAt, at);
    });

    test('a bare connection error counts as unreachable too', () async {
      final read = await readWithCache<String>(
          fetch: () async => throw const SocketException('down'), save: (v, t) async {}, load: () async => ServerRead.cached('old', at));
      expect(read.value, 'old');
    });

    test('unreachable with no copy kept (or one that cannot be read): the error as before', () async {
      await expectLater(
        readWithCache<String>(
            fetch: () async => throw ParError('cannot reach x', unreachable: true), save: (v, t) async {}, load: () async => null),
        throwsA(isA<ParError>().having((e) => e.message, 'message', 'cannot reach x')),
      );
      await expectLater(
        readWithCache<String>(
            fetch: () async => throw ParError('cannot reach x', unreachable: true),
            save: (v, t) async {},
            load: () async => throw const FormatException('damaged')),
        throwsA(isA<ParError>()),
      );
    });

    test("a 4xx is the server's own answer: the error, even with a copy kept", () async {
      await expectLater(
        readWithCache<String>(
            fetch: () async => throw ParError('No such service center.'),
            save: (v, t) async {},
            load: () async => ServerRead.cached('old', at)),
        throwsA(isA<ParError>().having((e) => e.message, 'message', 'No such service center.')),
      );
    });
  });

  test('the notice says the server cannot be reached and when the copy is from, in the phone\'s time', () {
    final local = DateTime(2026, 10, 21, 18, 5);
    expect(formatAsOf(local), 'Oct 21, 2026 at 6:05 PM');
    expect(formatAsOf(DateTime(2026, 1, 2, 0, 0)), 'Jan 2, 2026 at 12:00 AM');
    expect(formatAsOf(DateTime(2026, 1, 2, 12, 30)), 'Jan 2, 2026 at 12:30 PM');
    expect(serverOfflineNotice(local),
        "Mazama's server can't be reached - showing what it last sent on Oct 21, 2026 at 6:05 PM.");
    expect(serverOfflineNotice(null), "Mazama's server can't be reached - showing what it last sent.");
    expect(serverTryLater, "Mazama's server can't be reached - try again later.");
  });

  testWidgets('the notice banner shows the words, an extra sentence and an optional Retry', (tester) async {
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ServerOfflineNotice(cachedAt: at, extra: 'More later.', onRetry: () => retried++)),
    ));
    expect(find.text('${serverOfflineNotice(at)} More later.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ServerOfflineNotice(cachedAt: at))));
    expect(find.text(serverOfflineNotice(at)), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
