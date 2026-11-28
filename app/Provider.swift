// The desktop apps Lanes can run side by side, and what it needs to know
// about each: where the app is installed, how its processes look in `ps`,
// where a profile keeps its settings, how links reach it, how it updates,
// how its icon takes a profile's color, and how to read its usage.
//
// Claude (ClaudeProvider.swift) and ChatGPT (ChatGPTProvider.swift). A
// profile names its provider in an optional `.lanes-provider` file in its
// folder, next to `.lanes-color`; a missing file means "claude" (`lanes add
// --provider` writes one only for other providers). bin/lanes reads the
// same file and keeps the same values in its provider_* functions.

import AppKit

// How the app updates itself, which decides how a clone can drift from the
// installed app (Squirrel swaps the bundle in place; Sparkle relaunches it).
enum UpdaterKind { case squirrel, sparkle }

// How a profile's color goes on the app's icon: a hue rotation of a colored
// icon (Claude's), or a tinted plate behind a monochrome one.
enum IconStyle { case hueShift, tintedPlate }

protocol Provider {
    // The `.lanes-provider` value: "claude", "chatgpt".
    var id: String { get }
    // The app's name: "Claude". Its bundle is "<name>.app" and each
    // profile's clone and launcher "<name> <Profile>.app".
    var name: String { get }
    // How the app is called in prose: "Claude Desktop".
    var desktopName: String { get }
    // Where the app may be installed, in order of preference.
    var appCandidates: [String] { get }
    // The installed app, or the first candidate when there is none.
    var appPath: String { get }
    // Its icon.
    var icon: NSImage { get }
    // Contents/MacOS/<executable>.
    var executable: String { get }
    var bundleID: String { get }
    // The environment variable that points the app at a profile's private
    // config dir, and that dir's name inside the profile folder.
    var configEnv: String { get }
    var configSubdir: String { get }
    // The URL scheme the app handles and Lanes routes to the right profile,
    // if any.
    var linkScheme: String? { get }
    var updater: UpdaterKind { get }
    var iconStyle: IconStyle { get }
    // The data folder of the app's own install (the Default profile).
    var defaultDataDir: String { get }
    // Where usage is read from, as users know it: "claude.ai".
    var usageService: String { get }
    // The Keychain item usage reading needs, if any: "Claude Safe Storage".
    var keychainItem: String? { get }
    // Where to get the app when it isn't installed.
    var downloadURL: URL { get }
    // An expired sign-in usually renews itself once the app runs (a token
    // the app refreshes), rather than needing the user to sign in again.
    var renewsSignIn: Bool { get }

    // The profile's usage, from the service. Throws when it can't be read.
    func fetchUsage(dataDir: String) async throws -> Usage
    // The newest reading the app recorded itself, if it keeps any: the
    // fallback when the service can't be reached.
    func localUsage(dataDir: String) -> LocalReading?
}

extension Provider {
    var mainExecutable: String { "/Contents/MacOS/" + executable }

    // A `ps` command line of one of the app's main processes (any bundle:
    // the installed app or a clone). Helper processes (renderer, GPU, …)
    // inherit the --user-data-dir flag; they're skipped so one instance
    // doesn't count five times.
    func isMainProcess(_ commandLine: String) -> Bool {
        commandLine.contains(mainExecutable) && !commandLine.contains("Helper")
    }

    // The installed app's own process, as opposed to a clone's.
    func isInstalledApp(_ commandLine: String) -> Bool {
        commandLine.contains("\(name).app" + mainExecutable)
    }

    // "<clones>/Claude Work.app"
    func clonePath(in clonesDir: String, profile: String) -> String {
        clonesDir + "/\(name) \(profile).app"
    }

    var probeURL: URL? { linkScheme.flatMap { URL(string: $0 + "://") } }

    // Checked live: an app installed while Lanes runs counts at once.
    var isInstalled: Bool { installedCandidate(appCandidates) != nil }
}

enum Providers {
    static let claude = ClaudeProvider()
    static let chatgpt = ChatGPTProvider()
    static let all: [any Provider] = [claude, chatgpt]
    static let defaultID = "claude"

    // An id this Lanes doesn't know (a profile a newer Lanes made) is never
    // treated as Claude: bin/lanes won't launch it, and the app shows the
    // lane as it is, without reading its usage.
    static func named(_ id: String) -> any Provider {
        all.first { $0.id == id } ?? UnknownProvider(id: id)
    }

    // A profile folder's `.lanes-provider`: its first line, whitespace
    // dropped (as bin/lanes reads it). Missing or empty means "claude".
    static func id(ofProfileAt dir: String) -> String {
        let text = (try? String(contentsOfFile: dir + "/.lanes-provider", encoding: .utf8)) ?? ""
        let first = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first ?? ""
        let id = first.filter { !$0.isWhitespace }
        return id.isEmpty ? defaultID : String(id)
    }
}

// A provider only a newer Lanes knows. Nothing of it can be found or read:
// no app, no processes (its executable never matches), no usage.
struct UnknownProvider: Provider {
    let id: String
    var name: String { id }
    var desktopName: String { id }
    let appCandidates: [String] = []
    let appPath = "/nonexistent"
    var icon: NSImage { Self.genericIcon }
    let executable = "\u{1}lanes-unknown-provider"
    let bundleID = ""
    let configEnv = ""
    let configSubdir = ""
    let linkScheme: String? = nil
    let updater = UpdaterKind.sparkle
    let iconStyle = IconStyle.tintedPlate
    let defaultDataDir = "/nonexistent"
    var usageService: String { id }
    let keychainItem: String? = nil
    let downloadURL = URL(string: "https://github.com/pego/lanes/releases/latest")!
    let renewsSignIn = false

    static let error = "needs a newer Lanes"
    struct Unsupported: LocalizedError { var errorDescription: String? { UnknownProvider.error } }

    func fetchUsage(dataDir: String) async throws -> Usage { throw Unsupported() }
    func localUsage(dataDir: String) -> LocalReading? { nil }

    private static let genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)
}

extension Provider {
    var isKnown: Bool { !(self is UnknownProvider) }
}

// The first candidate that exists right now, if any.
func installedCandidate(_ candidates: [String]) -> String? {
    candidates.first { FileManager.default.fileExists(atPath: $0) }
}

// The first candidate that exists, or the first one.
func installedApp(_ candidates: [String]) -> String {
    installedCandidate(candidates) ?? candidates[0]
}

// An app's icon, kept per path and read again once the app appears there
// (or goes): before that, macOS hands out a generic icon. Kept alive, so
// tintedIcon's cache (keyed by the image) never mixes two up.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func icon(at path: String) -> NSImage {
        let key = (FileManager.default.fileExists(atPath: path) ? "+" : "-") + path
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[key] = icon
        return icon
    }
}
