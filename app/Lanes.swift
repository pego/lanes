// Lanes for Claude — a menu bar app for running several Claude Desktop
// accounts side by side.
//
// This file holds the profile store's state and profile operations, and the
// app's scenes. The store's other jobs live in Store+Usage.swift (refreshing
// and publishing usage), Store+Alerts.swift, Store+Updates.swift and
// Store+Links.swift (claude:// routing). Provider.swift describes the apps a
// profile can run: Claude (ClaudeProvider.swift, which also reads usage
// from claude.ai) and ChatGPT (ChatGPTProvider.swift, usage from
// chatgpt.com). Usage.swift holds usage as Lanes keeps it,
// History.swift keeps it and forecasts it, System.swift holds the
// system glue. The views live in Window.swift, MenuBar.swift, Settings.swift
// and Components.swift.
//
// This app is a frontend only: profile creation and removal shell out to the
// copy of `lanes` bundled in Resources, so the CLI, the AppleScript chooser,
// and this app share one implementation. Profiles are discovered from the
// filesystem (~/Library/Application Support/Lanes/profiles/<Name>) on every refresh;
// there is no registry to sync. Running instances are detected by reading
// each app process's --user-data-dir argument out of `ps`, because all
// instances share one binary and differ only in that flag.

import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Model

struct Profile: Identifiable, Hashable {
    let name: String
    let dataDir: String?          // nil = the default Claude install
    let colorName: String
    var providerID = Providers.defaultID
    var id: String { name }
    var isDefault: Bool { dataDir == nil }
    var color: ProfileColor { ProfileColor.named(colorName) }
    var provider: any Provider { Providers.named(providerID) }
}

final class ProfileStore: ObservableObject {
    // One instance: the app delegate routes claude:// links into it, and those
    // can arrive before any scene exists (the link is what launched the app).
    static let shared = ProfileStore()

    @Published var profiles: [Profile] = [Profile(name: "Default", dataDir: nil, colorName: "orange")]
    @Published var running: Set<String> = []
    @Published var errorMessage: String?
    // Version of the installed Claude.app (the single update source) and the
    // profiles whose clone is behind it. Drives the update banner.
    @Published var installedVersion: String = ""
    @Published var outdatedProfiles: [String] = []
    @Published var showAdd = false                 // set from the menu bar, shown by the window
    @Published var usage: [String: Usage] = [:]    // keyed by Profile.id
    @Published var lastUsageUpdate: Date?
    @Published var isRefreshingUsage = false
    @Published var removeRequest: Profile?         // set from the menu bar, confirmed by the window
    // Settings > Status (Health.swift); refreshed with usage and when shown.
    @Published var health: [HealthCheck] = []
    // First launch: the welcome sheet, and the prompts it holds back.
    @Published var showWelcome = false
    var welcomePending = false
    @Published var isCheckingHealth = false

    // Preferences, persisted in UserDefaults.
    @Published var alertsEnabled = UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled")
            if alertsEnabled && live { Notifier.shared.setUp() }
        }
    }
    // The two alert levels, in percent of a limit. The second is kept above the first.
    static let warnLevels: [Double] = [50, 60, 70, 75, 80, 85, 90]
    static let urgentLevels: [Double] = [80, 85, 90, 95, 98]
    @Published var alertWarn: Double = UserDefaults.standard.object(forKey: "alertWarn") as? Double ?? 80 {
        didSet {
            UserDefaults.standard.set(alertWarn, forKey: "alertWarn")
            if alertUrgent <= alertWarn {
                alertUrgent = Self.urgentLevels.first { $0 > alertWarn } ?? 98
            }
        }
    }
    @Published var alertUrgent: Double = UserDefaults.standard.object(forKey: "alertUrgent") as? Double ?? 95 {
        didSet { UserDefaults.standard.set(alertUrgent, forKey: "alertUrgent") }
    }
    @Published var paceAlertsEnabled = UserDefaults.standard.object(forKey: "paceAlertsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(paceAlertsEnabled, forKey: "paceAlertsEnabled") }
    }
    @Published var shortcutEnabled = UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(shortcutEnabled, forKey: "shortcutEnabled")
            GlobalShortcut.setEnabled(.panel, shortcutEnabled)
        }
    }
    @Published var bestShortcutEnabled = UserDefaults.standard.object(forKey: "bestShortcutEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(bestShortcutEnabled, forKey: "bestShortcutEnabled")
            GlobalShortcut.setEnabled(.best, bestShortcutEnabled)
        }
    }
    @Published var history: [String: [UsageSample]] = UsageHistory.load()
    @Published var usageInterval: Double = {
        let v = UserDefaults.standard.double(forKey: "usageInterval")
        return v > 0 ? v : 300
    }() {
        didSet {
            UserDefaults.standard.set(usageInterval, forKey: "usageInterval")
            scheduleUsageTimer()
        }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate")
            if autoUpdate { checkForUpdate() }
        }
    }

    // Set on the first launch of a newer version than the last one run (an
    // update), until What's New is opened or dismissed: the panel's strip.
    @Published var updatedTo: String?
    @Published var statusLine: [StatusLineState] = []     // Claude Code's, per profile
    @Published var isUpdatingStatusLine = false
    @Published var settingsRequest = 0                       // see openSettings(_:)

    // Lanes' own updates (not Claude's): the newer release on GitHub, if any.
    @Published var availableUpdate: String?
    @Published var isUpdating = false
    @Published var isCheckingForUpdate = false
    @Published var lastUpdateCheck: Date?
    @Published var updateError: String?
    // A version whose install failed isn't retried automatically this session.
    var failedUpdate: String?
    var updateTimer: Timer?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // Last alert level sent per profile and limit ("Work/5h", "Work/7d"):
    // 0 below the first level, 1 from it, 2 from the second.
    var alertLevel: [String: Int] = [:]
    // The reset (epoch) each pace alert was sent for, per "Work/5h": one per
    // window. Persisted so relaunching Lanes doesn't repeat it.
    var paceAlerted: [String: Double] = UserDefaults.standard.dictionary(forKey: "paceAlerted") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(paceAlerted, forKey: "paceAlerted") }
    }
    // Set from notification buttons, per "Work/5h": warnings muted until
    // (epoch), and a reset notification asked for the window ending at (epoch).
    var alertMutedUntil: [String: Double] = UserDefaults.standard.dictionary(forKey: "alertMutedUntil") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(alertMutedUntil, forKey: "alertMutedUntil") }
    }
    var remindAtReset: [String: Double] = UserDefaults.standard.dictionary(forKey: "remindAtReset") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(remindAtReset, forKey: "remindAtReset") }
    }

    // Owned by the store (not a view) so the menu bar stays live with the window closed.
    private var timers: [Timer] = []
    var usageTimer: Timer?
    // A non-live store (the screenshot renderer) holds sample data and never
    // touches processes, the network, hotkeys or link handling.
    let live: Bool

    init(live: Bool = true) {
        self.live = live
        guard live else { return }
        refresh()
        timers = [Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshRunning()
            self?.claimLinksIfNeeded()
        }]
        scheduleUsageTimer()
        Notifier.shared.attach()
        registerAlertCategories()
        // A first install shows the welcome first: the Keychain and
        // notification prompts wait for its step that explains them.
        if UserDefaults.standard.string(forKey: "lastRunVersion") == nil,
           !FileManager.default.fileExists(atPath: UsageHistory.path) {
            showWelcome = true
            welcomePending = true
        }
        if alertsEnabled && !welcomePending { Notifier.shared.setUp() }
        GlobalShortcut.setEnabled(.panel, shortcutEnabled)
        GlobalShortcut.setEnabled(.best, bestShortcutEnabled)
        refreshUsage()
        startLinkRouting()
        // Not only from the window: an auto-update relaunches straight into
        // the menu bar, and the new version must still repoint launchers.
        setUp()
        noteVersionChange()
        // First check shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdate() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    // The welcome's permissions step is done (or the sheet was closed):
    // ask for notifications and read usage, which may ask the Keychain.
    func finishWelcome() {
        guard welcomePending else { return }
        welcomePending = false
        if alertsEnabled && live { Notifier.shared.setUp() }
        refreshUsage()
    }

    // The Claude version a profile runs: its own clone, or the installed app.
    func claudeVersion(of p: Profile) -> String? {
        bundleVersion(bundlePath(for: p))
    }

    func dataPath(of p: Profile) -> String { p.dataDir ?? p.provider.defaultDataDir }

    func launchBest() {
        if let p = bestProfile() {
            launch(p)
        } else {
            NSSound.beep()
            Notifier.shared.post(title: "No usage data yet", body: "Lanes can't tell which profile is most free until usage loads.")
        }
    }

    let appSupport = NSHomeDirectory() + "/Library/Application Support"
    let clonesDir = UsageSnapshot.directory + "/apps"
    let profilesDir = UsageSnapshot.directory + "/profiles"
    var scriptPath: String? { Bundle.main.path(forResource: "lanes", ofType: nil) }

    func refresh() {
        guard live else { return }
        var list = [Profile(name: "Default", dataDir: nil, colorName: "orange")]
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: profilesDir) {
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                var isDir: ObjCBool = false
                let full = profilesDir + "/" + entry
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    let color = (try? String(contentsOfFile: full + "/.lanes-color", encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "orange"
                    list.append(Profile(name: entry, dataDir: full, colorName: color,
                                        providerID: Providers.id(ofProfileAt: full)))
                }
            }
        }
        // Only publish on actual change: every @Published assignment re-renders
        // the cards, which dismisses any open Menu mid-interaction.
        if list != profiles {
            profiles = list
            registerAlertCategories()
        }
        refreshRunning()
    }

    func refreshRunning() {
        guard live, let out = try? runTool("/bin/ps", ["-axo", "command"]) else { return }
        var found = Set<String>()
        for lineSub in out.split(separator: "\n") {
            let line = String(lineSub)
            // The main binary of the original bundle OR a profile clone
            // ("Claude Work.app/Contents/MacOS/Claude"), of the provider the
            // profile runs; never a helper process (see isMainProcess).
            if let r = line.range(of: "--user-data-dir=") {
                let rest = String(line[r.upperBound...])
                // The whole path, not a prefix: "Work" must not match "Workshop".
                for p in profiles where p.provider.isMainProcess(line) {
                    if let d = p.dataDir, rest == d || rest.hasPrefix(d + " ") { found.insert(p.id) }
                }
            } else if let p = profiles.first(where: \.isDefault),
                      p.provider.isMainProcess(line), p.provider.isInstalledApp(line) {
                found.insert(p.id)
            }
        }
        // Same deal as refresh(): the 2s poller must not republish an
        // unchanged set, or it closes menus the user is currently using.
        if found != running { running = found }

        // Version drift, informational only. Profiles self-update on their
        // own; a profile whose clone is strictly OLDER than the installed
        // default will also catch up (re-clone forward) on its next launch.
        // We surface just those — never a clone that self-updated AHEAD of
        // the default, which is fine and must not read as "behind".
        let claude = Providers.claude
        let installed = bundleVersion(claude.appPath) ?? ""
        if installed != installedVersion { installedVersion = installed }
        var behind: [String] = []
        if !installed.isEmpty {
            for p in profiles where !p.isDefault && p.providerID == claude.id {
                if let v = bundleVersion(claude.clonePath(in: clonesDir, profile: p.name)),
                   versionLessThan(v, installed) {
                    behind.append(p.name)
                }
            }
        }
        if behind != outdatedProfiles { outdatedProfiles = behind }
    }

    func launch(_ p: Profile) {
        if p.isDefault {
            do { try runTool("/usr/bin/open", ["-a", p.provider.appPath]) }
            catch { errorMessage = error.localizedDescription }
        } else {
            // lanes launch runs the profile from its own Claude.app clone (the
            // Dock tile wears the profile color and owns the window) or
            // focuses the running instance without spawning a new window.
            callCdp(["launch", p.name])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.refreshRunning() }
    }

    func add(_ name: String, color: String, provider: String = Providers.defaultID) {
        callCdp(["add", name, "--color", color] + (provider == Providers.defaultID ? [] : ["--provider", provider]))
    }

    func setColor(_ p: Profile, color: String) {
        callCdp(["color", p.name, color])
    }

    func remove(_ p: Profile, deleteData: Bool) {
        callCdp(["remove", p.name, deleteData ? "--delete-data" : "--keep-data"])
    }

    // A new version's first launch points launchers, watchdog and helper at
    // this app's lanes. Off the main thread: rebuilding launchers takes seconds.
    private var didSetUp = false
    func setUp() {
        guard live, !didSetUp, let lanes = scriptPath else { return }
        didSetUp = true
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try runTool("/bin/zsh", [lanes, "setup", "--if-needed"], env: ["LANES_FROM_CHOOSER": "1"]) }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                if let failure { self.errorMessage = failure }
                self.refresh()
            }
        }
    }

    private func callCdp(_ args: [String]) {
        guard let lanes = scriptPath else {
            errorMessage = "Bundled lanes script is missing from the app. Rebuild with: lanes gui"
            return
        }
        do {
            // LANES_FROM_CHOOSER stops lanes from rebuilding the app bundle
            // that is currently running us.
            try runTool("/bin/zsh", [lanes] + args, env: ["LANES_FROM_CHOOSER": "1"])
        } catch { errorMessage = error.localizedDescription }
        refresh()
    }

    func revealData(_ p: Profile) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dataPath(of: p))
    }

    // Saves a profile's usage history as CSV wherever the user picks.
    func exportHistory(_ p: Profile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lanes \(p.name) usage.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "The last 30 days of \(p.name)'s usage, one reading every ten minutes."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try UsageHistory.csv(history[p.name] ?? []).write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: claude:// link routing state (the routing itself: Store+Links.swift)

    @Published var routeLinks = UserDefaults.standard.object(forKey: "routeLinks") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(routeLinks, forKey: "routeLinks")
            lastClaim = nil
            if routeLinks { claimLinksIfNeeded() } else { releaseLinks() }
        }
    }
    // The profile whose Claude window was frontmost most recently: the one
    // that just opened the browser to sign in, so it's the picker's default.
    var lastActive: String?
    var lastClaim: Date?
    var activationObserver: NSObjectProtocol?
}

// MARK: - App

// A menu bar app: no Dock icon (LSUIElement), and the window is only a
// utility surface for adding/removing profiles. Opening the app again (Spotlight,
// Finder) pops the menu bar panel instead of a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Our own GetURL handler rather than SwiftUI's onOpenURL, which would also
    // bring up the window scene. Installed before launch finishes so the link
    // that cold-starts the app isn't dropped.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s) else { return }
        // lanes:// comes from the widget: launch?profile=<name>, or open.
        if url.scheme?.lowercased() == "lanes" {
            DispatchQueue.main.async {
                let store = ProfileStore.shared
                let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "profile" }?.value
                if url.host == "launch", let name, let p = store.profiles.first(where: { $0.name == name }) {
                    store.launch(p)
                } else {
                    GlobalShortcut.togglePanel()
                }
            }
            return
        }
        guard url.scheme?.lowercased() == "claude" else { return }
        // Let the Apple Event return before the (modal) picker runs.
        DispatchQueue.main.async { ProfileStore.shared.route(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { GlobalShortcut.togglePanel() }
        return flag
    }
}

// The screenshot renderer (scripts/snapshots.sh) and the unit tests
// (scripts/unit-tests.sh) compile these sources with their own entry point.
#if !LANES_SNAPSHOT && !LANES_TESTS
@main
#endif
struct LanesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ProfileStore.shared

    var body: some Scene {
        // Window (not WindowGroup): openWindow from the menu bar must reuse it.
        Window("Lanes", id: "main") {
            LanesWindow(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 780, height: 540)

        Window("Lanes Settings", id: "settings") {
            SettingsView(store: store)
        }
        // The tabs sit in the title bar's row, beside the window buttons.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuPanel(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

