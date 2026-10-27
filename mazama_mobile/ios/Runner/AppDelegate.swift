import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Held for the app's lifetime - TextScanner's own init() is what wires up the "mazama/text_scanner" channel
  // handler (see TextScanner.swift), so this reference just needs to outlive that handler, not be called again.
  private var textScanner: TextScanner?
  private var cartTimerWidget: CartTimerWidgetChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    excludeAppSupportFromBackup()

    let controller = window?.rootViewController as! FlutterViewController
    let scanChannel = FlutterMethodChannel(name: "mazama/text_scanner", binaryMessenger: controller.binaryMessenger)
    textScanner = TextScanner(channel: scanChannel, presentingController: controller)
    // The cart timers home-screen widget (CartTimerWidget.swift): the app sends it every cart's running timer.
    let widgetChannel = FlutterMethodChannel(name: "mazama/cart_timer_widget", binaryMessenger: controller.binaryMessenger)
    cartTimerWidget = CartTimerWidgetChannel(channel: widgetChannel)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The app keeps the worker's state-system session (session.json: email, access and refresh tokens) and its other
  /// files in Application Support, which iOS includes in iCloud and computer backups by default. A restored copy would
  /// be a working sign-in on another device, so the whole folder is marked as excluded from backup (SIGN-IN-SECURITY.md,
  /// claim 9). Best effort: a failure leaves the folder as iOS made it.
  private func excludeAppSupportFromBackup() {
    guard var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
  }
}
