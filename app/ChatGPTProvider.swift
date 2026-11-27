// ChatGPT (the desktop app, an Electron app that updates through Sparkle)
// as a provider: where it's installed, how a profile's instance is kept apart
// from the others, and reading its usage from chatgpt.com with the profile's
// own sign-in, with the app's session logs as a fallback.
//
// A profile's ChatGPT keeps Electron's data in the profile folder and its
// Codex home (auth.json, sessions/, config.toml) in <profile>/codex-home.
// ChatGPT's code sets its userData path from CODEX_ELECTRON_USER_DATA_PATH.
// In practice --user-data-dir alone also kept a clone's data apart (tested
// on 26.1120), but bin/lanes passes both, as OpenAI's own demo launcher
// does, so isolation doesn't hang on which one wins in a later version. It
// also sets CODEX_HOME, and CODEX_SPARKLE_ENABLED=false so a clone never
// updates itself (it follows the installed app; see ensure_clone).
// --user-data-dir is also what `ps` shows to tell profiles apart.

import AppKit

struct ChatGPTProvider: Provider {
    let id = "chatgpt"
    let name = "ChatGPT"
    let desktopName = "ChatGPT"
    var appCandidates: [String] { ["/Applications/ChatGPT.app", NSHomeDirectory() + "/Applications/ChatGPT.app"] }
    // Looked up each time: ChatGPT may be installed while Lanes runs.
    var appPath: String { installedApp(appCandidates) }
    var icon: NSImage { AppIcons.icon(at: appPath) }
    let executable = "ChatGPT"
    let bundleID = "com.openai.codex"
    let configEnv = "CODEX_HOME"
    let configSubdir = "codex-home"
    // Sign-in comes back to the instance that started it through a localhost
    // callback; codex:// links aren't routed (a click goes to whichever
    // ChatGPT macOS picks).
    let linkScheme: String? = nil
    let updater = UpdaterKind.sparkle
    let iconStyle = IconStyle.tintedPlate
    var defaultDataDir: String { NSHomeDirectory() + "/Library/Application Support/Codex" }
    let usageService = "chatgpt.com"
    let keychainItem: String? = nil
    let downloadURL = URL(string: "https://chatgpt.com/download")!
    // Its access token expires within days; the app refreshes it while it
    // runs (Lanes never does).
    let renewsSignIn = true

    func fetchUsage(dataDir: String) async throws -> Usage {
        let auth = try ChatGPTAuth.read(codexHome: dataDir + "/" + configSubdir)
        var req = URLRequest(url: ChatGPTUsage.endpoint, timeoutInterval: 20)
        req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let account = auth.accountID { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // The app refreshes its token while it runs; Lanes never does (two
        // writers of a rotating refresh token sign the profile out).
        if code == 401 || code == 403 { return Usage(error: "session expired") }
        guard code == 200 else { throw usageError("\(usageService) answered \(code)", formatChanged: code == 404) }
        return try ChatGPTUsage.parse(data)
    }

    func localUsage(dataDir: String) -> LocalReading? {
        ChatGPTUsage.latestLocal(codexHome: dataDir + "/" + configSubdir)
    }
}

// The sign-in the profile's ChatGPT keeps in <Codex home>/auth.json.
struct ChatGPTAuth: Equatable {
    var accessToken: String
    var accountID: String?

    static func read(codexHome: String, now: Date = Date()) throws -> ChatGPTAuth {
        guard let data = FileManager.default.contents(atPath: codexHome + "/auth.json") else {
            throw SignInError.notSignedIn
        }
        return try parse(data, now: now)
    }

    enum SignInError: LocalizedError {
        case notSignedIn, expired
        var errorDescription: String? { self == .notSignedIn ? "not signed in" : "session expired" }
    }

    // Signed in with an account (not an API key), and its access token not
    // past its expiry: an expired one only earns a 401.
    static func parse(_ data: Data, now: Date = Date()) throws -> ChatGPTAuth {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { throw SignInError.notSignedIn }
        if let exp = jwtExpiry(token), exp <= now { throw SignInError.expired }
        return ChatGPTAuth(accessToken: token, accountID: tokens["account_id"] as? String)
    }

    // The `exp` claim of a JWT, if it has one. Read, not verified.
    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

enum ChatGPTUsage {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // {"plan_type": "plus", "rate_limit": {"primary_window": {"used_percent": 6,
    //  "limit_window_seconds": 18000, "reset_at": 1790000000}, "secondary_window": …}}
    // Plus has a 5-hour and a weekly window; Free one 30-day window and a
    // null secondary.
    static func parse(_ data: Data, now: Date = Date()) throws -> Usage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = obj["rate_limit"] as? [String: Any] else {
            throw usageError("unexpected reply from chatgpt.com", formatChanged: true)
        }
        let limits = [("primary", rate["primary_window"]), ("secondary", rate["secondary_window"])]
            .compactMap { key, w in (w as? [String: Any]).flatMap { window($0, key: key, now: now) } }
        guard !limits.isEmpty || rate.keys.contains("primary_window") else {
            throw usageError("unexpected reply from chatgpt.com", formatChanged: true)
        }
        return Usage(limits: limits.sorted { $0.window < $1.window })
    }

    private static func window(_ w: [String: Any], key: String, now: Date) -> UsageLimit? {
        guard let secs = number(w["limit_window_seconds"]), secs > 0 else { return nil }
        var reset = number(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        if reset == nil, let after = number(w["reset_after_seconds"]) { reset = now.addingTimeInterval(after) }
        return UsageLimit(key: key, label: UsageLimit.label(forWindow: secs), used: number(w["used_percent"]),
                          reset: reset, window: secs)
    }

    // The newest rate_limits the app logged in <Codex home>/sessions/
    // YYYY/MM/DD/rollout-*.jsonl, with their reset times. A resumed session
    // appends to its older-dated file, so the files are picked by when they
    // were last written, not by their path: the last reading of each of the
    // few most recent, and the newest of those by its own timestamp.
    static func latestLocal(codexHome: String) -> LocalReading? {
        let root = codexHome + "/sessions"
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return nil }
        let files = e.compactMap { $0 as? String }.filter { $0.hasSuffix(".jsonl") }
            .map { f -> (path: String, at: Date) in
                let path = root + "/" + f
                return (path, (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast)
            }
            .sorted { $0.at > $1.at }.prefix(5)
        let readings = files.compactMap { f -> LocalReading? in
            guard let text = try? String(contentsOfFile: f.path, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                if let r = localReading(Data(line.utf8)) { return r }
            }
            return nil
        }
        return readings.max { $0.t < $1.t }
    }

    // One token_count line: {"timestamp": "…", "payload": {"rate_limits":
    // {"limit_id": "codex", "primary": {"used_percent": 11.0,
    // "window_minutes": 300, "resets_at": 1790000000}, "secondary": …}}}
    static func localReading(_ line: Data) -> LocalReading? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let t = parseISODate(obj["timestamp"]),
              let rl = (obj["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { return nil }
        if let id = rl["limit_id"] as? String, id != "codex" { return nil }
        let limits = [("primary", rl["primary"]), ("secondary", rl["secondary"])].compactMap { key, v -> UsageLimit? in
            guard let w = v as? [String: Any], let mins = number(w["window_minutes"]), mins > 0 else { return nil }
            let secs = mins * 60
            return UsageLimit(key: key, label: UsageLimit.label(forWindow: secs), used: number(w["used_percent"]),
                              reset: number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }, window: secs)
        }
        return limits.isEmpty ? nil : LocalReading(t: t, limits: limits.sorted { $0.window < $1.window })
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
