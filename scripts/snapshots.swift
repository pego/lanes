// Renders the README screenshots from sample data, in light and dark:
// the window (one lane open), the menu bar panel, the new-profile sheet
// and the menu bar glyph. Compiled with the app's sources by
// scripts/snapshots.sh; never touches real profiles, usage or the network.

import AppKit
import SwiftUI

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@main
enum Snapshots {
    static func main() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let icon = NSImage(contentsOfFile: "app/AppIcon.icns") { app.applicationIconImage = icon }

        MainActor.assumeIsolated {
            for (suffix, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let appearance = NSAppearance(named: name)!
                app.appearance = appearance
                let store = sampleStore()
                let dark = suffix == "dark"

                let window = render(LanesWindow(store: store, expanded: "Work"),
                                    size: CGSize(width: 860, height: 640), appearance: appearance)
                write(framed(window, radius: 12, trafficLights: true, dark: dark), to: "\(out)/window-\(suffix).png")

                let panel = render(MenuPanel(store: store).background(panelBackground(dark)),
                                   size: nil, appearance: appearance)
                write(framed(panel, radius: 14, trafficLights: false, dark: dark), to: "\(out)/menu-\(suffix).png")

                let sheet = render(AddSheet(existing: store.profiles.map(\.name), routesLinks: true,
                                            initialColor: "pink", initialName: "client acme") { _, _, _ in }
                                    .background(Color(nsColor: .windowBackgroundColor)),
                                   size: nil, appearance: appearance)
                write(framed(sheet, radius: 12, trafficLights: false, dark: dark), to: "\(out)/new-profile-\(suffix).png")

                write(menuBarStrip(store: store, dark: dark), to: "\(out)/menubar-\(suffix).png")
            }
        }
    }

    // MARK: Sample data

    @MainActor static func sampleStore() -> ProfileStore {
        let s = ProfileStore(live: false)
        let now = Date()
        s.profiles = [
            Profile(name: "Default", dataDir: nil, colorName: "orange"),
            Profile(name: "Work", dataDir: NSHomeDirectory() + "/Library/Application Support/Lanes/profiles/Work", colorName: "blue"),
            Profile(name: "Studio", dataDir: NSHomeDirectory() + "/Library/Application Support/Lanes/profiles/Studio", colorName: "green"),
            Profile(name: "Personal", dataDir: NSHomeDirectory() + "/Library/Application Support/Lanes/profiles/Personal", colorName: "purple"),
        ]
        s.running = ["Work", "Studio"]
        s.usage = [
            "Default": Usage(fiveHour: 23, sevenDay: 41, fiveHourReset: now + 3 * 3600 + 12 * 60,
                             sevenDayReset: now + 3 * 86400 + 5 * 3600),
            "Work": Usage(fiveHour: 86, sevenDay: 63, fiveHourReset: now + 38 * 60,
                          sevenDayReset: now + 2 * 86400 + 9 * 3600,
                          models: [ModelLimit(key: "seven_day_opus", label: "Opus", used: 48,
                                              reset: now + 2 * 86400 + 9 * 3600)],
                          fiveHourPace: Pace(atReset: 100, runsOutAt: now + 24 * 60),
                          sevenDayPace: Pace(atReset: 81, runsOutAt: nil)),
            "Studio": Usage(fiveHour: 7, sevenDay: 12, fiveHourReset: now + 4 * 3600 + 41 * 60,
                            sevenDayReset: now + 6 * 86400 + 2 * 3600),
            "Personal": Usage(fiveHour: nil, sevenDay: nil, error: "not signed in"),
        ]
        s.lastUsageUpdate = now - 95
        s.history = [
            "Default": history(peak: 55, weekNow: 41, seed: 1),
            "Work": history(peak: 92, weekNow: 63, seed: 2),
            "Studio": history(peak: 30, weekNow: 12, seed: 3),
        ]
        return s
    }

    // A week of plausible readings: one or two sessions a day, each climbing
    // through its 5-hour window and dropping back when the window resets,
    // and a weekly total that climbs to `weekNow`.
    static func history(peak: Double, weekNow: Double, seed: Double) -> [UsageSample] {
        let now = Date(), step: TimeInterval = 600
        let cal = Calendar.current
        var out: [UsageSample] = []
        var t = now - ClaudeLimit.sevenDayWindow + step
        while t <= now {
            let hour = Double(cal.component(.hour, from: t)) + Double(cal.component(.minute, from: t)) / 60
            let day = Double(cal.ordinality(of: .day, in: .era, for: t) ?? 0)
            let vary = 0.55 + 0.45 * abs(sin(day * 1.7 + seed))
            let starts = vary > 0.75 ? [9.5, 15.0] : [10.0]
            var h = 0.0
            for (i, start) in starts.enumerated() where hour >= start && hour < start + 5 {
                let ramp = min(1, (hour - start) / 3.2)
                h = peak * vary * (i == 0 ? 1 : 0.7) * pow(ramp, 0.8)
            }
            let progress = 1 - (now.timeIntervalSince(t) / ClaudeLimit.sevenDayWindow)
            out.append(UsageSample(t: t, h: min(100, h), w: weekNow * progress))
            t += step
        }
        return out
    }

    // MARK: Rendering

    static func panelBackground(_ dark: Bool) -> Color {
        dark ? Color(red: 0.16, green: 0.16, blue: 0.17) : Color(red: 0.95, green: 0.95, blue: 0.96)
    }

    @MainActor static func render<V: View>(_ view: V, size: CGSize?, appearance: NSAppearance) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        host.appearance = appearance
        let fit = size ?? host.fittingSize
        // Far off screen, but key, so controls draw in their active state.
        let window = KeyWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: fit),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        host.frame = CGRect(origin: .zero, size: fit)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    // Rounds the corners, adds a hairline, a soft shadow and, for windows,
    // the traffic lights the hidden title bar would show.
    static func framed(_ rep: NSBitmapImageRep, radius: CGFloat, trafficLights: Bool, dark: Bool) -> NSBitmapImageRep {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let pad: CGFloat = 36
        let size = CGSize(width: rep.size.width + pad * 2, height: rep.size.height + pad * 2)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let rect = CGRect(x: pad, y: pad, width: rep.size.width, height: rep.size.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.22)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        rep.draw(in: rect)
        if trafficLights {
            let colors = [NSColor(red: 1, green: 0.37, blue: 0.34, alpha: 1),
                          NSColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                          NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
            for (i, c) in colors.enumerated() {
                let d: CGFloat = 12
                let r = CGRect(x: rect.minX + 20 + CGFloat(i) * 20 - d / 2, y: rect.maxY - 20 - d / 2, width: d, height: d)
                c.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.12)).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        edge.lineWidth = 1
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    // The menu bar glyph at a few usage levels, on a menu bar-colored strip.
    @MainActor static func menuBarStrip(store: ProfileStore, dark: Bool) -> NSBitmapImageRep {
        let cases: [([Double?], Double?)] = [
            ([23, 41, 7], 41), ([23, 86, 7], 86), ([23, 95, 7], 95),
        ]
        let scale: CGFloat = 2, height: CGFloat = 28, gap: CGFloat = 28
        let glyphs = cases.map { MenuBarGlyph.image(levels: $0.0, percent: $0.1) }
        let width = glyphs.reduce(gap) { $0 + $1.size.width + gap }
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = CGSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), xRadius: 8, yRadius: 8).fill()
        var x = gap
        for g in glyphs {
            let r = CGRect(x: x, y: (height - g.size.height) / 2, width: g.size.width, height: g.size.height)
            if g.isTemplate {
                // Template images take the menu bar's ink: tint them by hand.
                let tinted = NSImage(size: g.size, flipped: false) { b in
                    g.draw(in: b)
                    (dark ? NSColor.white : NSColor.black).set()
                    b.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: r)
            } else {
                g.draw(in: r)
            }
            x += g.size.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    static func write(_ rep: NSBitmapImageRep, to path: String) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
