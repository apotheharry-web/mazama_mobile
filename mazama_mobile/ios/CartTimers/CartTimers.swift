// The cart timers home-screen widget (specs/multi-cart MC-D15): every cart's running session timer at the center the
// app was last on. The app writes a snapshot to the shared App Group (Runner/CartTimerWidget.swift, from
// lib/cart_timer_widget.dart) whenever a timer, a cart's lines or the list of carts changes, and reloads this widget.
// The snapshot holds moments (when each timer started, when its session ends), so each row counts on its own with
// Text(_, style: .timer) while the app is closed. Nothing here decides a number: the session end comes from the app.
import SwiftUI
import WidgetKit

/// Must match Runner/CartTimerWidget.swift and both .entitlements files.
private let appGroup = "group.com.mazamamushrooms.mobile"
private let snapshotKey = "cartTimersSnapshot"
private let widgetKind = "CartTimers"

/// One running timer. `endMs` is absent when its dose gives no session length: it counts up.
struct CartTimer: Decodable, Identifiable {
    let id: String
    let name: String
    let startMs: Double
    let endMs: Double?
    let booster: Bool

    var start: Date { Date(timeIntervalSince1970: startMs / 1000) }
    var end: Date? { endMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// The app's snapshot (cartTimerSnapshot in lib/cart_timer_widget.dart).
struct CartTimersSnapshot: Decodable {
    let version: Int
    let center: String
    let maxAgeMs: Double
    let carts: [CartTimer]

    /// Nil when nothing is stored, or it isn't a snapshot of this version.
    static func load() -> CartTimersSnapshot? {
        guard let json = UserDefaults(suiteName: appGroup)?.string(forKey: snapshotKey),
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CartTimersSnapshot.self, from: data),
              snapshot.version == 1
        else { return nil }
        return snapshot
    }

    /// The timers still running at [date]: one past maxAge is reset by the app (sessionTimerMaxAge), so it's gone.
    func running(at date: Date) -> [CartTimer] {
        carts.filter { date.timeIntervalSince($0.start) < maxAgeMs / 1000 }
    }

    /// The moments after [date] a row changes by itself: a session running out (left -> over), a timer aging out.
    func changes(after date: Date) -> [Date] {
        let moments = carts.flatMap { [$0.end, $0.start.addingTimeInterval(maxAgeMs / 1000)].compactMap { $0 } }
        return Array(Set(moments.filter { $0 > date })).sorted()
    }

    /// What the widget gallery shows before the app has sent anything.
    static var preview: CartTimersSnapshot {
        let now = Date().timeIntervalSince1970 * 1000
        let minute = 60_000.0
        return CartTimersSnapshot(version: 1, center: "", maxAgeMs: 8 * 60 * minute, carts: [
            CartTimer(id: "a", name: "Cart 1", startMs: now - 25 * minute, endMs: now + 215 * minute, booster: false),
            CartTimer(id: "b", name: "Cart 2", startMs: now - 70 * minute, endMs: now + 50 * minute, booster: true),
        ])
    }
}

struct CartTimersEntry: TimelineEntry {
    let date: Date
    let snapshot: CartTimersSnapshot?
}

struct CartTimersProvider: TimelineProvider {
    func placeholder(in context: Context) -> CartTimersEntry {
        CartTimersEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (CartTimersEntry) -> Void) {
        let stored = CartTimersSnapshot.load()
        completion(CartTimersEntry(date: Date(), snapshot: context.isPreview ? (stored ?? .preview) : stored))
    }

    /// One entry now and one at each moment a row changes; the clocks tick between them on their own. Never asks
    /// again by itself: the app reloads this whenever its timers change.
    func getTimeline(in context: Context, completion: @escaping (Timeline<CartTimersEntry>) -> Void) {
        let now = Date()
        let snapshot = CartTimersSnapshot.load()
        let dates = [now] + (snapshot?.changes(after: now) ?? [])
        completion(Timeline(entries: dates.map { CartTimersEntry(date: $0, snapshot: snapshot) }, policy: .never))
    }
}

/// A row's clock, as the app's carts list words it (MC-D14): counting down to the session's end ("left", "left w/
/// booster"), then up from it ("over · time up"); with no session length, up from the start ("elapsed").
/// Text(_, style: .timer) counts down to a future date and up from a past one, so one reference date does both.
private struct ClockState {
    let reference: Date
    let note: String
    let over: Bool

    init(_ timer: CartTimer, at date: Date) {
        if let end = timer.end {
            reference = end
            over = date >= end
            note = over ? "over · time up" : (timer.booster ? "left w/ booster" : "left")
        } else {
            reference = timer.start
            over = false
            note = "elapsed"
        }
    }
}

struct CartTimersView: View {
    let entry: CartTimersEntry
    @Environment(\.widgetFamily) private var family

    private var maxRows: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 4
        default: return 10 // cart_slots.dart maxCartsPerCenter
        }
    }

    private var title: String {
        let center = entry.snapshot?.center ?? ""
        return center.isEmpty ? "Cart timers" : "Cart timers · \(center)"
    }

    var body: some View {
        let running = entry.snapshot?.running(at: entry.date) ?? []
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if running.isEmpty {
                Text("No timers running")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(running.prefix(maxRows)) { timer in
                    row(timer)
                }
                if running.count > maxRows {
                    Text("+\(running.count - maxRows) more")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(_ timer: CartTimer) -> some View {
        let state = ClockState(timer, at: entry.date)
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 0) {
                name(timer).font(.caption)
                clock(state, alignment: .leading)
            }
        } else {
            // A .timer Text takes all the width it's offered, so the name is laid out first and the clock, right
            // aligned, gets what's left.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                name(timer).font(.subheadline).layoutPriority(1)
                clock(state, alignment: .trailing)
            }
        }
    }

    /// A cart's name may be a client's: hidden wherever the system redacts private widget content (locked screens).
    @ViewBuilder
    private func name(_ timer: CartTimer) -> some View {
        if #available(iOSApplicationExtension 15.0, *) {
            Text(timer.name).lineLimit(1).privacySensitive()
        } else {
            Text(timer.name).lineLimit(1)
        }
    }

    private func clock(_ state: ClockState, alignment: TextAlignment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(state.reference, style: .timer)
                .font(Font.body.monospacedDigit().weight(.semibold))
                .multilineTextAlignment(alignment)
                .foregroundColor(state.over ? .red : .primary)
            Text(state.note)
                .font(.caption2)
                .foregroundColor(state.over ? .red : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private extension View {
    /// iOS 17 draws a widget's background (and margins) itself and shows nothing without this; before, it's ours.
    @ViewBuilder
    func cartTimersBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(for: .widget) { Color(UIColor.systemBackground) }
        } else {
            padding().background(Color(UIColor.systemBackground))
        }
    }
}

@main
struct CartTimersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: CartTimersProvider()) { entry in
            CartTimersView(entry: entry).cartTimersBackground()
        }
        .configurationDisplayName("Cart timers")
        .description("Every cart's running session timer at your service center.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
