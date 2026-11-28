// Lanes' health: what it depends on, whether each part works, and a fix for
// what doesn't. Most checks come from `lanes doctor --tsv` (the same list
// the Terminal shows); the app adds what only it can see: notification
// permission, Keychain access, the claude:// handler, open at login.
// Shown in Settings > Status; a problem also puts a dot on the menu bar
// panel's gear.

import AppKit
import UserNotifications

struct HealthCheck: Identifiable, Equatable {
    enum Status: String { case ok, warn, fail }
    var id: String
    var status: Status
    var title: String
    var detail: String = ""
    var fix: String? = nil           // an action id, see ProfileStore.fix(_:)

    // What the Fix button says.
    var fixTitle: String? {
        guard let fix else { return nil }
        switch fix {
        case "setup", "watchdog": return "Fix"
        case _ where fix.hasPrefix("download-"): return "Download"
        case "notifications-ask": return "Allow"
        case "notifications-settings": return "Open Settings"
        case "retry-keychain": return "Try Again"
        case "claim-links": return "Fix"
        case "login": return "Turn On"
        default:
            if fix.hasPrefix("launcher:") { return "Recreate" }
            if fix.hasPrefix("signin:") { return "Open" }
            return nil
        }
    }

    // `lanes doctor --tsv`: status, id, title, detail, fix; tab-separated,
    // empty fields kept. Unknown statuses and short lines are skipped.
    static func parse(tsv: String) -> [HealthCheck] {
        tsv.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let s = Status(rawValue: f[0]) else { return nil }
            return HealthCheck(id: f[1], status: s, title: f[2],
                               detail: f.count > 3 ? f[3] : "",
                               fix: f.count > 4 && !f[4].isEmpty ? f[4] : nil)
        }
    }
}

extension ProfileStore {
    var healthIssues: [HealthCheck] { health.filter { $0.status != .ok } }

    // The issues worth a dot on the gear: not a choice (login off) nor
    // something that fixes itself (a clone a version behind).
    var healthNeedsAttention: Bool {
        healthIssues.contains { $0.id != "login" && !$0.id.hasPrefix("clone:") }
    }

    func checkHealth() {
        guard live, !isCheckingHealth, let lanes = scriptPath else { return }
        isCheckingHealth = true
        Task.detached {
            // Exits 1 when something failed: the report is on stdout either way.
            let tsv = (try? await offCooperativePool {
                try runTool("/bin/zsh", ["-c", "\"$0\" doctor --tsv || true", lanes], env: ["LANES_FROM_CHOOSER": "1"])
            }) ?? ""
            let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            await MainActor.run {
                // The app is running: that check is for the Terminal.
                var checks = HealthCheck.parse(tsv: tsv).filter { $0.id != "running" }
                checks += self.appChecks(notifications: notifications)
                // Problems first, worst first; then the rest in order.
                let rank: [HealthCheck.Status: Int] = [.fail: 0, .warn: 1, .ok: 2]
                checks = checks.enumerated().sorted {
                    (rank[$0.element.status]!, $0.offset) < (rank[$1.element.status]!, $1.offset)
                }.map(\.element)
                if checks != self.health { self.health = checks }
                self.isCheckingHealth = false
            }
        }
    }

    private func appChecks(notifications: UNAuthorizationStatus) -> [HealthCheck] {
        var out: [HealthCheck] = []
        if alertsEnabled {
            switch notifications {
            case .denied:
                out.append(HealthCheck(id: "notifications", status: .warn, title: "Notifications are turned off for Lanes",
                                       detail: "Usage alerts can't reach you. Allow them in System Settings → Notifications → Lanes.",
                                       fix: "notifications-settings"))
            case .notDetermined:
                out.append(HealthCheck(id: "notifications", status: .warn, title: "Lanes hasn't asked to send notifications yet",
                                       detail: "Usage alerts need your permission.", fix: "notifications-ask"))
            default:
                out.append(HealthCheck(id: "notifications", status: .ok, title: "Notifications are allowed"))
            }
        }
        let claude = Providers.claude
        switch ChromiumKey.state {
        case .denied(let why):
            out.append(HealthCheck(id: "keychain-access", status: .fail, title: "Lanes can't read \(claude.name)'s Keychain key",
                                   detail: "\(why). Without it Lanes can't see usage. Try again and choose Always Allow when macOS asks about “\(claude.keychainItem ?? "")”.",
                                   fix: "retry-keychain"))
        case .ok:
            out.append(HealthCheck(id: "keychain-access", status: .ok, title: "Lanes can read \(claude.name)'s Keychain key"))
        case .unknown:
            break
        }
        if routeLinks {
            for provider in routedProviders {
                guard let scheme = provider.linkScheme else { continue }
                let id = provider.id == claude.id ? "links" : "links-\(provider.id)"
                out.append(handlesLinks(of: provider)
                           ? HealthCheck(id: id, status: .ok, title: "\(scheme):// links go through Lanes")
                           : HealthCheck(id: id, status: .warn, title: "\(scheme):// links bypass Lanes",
                                         detail: "Another app took them over; \(provider.id == claude.id ? "sign-in" : provider.name) links may open in the wrong profile.",
                                         fix: "claim-links"))
            }
        }
        if !launchAtLogin {
            out.append(HealthCheck(id: "login", status: .warn, title: "Lanes doesn't open at login",
                                   detail: "Until you open it, usage, alerts and link routing are off.", fix: "login"))
        }
        return out
    }

    func fix(_ action: String) {
        guard live else { return }
        switch action {
        case "setup": runLanes(["setup"])
        case "watchdog": runLanes(["watchdog", "install"])
        case _ where action.hasPrefix("download-"):
            // "download-claude", "download-chatgpt": lanes doctor's row for an app that isn't installed.
            if let p = Providers.all.first(where: { "download-\($0.id)" == action }) { NSWorkspace.shared.open(p.downloadURL) }
        case "notifications-ask": Notifier.shared.setUp()
        case "notifications-settings":
            let id = Bundle.main.bundleIdentifier ?? ""
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
        case "retry-keychain":
            ChromiumKey.reset()
            refreshUsage()
        case "claim-links":
            lastClaim = [:]
            claimLinksIfNeeded()
        case "login": setLaunchAtLogin(true)
        default:
            if action.hasPrefix("launcher:") { runLanes(["add", String(action.dropFirst("launcher:".count))]) }
            if action.hasPrefix("signin:"), let p = profiles.first(where: { $0.id == String(action.dropFirst("signin:".count)) }) {
                launch(p)
            }
        }
        // Let the fix land (a prompt answered, a launcher rebuilt), then look again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.checkHealth() }
    }

    private func runLanes(_ args: [String]) {
        guard let lanes = scriptPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try runTool("/bin/zsh", [lanes] + args, env: ["LANES_FROM_CHOOSER": "1"]) }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                if let failure { self.errorMessage = failure }
                self.checkHealth()
            }
        }
    }
}
