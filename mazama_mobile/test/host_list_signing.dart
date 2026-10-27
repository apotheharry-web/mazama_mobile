// Test helper (not a test file): signs host lists with the shared vectors' TEST key
// (assets/shared/flows/contracts/signing_vectors.json's test_key, made from a fixed label; never Mazama's key), so the
// host list tests can verify lists the way the app does, with that TEST public key injected.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart' show Ed25519;
import 'package:mazama_mobile/login_hosts_store.dart';

final _vectors =
    jsonDecode(File('assets/shared/flows/contracts/signing_vectors.json').readAsStringSync()) as Map<String, Object?>;

/// The TEST public key, as a `signing.pub` text holds it.
final String testPublicKey = (_vectors['test_key'] as Map)['public_key'] as String;

/// A second TEST public key: a list signed with [testPublicKey]'s pair doesn't verify under it.
final String otherPublicKey = (_vectors['other_key'] as Map)['public_key'] as String;

final List<int> _testSeed = base64.decode((_vectors['test_key'] as Map)['private_key'] as String);

/// The `.sig` text of [text] (its UTF-8 bytes) under the TEST key: base64 and a newline, as `mazama-sales sign` writes.
Future<String> testSignature(String text) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(_testSeed);
  final signature = await algorithm.sign(utf8.encode(text), keyPair: keyPair);
  return '${base64.encode(signature.bytes)}\n';
}

/// The text of a host list at [version] naming [hosts].
String hostListText(String version, List<String> hosts) => '${jsonEncode({'version': version, 'hosts': hosts})}\n';

/// A host list at [version] naming [hosts], signed with the TEST key and verified as the app verifies one.
Future<HostList> signedHostList(String version, List<String> hosts) async {
  final text = hostListText(version, hosts);
  final list = await verifiedHostList(text, await testSignature(text), publicKey: testPublicKey);
  if (list == null) throw StateError('the TEST-signed list did not verify');
  return list;
}
