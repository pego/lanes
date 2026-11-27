// ProfileStore: claude:// link routing.
//
// macOS hands a claude:// link (the sign-in token, "open in app" links)
// to whichever Claude is running, since every clone shares one bundle id.
// When routing is on, this app is the scheme's default handler instead and
// forwards each link to one profile: NSWorkspace.open(_:withApplicationAt:)
// with that profile's clone delivers it to the running instance of exactly
// that bundle. Claude re-registers itself as the handler on every launch,
// so the 2 s poller claims it back.
//
// Only Claude's links are routed: claude:// is the one scheme Lanes claims
// (Info.plist), and the Default profile is Claude's own install.

import AppKit

extension ProfileStore {
    func bundlePath(for p: Profile) -> String {
        p.isDefault ? p.provider.appPath : p.provider.clonePath(in: clonesDir, profile: p.name)
    }

    private func profileID(forBundle url: URL?) -> String? {
        guard let path = url?.standardizedFileURL.path else { return nil }
        return profiles.first { URL(fileURLWithPath: bundlePath(for: $0)).standardizedFileURL.path == path }?.id
    }

    private func runningApp(for p: Profile) -> NSRunningApplication? {
        let want = URL(fileURLWithPath: bundlePath(for: p)).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == p.provider.bundleID && $0.bundleURL?.standardizedFileURL.path == want
        }
    }

    func startLinkRouting() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Providers.claude.bundleID,
                  let id = self.profileID(forBundle: app.bundleURL) else { return }
            self.lastActive = id
        }
        claimLinksIfNeeded()
    }

    // Cheap enough for the 2 s poller: one LaunchServices lookup, and a write
    // only when Claude took the scheme back (throttled in case it fails).
    func claimLinksIfNeeded() {
        let claude = Providers.claude
        guard routeLinks, !Bundle.main.bundlePath.contains("/AppTranslocation/"),
              let scheme = claude.linkScheme, let probe = claude.probeURL else { return }
        // Compared by bundle id, the key LaunchServices stores the default
        // under: with a second copy installed it may resolve to that path.
        let me = Bundle.main.bundleURL.standardizedFileURL
        if let cur = NSWorkspace.shared.urlForApplication(toOpen: probe),
           Bundle(url: cur)?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        if let t = lastClaim, Date().timeIntervalSince(t) < 10 { return }
        lastClaim = Date()
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: scheme) { _ in }
    }

    func releaseLinks() {
        let claude = Providers.claude
        guard let scheme = claude.linkScheme else { return }
        NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: claude.appPath),
                                                 toOpenURLsWithScheme: scheme) { _ in }
    }

    // The profiles a link may go to: those whose app owns its scheme. A
    // claude:// sign-in token must never reach a ChatGPT clone.
    func linkTargets(for url: URL) -> [Profile] {
        guard let scheme = url.scheme?.lowercased() else { return [] }
        return profiles.filter { $0.provider.linkScheme?.lowercased() == scheme }
    }

    func route(_ url: URL) {
        refresh()
        let targets = linkTargets(for: url)
        guard !targets.isEmpty else { return }
        let live = targets.filter { running.contains($0.id) }
        if live.count == 1 { deliver(url, to: live[0]); return }
        // None running: pick which to start. Several: the frontmost-most-recently
        // one is preselected, so Return confirms the usual case.
        let preselect = live.first { $0.id == lastActive }?.id ?? live.first?.id ?? targets.first?.id
        if let p = pickProfile(for: url, among: targets, preselect: preselect) { deliver(url, to: p) }
    }

    private func pickProfile(for url: URL, among targets: [Profile], preselect: String?) -> Profile? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open this Claude link in which profile?"
        // Never show the query: a sign-in link carries its token there.
        let where_ = [url.host, url.path.isEmpty ? nil : url.path].compactMap { $0 }.joined()
        alert.informativeText = (where_.isEmpty ? "" : "claude://\(where_)\n\n")
            + "Sign-in links belong to the profile you clicked \"Log in\" in."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for p in targets {
            let item = NSMenuItem(title: p.name + (running.contains(p.id) ? "" : "  (not running)"),
                                  action: nil, keyEquivalent: "")
            item.representedObject = p.id
            item.image = Self.swatchImage(NSColor(p.color.swatch))
            popup.menu?.addItem(item)
            if p.id == preselect { popup.select(item) }
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let id = popup.selectedItem?.representedObject as? String else { return nil }
        return targets.first { $0.id == id }
    }

    private static func swatchImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
    }

    private func deliver(_ url: URL, to p: Profile) {
        lastActive = p.id
        if p.isDefault || running.contains(p.id) && runningApp(for: p) != nil {
            open(url, in: p)
            return
        }
        // Never open a link with a clone that isn't running: LaunchServices
        // would start it without --user-data-dir, on the DEFAULT account. Start
        // it isolated through lanes, then forward once both ps (the flag) and
        // LaunchServices (the bundle) see it, so the link can't spawn a copy.
        guard let lanes = scriptPath else { linkFailed("The bundled lanes script is missing from the app."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try runTool("/bin/zsh", [lanes, "launch", p.name], env: ["LANES_FROM_CHOOSER": "1"]) }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                if let failure { self.linkFailed(failure); return }
                self.waitForLaunch(of: p, deadline: Date().addingTimeInterval(30)) { self.open(url, in: p) }
            }
        }
    }

    private func waitForLaunch(of p: Profile, deadline: Date, then: @escaping () -> Void) {
        refreshRunning()
        if running.contains(p.id), runningApp(for: p) != nil {
            // Electron queues open-url until it's ready, but give LaunchServices
            // a beat to finish the check-in it just reported.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: then)
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForLaunch(of: p, deadline: deadline, then: then) }
        } else {
            linkFailed("\(p.name) didn't start in time, so the Claude link wasn't opened. Click it again.")
        }
    }

    // The window (and its error alert) is usually closed while routing.
    private func linkFailed(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't open the Claude link"
        alert.informativeText = message
        alert.runModal()
    }

    private func open(_ url: URL, in p: Profile) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: bundlePath(for: p)),
                                configuration: cfg) { _, error in
            if let error { DispatchQueue.main.async { self.linkFailed(error.localizedDescription) } }
        }
    }
}
