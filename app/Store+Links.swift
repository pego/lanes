// ProfileStore: claude:// and codex:// link routing.
//
// macOS hands an app's link (Claude's sign-in token, ChatGPT's "connect an
// app" callback, "open in app" links) to whichever copy of the app is
// running, since every clone shares one bundle id. When routing is on, this
// app is the default handler of each provider's scheme instead and forwards
// each link to one profile of that provider: NSWorkspace.open(_:withApplicationAt:)
// with that profile's clone delivers it to the running instance of exactly
// that bundle. An app may re-register itself as the handler when it
// launches, so the 2 s poller claims it back.
//
// The schemes are in Info.plist (bin/lanes writes it). Claude's is always
// claimed; another app's only while it's installed.

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
                  let provider = Providers.all.first(where: { $0.bundleID == app.bundleIdentifier }),
                  let id = self.profileID(forBundle: app.bundleURL) else { return }
            self.lastActive[provider.id] = id
        }
        claimLinksIfNeeded()
    }

    // The apps whose links Lanes routes: Claude always, another only while
    // it's installed (claiming a scheme for an app that isn't there would
    // swallow its links).
    var routedProviders: [any Provider] {
        Providers.all.filter { $0.linkScheme != nil && ($0.id == Providers.claude.id || $0.isInstalled) }
    }

    // Cheap enough for the 2 s poller: one LaunchServices lookup per scheme,
    // and a write only when an app took its scheme back (throttled in case
    // it fails).
    func claimLinksIfNeeded() {
        guard routeLinks, !Bundle.main.bundlePath.contains("/AppTranslocation/") else { return }
        let me = Bundle.main.bundleURL.standardizedFileURL
        for provider in routedProviders {
            guard let scheme = provider.linkScheme, !handlesLinks(of: provider) else { continue }
            if let t = lastClaim[scheme], Date().timeIntervalSince(t) < 10 { continue }
            lastClaim[scheme] = Date()
            NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: scheme) { _ in }
        }
    }

    // Whether macOS hands this app's links to Lanes. Compared by bundle id,
    // the key LaunchServices stores the default under: with a second copy
    // installed it may resolve to that path.
    func handlesLinks(of provider: any Provider) -> Bool {
        guard let probe = provider.probeURL,
              let cur = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: cur)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    func releaseLinks() {
        for provider in Providers.all {
            guard let scheme = provider.linkScheme, provider.isInstalled else { continue }
            NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: provider.appPath),
                                                     toOpenURLsWithScheme: scheme) { _ in }
        }
    }

    // The app a link belongs to, by its scheme.
    static func provider(forLink url: URL) -> (any Provider)? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        return Providers.all.first { $0.linkScheme?.lowercased() == scheme }
    }

    // The profiles a link may go to: those whose app owns its scheme. A
    // claude:// sign-in token must never reach a ChatGPT clone, nor a
    // codex:// callback a Claude one.
    func linkTargets(for url: URL) -> [Profile] {
        guard let provider = Self.provider(forLink: url) else { return [] }
        return profiles.filter { $0.providerID == provider.id }
    }

    func route(_ url: URL) {
        refresh()
        guard let provider = Self.provider(forLink: url) else { return }
        let targets = linkTargets(for: url)
        guard !targets.isEmpty else { return }
        let live = targets.filter { running.contains($0.id) }
        if live.count == 1 { deliver(url, to: live[0]); return }
        // None running: pick which to start. Several: the frontmost-most-recently
        // one is preselected, so Return confirms the usual case.
        let preselect = live.first { $0.id == lastActive[provider.id] }?.id ?? live.first?.id ?? targets.first?.id
        if let p = pickProfile(for: url, provider: provider, among: targets, preselect: preselect) { deliver(url, to: p) }
    }

    // The picker's hint: which profile a link like this belongs to.
    static func linkHint(_ provider: any Provider) -> String {
        provider.id == Providers.claude.id
            ? "Sign-in links belong to the profile you clicked \"Log in\" in."
            : "A link that finishes connecting an app belongs to the profile you started connecting in."
    }

    private func pickProfile(for url: URL, provider: any Provider, among targets: [Profile], preselect: String?) -> Profile? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open this \(provider.name) link in which profile?"
        // Never show the query: a sign-in link carries its token there.
        let where_ = [url.host, url.path.isEmpty ? nil : url.path].compactMap { $0 }.joined()
        alert.informativeText = (where_.isEmpty ? "" : "\(provider.linkScheme ?? "")://\(where_)\n\n")
            + Self.linkHint(provider)
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
        lastActive[p.providerID] = p.id
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
            linkFailed("\(p.name) didn't start in time, so the \(p.provider.name) link wasn't opened. Click it again.")
        }
    }

    // The window (and its error alert) is usually closed while routing.
    private func linkFailed(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't open the link"
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
