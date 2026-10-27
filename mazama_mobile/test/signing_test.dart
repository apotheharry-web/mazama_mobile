// SL-D13: the owner's Ed25519 signature on sign-in host lists (lib/signing.dart), held to the shared vectors
// ../mazama_modules/flows/contracts/signing_vectors.json (vendored at assets/shared/flows/contracts/ by
// tool/sync_flows.sh - run that first if this can't find the file), which the server's own verifier
// (mazama_sales signing.py) passes too. The vectors' keys are TEST keys only, injected here; the app itself reads
// assets/signing/signing.pub.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show CachingAssetBundle, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/signing.dart';

final _vectors =
    jsonDecode(File('assets/shared/flows/contracts/signing_vectors.json').readAsStringSync()) as Map<String, Object?>;
final _cases = (_vectors['cases'] as List).cast<Map<String, Object?>>();
Map<String, Object?> _case(String name) => _cases.firstWhere((c) => c['name'] == name);

/// An asset bundle holding [files] (asset key -> text); any other key fails to load, as a missing asset does.
class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) throw StateError('no asset $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

void main() {
  // bundledPublicKey() without a bundle reads rootBundle, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the vectors are the shared set, with the cases the format calls for', () {
    final names = _cases.map((c) => c['name']).toSet();
    expect(_cases, hasLength(30)); // gen_signing_vectors.py writes exactly these; a new case is added here too
    expect(_cases.length, names.length);
    for (final name in [
      'good',
      'trailing_newlines',
      'wrong_key',
      'flipped_payload_byte',
      'flipped_signature_byte_r',
      'flipped_signature_byte_s',
      'signature_s_plus_l',
      'signature_bad_base64',
      'signature_63_bytes',
      'public_key_31_bytes',
      'none_key',
      'crlf_payload',
      'crlf_payload_read_as_lf',
      'signature_url_safe_alphabet',
      'signature_non_canonical',
    ]) {
      expect(names, contains(name));
    }
  });

  for (final c in _cases) {
    test('vector ${c['name']}: ${c['valid'] == true ? 'verifies' : 'does not verify'}', () async {
      final payload = base64.decode(c['payload_b64'] as String);
      final ok = await verifySigned(payload, c['signature'] as String, publicKey: c['public_key'] as String);
      expect(ok, c['valid'], reason: c['why'] as String?);
    });
  }

  test('the TEST keys are not the bundled key', () {
    final bundled = File(signingPublicKeyAsset).readAsStringSync().trim();
    final testKey = (_vectors['test_key'] as Map)['public_key'] as String;
    final otherKey = (_vectors['other_key'] as Map)['public_key'] as String;
    expect(bundled, isNot(testKey));
    expect(bundled, isNot(otherKey));
  });

  group('scalarBelowOrder (RFC 8032: S < L)', () {
    // L, little-endian, as signature bytes 32..63.
    final order = Uint8List.fromList([
      0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, //
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    ]);
    Uint8List sigWithS(List<int> s) => Uint8List.fromList([...List<int>.filled(32, 0xab), ...s]);

    test('S = 0 and S = L - 1 are below L; S = L and S above it are not', () {
      expect(scalarBelowOrder(sigWithS(List<int>.filled(32, 0))), isTrue);
      expect(scalarBelowOrder(sigWithS([order[0] - 1, ...order.sublist(1)])), isTrue);
      expect(scalarBelowOrder(sigWithS(order)), isFalse);
      expect(scalarBelowOrder(sigWithS([order[0] + 1, ...order.sublist(1)])), isFalse);
      expect(scalarBelowOrder(sigWithS([...order.sublist(0, 31), 0x11])), isFalse);
      expect(scalarBelowOrder(sigWithS(List<int>.filled(32, 0xff))), isFalse);
    });

    test('a good signature has S below L; its S + L vector does not', () {
      expect(scalarBelowOrder(base64.decode(_case('good')['signature'] as String)), isTrue);
      expect(scalarBelowOrder(base64.decode(_case('signature_s_plus_l')['signature'] as String)), isFalse);
    });

    test('anything but 64 bytes is not a signature', () {
      expect(scalarBelowOrder(Uint8List(63)), isFalse);
      expect(scalarBelowOrder(Uint8List(65)), isFalse);
      expect(scalarBelowOrder(const <int>[]), isFalse);
    });
  });

  group('publicKeyBytes', () {
    test('a good signing.pub gives its 32 bytes, with or without the newline', () {
      final key = (_vectors['test_key'] as Map)['public_key'] as String;
      expect(publicKeyBytes(key), base64.decode(key));
      expect(publicKeyBytes('$key\n'), base64.decode(key));
      expect(publicKeyBytes(key)!.length, 32);
    });

    test('none, null and malformed text give null', () {
      final key = (_vectors['test_key'] as Map)['public_key'] as String;
      for (final text in <String?>[null, 'none', 'none\n', '', '\n', ' $key', '$key\r\n', '$key\n\n', 'not a key!']) {
        expect(publicKeyBytes(text), isNull, reason: jsonEncode(text));
      }
    });
  });

  group('bundledPublicKey', () {
    test('reads assets/signing/signing.pub from the bundle it is given', () async {
      final bundle = _Bundle({signingPublicKeyAsset: 'abc\n'});
      expect(await bundledPublicKey(bundle: bundle), 'abc\n');
    });

    test('is null when the asset cannot be read', () async {
      expect(await bundledPublicKey(bundle: _Bundle({})), isNull);
    });

    test("the app's own bundle holds the vendored signing.pub", () async {
      expect(await bundledPublicKey(), File(signingPublicKeyAsset).readAsStringSync());
      expect(await bundledPublicKey(bundle: rootBundle), File(signingPublicKeyAsset).readAsStringSync());
    });
  });

  group('verifySigned without an injected key uses the bundled one', () {
    final good = _case('good');
    final payload = base64.decode(good['payload_b64'] as String);
    final signature = good['signature'] as String;

    test("a good signature under the bundle's key verifies", () async {
      final bundle = _Bundle({signingPublicKeyAsset: good['public_key'] as String});
      expect(await verifySigned(payload, signature, bundle: bundle), isTrue);
    });

    test('the shipped placeholder `none` verifies nothing', () async {
      final bundle = _Bundle({signingPublicKeyAsset: 'none\n'});
      expect(await verifySigned(payload, signature, bundle: bundle), isFalse);
    });

    test('a missing asset verifies nothing and does not throw', () async {
      expect(await verifySigned(payload, signature, bundle: _Bundle({})), isFalse);
    });

    test('the vendored signing.pub does not accept the TEST signature', () async {
      expect(await verifySigned(payload, signature), isFalse);
    });
  });

  test('odd inputs give false, never throw', () async {
    final good = _case('good');
    final key = good['public_key'] as String;
    final signature = good['signature'] as String;
    final payload = base64.decode(good['payload_b64'] as String);
    final oddSignatures = <String>[
      '',
      '\n',
      '====',
      'A===',
      '${'A' * 86}==',
      '${'/' * 86}==',
      'A' * 88,
      '%3D%3D',
      '\u0000' * 88,
      '${signature.trim()}é',
      signature.trim().replaceAll('=', '%3D'),
      'é' * 88,
    ];
    for (final s in oddSignatures) {
      expect(await verifySigned(payload, s, publicKey: key), isFalse, reason: jsonEncode(s));
    }
    // a 32-byte value that is not a curve point must not throw either
    final notAPoint = base64.encode(List<int>.filled(32, 0xff));
    expect(await verifySigned(payload, signature, publicKey: notAPoint), isFalse);
    expect(await verifySigned(payload, signature, publicKey: base64.encode(List<int>.filled(32, 0))), isFalse);
    // an all-zero signature (R and S zero) under a real key
    expect(await verifySigned(payload, base64.encode(List<int>.filled(64, 0)), publicKey: key), isFalse);
    expect(await verifySigned(<int>[], signature, publicKey: key), isFalse);
  });
}
