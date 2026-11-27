// ProfileStore: refreshing usage, publishing the snapshot for the widget and
// the CLI, and picking the profile with the most room.

import Foundation
import WidgetKit

extension ProfileStore {
    func scheduleUsageTimer() {
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: usageInterval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    // Called when the menu bar panel opens: skip the network if the data is fresh.
    func refreshUsageIfStale() {
        if let t = lastUsageUpdate, Date().timeIntervalSince(t) < 30 { return }
        refreshUsage()
    }

    func refreshUsage() {
        guard live, !isRefreshingUsage, !welcomePending else { return }
        isRefreshingUsage = true
        let targets = profiles.map { ($0.id, $0.provider, dataPath(of: $0)) }
        Task.detached {
            // All profiles at once, each with its own time limit, so one that
            // hangs (a stuck request, a slow disk) doesn't hold up the rest.
            await withTaskGroup(of: (String, Usage, LocalUsage.Reading?).self) { group in
                for (id, provider, dir) in targets {
                    group.addTask {
                        do { return (id, try await withTimeout(usageTimeout) { try await provider.fetchUsage(dataDir: dir) }, nil) }
                        catch {
                            let u = Usage(fiveHour: nil, sevenDay: nil, error: error.localizedDescription,
                                          formatChanged: isFormatError(error))
                            return (id, u, provider.localUsage(dataDir: dir))
                        }
                    }
                }
                for await (id, u, local) in group {
                    await MainActor.run { self.apply(u, for: id, local: local) }
                }
            }
            await MainActor.run {
                self.lastUsageUpdate = Date()
                self.isRefreshingUsage = false
                self.publishUsage()
                // Sign-ins and Keychain access just got their answer.
                self.checkHealth()
            }
        }
    }

    // How long a failed check may keep showing older numbers.
    static let staleGrace: TimeInterval = 3600

    func apply(_ fresh: Usage, for id: String, local: LocalUsage.Reading? = nil) {
        var u = Self.merge(fresh: fresh, previous: usage[id], previousAt: lastUsageUpdate, local: local)
        if u.error == nil, u.staleSince == nil {
            let samples = history[id] ?? []
            u.fiveHourPace = Forecast.pace(value: u.fiveHour, reset: u.fiveHourReset, window: LimitWindow.fiveHour,
                                           samples: samples.compactMap { s in s.h.map { (s.t, $0) } },
                                           lookback: 3600, minSpan: 15 * 60)
            u.sevenDayPace = Forecast.pace(value: u.sevenDay, reset: u.sevenDayReset, window: LimitWindow.week,
                                           samples: samples.compactMap { s in s.w.map { (s.t, $0) } },
                                           lookback: 86400, minSpan: 3 * 3600)
        }
        if usage[id] != u { usage[id] = u }
        guard u.staleError == nil else { return }
        scheduleResetAlerts(u, for: id)
        thresholdAlerts(u, for: id)
        paceAlerts(u, for: id)
    }

    // What a lane shows after a check. A failed check (network, the service
    // having a moment) doesn't blank the lane: for up to staleGrace it keeps
    // the newest older numbers there are, marked as stale. That's Lanes' own
    // last reading, or the app's own record when that one is newer (or
    // Lanes has none yet, as right after launching offline). Signing out
    // still clears the lane at once.
    static func merge(fresh: Usage, previous prev: Usage?, previousAt: Date?, local: LocalUsage.Reading?,
                      now: Date = Date()) -> Usage {
        guard fresh.error != nil, !fresh.needsSignIn else { return fresh }
        var best: (at: Date, usage: Usage)?
        if let prev, prev.error == nil, !prev.hasNoData {
            best = (prev.staleSince ?? previousAt ?? now, prev)
        }
        if let local, best.map({ local.t > $0.at }) ?? true {
            // No reset times in that record: keep the previous ones only for
            // the window the reading falls in, and only while it's still open.
            func reset(_ r: Date?) -> Date? { r.flatMap { $0 > local.t && $0 > now ? $0 : nil } }
            var u = Usage(fiveHour: local.fiveHour, sevenDay: local.sevenDay,
                          fiveHourReset: reset(prev?.fiveHourReset), sevenDayReset: reset(prev?.sevenDayReset),
                          error: nil)
            u.fromLocalRecord = true
            best = (local.t, u)
        }
        guard let best, now.timeIntervalSince(best.at) < staleGrace else { return fresh }
        var u = best.usage
        u.staleError = fresh.error
        u.staleSince = best.at
        u.formatChanged = fresh.formatChanged
        return u
    }

    // Writes usage.json (widget, `lanes usage --json`) and usage.tsv (`lanes usage`,
    // `lanes launch --best`), records history, and asks WidgetKit to redraw.
    func publishUsage() {
        let now = Date()
        let entries = profiles.map { p -> UsageSnapshot.Entry in
            let u = usage[p.id]
            return .init(name: p.name, color: p.colorName, running: running.contains(p.id),
                         fiveHour: u?.fiveHour, sevenDay: u?.sevenDay,
                         fiveHourReset: u?.fiveHourReset, sevenDayReset: u?.sevenDayReset, error: u?.error,
                         fiveHourRunsOut: u?.fiveHourPace?.runsOutAt, sevenDayRunsOut: u?.sevenDayPace?.runsOutAt,
                         limits: u.flatMap { $0.models.isEmpty ? nil : $0.models },
                         staleSince: u?.staleSince)
        }
        let dir = UsageSnapshot.directory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? UsageSnapshot.encoder.encode(UsageSnapshot(updated: now, profiles: entries)) {
            try? data.write(to: URL(fileURLWithPath: UsageSnapshot.path), options: .atomic)
        }
        // One line per profile, tab-separated, for the shell: name color running
        // 5h% 5h-reset 7d% 7d-reset error 5h-runs-out 7d-runs-out models stale-since.
        // Empty field = unknown; times are epoch; models is
        // "Opus=12@<reset>,Sonnet=3@<reset>". New columns only ever go at the end.
        func n(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "" }
        func t(_ d: Date?) -> String { d.map { String(Int($0.timeIntervalSince1970)) } ?? "" }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        var tsv = "# updated \(Int(now.timeIntervalSince1970))\n"
        for e in entries {
            let models = (e.limits ?? []).map {
                clean($0.label).replacingOccurrences(of: ",", with: " ") + "=" + n($0.used) + "@" + t($0.reset)
            }.joined(separator: ",")
            tsv += [e.name, e.color, e.running ? "1" : "0", n(e.fiveHour), t(e.fiveHourReset),
                    n(e.sevenDay), t(e.sevenDayReset), clean(e.error ?? ""),
                    t(e.fiveHourRunsOut), t(e.sevenDayRunsOut), models, t(e.staleSince)]
                .joined(separator: "\t") + "\n"
        }
        try? tsv.write(toFile: dir + "/usage.tsv", atomically: true, encoding: .utf8)

        // Stale numbers are a repeat of an older reading, not a new one.
        var h = history
        for e in entries where e.error == nil && e.staleSince == nil && (e.fiveHour != nil || e.sevenDay != nil) {
            UsageHistory.append(UsageSample(t: now, h: e.fiveHour, w: e.sevenDay), to: &h[e.name, default: []])
        }
        UsageHistory.prune(&h, profiles: Set(entries.map(\.name)))
        if h != history { history = h; UsageHistory.save(h) }

        WidgetCenter.shared.reloadAllTimelines()
    }

    // Most 5-hour headroom, weekly as the tie-breaker; a profile whose weekly
    // limit is used up only wins if every one is.
    func bestProfile() -> Profile? {
        let scored = profiles.compactMap { p -> (Profile, Double, Double)? in
            guard let u = usage[p.id], u.error == nil, let h = u.fiveHour else { return nil }
            return (p, h, u.sevenDay ?? 0)
        }
        let usable = scored.filter { $0.2 < 100 }
        return (usable.isEmpty ? scored : usable).min { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    // The best profile, but only when there's a real choice: two or more
    // profiles with usage numbers. Drives the "most room" callouts.
    func roomiestProfile() -> Profile? {
        let withData = profiles.filter { usage[$0.id]?.fiveHour != nil && usage[$0.id]?.error == nil }
        return withData.count >= 2 ? bestProfile() : nil
    }

    // "3 profiles · 1 running · most room in Work (92% left)"
    var summary: String {
        let n = profiles.count, r = running.count
        var parts = ["\(n) profile\(n == 1 ? "" : "s")", r == 0 ? "none running" : "\(r) running"]
        if let b = roomiestProfile(), let h = usage[b.id]?.fiveHour {
            parts.append("most room in \(b.name) (\(max(0, 100 - Int(h.rounded())))% left)")
        }
        return parts.joined(separator: " · ")
    }
}
