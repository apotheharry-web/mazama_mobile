import Flutter
import Foundation
import WidgetKit

/// The native end of "mazama/cart_timer_widget" (lib/cart_timer_widget.dart): keeps the app's snapshot of every cart's
/// running timer where the cart timers widget extension (CartTimers/CartTimers.swift) reads it - the shared App Group's
/// defaults - and asks WidgetKit to redraw. "update" carries the snapshot as a JSON string; "clear" empties it.
///
/// WidgetKit is iOS 14+; the app still runs on 13 (OTHER_LDFLAGS weak-links WidgetKit), where there's no widget and
/// the reload is skipped.
final class CartTimerWidgetChannel {
    /// Must match CartTimers/CartTimers.swift and both .entitlements files.
    static let appGroup = "group.com.mazamamushrooms.mobile"
    static let snapshotKey = "cartTimersSnapshot"
    static let widgetKind = "CartTimers"

    private let channel: FlutterMethodChannel

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        channel.setMethodCallHandler { call, result in
            guard let defaults = UserDefaults(suiteName: CartTimerWidgetChannel.appGroup) else {
                result(FlutterError(code: "NO_APP_GROUP", message: "The cart timers widget's storage isn't available.", details: nil))
                return
            }
            switch call.method {
            case "update":
                guard let json = call.arguments as? String else {
                    result(FlutterError(code: "BAD_SNAPSHOT", message: "The cart timers snapshot couldn't be read.", details: nil))
                    return
                }
                defaults.set(json, forKey: CartTimerWidgetChannel.snapshotKey)
                CartTimerWidgetChannel.reload()
                result(nil)
            case "clear":
                defaults.removeObject(forKey: CartTimerWidgetChannel.snapshotKey)
                CartTimerWidgetChannel.reload()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func reload() {
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
    }
}
