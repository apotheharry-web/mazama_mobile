// SL-D13: the owner's Ed25519 signature on sign-in host lists (and, on the server, hosted sign-in specs).
//
// Format (shared with the server's mazama_sales signing.py, held to the vectors in
// assets/shared/flows/contracts/signing_vectors.json, vendored from ../mazama_modules/flows/contracts/):
// - the signature covers the exact bytes of the signed file, nothing normalised (a CRLF is part of the payload);
// - a `.sig` text is one line: standard base64 (canonical, padded) of the 64-byte signature, optionally ending in one
//   newline;
// - `signing.pub` is one line the same way, of the 32-byte raw public key (the owner's, since 2026-10-25); the literal
//   `none` means "no key": every verification fails.
// The checks themselves are the shared core's (specs/core row 13): the same Rust the server's signing.py calls, so the
// two cannot read a key or a signature differently. Base64 is read strictly there (no URL-safe alphabet, no missing
// padding, no stray low bits), and the signature is checked strictly (S below the group order, no small-order key).
//
// verifySigned never throws: anything malformed is simply not a good signature.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'mazama_core.dart' show MazamaCore;

/// Where the bundled public key lives in the app's assets (vendored from ../mazama_modules/flows/signing.pub).
const signingPublicKeyAsset = 'assets/signing/signing.pub';

/// The text `signing.pub` holds while there is no key.
const noSigningKey = 'none';

/// The 32 raw bytes a `signing.pub` text names, or null for `none`, null or anything malformed. The shared core's rule
/// (`flows.public_key`, specs/core row 13): one ASCII line, one trailing newline allowed, canonical base64 of 32 bytes.
Uint8List? publicKeyBytes(String? text) {
  if (text == null) return null;
  try {
    final Object? key = MazamaCore.instance.flowsPublicKey({'text': text})['key_b64'];
    return key is String ? base64.decode(key) : null;
  } catch (_) {
    return null;
  }
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
/// `signing.pub` text) - by default the bundled key ([bundledPublicKey], from [bundle]). Never throws. The shared core
/// checks it (`flows.verify_signature`, specs/core row 13, strictly: S below the group order, no small-order key or R),
/// the same function the server's signing.py calls; the vectors are flows/contracts/signing_vectors.json.
Future<bool> verifySigned(List<int> payload, String signature, {String? publicKey, AssetBundle? bundle}) async {
  try {
    final key = publicKey ?? await bundledPublicKey(bundle: bundle);
    if (key == null) return false;
    final answer = MazamaCore.instance.flowsVerifySignature({
      'payload_b64': base64.encode(payload),
      'signature': signature,
      'public_key': key,
    });
    return answer['valid'] == true;
  } catch (_) {
    return false;
  }
}
