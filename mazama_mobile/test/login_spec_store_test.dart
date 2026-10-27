// SL-R9: the saved sign-in spec beside the bundled one (login_spec_store.dart). The newer valid one wins; a saved file
// that is corrupt, of a later format or names a host the app won't talk to never replaces the bundled one.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';
import 'package:mazama_mobile/login_hosts_store.dart';
import 'package:mazama_mobile/login_spec_store.dart';

import 'host_list_signing.dart';

/// A minimal usable sign-in spec (each flow extracts access_token): [marker] tells which copy was chosen.
String specText({
  String version = '2026-10-24.3',
  String marker = 'bundled',
  int? format,
  String host = 'oregonpsilocybinprodb2c.b2clogin.com',
  bool renew = true,
}) {
  final buf = StringBuffer();
  if (format != null) buf.writeln('format: $format');
  buf
    ..writeln('vars:')
    ..writeln('  spec_version: "$version"')
    ..writeln('  marker: $marker')
    ..writeln('flows:')
    ..writeln('  login:')
    ..writeln('    - id: open')
    ..writeln('      type: request')
    ..writeln('      method: GET')
    ..writeln('      url: "https://$host/"')
    ..writeln('      extract:')
    ..writeln('        - {var: access_token, source: body, json: access_token}');
  if (renew) {
    buf
      ..writeln('  renew:')
      ..writeln('    - id: refresh')
      ..writeln('      type: request')
      ..writeln('      method: GET')
      ..writeln('      url: "https://$host/"')
      ..writeln('      extract:')
      ..writeln('        - {var: access_token, source: body, json: access_token}');
  }
  return buf.toString();
}

void main() {
  late Directory dir;
  late LoginSpecStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('login_spec_store_test_');
    store = LoginSpecStore(dataDir: () => dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void writeSaved(String text) => File('${dir.path}/login_spec.yaml').writeAsStringSync(text);

  test('with nothing saved, the bundled spec is used', () async {
    final spec = await store.current(specText());
    expect(spec.vars['marker'], 'bundled');
  });

  test('a saved spec newer than the bundled one is used', () async {
    writeSaved(specText(version: '2026-10-25.1', marker: 'saved'));
    final spec = await store.current(specText(version: '2026-10-24.3'));
    expect(spec.vars['marker'], 'saved');
    expect(spec.specVersion, '2026-10-25.1');
  });

  test('a bundled spec newer than the saved one wins (an app update beats an older download)', () async {
    writeSaved(specText(version: '2026-10-24.9', marker: 'saved'));
    final spec = await store.current(specText(version: '2026-10-24.10'));
    expect(spec.vars['marker'], 'bundled');
  });

  test('on a tie the bundled spec is used', () async {
    writeSaved(specText(marker: 'saved'));
    expect((await store.current(specText())).vars['marker'], 'bundled');
  });

  final unusable = <String, String>{
    'corrupt YAML': 'flows: [\n  {unclosed\n',
    'not a mapping': '- a\n- b\n',
    'a later format': specText(version: '2027-01-01.1', marker: 'saved', format: 4),
    'a host the app does not talk to': specText(version: '2027-01-01.1', marker: 'saved', host: 'evil.example.com'),
    'no renew flow': specText(version: '2027-01-01.1', marker: 'saved', renew: false),
    'a request to the state\'s API (SL-D16)': specText(version: '2027-01-01.1', marker: 'saved', host: 'psilocybin.oregon.gov'),
    'a malformed spec_version': specText(version: '2027-1-1.1', marker: 'saved'),
    'a YAML alias': '${specText(version: '2027-01-01.1', marker: 'saved')}extra: &a [1]\nmore: *a\n',
    'a request step without a url': specText(version: '2027-01-01.1', marker: 'saved')
        .replaceFirst('      url: "https://oregonpsilocybinprodb2c.b2clogin.com/"\n', ''),
    'a step that is not a mapping': specText(version: '2027-01-01.1', marker: 'saved')
        .replaceFirst('  renew:\n    - id: refresh', '  renew:\n    - just text\n    - id: refresh'),
  };
  for (final e in unusable.entries) {
    test('a saved spec with ${e.key} is ignored: the bundled one is used', () async {
      writeSaved(e.value);
      expect(usableLoginSpec(e.value), isNull);
      expect((await store.current(specText())).vars['marker'], 'bundled');
    });
  }

  group('hosts a signed list adds (SL-R18)', () {
    tearDown(() => useLoginHosts(null));

    test('a saved spec at a listed host is used once the list is in use, and ignored without it', () async {
      final moved = specText(version: '2027-01-01.1', marker: 'saved', host: 'login.example.gov');
      writeSaved(moved);
      expect((await store.current(specText())).vars['marker'], 'bundled');
      useLoginHosts(await signedHostList('2026-11-01.1', ['login.example.gov']));
      expect((await store.current(specText())).vars['marker'], 'saved');
      expect(usableLoginSpec(moved), isNotNull);
    });

    test('usableLoginSpec takes the hosts it is given over the ones in use', () async {
      final moved = specText(version: '2027-01-01.1', host: 'login.example.gov');
      expect(usableLoginSpec(moved), isNull);
      expect(usableLoginSpec(moved, allowedHosts: [...defaultAllowedHosts, 'login.example.gov']), isNotNull);
      useLoginHosts(await signedHostList('2026-11-01.1', ['login.example.gov']));
      expect(usableLoginSpec(moved, allowedHosts: defaultAllowedHosts), isNull);
    });

    test('save keeps a spec at a listed host only while the list is in use', () async {
      final moved = specText(version: '2027-01-01.1', marker: 'saved', host: 'login.example.gov');
      await expectLater(store.save(moved), throwsA(isA<FlowSpecError>()));
      useLoginHosts(await signedHostList('2026-11-01.1', ['login.example.gov']));
      await store.save(moved);
      expect(File('${dir.path}/login_spec.yaml').readAsStringSync(), moved);
    });
  });

  test('a saved file that is not UTF-8 is ignored', () async {
    File('${dir.path}/login_spec.yaml').writeAsBytesSync([0xff, 0xfe, 0x00, 0x61]);
    expect((await store.current(specText())).vars['marker'], 'bundled');
  });

  test('save then current gives the saved spec; the write leaves no temporary file behind', () async {
    final text = specText(version: '2026-10-30.1', marker: 'saved');
    await store.save(text);
    expect(File('${dir.path}/login_spec.yaml').readAsStringSync(), text);
    expect(dir.listSync().map((f) => f.uri.pathSegments.last).toList(), ['login_spec.yaml']);
    expect((await store.current(specText())).vars['marker'], 'saved');
  });

  test('save replaces an earlier saved spec', () async {
    await store.save(specText(version: '2026-10-30.1', marker: 'first'));
    await store.save(specText(version: '2026-10-30.2', marker: 'second'));
    expect((await store.current(specText())).vars['marker'], 'second');
  });

  test('save refuses a spec the phone cannot use and keeps the one it had', () async {
    await store.save(specText(version: '2026-10-30.1', marker: 'saved'));
    await expectLater(store.save(specText(version: '2026-10-31.1', host: 'evil.example.com')),
        throwsA(isA<FlowSpecError>()));
    expect((await store.current(specText())).vars['marker'], 'saved');
  });

  test('save creates the data directory when it is missing', () async {
    final nested = Directory('${dir.path}/not/yet');
    final s = LoginSpecStore(dataDir: () => nested);
    await s.save(specText(version: '2026-10-30.1', marker: 'saved'));
    expect((await s.current(specText())).vars['marker'], 'saved');
  });

  test('a broken bundled spec falls back to a usable saved one, and throws with none', () async {
    await expectLater(store.current('format: 4\n'), throwsA(isA<FlowSpecError>()));
    writeSaved(specText(version: '2026-10-30.1', marker: 'saved'));
    expect((await store.current('format: 4\n')).vars['marker'], 'saved');
  });

  test('the shipped login spec is a usable sign-in spec', () {
    final spec = usableLoginSpec(File('assets/flows/login.yaml').readAsStringSync());
    expect(spec, isNotNull);
    expect(isSpecVersion(spec!.specVersion), isTrue);
  });

  test("the server's example reply carries a usable sign-in spec", () {
    final example =
        jsonDecode(File('assets/shared/api/examples/login_spec.response.json').readAsStringSync()) as Map;
    expect(usableLoginSpec(example['yaml'] as String)?.specVersion, example['specVersion']);
  });

  // Final review I2: the server's login_spec_source.usable gives every one of these answers too.
  final validity =
      jsonDecode(File('assets/shared/flows/contracts/login_spec_validity.json').readAsStringSync()) as Map<String, Object?>;
  final cases = (validity['cases'] as List).cast<Map<String, Object?>>();
  test('the shared validity vectors cover both answers', () {
    expect(cases.length, greaterThanOrEqualTo(30));
    expect(cases.map((c) => c['usable']).toSet(), {true, false});
  });
  for (final c in cases) {
    test('shared validity vector: ${c['name']}', () {
      // a case with "served" is asked in that served mode (SL-R19); one without, in none
      final served = c['served'] == null ? null : ServedAs.values.byName(c['served'] as String);
      expect(usableLoginSpec(c['yaml'] as String, served: served) != null, c['usable'] as bool,
          reason: c['why'] as String);
    });
  }

  test('a format 3 open_browser spec is unusable for a format 2 reader', () {
    final text = cases.firstWhere((c) => c['name'] == 'format 3 with open_browser')['yaml'] as String;
    expect((usableLoginSpec(text) != null, usableLoginSpec(text, maxFormat: 2) != null), (true, false));
  });

  test('choose says whether the saved spec was chosen', () async {
    expect((await store.choose(specText())).saved, isFalse);
    writeSaved(specText(version: '2026-10-30.1', marker: 'saved'));
    final choice = await store.choose(specText());
    expect((choice.saved, choice.spec.vars['marker']), (true, 'saved'));
  });

  test('quarantine sets the saved spec aside: the bundled one is chosen and the file is kept as .bad', () async {
    final text = specText(version: '2026-10-30.1', marker: 'saved');
    writeSaved(text);
    store.quarantine();
    final choice = await store.choose(specText());
    expect((choice.saved, choice.spec.vars['marker']), (false, 'bundled'));
    expect(File('${dir.path}/login_spec.yaml').existsSync(), isFalse);
    expect(File('${dir.path}/login_spec.yaml.bad').readAsStringSync(), text);
    store.quarantine(); // nothing saved: nothing happens, nothing thrown
    expect(File('${dir.path}/login_spec.yaml.bad').readAsStringSync(), text);
  });

  test('the shared validity vectors cover both served modes with both answers (SL-R19)', () {
    final served = {for (final c in cases.where((c) => c['served'] != null)) (c['served'], c['usable'])};
    expect(served, {('login', true), ('login', false), ('browser', true), ('browser', false)});
  });

  group('the served mode (SL-R19)', () {
    final browserText = cases.firstWhere((c) => c['name'] == 'format 3 with open_browser')['yaml'] as String;

    test('the password store neither keeps nor reads a spec with an open_browser', () async {
      await expectLater(store.save(browserText), throwsA(isA<FlowSpecError>()));
      expect(File('${dir.path}/login_spec.yaml').existsSync(), isFalse);
      writeSaved(browserText.replaceFirst('"2026-10-24.3"', '"2999-01-01.1"'));
      expect(store.savedSpec(), isNull);
    });

    test('the browser store keeps its own file, held to the browser mode', () async {
      final browser = LoginSpecStore.browser(dataDir: () => dir);
      expect(browser.fileName, 'login_browser_spec.yaml');
      await expectLater(browser.save(specText(marker: 'login')), throwsA(isA<FlowSpecError>()));
      await browser.save(browserText);
      expect(File('${dir.path}/login_browser_spec.yaml').readAsStringSync(), browserText);
      expect(File('${dir.path}/login_spec.yaml').existsSync(), isFalse);
      expect(browser.savedSpec()?.specVersion, '2026-10-24.3');
      expect(store.savedSpec(), isNull); // the password store doesn't see it
      browser.quarantine();
      expect(File('${dir.path}/login_browser_spec.yaml.bad').readAsStringSync(), browserText);
      expect(browser.savedSpec(), isNull);
    });
  });
}
