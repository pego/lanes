// Usage as Lanes keeps it, whatever the provider: the numbers, where they're
// heading, why they're missing; and the helpers every provider's reading
// shares (errors, time limits, reset texts). Reading it from a service is
// each provider's job (ClaudeProvider.swift).

import Foundation

// One profile's usage, as its provider last reported it.
struct Usage: Equatable {
    var fiveHour: Double?   // percent of the 5-hour limit used
    var sevenDay: Double?   // percent of the weekly limit used
    var fiveHourReset: Date?
    var sevenDayReset: Date?
    var error: String?
    // Weekly limits for single model families, when the account has them.
    var models: [ModelLimit] = []
    // Where each limit is heading at the current rate (see Forecast).
    var fiveHourPace: Pace? = nil
    var sevenDayPace: Pace? = nil
    // The last check failed (staleError), so these are the numbers from
    // staleSince: still shown, for up to an hour, rather than blanked.
    var staleError: String? = nil
    var staleSince: Date? = nil
    // Those older numbers come from the app's own record
    // (Provider.localUsage), not from Lanes' last reading.
    var fromLocalRecord = false
    // The failure looks like the service changed its usage endpoint rather than
    // a network hiccup: drives the "can't read usage" banner.
    var formatChanged = false

    var needsSignIn: Bool { error == "not signed in" || error == "session expired" }
    var hasNoData: Bool { error == nil && fiveHour == nil && sevenDay == nil }
}

// Where a limit is heading if usage keeps its recent rate.
struct Pace: Equatable {
    var atReset: Double     // projected percent when the window resets (capped at 100)
    var runsOutAt: Date?    // when it hits 100%, if that's before the reset
}

// "resets in 2h 10m" within a day, "resets Mon 09:30" beyond that.
func resetText(_ date: Date?) -> String? {
    guard let date else { return nil }
    let secs = date.timeIntervalSinceNow
    guard secs > 0 else { return nil }
    if secs < 3600 { return "resets in \(max(1, Int((secs / 60).rounded(.up)))) min" }
    if secs < 24 * 3600 {
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return m == 0 ? "resets in \(h)h" : "resets in \(h)h \(m)m"
    }
    return "resets " + clockText(date)
}

// "15:40" today, "Thu 15:40" on another day. English day names, like the rest
// of the app, whatever the system locale.
func clockText(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: date)
}

func parseISODate(_ v: Any?) -> Date? {
    guard let str = v as? String else { return nil }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return frac.date(from: str) ?? ISO8601DateFormatter().date(from: str)
}


// Code 2 marks a failure that points at the service's side having changed (an
// endpoint gone, a reply in another shape) rather than at this Mac.
func usageError(_ m: String, formatChanged: Bool = false) -> NSError {
    NSError(domain: "usage", code: formatChanged ? 2 : 1, userInfo: [NSLocalizedDescriptionKey: m])
}

func isFormatError(_ error: Error) -> Bool {
    let ns = error as NSError
    return (ns.domain == "usage" && ns.code == 2) || ns.domain == NSCocoaErrorDomain
}

// How long one profile's check may take, end to end, before it counts as
// failed: one slow or stuck profile must not hold up the others.
let usageTimeout: TimeInterval = 30

// MARK: Concurrency helpers

// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// Runs blocking work (a child process, a Keychain prompt) on a GCD thread.
func offCooperativePool<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        DispatchQueue.global(qos: .utility).async { c.resume(with: Result { try work() }) }
    }
}

// The result of `op`, or a "timed out" error after `seconds`, whichever
// comes first. The operation isn't cancelled (blocking work can't be); its
// late result is dropped.
func withTimeout<T>(_ seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { c in
        Task {
            let r: Result<T, Error>
            do { r = .success(try await op()) } catch { r = .failure(error) }
            if once.claim() { c.resume(with: r) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { c.resume(throwing: usageError("timed out")) }
        }
    }
}
