// Usage history (the drawer's chart, CSV export) and the forecast built on it.

import Foundation

// One usage reading. Short keys: the file holds a week of them per profile.
// It keeps a profile's first two limits (Usage.primary, .secondary), named
// after Claude's; hw and ww are their windows in seconds, written only when
// they aren't Claude's (5 hours, a week), so Claude's readings stay as they
// were.
struct UsageSample: Codable, Equatable {
    var t: Date
    var h: Double?   // 5-hour % (the first limit)
    var w: Double?   // weekly % (the second)
    var hw: Double? = nil
    var ww: Double? = nil

    init(t: Date, h: Double?, w: Double?, hWindow: TimeInterval? = nil, wWindow: TimeInterval? = nil) {
        self.t = t
        self.h = h
        self.w = w
        hw = hWindow == ClaudeLimit.fiveHourWindow ? nil : hWindow
        ww = wWindow == ClaudeLimit.sevenDayWindow ? nil : wWindow
    }

    // The reading of the profile's limit at `index` (in Usage.limits).
    func value(at index: Int) -> Double? { index == 0 ? h : index == 1 ? w : nil }
    // How long that limit's window ran when this was read.
    func window(at index: Int) -> TimeInterval? {
        index == 0 ? hw ?? ClaudeLimit.fiveHourWindow : index == 1 ? ww ?? ClaudeLimit.sevenDayWindow : nil
    }
}

// 30 days of readings per profile in usage-history.json, at most one every
// ~10 minutes whatever the refresh interval (about 200 KB per profile).
// Local only, never sent anywhere.
enum UsageHistory {
    static let keep: TimeInterval = 30 * 86400
    static var path: String { UsageSnapshot.directory + "/usage-history.json" }

    static func load() -> [String: [UsageSample]] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode([String: [UsageSample]].self, from: data)) ?? [:]
    }

    static func save(_ h: [String: [UsageSample]]) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        if let data = try? e.encode(h) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }

    static func append(_ s: UsageSample, to list: inout [UsageSample]) {
        if let last = list.last, s.t.timeIntervalSince(last.t) < 9 * 60 { return }
        list.append(s)
    }

    static func prune(_ h: inout [String: [UsageSample]], profiles: Set<String>) {
        let cutoff = Date().addingTimeInterval(-keep)
        for k in h.keys {
            if !profiles.contains(k) { h[k] = nil; continue }
            h[k]?.removeAll { $0.t < cutoff }
        }
    }

    // time,five_hour,weekly: ISO 8601 UTC times, empty when unknown.
    // Same columns as `lanes history`, minus the profile.
    static func csv(_ samples: [UsageSample]) -> String {
        let f = ISO8601DateFormatter()
        func n(_ v: Double?) -> String { v.map { String(format: "%g", $0) } ?? "" }
        return "time,five_hour,weekly\n" + samples.map { "\(f.string(from: $0.t)),\(n($0.h)),\(n($0.w))\n" }.joined()
    }
}

// The times that depend on how long a limit's window runs: how far back the
// forecast looks and how much history it needs, and how early a pace alert
// fires. Tuned by hand on Claude's two windows, 5 hours and a week; any
// other length gets a value between (or beyond) those two, interpolated on
// a log scale, so Claude's come out exactly as tuned.
struct WindowTiming {
    let window: TimeInterval

    static let short: TimeInterval = 5 * 3600
    static let long: TimeInterval = 7 * 86400

    // `atShort` for a 5-hour window, `atLong` for a week.
    static func scaled(_ window: TimeInterval, atShort: TimeInterval, atLong: TimeInterval) -> TimeInterval {
        if window == short { return atShort }
        if window == long { return atLong }
        guard window > 0 else { return atShort }
        let t = log(window / short) / log(long / short)
        return (atShort * pow(atLong / atShort, t)).rounded()
    }

    // The forecast's rate is measured over this much of the recent past…
    var lookback: TimeInterval { Self.scaled(window, atShort: 3600, atLong: 86400) }
    // …from a reading at least this old.
    var minSpan: TimeInterval { Self.scaled(window, atShort: 15 * 60, atLong: 3 * 3600) }
    // A pace alert fires when the limit runs out within this…
    var paceSoon: TimeInterval { Self.scaled(window, atShort: 45 * 60, atLong: 86400) }
    // …and at least this long before it resets.
    var paceSpare: TimeInterval { Self.scaled(window, atShort: 15 * 60, atLong: 6 * 3600) }
}

extension UsageLimit {
    var timing: WindowTiming { WindowTiming(window: window) }
}

// Where a limit is heading: its rate over the recent past (the last hour for
// the 5-hour limit, the last day for the weekly one; see WindowTiming), but
// only within the current window, so the drop at the last reset never
// counts. Needs a reading at least `minSpan` old to say anything. Usage that
// went down (a reset the readings straddle) counts as no usage.
enum Forecast {
    static func pace(_ limit: UsageLimit, samples: [(Date, Double)], now: Date = Date()) -> Pace? {
        pace(value: limit.used, reset: limit.reset, window: limit.window, samples: samples,
             lookback: limit.timing.lookback, minSpan: limit.timing.minSpan, now: now)
    }

    static func pace(value: Double?, reset: Date?, window: TimeInterval, samples: [(Date, Double)],
                     lookback: TimeInterval, minSpan: TimeInterval, now: Date = Date()) -> Pace? {
        guard let value, let reset, value < 100 else { return nil }
        let left = reset.timeIntervalSince(now)
        guard left > 0, left <= window else { return nil }
        let from = max(reset.addingTimeInterval(-window), now.addingTimeInterval(-lookback))
        guard let first = samples.first(where: { $0.0 >= from && $0.0 < now }) else { return nil }
        let span = now.timeIntervalSince(first.0)
        guard span >= minSpan else { return nil }
        let rate = max(0, (value - first.1) / span)          // percent per second
        let runsOut = rate > 0 ? (100 - value) / rate : .infinity
        return Pace(atReset: min(100, value + rate * left),
                    runsOutAt: runsOut < left ? now.addingTimeInterval(runsOut) : nil)
    }
}
