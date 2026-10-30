// specs/app-updates AU-R1, AU-R2: the signed release file on the phone (app_release.dart), held to the shared vectors
// ../mazama_modules/flows/contracts/app_release_vectors.json (vendored at assets/shared/flows/contracts/ by
// tool/sync_flows.sh), which the server's app_release.py passes too. The vectors' key is the TEST key, injected here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/app_release.dart';
import 'package:mazama_mobile/login_hosts_store.dart' show verifiedHostList;
import 'package:mazama_mobile/login_spec_store.dart' show usableLoginSpec;
import 'package:mazama_mobile/signing.dart';

final _vectors =
    jsonDecode(File('assets/shared/flows/contracts/app_release_vectors.json').readAsStringSync()) as Map<String, Object?>;
final _cases = (_vectors['cases'] as List).cast<Map<String, Object?>>();
final _signed = (_vectors['signed'] as List).cast<Map<String, Object?>>();
final _today = DateTime.parse('${_vectors['today']}T12:00:00Z');
final _key = _vectors['public_key'] as String;
const _keyNames = {'kind', 'version', 'build', 'apk', 'sha256', 'size', 'minSdk'};

void main() {
  test('the limits are the shared ones', () {
    expect(_vectors['max_bytes'], maxReleaseFileBytes);
    expect(_cases.map((c) => c['name']).toSet(), hasLength(_cases.length));
    expect(_cases.where((c) => c['valid'] == true), isNotEmpty);
  });

  group('every case parses as the vectors say', () {
    for (final c in _cases) {
      test('${c['name']}: ${c['valid'] == true ? 'valid' : 'invalid'}', () {
        final text = c['text'] as String;
        if (c['valid'] == true) {
          final (version, build, apk, sha, size, minSdk) = parseReleaseFile(text, today: _today);
          expect([version, build, apk, sha, size, minSdk],
              [c['version'], c['build'], c['apk'], c['sha256'], c['size'], c['minSdk']]);
        } else {
          expect(() => parseReleaseFile(text, today: _today), throwsFormatException, reason: c['why'] as String?);
        }
      });
    }
  });

  group('every signed case verifies as the vectors say', () {
    for (final c in _signed) {
      test('${c['name']} (as ${c['as']})', () async {
        final text = c['text'] as String;
        final signature = c['signature'] as String;
        switch (c['as']) {
          case 'release':
            final got = await verifiedReleaseFile(text, signature, today: _today, publicKey: _key);
            expect(got != null, c['ok']);
            if (got != null) {
              expect(got.text, text);
              expect(got.signature, signature);
              expect(got.build, 26103001);
            }
          case 'host_list':
            expect(await verifySigned(utf8.encode(text), signature, publicKey: _key), isTrue);
            expect(await verifiedHostList(text, signature, publicKey: _key) != null, c['ok']);
          case 'login_spec':
            expect(await verifySigned(utf8.encode(text), signature, publicKey: _key), isTrue);
            expect(usableLoginSpec(text) != null, c['ok']);
          default:
            fail('unknown reader ${c['as']}');
        }
      });
    }
  });

  test('a refusal names no part of the text', () {
    for (final c in _cases.where((c) => c['valid'] != true)) {
      final text = c['text'] as String;
      String message = '';
      try {
        parseReleaseFile(text, today: _today);
      } on FormatException catch (e) {
        message = e.message;
      }
      for (var i = 0; i + 6 <= text.length; i++) {
        final piece = text.substring(i, i + 6);
        if (piece.trim() != piece || piece.split('').toSet().length < 2) continue;
        if (_keyNames.any((k) => k.contains(piece))) continue;
        expect(message.contains(piece), isFalse, reason: '${c['name']}: "$piece" in "$message"');
      }
    }
  });

  test('none verifies nothing', () async {
    final good = _signed.firstWhere((c) => c['name'] == 'good');
    expect(await verifiedReleaseFile(good['text'] as String, good['signature'] as String, publicKey: noSigningKey),
        isNull);
    expect(await verifiedReleaseFile(good['text'] as String, good['signature'] as String, publicKey: _key), isNotNull);
  });

  test('without today the date bound is skipped', () {
    final lateCase = _cases.firstWhere((c) => c['name'] == 'build_dated_after_tomorrow');
    expect(parseReleaseFile(lateCase['text'] as String).$2, 26110101);
    expect(() => parseReleaseFile(lateCase['text'] as String, today: _today), throwsFormatException);
    final notADate = _cases.firstWhere((c) => c['name'] == 'build_not_a_date');
    expect(() => parseReleaseFile(notADate['text'] as String), throwsFormatException);
  });

  test("the date bound follows the checker's day", () {
    final tomorrow = _cases.firstWhere((c) => c['name'] == 'build_dated_tomorrow');
    expect(parseReleaseFile(tomorrow['text'] as String, today: _today).$2, 26103101);
    expect(() => parseReleaseFile(tomorrow['text'] as String, today: _today.subtract(const Duration(days: 1))),
        throwsFormatException);
  });

  test('every one-byte change of a signed file or its signature is refused', () async {
    final good = _signed.firstWhere((c) => c['name'] == 'good');
    final text = good['text'] as String;
    final signature = good['signature'] as String;
    expect(await verifiedReleaseFile(text, signature, today: _today, publicKey: _key), isNotNull);
    final bytes = utf8.encode(text);
    for (var i = 0; i < bytes.length; i++) {
      final changed = [...bytes]..[i] ^= 0x01;
      final t = utf8.decode(changed, allowMalformed: true);
      expect(await verifiedReleaseFile(t, signature, today: _today, publicKey: _key), isNull, reason: 'byte $i');
    }
    for (var i = 0; i < signature.length; i++) {
      final units = signature.codeUnits.toList()..[i] ^= 0x01;
      expect(await verifiedReleaseFile(text, String.fromCharCodes(units), today: _today, publicKey: _key), isNull,
          reason: 'signature $i');
    }
  });

  test('the bundled signing.pub is exactly one key line (AU-D12: no list of keys)', () {
    final text = File(signingPublicKeyAsset).readAsStringSync();
    expect(text.trimRight().split('\n'), hasLength(1));
    expect(publicKeyBytes(text), isNotNull);
  });
}
