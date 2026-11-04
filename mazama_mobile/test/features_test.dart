// The features registry on the phone: every page belongs to one feature, and the generated
// table (lib/features.g.dart) says which license types each is on for. Reads the app's own lib/, never
// mazama_modules/.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/feature_pages.g.dart';
import 'package:mazama_mobile/features.g.dart';

import 'features_off.dart';

// Any page class, whatever its modifiers or type parameters: `class X`, `final class X`, `abstract base class X<T>`.
final _pageClass = RegExp(r'^(?:(?:abstract|base|final|sealed|interface)\s+)*class ([A-Z]\w*Page)\b', multiLine: true);

/// Every class name declared in lib/ (exact names, so `StockPage` isn't found inside `CenterStockPage`).
final _anyClass = RegExp(r'^(?:(?:abstract|base|final|sealed|interface|mixin)\s+)*class ([A-Z]\w*)\b', multiLine: true);

// Page classes are found in lib/ whole, the feature folders under lib/features/ included (FR-11).
List<String> _sources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .map((f) => f.readAsStringSync())
    .toList();

void main() {
  test('every listed page is a class in lib', () {
    final declared = {for (final s in _sources()) ..._anyClass.allMatches(s).map((m) => m.group(1)!)};
    final listed = [for (final f in features.values) ...f.pages, ...framePages];
    for (final name in listed) {
      expect(declared.contains(name), isTrue, reason: '$name is in features.yaml but not a class in lib/');
    }
  });

  test('every page class is listed once', () {
    final classes = {for (final s in _sources()) ..._pageClass.allMatches(s).map((m) => m.group(1)!)};
    expect(classes, isNotEmpty);
    for (final name in classes) {
      final owners = [
        for (final f in features.values)
          if (f.pages.contains(name)) f.name,
        if (framePages.contains(name)) 'frame',
      ];
      expect(owners, hasLength(1), reason: '$name is owned by $owners: give it one feature in features.yaml');
    }
  });

  test("today's license types", () {
    expect(featureOnForLicense('mazama_tab', 'ServiceCenter'), isTrue);
    expect(featureOnForLicense('mazama_tab', 'Manufacturer'), isFalse);
    expect(featureOnForLicense('sign_in', 'Manufacturer'), isTrue);
    expect(featureOnForLicense('no_such_feature', 'ServiceCenter'), isFalse);
    expect(licenseTypeListed('ServiceCenter'), isTrue);
    expect(licenseTypeListed('Manufacturer', debugBuild: false), isFalse);
  });

  test('the inventory portal is on for no license type (CW-R9)', () {
    expect(featureOnForLicense('inventory_portal', 'ServiceCenter'), isFalse);
    expect(featureOnForLicense('inventory_portal', 'Manufacturer'), isFalse);
    expect(features['inventory_portal']!.pages, isEmpty);
  });

  test("the Sales tab is on for service centers (CW-R10)", () {
    expect(featureOnForLicense('recent_sales', 'ServiceCenter'), isTrue);
    expect(featureOnForLicense('recent_sales', 'Manufacturer'), isFalse);
    expect(features['recent_sales']!.pages, ['SalesPage']);
  });

  test('a table can switch a feature off for the tests of each gate', () {
    final off = featuresWithOff(['mazama_tab']);
    expect(featureOnForLicense('mazama_tab', 'ServiceCenter', table: off), isFalse);
    expect(featureOnForLicense('center_stock', 'ServiceCenter', table: off), isTrue);
    expect(licenseTypeListed('ServiceCenter', table: featuresWithOff([for (final f in features.values) f.name])), isFalse);
  });

  group('debug-only features (FR-11)', () {
    final table = {
      'x': const Feature(
        name: 'x',
        id: 'F-99',
        what: 'A feature built for debug builds only.',
        built: ['phone'],
        onWeb: [],
        onPhone: [],
        onPhoneDebug: ['Manufacturer'],
        pages: [],
        uses: [],
        shared: 'complete',
        logic: [],
      ),
    };

    test('a debug build counts onPhoneDebug, a release build does not', () {
      expect(featureOnForLicense('x', 'Manufacturer', table: table, debugBuild: true), isTrue);
      expect(featureOnForLicense('x', 'Manufacturer', table: table, debugBuild: false), isFalse);
      expect(featureOnForLicense('x', 'ServiceCenter', table: table, debugBuild: true), isFalse);
    });

    test('the picker lists a license type its debug-only feature is on for, in a debug build only', () {
      expect(licenseTypeListed('Manufacturer', table: table, debugBuild: true), isTrue);
      expect(licenseTypeListed('Manufacturer', table: table, debugBuild: false), isFalse);
      expect(licenseTypeListed('ServiceCenter', table: table, debugBuild: true), isFalse);
    });

    test('a released feature is on in both builds', () {
      expect(featureOnForLicense('mazama_tab', 'ServiceCenter', debugBuild: false), isTrue);
      expect(featureOnForLicense('mazama_tab', 'ServiceCenter', debugBuild: true), isTrue);
    });

    test('every feature folder has an entry and belongs to a feature', () {
      final dir = Directory('lib/features');
      final folders = dir.existsSync()
          ? [for (final d in dir.listSync().whereType<Directory>()) d.path.split(Platform.pathSeparator).last]
          : <String>[];
      expect(featureEntries.keys.toSet(), folders.toSet());
      for (final name in folders) {
        expect(features.containsKey(name), isTrue, reason: 'lib/features/$name/ has no feature of that name');
        expect(File('lib/features/$name/entry.dart').existsSync(), isTrue, reason: '$name has no entry.dart');
      }
    });

    test('at most one feature folder with a page is on for Manufacturer (the picker opens that one)', () {
      for (final debugBuild in [true, false]) {
        final pages = [
          for (final e in featureEntries.entries)
            if (e.value.page != null && featureOnForLicense(e.key, 'Manufacturer', debugBuild: debugBuild)) e.key
        ];
        expect(pages.length, lessThanOrEqualTo(1), reason: 'debugBuild $debugBuild: $pages');
      }
    });

    test('no file outside lib/features/<name>/ imports from it', () {
      final dir = Directory('lib/features');
      if (!dir.existsSync()) return;
      for (final d in dir.listSync().whereType<Directory>()) {
        final name = d.path.split(Platform.pathSeparator).last;
        final inside = 'lib/features/$name/';
        for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
          final path = f.path.replaceAll(Platform.pathSeparator, '/');
          if (!path.endsWith('.dart') || path.startsWith(inside) || path == 'lib/feature_pages.g.dart') continue;
          expect(RegExp("['\"][^'\"]*features/$name/").hasMatch(f.readAsStringSync()), isFalse,
              reason: '$path imports from lib/features/$name/: reach it through featureEntries');
        }
      }
    });
  });

  test('the class patterns match exact names and every modifier', () {
    const sample = 'class CenterStockPage extends X {}\nfinal class AlphaPage extends Y {}\nabstract base class BetaPage<T> {}\n';
    expect([for (final m in _pageClass.allMatches(sample)) m.group(1)], ['CenterStockPage', 'AlphaPage', 'BetaPage']);
    final names = {for (final m in _anyClass.allMatches(sample)) m.group(1)!};
    expect(names.contains('StockPage'), isFalse); // a substring of CenterStockPage is not a class
  });
}
