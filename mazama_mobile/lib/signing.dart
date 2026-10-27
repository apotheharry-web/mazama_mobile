// SL-D13: the owner's Ed25519 signature on sign-in host lists (and, on the server, hosted sign-in specs).
//
// Format (shared with the server's mazama_sales signing.py, held to the vectors in
// assets/shared/flows/contracts/signing_vectors.json, vendored from ../mazama_modules/flows/contracts/):
// - the signature covers the exact bytes of the signed file, nothing normalised (a CRLF is part of the payload);
// - a `.sig` text is one line: standard base64 (canonical, padded) of the 64-byte signature, optionally ending in one
//   newline;
// - `signing.pub` is one line the same way, of the 32-byte raw public key (the owner's, since 2026-10-25); the literal
//   `none` means "no key": every verification fails.
// Base64 is decoded as strictly as the server does: dart:convert's base64.decode also takes the URL-safe alphabet,
// `%3D` padding and stray low bits, so those are refused here before it is called.
//
// verifySigned never throws: anything malformed is simply not a good signature.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Where the bundled public key lives in the app's assets (vendored from ../mazama_modules/flows/signing.pub).
const signingPublicKeyAsset = 'assets/signing/signing.pub';

/// The text `signing.pub` holds while there is no key.
const noSigningKey = 'none';

final _base64Shape = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

/// L, the order of the Ed25519 base point (2^252 + 27742317777372353535851937790883648493, RFC 8032), little-endian.
const _groupOrder = <int>[
  0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
];

/// True when the signature's S (its second 32 bytes, little-endian) is below L, as RFC 8032 requires. Checked here
/// whatever package:cryptography does, so S + L (the same signature, malleated) is refused on both sides (the
/// server's verifier refuses it too; vector `signature_s_plus_l`).
bool scalarBelowOrder(List<int> signature) {
  if (signature.length != 64) return false;
  for (var i = 31; i >= 0; i--) {
    final s = signature[32 + i];
    if (s != _groupOrder[i]) return s < _groupOrder[i];
  }
  return false; // S == L
}

/// The single line of a `.sig` / `signing.pub` text, or null when it isn't exactly one ASCII line (one trailing
/// newline allowed, nothing else: no CR, no tab or space, no second line, not empty).
String? _oneLine(String text) {
  final line = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
  if (line.isEmpty) return null;
  for (final unit in line.codeUnits) {
    if (unit > 0x7f || unit == 0x0a || unit == 0x0d || unit == 0x09 || unit == 0x20) return null;
  }
  return line;
}

/// Standard, padded, canonical base64 of exactly [length] bytes; anything else null.
Uint8List? _strictBase64(String text, int length) {
  if (text.length % 4 != 0 || !_base64Shape.hasMatch(text)) return null;
  final Uint8List raw;
  try {
    raw = base64.decode(text);
  } on FormatException {
    return null;
  }
  if (raw.length != length || base64.encode(raw) != text) return null;
  return raw;
}

/// The 32 raw bytes a `signing.pub` text names, or null for `none`, null or anything malformed.
Uint8List? publicKeyBytes(String? text) {
  if (text == null) return null;
  final line = _oneLine(text);
  if (line == null || line == noSigningKey) return null;
  return _strictBase64(line, 32);
}

/// The text of the bundled `signing.pub`, read from [bundle] (the app's own, [rootBundle], unless a test passes
/// one), or null when it can't be read. The owner's key since 2026-10-25 (`none` before: no key).
Future<String?> bundledPublicKey({AssetBundle? bundle}) async {
  try {
    // cache: false - rootBundle caches loadString's Future per key for the whole process (see widget_test.dart)
    return await (bundle ?? rootBundle).loadString(signingPublicKeyAsset, cache: false);
  } catch (_) {
    return null;
  }
}

/// True only when [signature] (a `.sig` text) is a good Ed25519 signature of exactly [payload] under [publicKey] (a
/// `signing.pub` text) - by default the bundled key ([bundledPublicKey], from [bundle]). Never throws.
Future<bool> verifySigned(List<int> payload, String signature, {String? publicKey, AssetBundle? bundle}) async {
  try {
    final key = publicKeyBytes(publicKey ?? await bundledPublicKey(bundle: bundle));
    final line = _oneLine(signature);
    final sig = line == null ? null : _strictBase64(line, 64);
    if (key == null || sig == null || !scalarBelowOrder(sig)) return false;
    return await Ed25519().verify(
      payload,
      signature: Signature(sig, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}
