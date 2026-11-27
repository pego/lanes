// Claude Desktop as a provider: where it's installed, how its processes
// look, and reading its usage from claude.ai with each profile's own
// session cookies, with the local file Claude Desktop keeps as a fallback.

import AppKit
import CommonCrypto

struct ClaudeProvider: Provider {
    let id = "claude"
    let name = "Claude"
    let desktopName = "Claude Desktop"
    var appCandidates: [String] { ["/Applications/Claude.app", NSHomeDirectory() + "/Applications/Claude.app"] }
    var appPath: String { Self.installed }
    var icon: NSImage { Self.appIcon }
    let executable = "Claude"
    let bundleID = "com.anthropic.claudefordesktop"
    let configEnv = "CLAUDE_CONFIG_DIR"
    let configSubdir = "claude-config"
    let linkScheme: String? = "claude"
    let updater = UpdaterKind.squirrel
    let iconStyle = IconStyle.hueShift
    var defaultDataDir: String { NSHomeDirectory() + "/Library/Application Support/Claude" }
    let usageService = "claude.ai"
    let keychainItem: String? = "Claude Safe Storage"
    let downloadURL = URL(string: "https://claude.ai/download")!

    func fetchUsage(dataDir: String) async throws -> Usage { try await fetchClaudeUsage(dataDir: dataDir) }
    func localUsage(dataDir: String) -> LocalReading? { LocalUsage.latest(dataDir: dataDir) }

    private static let installed = installedApp(Providers.claude.appCandidates)
    // Read once: every lane, sheet and preview draws it, tinted per profile.
    private static let appIcon = NSWorkspace.shared.icon(forFile: installed)
}

// MARK: Claude's limits

// Usage in Claude's terms: its 5-hour and weekly limits by name. Claude's
// usage always carries both, in that order, even when one is unknown.
extension Usage {
    init(fiveHour: Double?, sevenDay: Double?, fiveHourReset: Date? = nil, sevenDayReset: Date? = nil,
         error: String? = nil, models: [ModelLimit] = [], fiveHourPace: Pace? = nil, sevenDayPace: Pace? = nil,
         formatChanged: Bool = false) {
        self.init(limits: [ClaudeLimit.fiveHour(fiveHour, reset: fiveHourReset, pace: fiveHourPace),
                           ClaudeLimit.sevenDay(sevenDay, reset: sevenDayReset, pace: sevenDayPace)],
                  error: error, models: models, formatChanged: formatChanged)
    }

    private mutating func update(_ key: String, _ change: (inout UsageLimit) -> Void) {
        if let i = limits.firstIndex(where: { $0.key == key }) { change(&limits[i]); return }
        var l = key == "five_hour" ? ClaudeLimit.fiveHour(nil, reset: nil) : ClaudeLimit.sevenDay(nil, reset: nil)
        change(&l)
        limits.append(l)
        limits.sort { $0.window < $1.window }
    }

    var fiveHour: Double? {
        get { limit("five_hour")?.used }
        set { update("five_hour") { $0.used = newValue } }
    }
    var sevenDay: Double? {
        get { limit("seven_day")?.used }
        set { update("seven_day") { $0.used = newValue } }
    }
    var fiveHourReset: Date? {
        get { limit("five_hour")?.reset }
        set { update("five_hour") { $0.reset = newValue } }
    }
    var sevenDayReset: Date? {
        get { limit("seven_day")?.reset }
        set { update("seven_day") { $0.reset = newValue } }
    }
    var fiveHourPace: Pace? { limit("five_hour")?.pace }
    var sevenDayPace: Pace? { limit("seven_day")?.pace }
}

extension LocalReading {
    init(t: Date, fiveHour: Double?, sevenDay: Double?) {
        self.init(t: t, limits: [ClaudeLimit.fiveHour(fiveHour, reset: nil), ClaudeLimit.sevenDay(sevenDay, reset: nil)])
    }
    var fiveHour: Double? { limits.first { $0.key == "five_hour" }?.used }
    var sevenDay: Double? { limits.first { $0.key == "seven_day" }?.used }
}

// "Opus" for "seven_day_opus".
func modelLimitLabel(_ key: String) -> String {
    let suffix = String(key.dropFirst("seven_day_".count))
    let known = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku", "oauth_apps": "Apps"]
    return known[suffix] ?? suffix.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

// MARK: Session cookies

// The key that decrypts Claude's cookies, derived from the "Claude Safe
// Storage" Keychain item. Every profile shares it (clones share Claude's
// signature), so it's read once and kept in memory: profiles checked in
// parallel would otherwise each ask the Keychain, and each could prompt.
// A failed read (the prompt denied) is remembered for a minute, so one
// refresh can't stack a prompt per profile.
enum ChromiumKey {
    private static let lock = NSLock()
    private static var cached: Data?
    private static var failure: (error: Error, at: Date)?
    static let retryAfter: TimeInterval = 60

    static func get() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let failure, Date().timeIntervalSince(failure.at) < retryAfter { throw failure.error }
        do {
            // macOS asks once; "Always Allow" makes it silent afterwards.
            let pw: String
            do {
                pw = try runTool("/usr/bin/security", ["find-generic-password", "-w", "-s", Providers.claude.keychainItem!])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                // security's own wording is no help on a lane: say which case it is.
                throw usageError(error.localizedDescription.contains("could not be found")
                                 ? "\(Providers.claude.name)'s Keychain item is missing" : "no Keychain access")
            }
            let key = try derive(password: pw)
            cached = key
            failure = nil
            return key
        } catch {
            failure = (error, Date())
            throw error
        }
    }

    // Dropped when it no longer decrypts anything (the Keychain item changed).
    static func forget() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    // "Try Again" from Settings > Status: ask the Keychain on the next check,
    // even within a minute of a denial.
    static func reset() {
        lock.lock()
        cached = nil
        failure = nil
        lock.unlock()
    }

    enum State { case unknown, ok, denied(String) }
    // Never waits: while a read holds the lock (a Keychain prompt may be up),
    // the answer is "unknown", not a frozen main thread.
    static var state: State {
        guard lock.try() else { return .unknown }
        defer { lock.unlock() }
        if cached != nil { return .ok }
        if let failure { return .denied(failure.error.localizedDescription) }
        return .unknown
    }

    static func derive(password pw: String) throws -> Data {
        var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { k in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.utf8.count, Array("saltysalt".utf8), 9,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 k.bindMemory(to: UInt8.self).baseAddress, 16)
        }
        guard status == kCCSuccess else { throw usageError("key derivation failed") }
        return key
    }
}

func decryptCookie(_ blob: Data, key: Data) -> String? {
    guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
    let body = blob.dropFirst(3)
    var out = Data(count: body.count + kCCBlockSizeAES128)
    var n = 0
    let iv = [UInt8](repeating: 0x20, count: 16)
    let outCap = out.count
    let status = out.withUnsafeMutableBytes { o in
        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                [UInt8](key), 16, iv, [UInt8](body), body.count, o.baseAddress, outCap, &n)
    }
    guard status == kCCSuccess else { return nil }
    let plain = out.prefix(n)
    // Newer Chromium prepends a 32-byte host hash; random bytes are not valid UTF-8.
    if let s = String(data: plain, encoding: .utf8) { return s }
    // Too short to hold that hash: garbage from a wrong key, not a value.
    guard plain.count > 32 else { return nil }
    return String(data: plain.dropFirst(32), encoding: .utf8)
}

private func claudeCookieHeader(dataDir: String) throws -> String {
    let fm = FileManager.default
    guard let src = [dataDir + "/Network/Cookies", dataDir + "/Cookies"].first(where: fm.fileExists)
    else { throw usageError("not signed in") }
    // Copy first: Claude keeps the live database locked while it runs.
    let tmp = NSTemporaryDirectory() + "lanes-cookies-\(UUID().uuidString)"
    defer { for e in ["", "-wal", "-journal"] { try? fm.removeItem(atPath: tmp + e) } }
    for e in ["", "-wal", "-journal"] where fm.fileExists(atPath: src + e) { try fm.copyItem(atPath: src + e, toPath: tmp + e) }
    let rows = try runTool("/usr/bin/sqlite3", [tmp, "SELECT name || '|' || hex(encrypted_value) FROM cookies WHERE host_key LIKE '%claude.ai'"])
        .split(separator: "\n").compactMap { row -> (String, Data)? in
            let f = row.split(separator: "|", maxSplits: 1).map(String.init)
            guard f.count == 2, let blob = Data(hexString: f[1]) else { return nil }
            return (f[0], blob)
        }
    func decrypted(with key: Data) -> [String] {
        rows.compactMap { name, blob in decryptCookie(blob, key: key).map { "\(name)=\($0)" } }
    }
    var pairs = decrypted(with: try ChromiumKey.get())
    // Cookies there, yet none decrypts: the remembered key is out of date.
    if pairs.isEmpty, !rows.isEmpty {
        ChromiumKey.forget()
        pairs = decrypted(with: try ChromiumKey.get())
    }
    guard pairs.contains(where: { $0.hasPrefix("sessionKey=") }) else { throw usageError("not signed in") }
    return pairs.joined(separator: "; ")
}

extension Data {
    init?(hexString h: String) {
        guard h.count % 2 == 0 else { return nil }
        var d = Data(), i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}

// MARK: claude.ai

// Reads the same numbers as Settings > Usage by calling claude.ai with the
// profile's own session cookies, decrypted from its Electron cookie jar.
// shortcut: undocumented endpoint, may change without notice; the cookies are
// only read, never stored, and only sent to claude.ai.
func fetchClaudeUsage(dataDir: String) async throws -> Usage {
    // The cookie read shells out (sqlite3, and the Keychain, which may wait
    // on a prompt): kept off Swift's cooperative threads.
    let cookie = try await offCooperativePool { try claudeCookieHeader(dataDir: dataDir) }
    func get(_ path: String) async throws -> Any {
        var r = URLRequest(url: URL(string: "https://claude.ai/api" + path)!, timeoutInterval: 20)
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
                   forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw usageError(code == 401 || code == 403 ? "session expired" : "HTTP \(code)", formatChanged: code == 404)
        }
        return try JSONSerialization.jsonObject(with: data)
    }
    let result = try await usage(organizations: try await get("/organizations")) { id in
        try await get("/organizations/\(id)/usage")
    }
    if result.usage.error != nil || result.usage.hasNoData { writeUsageDebug(dataDir: dataDir, raw: result.raw) }
    return result.usage
}

// Picks the usage out of claude.ai's replies: the organization list, then
// each organization's usage until one reports numbers. Separate from the
// network so the parsing can be tested against saved replies.
func usage(organizations: Any,
           reply: (String) async throws -> Any) async throws -> (usage: Usage, raw: [[String: Any]]) {
    guard let orgs = organizations as? [[String: Any]], !orgs.isEmpty else { throw usageError("no organization") }
    // An account can belong to several organizations (API/Console, team, personal);
    // only some carry chat usage limits, so try each until one reports numbers.
    var raw: [[String: Any]] = []
    var best: Usage?
    for o in orgs {
        guard let id = o["uuid"] as? String,
              let j = try? await reply(id) as? [String: Any] else { continue }
        let u = parseUsageReply(j)
        raw.append(["org": id, "name": o["name"] ?? "", "capabilities": o["capabilities"] ?? [], "usage": j])
        if u.fiveHour != nil || u.sevenDay != nil { return (u, raw) }
        best = best ?? u
    }
    // Not one organization answered: the endpoint itself is likely gone.
    return (best ?? Usage(fiveHour: nil, sevenDay: nil, error: "unexpected response", formatChanged: true), raw)
}

// One organization's /usage reply.
func parseUsageReply(_ j: [String: Any]) -> Usage {
    func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    func pct(_ k: String) -> Double? { number((j[k] as? [String: Any])?["utilization"]) }
    func reset(_ k: String) -> Date? { parseISODate((j[k] as? [String: Any])?["resets_at"]) }
    // Per-model weekly limits ("seven_day_opus", …), read generically so a
    // new model family shows up without a Lanes update. Null when unused.
    let models = j.keys.sorted().filter { $0.hasPrefix("seven_day_") }.compactMap { k -> ModelLimit? in
        guard let v = pct(k) else { return nil }
        return ModelLimit(key: k, label: modelLimitLabel(k), used: v, reset: reset(k))
    }
    return Usage(fiveHour: pct("five_hour"), sevenDay: pct("seven_day"),
                 fiveHourReset: reset("five_hour"), sevenDayReset: reset("seven_day"), error: nil,
                 models: models)
}

// When no organization reports usage, keep the raw replies (no cookies) so the
// cause can be inspected: ~/Library/Logs/Lanes/usage-debug.json
private func writeUsageDebug(dataDir: String, raw: [[String: Any]]) {
    let dir = NSHomeDirectory() + "/Library/Logs/Lanes"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let payload: [String: Any] = ["dataDir": dataDir, "date": ISO8601DateFormatter().string(from: Date()), "orgs": raw]
    if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: dir + "/usage-debug-\((dataDir as NSString).lastPathComponent).json"))
    }
}

// MARK: Claude Desktop's own record

// Claude Desktop keeps a short history of the same percentages in each data
// folder (plan-usage-history.json), written whenever it checks usage itself.
// It has no reset times and only a handful of readings a day, so it is never
// the source, only a fallback: when claude.ai can't be reached, a reading
// there that's newer than Lanes' last one is better than nothing.
// shortcut: undocumented, internal format; anything unexpected reads as nil.
enum LocalUsage {
    typealias Reading = LocalReading

    static func path(dataDir: String) -> String { dataDir + "/plan-usage-history.json" }

    static func latest(dataDir: String) -> Reading? {
        guard let data = FileManager.default.contents(atPath: path(dataDir: dataDir)) else { return nil }
        return latest(json: data)
    }

    // {"version":2,"samples":[{"t":<epoch ms>,"org":"…","u":{"fh":12,"sd":40}}, …]}
    static func latest(json data: Data) -> Reading? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else { return nil }
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        let readings = samples.compactMap { s -> Reading? in
            guard let ms = number(s["t"]), let u = s["u"] as? [String: Any] else { return nil }
            let r = Reading(t: Date(timeIntervalSince1970: ms / 1000), fiveHour: number(u["fh"]), sevenDay: number(u["sd"]))
            return r.fiveHour == nil && r.sevenDay == nil ? nil : r
        }
        return readings.max { $0.t < $1.t }
    }
}
