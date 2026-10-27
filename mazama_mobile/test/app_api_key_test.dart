import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/app_api_key.dart';

void main() {
  group('appApiKeyHeadersFor', () {
    test('sends a key as X-App-Key', () {
      expect(appApiKeyHeadersFor('k-123'), {'X-App-Key': 'k-123'});
    });

    test('sends no header at all for an empty key (a build without --dart-define=APP_API_KEY)', () {
      expect(appApiKeyHeadersFor(''), isEmpty);
    });
  });

  group('this build', () {
    test('the key comes from --dart-define=APP_API_KEY, never from the source', () {
      expect(appApiKey, const String.fromEnvironment('APP_API_KEY', defaultValue: ''));
      expect(appApiKeyHeaders, appApiKeyHeadersFor(appApiKey));
    });

    test('no key-like value is written in the app\'s source', () {
      final hex = RegExp(r'\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{32,}\b'); // hex, letters and digits
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        expect(hex.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
      }
    });

    test('the header name matches what mazama_sales\' web/access.py checks', () {
      expect(appApiKeyHeaderName, 'X-App-Key');
    });
  });
}
