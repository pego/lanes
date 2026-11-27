// Lanes widget: per-profile usage bars on the desktop or in
// Notification Center. Draws the snapshot the menu bar app writes after each
// refresh (UsageSnapshot in Shared.swift); it never talks to claude.ai or
// reads cookies itself. The app asks WidgetKit to reload after every write;
// the timeline below is only the fallback.

import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snapshot: UsageSnapshot.load() ?? (context.isPreview ? .sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: Date(), snapshot: UsageSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

extension UsageSnapshot {
    static let sample = UsageSnapshot(updated: Date(), profiles: [
        .init(name: "Work", color: "blue", running: true, fiveHour: 62, sevenDay: 35,
              fiveHourReset: Date().addingTimeInterval(7200), sevenDayReset: Date().addingTimeInterval(3 * 86400)),
        .init(name: "Personal", color: "green", running: false, fiveHour: 12, sevenDay: 48,
              fiveHourReset: Date().addingTimeInterval(9000), sevenDayReset: Date().addingTimeInterval(5 * 86400)),
    ])
}

// lanes://launch?profile=<name> launches or focuses that profile;
// lanes://open pops the menu bar panel. Handled by the app.
func launchURL(_ name: String) -> URL {
    var c = URLComponents()
    c.scheme = "lanes"
    c.host = "launch"
    c.queryItems = [URLQueryItem(name: "profile", value: name)]
    return c.url!
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    private var maxRows: Int {
        switch family {
        case .systemSmall: return 4
        case .systemMedium: return 3
        default: return 7
        }
    }

    var body: some View {
        Group {
            if let snap = entry.snapshot, !snap.profiles.isEmpty {
                content(snap)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "road.lanes").font(.title2).foregroundStyle(.secondary)
                    Text("Open Lanes to load usage.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "lanes://open"))
    }

    private func content(_ snap: UsageSnapshot) -> some View {
        // Signed-in profiles first, busiest first: the ones worth watching.
        let rows = snap.profiles.sorted { a, b in
            let x = a.error == nil ? (a.meters.first?.used ?? -1) : -2
            let y = b.error == nil ? (b.meters.first?.used ?? -1) : -2
            return x > y
        }.prefix(maxRows)
        return VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            header(snap)
            ForEach(Array(rows)) { p in
                if family == .systemSmall {
                    SmallRow(p: p)
                } else {
                    Link(destination: launchURL(p.name)) { WideRow(p: p, showResets: family != .systemMedium || rows.count <= 2) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ snap: UsageSnapshot) -> some View {
        HStack(spacing: 4) {
            Text(family == .systemSmall ? "5-hour usage" : "Claude usage")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // Only worth saying when the app stopped refreshing.
            if Date().timeIntervalSince(snap.updated) > 30 * 60 {
                Text(snap.updated, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private func percent(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "—" }

private func statusText(_ p: UsageSnapshot.Entry) -> String? {
    guard let e = p.error else { return nil }
    return e == "not signed in" || e == "session expired" ? "Not signed in" : "Unavailable"
}

private struct SmallRow: View {
    let p: UsageSnapshot.Entry

    var body: some View {
        let tint = ProfileColor.named(p.color).swatch
        let first = p.meters.first
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Capsule().fill(tint.opacity(p.running ? 1 : 0.4)).frame(width: 3, height: 11)
                Text(p.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(statusText(p) ?? percent(first?.used))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if statusText(p) == nil, let first {
                LaneMeter(value: first.used, tint: tint,
                          pace: elapsedFraction(reset: first.reset, window: first.window), height: 4)
            }
        }
    }
}

private struct WideRow: View {
    let p: UsageSnapshot.Entry
    let showResets: Bool

    var body: some View {
        let tint = ProfileColor.named(p.color).swatch
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                Capsule().fill(tint.opacity(p.running ? 1 : 0.4)).frame(width: 3.5, height: 16)
                Text(p.name).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .frame(width: 80, alignment: .leading)
            if let status = statusText(p) {
                Text(status).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(p.meters) { m in column(m.compactLabel, m.used, m.reset, m.window, tint) }
            }
        }
    }

    private func column(_ label: String, _ value: Double?, _ reset: Date?, _ window: TimeInterval, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(percent(value)).font(.caption2.monospacedDigit().weight(.medium))
            }
            LaneMeter(value: value, tint: tint, pace: elapsedFraction(reset: reset, window: window), height: 5)
            if showResets, let reset, reset > Date() {
                // Counts down live without timeline reloads.
                Text(reset, style: .relative).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

@main
struct LanesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LanesUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("5-hour and weekly usage for each profile.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
