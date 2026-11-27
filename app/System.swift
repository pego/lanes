// System glue shared by the app: reading app versions, running the bundled
// tools, notifications and global shortcuts. Finding each app is its
// provider's job (Provider.swift).

import SwiftUI
import AppKit
import UserNotifications
import Carbon.HIToolbox

// Read fresh every call (NOT via Bundle(path:), which caches infoDictionary
// and would miss a re-clone). Returns nil if the bundle/plist is absent.
func bundleVersion(_ appPath: String) -> String? {
    guard let dict = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") else { return nil }
    return dict["CFBundleShortVersionString"] as? String
}

// True when `a` is strictly older than `b` (ordered dotted-numeric compare).
// Mirrors version_lt in bin/lanes — a plain != would wrongly flag a profile
// that self-updated AHEAD of the default as "behind".
func versionLessThan(_ a: String, _ b: String) -> Bool {
    if a == b { return false }
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x < y }
    }
    return false
}

@discardableResult
func runTool(_ tool: String, _ args: [String], env: [String: String] = [:]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if !env.isEmpty {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
    }
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    try p.run()
    // Read before waiting so a chatty child can't fill the pipe and deadlock.
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: outData, encoding: .utf8) ?? ""
    let errText = String(data: errData, encoding: .utf8) ?? ""
    if p.terminationStatus != 0 {
        throw NSError(domain: "lanes", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? out : errText])
    }
    return out
}

// MARK: - System integrations

// Shows banners even while the app is frontmost (the default is to suppress them).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    // Always, at launch: clicks on notifications (What's New) reach us even
    // with alerts off. Doesn't ask for permission.
    func attach() { UNUserNotificationCenter.current().delegate = self }

    func setUp() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static let whatsNewID = "whats-new"

    func post(title: String, body: String, identifier: String = UUID().uuidString,
              category: String? = nil, info: [String: Any] = [:]) {
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier,
                                  content: content(title, body, category: category, info: info), trigger: nil))
    }

    // Clicking "Lanes updated to …" opens What's New; any other Lanes
    // notification hands its click or action button to the store.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if id == Self.whatsNewID {
                WhatsNewWindow.show()
            } else {
                ProfileStore.shared.handleNotification(action: action, info: info)
            }
        }
        done()
    }

    // Fires at `date` even if the app has quit by then; posting again with the
    // same identifier replaces the pending one.
    func schedule(_ identifier: String, at date: Date, title: String, body: String,
                  category: String? = nil, info: [String: Any] = [:]) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier,
                                  content: content(title, body, category: category, info: info), trigger: trigger))
    }

    private func content(_ title: String, _ body: String, category: String?, info: [String: Any]) -> UNNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let category { c.categoryIdentifier = category }
        c.userInfo = info
        return c
    }

    // The action buttons notifications can carry. Their titles name a
    // profile, so there's a set per profile, replaced whenever the profiles
    // change: registered ahead, so a notification never arrives before its
    // buttons do.
    func registerCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    func cancel(_ identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// Global shortcuts: ⌥⌘P opens the menu bar panel, ⌥⌘B opens the profile with
// the most headroom. Each can be turned off on its own.
enum GlobalShortcut {
    enum Key: UInt32 { case panel = 1, best = 2 }
    private static var refs: [Key: EventHotKeyRef] = [:]
    private static var handlerInstalled = false

    static func setEnabled(_ key: Key, _ on: Bool) {
        if on {
            if !handlerInstalled {
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                    var hk = EventHotKeyID()
                    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                    DispatchQueue.main.async {
                        if hk.id == Key.best.rawValue { ProfileStore.shared.launchBest() } else { GlobalShortcut.togglePanel() }
                    }
                    return noErr
                }, 1, &spec, nil, nil)
                handlerInstalled = true
            }
            guard refs[key] == nil else { return }
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key == .panel ? kVK_ANSI_P : kVK_ANSI_B), UInt32(optionKey | cmdKey),
                                EventHotKeyID(signature: OSType(0x43445052), id: key.rawValue),
                                GetApplicationEventTarget(), 0, &ref)
            refs[key] = ref
        } else if let r = refs[key] {
            UnregisterEventHotKey(r)
            refs[key] = nil
        }
    }

    // Clicks the app's status item, which SwiftUI offers no API to open.
    static func togglePanel() {
        func button(in v: NSView?) -> NSButton? {
            guard let v else { return nil }
            if let b = v as? NSButton { return b }
            for sub in v.subviews { if let b = button(in: sub) { return b } }
            return nil
        }
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBarWindow") {
            if let b = button(in: w.contentView) { b.performClick(nil); return }
        }
    }
}
