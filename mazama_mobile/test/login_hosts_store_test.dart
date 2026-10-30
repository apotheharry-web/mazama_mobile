// SL-R18: the signed sign-in host list on the phone (login_hosts_store.dart): the text rule, held to the shared vectors
// ../mazama_modules/flows/contracts/host_list_vectors.json (vendored at assets/shared/flows/contracts/ by
// tool/sync_flows.sh), which the server's login_hosts.py passes too; verification against the bundled key (the
// vectors' TEST key injected here); the hosts every flow may use; and the saved copy.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/flow/flow_spec.dart' show defaultAllowedHosts;
import 'package:mazama_mobile/login_hosts_store.dart';
import 'package:mazama_mobile/signing.dart' show signingPublicKeyAsset;

import 'host_list_signing.dart';

final _vectors =
    jsonDecode(File('assets/shared/flows/contracts/host_list_vectors.json').readAsStringSync()) as Map<String, Object?>;
final _cases = (_vectors['cases'] as List).cast<Map<String, Object?>>();

/// An asset bundle holding only signing.pub, with [text] in it.
class _KeyBundle extends CachingAssetBundle {
  _KeyBundle(this.text);
  final String text;

  @override
  Future<ByteData> load(String key) async {
    if (key != signingPublicKeyAsset) throw StateError('no asset $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

void main() {
  tearDown(() => useLoginHosts(null));

  group('the text rule (shared vectors)', () {
    test('the limits are the shared ones', () {
      expect(_vectors['max_bytes'], maxHostListBytes);
      expect(_vectors['max_hosts'], maxListedHosts);
      expect(_cases, hasLength(50));
      expect(_cases.map((c) => c['name']).toSet(), hasLength(_cases.length));
    });

    for (final c in _cases) {
      test('vector ${c['name']}: ${c['valid'] == true ? 'valid' : 'invalid'}', () {
        final text = c['text'] as String;
        if (c['valid'] == true) {
          final (version, hosts) = parseHostList(text);
          expect(version, c['version']);
          expect(hosts, c['hosts']);
        } else {
          expect(() => parseHostList(text), throwsFormatException, reason: c['why'] as String?);
        }
      });
    }

    test('one byte over the size limit is refused, at the limit it is read', () {
      const head = '{"version": "2026-11-01.1", "hosts": []';
      final atLimit = '$head${' ' * (maxHostListBytes - head.length - 1)}}';
      expect(utf8.encode(atLimit).length, maxHostListBytes);
      expect(parseHostList(atLimit).$2, isEmpty);
      expect(() => parseHostList('$head${' ' * (maxHostListBytes - head.length)}}'), throwsFormatException);
    });

    test('validListedHost takes only text', () {
      expect(validListedHost('login.example.gov'), isTrue);
      expect(validListedHost(null), isFalse);
      expect(validListedHost(5), isFalse);
      expect(validListedHost(const ['login.example.gov']), isFalse);
    });
  });

  group('verifiedHostList', () {
    test('a list signed with the key verifies, with its version, hosts, text and signature', () async {
      final text = hostListText('2026-11-01.1', ['login.example.gov']);
      final sig = await testSignature(text);
      final list = await verifiedHostList(text, sig, publicKey: testPublicKey);
      expect(list, isNotNull);
      expect(list!.version, '2026-11-01.1');
      expect(list.hosts, ['login.example.gov']);
      expect(list.text, text);
      expect(list.signature, sig);
    });

    test('another key, a changed byte, a CRLF or an invalid list with a good signature: null', () async {
      final text = hostListText('2026-11-01.1', ['login.example.gov']);
      final sig = await testSignature(text);
      expect(await verifiedHostList(text, sig, publicKey: otherPublicKey), isNull);
      expect(await verifiedHostList(text.replaceFirst('login', 'logon'), sig, publicKey: testPublicKey), isNull);
      expect(await verifiedHostList(text.replaceFirst('\n', '\r\n'), sig, publicKey: testPublicKey), isNull);
      const bad = '{"version": "2026-11-01.1", "hosts": ["*.example.gov"]}';
      expect(await verifiedHostList(bad, await testSignature(bad), publicKey: testPublicKey), isNull);
      expect(await verifiedHostList(text, 'not a signature', publicKey: testPublicKey), isNull);
    });

    test('the `none` key verifies nothing', () async {
      final text = hostListText('2026-11-01.1', ['login.example.gov']);
      final sig = await testSignature(text);
      expect(await verifiedHostList(text, sig, publicKey: 'none\n'), isNull);
      expect(await verifiedHostList(text, sig, bundle: _KeyBundle('none\n')), isNull);
    });

    test('without an injected key, the bundled one is used', () async {
      final text = hostListText('2026-11-01.1', ['login.example.gov']);
      final sig = await testSignature(text);
      expect(await verifiedHostList(text, sig, bundle: _KeyBundle('$testPublicKey\n')), isNotNull);
      expect(await verifiedHostList(text, sig, bundle: _KeyBundle('$otherPublicKey\n')), isNull);
    });

    test('the signature covers the exact text: a trailing space is part of it', () async {
      const text = '{"version": "2026-11-01.1", "hosts": ["login.example.gov"]} ';
      final sig = await testSignature(text);
      expect(await verifiedHostList(text, sig, publicKey: testPublicKey), isNotNull);
      expect(await verifiedHostList(text.trimRight(), sig, publicKey: testPublicKey), isNull);
    });
  });

  group('the hosts flows may use', () {
    test('a list adds hosts to the built-in ones and never removes them', () async {
      final list = await signedHostList('2026-11-01.1', ['psilocybin.oregon.gov', 'z.example.gov', 'a.example.gov']);
      expect(list.extra, ['a.example.gov', 'z.example.gov']);
      expect(allowedHostsWith(list), [...defaultAllowedHosts, 'a.example.gov', 'z.example.gov']);
      expect(allowedHostsWith(null), defaultAllowedHosts);
      final empty = await signedHostList('2026-11-01.2', []);
      expect(allowedHostsWith(empty), defaultAllowedHosts);
    });

    test('with no list in use, the built-in hosts only; useLoginHosts puts a list in use and null takes it out',
        () async {
      expect(loginHostsInUse, isNull);
      expect(currentAllowedHosts(), defaultAllowedHosts);
      final list = await signedHostList('2026-11-01.1', ['login.example.gov']);
      useLoginHosts(list);
      expect(loginHostsInUse, same(list));
      expect(currentAllowedHosts(), [...defaultAllowedHosts, 'login.example.gov']);
      useLoginHosts(null);
      expect(currentAllowedHosts(), defaultAllowedHosts);
    });

    test('the allowed hosts cannot be changed by whoever reads them', () {
      expect(() => currentAllowedHosts().add('evil.example.com'), throwsUnsupportedError);
    });

    test('hostsAddedTo names only the hosts that were not allowed before', () async {
      final list = await signedHostList('2026-11-01.1', ['b.example.gov', 'a.example.gov', 'psilocybin.oregon.gov']);
      expect(hostsAddedTo(defaultAllowedHosts, list), ['a.example.gov', 'b.example.gov']);
      expect(hostsAddedTo([...defaultAllowedHosts, 'a.example.gov'], list), ['b.example.gov']);
      expect(hostsAddedTo(defaultAllowedHosts, null), isEmpty);
    });

    test('a newer list replaces the one in use; the same version or an older one does not', () async {
      final v1 = await signedHostList('2026-11-01.1', ['a.example.gov']);
      final v2 = await signedHostList('2026-11-01.2', ['b.example.gov']);
      final v10 = await signedHostList('2026-11-01.10', ['c.example.gov']);
      expect(newerHostList(v1, null), isTrue);
      expect(newerHostList(v2, v1), isTrue);
      expect(newerHostList(v10, v2), isTrue); // .10 is after .2
      expect(newerHostList(v1, v2), isFalse);
      expect(newerHostList(v1, v1), isFalse);
    });
  });

  group('LoginHostsStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('login_hosts_store_test_'));
    tearDown(() => dir.deleteSync(recursive: true));

    File file() => File('${dir.path}/login_hosts.json');

    test('nothing saved: null', () async {
      expect(await LoginHostsStore(dataDir: () => dir, publicKey: testPublicKey).load(), isNull);
    });

    test('a saved list is read back and verified again', () async {
      final list = await signedHostList('2026-11-01.1', ['login.example.gov']);
      await LoginHostsStore(dataDir: () => dir, publicKey: testPublicKey).save(list);
      expect(file().existsSync(), isTrue);
      expect(File('${dir.path}/login_hosts.json.tmp').existsSync(), isFalse);
      final back = await LoginHostsStore(dataDir: () => dir, publicKey: testPublicKey).load();
      expect(back?.version, '2026-11-01.1');
      expect(back?.hosts, ['login.example.gov']);
      expect(back?.text, list.text);
    });

    test('a saved list that no longer verifies (another key, the `none` key, a changed list) is not used', () async {
      final list = await signedHostList('2026-11-01.1', ['login.example.gov']);
      await LoginHostsStore(dataDir: () => dir, publicKey: testPublicKey).save(list);
      expect(await LoginHostsStore(dataDir: () => dir, publicKey: otherPublicKey).load(), isNull);
      expect(await LoginHostsStore(dataDir: () => dir, publicKey: 'none').load(), isNull);
      expect(await LoginHostsStore(dataDir: () => dir, bundle: _KeyBundle('none\n')).load(), isNull);
      final tampered = {'list': list.text.replaceFirst('login.example.gov', 'evil.example.com'), 'signature': list.signature};
      file().writeAsStringSync(jsonEncode(tampered));
      expect(await LoginHostsStore(dataDir: () => dir, publicKey: testPublicKey).load(), isNull);
    });

    test('a corrupt or odd file is as if nothing were saved', () async {
      final store = LoginHostsStore(dataDir: () => dir, publicKey: testPublicKey);
      for (final text in ['', 'not json', '[1, 2]', '{"list": 5, "signature": "x"}', '{"list": "x"}']) {
        file().writeAsStringSync(text);
        expect(await store.load(), isNull, reason: text);
      }
      file().writeAsBytesSync([0xff, 0xfe, 0x00]);
      expect(await store.load(), isNull);
    });

    test('a save replaces the list saved before', () async {
      final store = LoginHostsStore(dataDir: () => dir, publicKey: testPublicKey);
      await store.save(await signedHostList('2026-11-01.1', ['a.example.gov']));
      await store.save(await signedHostList('2026-11-01.2', ['b.example.gov']));
      expect((await store.load())?.hosts, ['b.example.gov']);
    });
  });
}
