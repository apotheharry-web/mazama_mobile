import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/text_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returns the recognized lines the native side hands back', () async {
    final channel = MethodChannel('mazama/text_scanner_test_1');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'scanLabel');
      return ['Lot: 579b4701', 'Net wt 0.50 g'];
    });
    final lines = await scanLabelText(channel: channel);
    expect(lines, ['Lot: 579b4701', 'Net wt 0.50 g']);
  });

  test('a null result (the worker backed out of the camera screen) throws ScanCancelled', () async {
    final channel = MethodChannel('mazama/text_scanner_test_2');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => null);
    await expectLater(scanLabelText(channel: channel), throwsA(isA<ScanCancelled>()));
  });

  test('a platform failure (camera permission denied, no camera, OCR error) surfaces as a PlatformException', () async {
    final channel = MethodChannel('mazama/text_scanner_test_3');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'CAMERA_DENIED', message: 'Camera access was denied.'),
    );
    await expectLater(scanLabelText(channel: channel), throwsA(isA<PlatformException>()));
  });
}
