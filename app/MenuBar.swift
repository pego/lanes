// The menu bar: a glyph of stacked lanes (one bar per profile, filled to
// its 5-hour usage), and the panel it opens, which leads with the lane
// that has the most room.

import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let values = store.profiles.map { p -> Double? in
            guard let u = store.usage[p.id], u.error == nil else { return nil }
            return u.primary?.used
        }
        Image(nsImage: MenuBarGlyph.image(levels: values, percent: values.compactMap { $0 }.max()))
            // Always on screen, so it opens Settings for AppKit windows.
            .onChange(of: store.settingsRequest) { _ in openWindow(id: "settings") }
    }
}

enum MenuBarGlyph {
    static let maxLanes = 3

    // Up to three lanes, keeping the profiles' order; with more profiles, the
    // three busiest. A template image that follows the menu bar's tint, except
    // near a limit, when it turns orange (75%) or red (90%).
    static func image(levels: [Double?], percent: Double?) -> NSImage {
        var lanes = levels
        if lanes.count > maxLanes {
            let keep = lanes.indices.sorted { (lanes[$0] ?? -1) > (lanes[$1] ?? -1) }.prefix(maxLanes).sorted()
            lanes = keep.map { lanes[$0] }
        }
        if lanes.isEmpty { lanes = [nil, nil, nil] }

        let warn: NSColor? = percent.flatMap { $0 >= 90 ? .systemRed : ($0 >= 75 ? .systemOrange : nil) }
        let ink = warn ?? .black
        let text = percent.map {
            NSAttributedString(string: "\(Int($0.rounded()))%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: ink,
            ])
        }

        // Each lane is an outlined track with its fill inside: it reads as a
        // gauge, where plain filled bars read as a "text" or list icon.
        let barW: CGFloat = 17, barH: CGFloat = lanes.count > 2 ? 4.4 : 5.2, gap: CGFloat = lanes.count > 2 ? 1.4 : 2
        let stackH = CGFloat(lanes.count) * barH + CGFloat(lanes.count - 1) * gap
        let textW = text.map { ceil($0.size().width) + 4 } ?? 0
        let size = NSSize(width: barW + textW + 2, height: 18)

        let img = NSImage(size: size, flipped: true) { _ in
            var y = (size.height - stackH) / 2
            for v in lanes {
                let track = NSRect(x: 1, y: y, width: barW, height: barH)
                let r = barH / 2
                let outline = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
                outline.lineWidth = 1
                ink.withAlphaComponent(0.6).setStroke()
                outline.stroke()
                if let v, v > 0 {
                    let inner = track.insetBy(dx: 1.4, dy: 1.4)
                    let w = max(inner.height, inner.width * min(v, 100) / 100)
                    ink.setFill()
                    NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height),
                                 xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
                }
                y += barH + gap
            }
            if let text {
                let h = text.size().height
                text.draw(at: NSPoint(x: barW + 5, y: (size.height - h) / 2))
            }
            return true
        }
        img.isTemplate = warn == nil
        img.accessibilityDescription = percent.map { "Lanes: busiest profile at \(Int($0.rounded()))% of its 5-hour limit" } ?? "Lanes"
        return img
    }
}

// MARK: - Panel

struct MenuPanel: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            if let broken = store.brokenUsageProvider {
                UsageBrokenBanner(store: store, provider: broken)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            if let best = store.roomiestProfile() {
                RoomiestCard(profile: best,
                             running: store.running.contains(best.id),
                             usage: store.usage[best.id],
                             shortcut: store.bestShortcutEnabled) {
                    store.launch(best); closePanel()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            VStack(spacing: 0) {
                ForEach(Array(store.profiles.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { LaneMarking().padding(.horizontal, 12) }
                    PanelLane(
                        profile: p,
                        running: store.running.contains(p.id),
                        usage: store.usage[p.id],
                        launch: { store.launch(p); closePanel() },
                        reveal: { store.revealData(p) },
                        setColor: p.isDefault ? nil : { store.setColor(p, color: $0) },
                        remove: p.isDefault ? nil : { store.removeRequest = p; show("main") }
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
            if let v = store.availableUpdate, !store.autoUpdate || store.isUpdating || store.updateError != nil {
                updateBar(v)
            } else if let v = store.updatedTo {
                whatsNewBar(v)
            }
            footer
        }
        .frame(width: 330)
        .onAppear { store.refreshUsageIfStale() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.refreshUsageIfStale()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Lanes")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                UpdatedAgo(date: store.lastUsageUpdate)
                    .font(.caption2)
            }
            Spacer()
            Button { store.refresh(); store.refreshUsage() } label: {
                Group {
                    if store.isRefreshingUsage {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)))
            .help("Refresh usage")
            Button { SettingsGear.prepare(store); show("settings") } label: {
                SettingsGear(flagged: store.healthNeedsAttention, size: 16)
            }
            .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)))
            .help(store.healthNeedsAttention ? "Settings: something needs a look" : "Settings")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { store.showAdd = true; show("main") } label: {
                Label("New Profile", systemImage: "plus")
            }
            Button { show("main") } label: {
                Label("Open Lanes", systemImage: "rectangle.stack")
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help("Quit Lanes")
        }
        .buttonStyle(HoverButtonStyle())
        .font(.callout)
        .padding(6)
        .background(Color.primary.opacity(0.045))
        .overlay(alignment: .top) { Divider() }
    }

    private func updateBar(_ version: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.coral)
            Text(store.isUpdating ? "Updating Lanes…" : "Lanes \(version) is available")
                .font(.callout)
            Spacer()
            if store.isUpdating {
                ProgressView().controlSize(.small)
            } else {
                Button("Update") { store.installUpdate() }
                    .buttonStyle(HoverButtonStyle())
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Brand.coral.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }

    // After an update, until opened or dismissed.
    private func whatsNewBar(_ version: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Brand.azure)
            Text("Updated to Lanes \(version)")
                .font(.callout)
            Spacer()
            Button("What's New") { closePanel(); WhatsNewWindow.show() }
                .buttonStyle(HoverButtonStyle())
                .font(.callout.weight(.semibold))
            Button { store.updatedTo = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)))
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Brand.azure.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }

    private func closePanel() { NSApp.keyWindow?.orderOut(nil) }

    private func show(_ id: String) {
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

// The lane with the most 5-hour headroom, and a one-click way into it.
struct RoomiestCard: View {
    let profile: Profile
    let running: Bool
    let usage: Usage?
    let shortcut: Bool
    let open: () -> Void

    private var tint: Color { profile.color.swatch }
    private var left: Int { max(0, 100 - Int((usage?.primary?.used ?? 0).rounded())) }
    private var limitName: String { usage?.primary?.tag ?? "5h" }

    var body: some View {
        HStack(spacing: 12) {
            TintedClaudeIcon(color: profile.color, size: 34, provider: profile.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text("MOST ROOM")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(profile.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(left)% of \(limitName) left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Button(running ? "Focus" : "Open", action: open)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .controlSize(.small)
                if shortcut { KeyCap(keys: "⌥⌘B") }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.08)],
                                     startPoint: .leading, endPoint: .trailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(tint.opacity(0.25)))
    }
}

// One profile in the panel: its lane stripe, name, state and both meters.
// Click to launch or focus it; right-click for the rest.
struct PanelLane: View {
    let profile: Profile
    let running: Bool
    let usage: Usage?
    let launch: () -> Void
    let reveal: () -> Void
    let setColor: ((String) -> Void)?
    let remove: (() -> Void)?
    @State private var hovering = false

    private var tint: Color { profile.color.swatch }

    var body: some View {
        Button(action: launch) {
            HStack(alignment: .top, spacing: 10) {
                LaneStripe(tint: tint, lit: running, width: 3.5)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        if hovering {
                            HStack(spacing: 3) {
                                Text(running ? "Focus" : "Launch")
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(tint)
                        } else if running {
                            RunState(running: true)
                        }
                    }
                    UsagePair(usage: usage, tint: tint, provider: profile.provider, compact: true, spacing: 14, signIn: launch)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(hovering ? 0.10 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(running ? "Focus" : "Launch", action: launch)
            Button("Reveal Data Folder in Finder", action: reveal)
            if let setColor {
                Menu("Color") {
                    ForEach(ProfileColor.all) { c in
                        Button {
                            setColor(c.name)
                        } label: {
                            if c.name == profile.colorName {
                                Label(c.name.capitalized, systemImage: "checkmark")
                            } else {
                                Text(c.name.capitalized)
                            }
                        }
                    }
                }
            }
            if let remove {
                Divider()
                Button("Remove…", role: .destructive, action: remove)
            }
        }
    }
}
