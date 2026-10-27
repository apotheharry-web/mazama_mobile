// This phone's own native text recognizer - Apple's Vision framework on iOS, Google ML Kit's text recognition
// on Android - reached through a plain MethodChannel, not a pub.dev OCR plugin. Same reasoning as
// device_id.dart/cart_store.dart avoiding a new pub.dev dependency: no package version can be verified against
// the real registry from this sandbox, and both frameworks already ship with their OS, so a thin hand-written
// channel needs nothing from pub.dev on either side. The Swift/Kotlin half this calls into is
// ios/Runner/TextScanner.swift and android/app/src/main/kotlin/com/example/mazama_mobile/TextScanner.kt;
// cart_page.dart's _onScanPressed shows how the result is used.
//
// The native side does the camera work too - it opens the platform's own camera capture screen, takes the
// photo, and runs ML Kit/Vision on it - so nothing here ever touches camera frames or image bytes, only the
// lines of text that came out the other end. That keeps this exactly as "lightweight" on the phone as every
// other client in this app (packages_client.dart, label_client.dart): the actual fuzzy matching against
// inventory - the same ocr.find_ids/ocr.closest heuristics the server's Tesseract path already uses - happens
// server-side too, in scan_match_client.dart, not here.
import 'package:flutter/services.dart';

const _channel = MethodChannel('mazama/text_scanner');

/// Thrown when the worker backs out of the native camera screen (or declines the camera permission prompt)
/// without ever taking a photo. Not an error - "there is nothing to scan" - so _onScanPressed can stay silent
/// about it exactly the way _onAddPkpr already stays silent about a cancelled line dialog.
class ScanCancelled implements Exception {}

/// Opens the native camera + on-device text recognizer and returns every line of text it found (best guess at
/// line order - the same shape a photo's own OCR passes already produce for scan_match_client.dart to send on).
/// Throws [ScanCancelled] if the worker backed out, or a [PlatformException] for anything else that went wrong
/// (camera permission denied, no camera on this device, the recognizer itself erroring) - the message is
/// written to be shown to the worker directly, same as every other client error type in this app.
///
/// [channel] is overridable for tests, the same pattern CartPage's own fields use for every other call this app
/// makes - a widget test never reaches a real platform channel (there's no native host to answer it in a test
/// run at all), so it supplies a fake MethodChannel via setMockMethodCallHandler instead.
Future<List<String>> scanLabelText({MethodChannel? channel}) async {
  final ch = channel ?? _channel;
  final Object? result = await ch.invokeMethod('scanLabel');
  if (result == null) throw ScanCancelled();
  return List<String>.from(result as List);
}
