// SL-R7: the flow spec's `format`, the order of `spec_version`s and the https host check, through the shared vectors in
// assets/shared/flows/contracts/spec_versions.json (vendored from ../mazama_modules/flows/contracts/ by
// tool/sync_flows.sh), the same ones mazama_sales/tests/state/test_spec_versions.py runs.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/flow/flow_spec.dart';

final Map<String, Object?> _vectors =
    jsonDecode(File('assets/shared/flows/contracts/spec_versions.json').readAsStringSync()) as Map<String, Object?>;

FlowSpec _asset(String name) => FlowSpec.fromYaml(File('assets/flows/$name.yaml').readAsStringSync());

void main() {
  test('compareSpecVersions gives every shared vector its answer', () {
    final cases = (_vectors['compare'] as List).cast<List<Object?>>();
    expect(cases, isNotEmpty);
    for (final c in cases) {
      expect(compareSpecVersions(c[0] as String?, c[1] as String?), c[2], reason: '${c[0]} vs ${c[1]}');
    }
  });

  test('hostAllowed gives every shared vector its answer', () {
    final cases = (_vectors['hosts'] as List).cast<List<Object?>>();
    expect(cases, isNotEmpty);
    for (final c in cases) {
      expect(hostAllowedUrl(c[0] as String), c[1], reason: '${c[0]}');
    }
  });

  test('a url with credentials is not allowed, nor one off a custom allowlist', () {
    expect(hostAllowed(Uri.parse('https://psilocybin.oregon.gov@evil.com/')), isFalse);
    expect(hostAllowed(Uri.parse('https://psilocybin.oregon.gov/x')), isTrue);
    expect(hostAllowed(Uri.parse('https://PSILOCYBIN.oregon.gov/x')), isTrue);
    expect(hostAllowed(Uri.parse('https://psilocybin.oregon.gov/x'), allowed: const ['example.com']), isFalse);
    expect(supportedFlowFormat, 3);
    expect(defaultAllowedHosts, contains('psilocybin.oregon.gov'));
    expect(hostAllowedUrl('https://oregonpsilocybinprodb2c.b2clogin.com/x'), isTrue);
    expect(hostAllowedUrl('https://evil.b2clogin.com/x'), isFalse); // SL-R17: no other tenant
  });

  test('a spec with a later format is refused', () {
    expect(() => FlowSpec.fromYaml('format: 4\nvars: {}\nflows: {}\n'), throwsA(isA<FlowSpecError>()));
  });

  test('a format that is not a positive integer is refused', () {
    for (final bad in ['0', '-1', '"1"', '1.5', 'true', 'null']) {
      expect(() => FlowSpec.fromYaml('format: $bad\nvars: {}\nflows: {}\n'), throwsA(isA<FlowSpecError>()),
          reason: bad);
    }
  });

  test('no format loads as format 1', () {
    expect(FlowSpec.fromYaml('vars:\n  a: x\nflows: {}\n').format, 1);
    expect(FlowSpec.fromYaml('format: 1\nflows: {}\n').format, 1);
  });

  test('the shipped specs only talk to allowed hosts', () {
    for (final name in ['login', 'sale', 'state_reads', 'sb303']) {
      expect(specHostsAllowed(_asset(name)), isTrue, reason: name);
    }
  });

  test('the login spec is format 1 with a valid version', () {
    final spec = _asset('login');
    expect(spec.format, 1);
    expect(compareSpecVersions(spec.specVersion, '2026-10-24.2'), 1);
  });

  test('a spec whose b2c var points elsewhere is not allowed', () {
    final text = File('assets/flows/login.yaml').readAsStringSync();
    final evil = text.replaceFirst(
        'b2c: "https://{{tenant}}.b2clogin.com/{{tenant}}.onmicrosoft.com"', 'b2c: "https://evil.com"');
    expect(evil, isNot(text));
    expect(specHostsAllowed(FlowSpec.fromYaml(evil)), isFalse);
  });

  for (final tenant in ['evil', 'login', 'xoregonpsilocybinprodb2c']) {
    test('a spec whose tenant is another B2C tenant is not allowed ($tenant)', () {
      final text = File('assets/flows/login.yaml').readAsStringSync();
      final evil = text.replaceFirst('tenant: oregonpsilocybinprodb2c\n', 'tenant: $tenant\n');
      expect(evil, isNot(text));
      expect(specHostsAllowed(FlowSpec.fromYaml(evil)), isFalse);
    });
  }

  test('a host the spec does not fix is not allowed, a variable after the host is', () {
    const open = 'vars: {}\nflows:\n  x:\n    - id: a\n      type: request\n      method: GET\n'
        '      url: "{{somewhere}}/y"\n';
    expect(specHostsAllowed(FlowSpec.fromYaml(open)), isFalse);
    const fine = 'vars:\n  api: "https://psilocybin.oregon.gov/"\nflows:\n  x:\n    - id: a\n      type: request\n'
        '      method: GET\n      url: "{{api}}{{path}}"\n';
    expect(specHostsAllowed(FlowSpec.fromYaml(fine)), isTrue);
  });

  // The controller's ruling carried from the server (flowspec.py load_spec_text): no YAML anchors or aliases, plain
  // vars only, at most 64 KiB, so the phone never expands an alias bomb from a saved or fetched spec.
  group('what a flow spec may not contain', () {
    test('a YAML anchor is refused, even unused', () {
      expect(() => FlowSpec.fromYaml('vars:\n  a: &x hello\nflows: {}\n'), throwsA(isA<FlowSpecError>()));
    });

    test('a YAML alias is refused', () {
      expect(() => FlowSpec.fromYaml('x: &x [1]\nvars:\n  a: b\nflows:\n  f: *x\n'), throwsA(isA<FlowSpecError>()));
    });

    test('an alias bomb is refused at once, also when used as a mapping key', () {
      final bomb = StringBuffer('a0: &a0 ["x", "x", "x", "x", "x", "x", "x", "x", "x"]\n');
      for (var i = 1; i < 12; i++) {
        bomb.writeln('a$i: &a$i [${List.filled(9, '*a${i - 1}').join(', ')}]');
      }
      final asKey = '${bomb}k:\n  ? *a11\n  : v\nflows: {}\n';
      final asValue = '${bomb}flows: {}\n';
      final watch = Stopwatch()..start();
      expect(() => FlowSpec.fromYaml(asKey), throwsA(isA<FlowSpecError>()));
      expect(() => FlowSpec.fromYaml(asValue), throwsA(isA<FlowSpecError>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('an & or * inside quoted text is not an anchor or alias', () {
      final spec = FlowSpec.fromYaml('vars:\n  q: "a=1&b=*2"\n  r: \'&x *y\'\nflows: {}\n');
      expect(spec.vars, {'q': 'a=1&b=*2', 'r': '&x *y'});
    });

    test('vars must be plain values', () {
      for (final bad in ['[1, 2]', '{b: 1}', '\n    - x']) {
        expect(() => FlowSpec.fromYaml('vars:\n  a: $bad\nflows: {}\n'), throwsA(isA<FlowSpecError>()), reason: bad);
      }
      final ok = FlowSpec.fromYaml('vars:\n  s: text\n  i: 3\n  f: 1.5\n  b: true\nflows: {}\n');
      expect(ok.vars, {'s': 'text', 'i': '3', 'f': '1.5', 'b': 'true'});
    });

    test('vars must be a mapping', () {
      expect(() => FlowSpec.fromYaml('vars: [a, b]\nflows: {}\n'), throwsA(isA<FlowSpecError>()));
      expect(() => FlowSpec.fromYaml('vars: text\nflows: {}\n'), throwsA(isA<FlowSpecError>()));
    });

    test('text over 65 536 bytes is refused, counted in UTF-8 bytes', () {
      expect(maxFlowSpecBytes, 65536);
      const base = 'vars: {}\nflows: {}\n';
      final atLimit = '$base#${'x' * (maxFlowSpecBytes - base.length - 1)}';
      expect(utf8.encode(atLimit).length, maxFlowSpecBytes);
      expect(FlowSpec.fromYaml(atLimit).vars, isEmpty);
      expect(() => FlowSpec.fromYaml('${atLimit}x'), throwsA(isA<FlowSpecError>()));
      final wide = '$base#${'é' * 33000}'; // 33 000 characters, 66 000 bytes
      expect(wide.length, lessThan(maxFlowSpecBytes));
      expect(() => FlowSpec.fromYaml(wide), throwsA(isA<FlowSpecError>()));
    });

    test('text that is not YAML is a FlowSpecError', () {
      expect(() => FlowSpec.fromYaml('flows: [\n  {unclosed\n'), throwsA(isA<FlowSpecError>()));
      expect(() => FlowSpec.fromYaml('a: *nowhere\n'), throwsA(isA<FlowSpecError>()));
    });

    test('every bundled spec still loads', () {
      final names = [
        for (final f in Directory('assets/flows').listSync())
          if (f is File && f.path.endsWith('.yaml')) f.uri.pathSegments.last
      ];
      expect(names, containsAll(['login.yaml', 'sale.yaml', 'state_reads.yaml', 'sb303.yaml']));
      for (final name in names) {
        expect(() => FlowSpec.fromYaml(File('assets/flows/$name').readAsStringSync()), returnsNormally, reason: name);
      }
    });
  });

  test('isSpecVersion holds to YYYY-MM-DD.N', () {
    for (final good in ['2026-10-24.3', '2026-10-24.0', '2026-10-24.0012']) {
      expect(isSpecVersion(good), isTrue, reason: good);
    }
    for (final bad in [null, '', '2026-10-24', '2026-10-24.', '2026-1-24.3', 'x2026-10-24.3', '2026-10-24.3 ', '2026-10-24.-1']) {
      expect(isSpecVersion(bad), isFalse, reason: '$bad');
    }
  });
}
