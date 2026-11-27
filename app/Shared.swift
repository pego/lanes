// Shared by the Lanes app and its widget extension (compiled into
// both): the color palette and the usage snapshot the app publishes for the
// widget and for `lanes usage`.

import SwiftUI
import AppKit

// The brand: coral and azure, the two lanes of the logo. Each has a lighter
// shade for dark appearance and a deeper one that keeps its contrast on white.
// These tint controls and accents; the lanes themselves wear the profile colors.
enum Brand {
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        })
    }
    static let coral = adaptive(light: (0xE0, 0x56, 0x4B), dark: (0xF4, 0x73, 0x69))
    static let azure = adaptive(light: (0x1E, 0x88, 0xD6), dark: (0x88, 0xDC, 0xFF))
}

// Mirrors the HUES palette in bin/lanes — names must stay in sync.
struct ProfileColor: Identifiable, Hashable {
    let name: String
    let hue: Double        // degrees of hue rotation applied to Claude's icon
    let swatch: Color      // matching UI accent

    var id: String { name }

    static let all: [ProfileColor] = [
        ProfileColor(name: "orange", hue: 0,   swatch: Color(red: 0.85, green: 0.47, blue: 0.34)),
        ProfileColor(name: "red",    hue: -25, swatch: Color(red: 0.86, green: 0.34, blue: 0.32)),
        ProfileColor(name: "yellow", hue: 40,  swatch: Color(red: 0.80, green: 0.63, blue: 0.25)),
        ProfileColor(name: "green",  hue: 110, swatch: Color(red: 0.36, green: 0.69, blue: 0.42)),
        ProfileColor(name: "teal",   hue: 160, swatch: Color(red: 0.27, green: 0.65, blue: 0.62)),
        ProfileColor(name: "blue",   hue: 200, swatch: Color(red: 0.33, green: 0.56, blue: 0.83)),
        ProfileColor(name: "purple", hue: 250, swatch: Color(red: 0.62, green: 0.47, blue: 0.83)),
        ProfileColor(name: "pink",   hue: 310, swatch: Color(red: 0.83, green: 0.42, blue: 0.62)),
    ]

    static func named(_ name: String) -> ProfileColor {
        all.first { $0.name == name } ?? all[0]
    }
}

// Bar color for a usage percentage: the profile's color, orange from 75%, red from 90%.
func usageColor(_ value: Double?, tint: Color) -> Color {
    guard let value else { return .secondary }
    if value >= 90 { return .red }
    if value >= 75 { return .orange }
    return tint
}

// One rolling usage limit, as a provider reports it: how much of it is used,
// when it resets and how long its window runs. A provider reports one or
// several, in any lengths, shortest window first: Claude a 5-hour and a
// weekly one.
struct UsageLimit: Equatable, Identifiable {
    var key: String          // the provider's name for it: "five_hour"
    var label: String        // above its meter: "5 hours"
    var used: Double?        // percent
    var reset: Date?
    var window: TimeInterval
    // Where it's heading at the current rate (see Forecast).
    var pace: Pace? = nil
    var id: String { key }

    // Its name in alert bookkeeping ("Work/5h") and notifications: "5h", "7d".
    var tag: String { let s = Self.span(window); return "\(s.n)\(s.unit)" }
    // In tight spots (the widget): "5h", "Week".
    var compactLabel: String { window == Self.week ? "Week" : tag }
    // In sentences: "5-hour limit", "weekly limit".
    var noun: String {
        if window == Self.week { return "weekly limit" }
        let s = Self.span(window)
        return "\(s.n)-\(["m": "minute", "h": "hour", "d": "day"][s.unit]!) limit"
    }

    static let week: TimeInterval = 7 * 86400

    // A window in whole days, else whole hours, else minutes.
    static func span(_ w: TimeInterval) -> (n: Int, unit: String) {
        let s = Int(w.rounded())
        if s >= 86400, s % 86400 == 0 { return (s / 86400, "d") }
        if s >= 3600, s % 3600 == 0 { return (s / 3600, "h") }
        return (max(1, s / 60), "m")
    }

    // The window of a tag ("5h" → 5 hours), for a notification that outlived
    // its usage reading.
    static func window(ofTag tag: String) -> TimeInterval? {
        guard let unit = tag.last, let n = Double(tag.dropLast()), n > 0 else { return nil }
        switch unit {
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        default: return nil
        }
    }
}

// Where a limit is heading if usage keeps its recent rate.
struct Pace: Equatable {
    var atReset: Double     // projected percent when the window resets (capped at 100)
    var runsOutAt: Date?    // when it hits 100%, if that's before the reset
}

// Claude's two limits. Here rather than with ClaudeProvider because
// usage.json and usage.tsv have columns for exactly these two, and the
// widget, which only reads usage.json, draws them.
enum ClaudeLimit {
    static let fiveHourWindow: TimeInterval = 5 * 3600
    static let sevenDayWindow: TimeInterval = UsageLimit.week

    static func fiveHour(_ used: Double?, reset: Date?, pace: Pace? = nil) -> UsageLimit {
        UsageLimit(key: "five_hour", label: "5 hours", used: used, reset: reset, window: fiveHourWindow, pace: pace)
    }
    static func sevenDay(_ used: Double?, reset: Date?, pace: Pace? = nil) -> UsageLimit {
        UsageLimit(key: "seven_day", label: "Week", used: used, reset: reset, window: sevenDayWindow, pace: pace)
    }
}

// How far through its window a limit is (0…1), worked out from its reset
// time. Drawn as the pace marker on a meter: usage left of the marker is
// burning slower than the clock.
func elapsedFraction(reset: Date?, window: TimeInterval, now: Date = Date()) -> Double? {
    guard let reset else { return nil }
    let remaining = reset.timeIntervalSince(now)
    guard remaining > 0, remaining <= window else { return nil }
    return 1 - remaining / window
}

// A lane-style usage meter: a track, the used share in the profile's color
// (orange/red near the limit), an optional pace marker, and an optional
// projection: a faint extension to where usage will be when the limit resets.
struct LaneMeter: View {
    let value: Double?
    let tint: Color
    var pace: Double? = nil
    var projected: Double? = nil
    var height: CGFloat = 6

    private var fraction: Double { min(max((value ?? 0) / 100, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if let projected, projected > (value ?? 0) + 1 {
                    Capsule().fill(usageColor(projected, tint: tint).opacity(0.3))
                        .frame(width: max(height, w * min(projected / 100, 1)))
                }
                if fraction > 0 {
                    Capsule().fill(usageColor(value, tint: tint))
                        .frame(width: max(height, w * fraction))
                }
                if let pace {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2, height: height + 6)
                        .offset(x: min(max(w * pace - 1, 0), w - 2))
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
    }
}

// A weekly limit claude.ai reports for one model family on its own (e.g.
// "seven_day_opus"), next to the overall 5-hour and weekly ones.
struct ModelLimit: Codable, Equatable, Identifiable {
    var key: String       // as claude.ai names it: "seven_day_opus"
    var label: String     // "Opus"
    var used: Double      // percent
    var reset: Date?
    var id: String { key }
    // Not stored: every one is weekly.
    var window: TimeInterval { ClaudeLimit.sevenDayWindow }
}

// Written by the app after every usage refresh; read by the widget (sandboxed,
// with a read-only exception for this folder) and by `lanes usage --json`.
struct UsageSnapshot: Codable {
    struct Entry: Codable, Identifiable {
        var name: String
        var color: String
        var running: Bool
        var fiveHour: Double?
        var sevenDay: Double?
        var fiveHourReset: Date?
        var sevenDayReset: Date?
        var error: String?
        // When each limit runs out at the current pace, if before it resets.
        var fiveHourRunsOut: Date? = nil
        var sevenDayRunsOut: Date? = nil
        var limits: [ModelLimit]? = nil
        // Set when the last check failed and these are the previous numbers.
        var staleSince: Date? = nil
        var id: String { name }
    }
    var updated: Date
    var profiles: [Entry]

    // The file has a column pair for two limits: a profile's first (shortest
    // window) in fiveHour…, its second in sevenDay…. Named after Claude's,
    // whose windows they are: the file doesn't record windows.

    // The real home, not the sandbox container NSHomeDirectory() returns in the widget.
    static var directory: String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/Application Support/Lanes"
    }
    static var path: String { directory + "/usage.json" }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static func load() -> UsageSnapshot? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(UsageSnapshot.self, from: data)
    }
}

extension UsageSnapshot.Entry {
    // The two limits the file has columns for, as limits (see UsageSnapshot).
    var meters: [UsageLimit] {
        [ClaudeLimit.fiveHour(fiveHour, reset: fiveHourReset), ClaudeLimit.sevenDay(sevenDay, reset: sevenDayReset)]
    }
}
