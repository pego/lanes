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
                            let u = Usage(error: error.localizedDescription, formatChanged: isFormatError(error))
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

    // Each limit's pace from the profile's history. History keeps the first
    // two limits; the rest have no forecast. Readings from another window
    // (a plan change) don't count.
    static func forecast(_ u: inout Usage, history samples: [UsageSample], now: Date = Date()) {
        for i in u.limits.indices {
            let series = samples.compactMap { s in
                s.window(at: i) == u.limits[i].window ? s.value(at: i).map { (s.t, $0) } : nil
            }
            u.limits[i].pace = Forecast.pace(u.limits[i], samples: series, now: now)
        }
    }

    // How long a failed check may keep showing older numbers.
    static let staleGrace: TimeInterval = 3600

    func apply(_ fresh: Usage, for id: String, local: LocalUsage.Reading? = nil) {
        var u = Self.merge(fresh: fresh, previous: usage[id], previousAt: lastUsageUpdate, local: local)
        if u.error == nil, u.staleSince == nil { Self.forecast(&u, history: history[id] ?? []) }
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
    static func merge(fresh: Usage, previous prev: Usage?, previousAt: Date?, local: LocalReading?,
                      now: Date = Date()) -> Usage {
        guard fresh.error != nil, !fresh.needsSignIn else { return fresh }
        var best: (at: Date, usage: Usage)?
        if let prev, prev.error == nil, !prev.hasNoData {
            best = (prev.staleSince ?? previousAt ?? now, prev)
        }
        if let local, best.map({ local.t > $0.at }) ?? true {
            // Claude's record has no reset times: keep the previous ones only
            // for the window the reading falls in, and only while it's still open.
            func reset(_ r: Date?) -> Date? { r.flatMap { $0 > local.t && $0 > now ? $0 : nil } }
            var u = Usage(limits: local.limits.map { l in
                var l = l
                l.reset = reset(l.reset ?? prev?.limit(l.key)?.reset)
                return l
            }, error: nil)
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
        let entries = snapshotEntries()
        let dir = UsageSnapshot.directory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? UsageSnapshot.encoder.encode(UsageSnapshot(updated: now, profiles: entries)) {
            try? data.write(to: URL(fileURLWithPath: UsageSnapshot.path), options: .atomic)
        }
        try? Self.usageTSV(entries, updated: now).write(toFile: dir + "/usage.tsv", atomically: true, encoding: .utf8)

        // Stale numbers are a repeat of an older reading, not a new one.
        var h = history
        for e in entries where e.error == nil && e.staleSince == nil && (e.fiveHour != nil || e.sevenDay != nil) {
            UsageHistory.append(UsageSample(t: now, h: e.fiveHour, w: e.sevenDay,
                                            hWindow: e.fiveHourWindow, wWindow: e.sevenDayWindow),
                                to: &h[e.name, default: []])
        }
        UsageHistory.prune(&h, profiles: Set(entries.map(\.name)))
        if h != history { history = h; UsageHistory.save(h) }

        WidgetCenter.shared.reloadAllTimelines()
    }

    // A profile's first two limits go in the snapshot's two column pairs
    // (see UsageSnapshot); its per-model limits in `limits`.
    func snapshotEntries() -> [UsageSnapshot.Entry] {
        profiles.map { p -> UsageSnapshot.Entry in
            let u = usage[p.id]
            let first = u?.primary, second = u?.secondary
            let claude = p.providerID == Providers.claude.id
            return .init(name: p.name, color: p.colorName, running: running.contains(p.id),
                         fiveHour: first?.used, sevenDay: second?.used,
                         fiveHourReset: first?.reset, sevenDayReset: second?.reset, error: u?.error,
                         fiveHourRunsOut: first?.pace?.runsOutAt, sevenDayRunsOut: second?.pace?.runsOutAt,
                         limits: u.flatMap { $0.models.isEmpty ? nil : $0.models },
                         staleSince: u?.staleSince,
                         provider: claude ? nil : p.providerID,
                         fiveHourWindow: claude ? nil : first?.window,
                         sevenDayWindow: claude ? nil : second?.window)
        }
    }

    // One line per profile, tab-separated, for the shell: name color running
    // 5h% 5h-reset 7d% 7d-reset error 5h-runs-out 7d-runs-out models stale-since
    // provider window1 window2. Empty field = unknown; times are epoch;
    // models is "Opus=12@<reset>,Sonnet=3@<reset>". The "5h" and "7d"
    // columns are a profile's first and second limit, whose windows (in
    // seconds) are window1 and window2: Claude's are 18000 and 604800.
    // New columns only ever go at the end.
    static func usageTSV(_ entries: [UsageSnapshot.Entry], updated now: Date) -> String {
        func n(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "" }
        func t(_ d: Date?) -> String { d.map { String(Int($0.timeIntervalSince1970)) } ?? "" }
        func w(_ s: TimeInterval?) -> String { s.map { String(Int($0)) } ?? "" }
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
                    t(e.fiveHourRunsOut), t(e.sevenDayRunsOut), models, t(e.staleSince),
                    e.provider ?? Providers.claude.id, w(e.provider == nil ? ClaudeLimit.fiveHourWindow : e.fiveHourWindow),
                    w(e.provider == nil ? ClaudeLimit.sevenDayWindow : e.sevenDayWindow)]
                .joined(separator: "\t") + "\n"
        }
        return tsv
    }

    // Most headroom in the first limit (Claude's 5-hour one), the second
    // (weekly) as the tie-breaker; a profile whose second limit is used up
    // only wins if every one is. Among one provider's profiles: one app's
    // room says nothing about another's. Without a provider, Claude's, or
    // the first provider with any numbers.
    func bestProfile(provider: String? = nil) -> Profile? {
        guard let provider else {
            for p in Providers.all { if let b = bestProfile(provider: p.id) { return b } }
            return nil
        }
        let scored = profiles.compactMap { p -> (Profile, Double, Double)? in
            guard p.providerID == provider, let u = usage[p.id], u.error == nil, let h = u.primary?.used else { return nil }
            return (p, h, u.secondary?.used ?? 0)
        }
        let usable = scored.filter { $0.2 < 100 }
        return (usable.isEmpty ? scored : usable).min { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    // The best profile, but only when there's a real choice: two or more
    // profiles of that provider with usage numbers. Drives the "most room"
    // callouts.
    func roomiestProfile(provider: String? = nil) -> Profile? {
        guard let provider else {
            for p in Providers.all { if let b = roomiestProfile(provider: p.id) { return b } }
            return nil
        }
        let withData = profiles.filter {
            $0.providerID == provider && usage[$0.id]?.primary?.used != nil && usage[$0.id]?.error == nil
        }
        return withData.count >= 2 ? bestProfile(provider: provider) : nil
    }

    // "3 profiles · 1 running · most room in Work (92% left)"
    var summary: String {
        let n = profiles.count, r = running.count
        var parts = ["\(n) profile\(n == 1 ? "" : "s")", r == 0 ? "none running" : "\(r) running"]
        if let b = roomiestProfile(), let h = usage[b.id]?.primary?.used {
            parts.append("most room in \(b.name) (\(max(0, 100 - Int(h.rounded())))% left)")
        }
        return parts.joined(separator: " · ")
    }
}
