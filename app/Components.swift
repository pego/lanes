// The small pieces the window, the menu bar panel and settings share. The
// visual idea throughout: each profile is a lane on a track, painted in its
// color, with dashed lane markings between them.

import SwiftUI
import AppKit
import CoreImage

// The app's own icon in the profile's color, made the way the helper makes
// the Dock tiles and launchers, so the window shows exactly the icon you'll
// find in the Dock: Claude's hue-shifted (CIHueAdjust), ChatGPT's monochrome
// one on a plate of the color (see IconStyle).
struct TintedClaudeIcon: View {
    let color: ProfileColor
    var size: CGFloat = 40
    var provider: any Provider = Providers.claude

    var body: some View {
        Image(nsImage: tintedIcon(provider.icon, color: color, style: provider.iconStyle))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

private var tintCache: [ObjectIdentifier: [String: NSImage]] = [:]

func tintedIcon(_ icon: NSImage, color: ProfileColor, style: IconStyle) -> NSImage {
    let key = "\(style)-\(color.hue)-\(color.r)-\(color.g)-\(color.b)"
    if let hit = tintCache[ObjectIdentifier(icon)]?[key] { return hit }
    let px = 256
    // Claude's own orange is hue 0: its icon as it is.
    if style == .hueShift && color.hue == 0 { return icon }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return icon }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    guard let ci = CIImage(bitmapImageRep: rep) else { return icon }
    let f: CIFilter?
    switch style {
    case .hueShift:
        f = CIFilter(name: "CIHueAdjust")
        f?.setValue(color.hue * .pi / 180, forKey: kCIInputAngleKey)
    case .tintedPlate:
        // Multiplies the white plate into the color; the dark glyph stays
        // dark and the transparent corners stay transparent.
        f = CIFilter(name: "CIColorMatrix")
        f?.setValue(CIVector(x: color.r, y: 0, z: 0, w: 0), forKey: "inputRVector")
        f?.setValue(CIVector(x: 0, y: color.g, z: 0, w: 0), forKey: "inputGVector")
        f?.setValue(CIVector(x: 0, y: 0, z: color.b, w: 0), forKey: "inputBVector")
    }
    guard let f else { return icon }
    f.setValue(ci, forKey: kCIInputImageKey)
    guard let out = f.outputImage,
          let cg = CIContext().createCGImage(out, from: CGRect(x: 0, y: 0, width: px, height: px))
    else { return icon }
    let img = NSImage(cgImage: cg, size: NSSize(width: px, height: px))
    tintCache[ObjectIdentifier(icon), default: [:]][key] = img
    return img
}

// "Updated 2 min ago", kept current. Written out rather than a relative date
// style so it stays in the app's language whatever the system locale.
struct UpdatedAgo: View {
    let date: Date?
    var prefix = "Updated"

    var body: some View {
        if let date {
            TimelineView(.periodic(from: date, by: 10)) { ctx in
                Text("\(prefix) \(agoText(ctx.date.timeIntervalSince(date)))")
            }
        } else {
            Text("Fetching usage…")
        }
    }

    private func agoText(_ s: TimeInterval) -> String {
        if s < 15 { return "just now" }
        if s < 60 { return "\(Int(s)) s ago" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        return "\(Int(s / 3600)) h ago"
    }
}

// A horizontal track line: dashed between lanes, solid at the track's edges.
struct LaneMarking: View {
    var dashed = true
    var opacity: Double = 0.16

    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(Color.primary.opacity(opacity),
                    style: StrokeStyle(lineWidth: 1, dash: dashed ? [7, 5] : []))
        }
        .frame(height: 1)
    }
}

// The lane's painted edge: bright while the profile is running.
struct LaneStripe: View {
    let tint: Color
    let lit: Bool
    var width: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(tint.opacity(lit ? 1 : 0.35))
            .frame(width: width)
    }
}

// "5H 42%" over a meter, with when the limit resets underneath, and (outside
// compact mode) where it's heading at the current pace.
struct MeterCell: View {
    let label: String
    let value: Double?
    let reset: Date?
    let window: TimeInterval
    let tint: Color
    var forecast: Pace? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: compact ? 12 : 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(value.map { $0 >= 75 } == true ? usageColor(value, tint: tint) : Color.primary)
            }
            LaneMeter(value: value, tint: tint,
                      pace: elapsedFraction(reset: reset, window: window),
                      projected: forecast?.atReset,
                      height: compact ? 5 : 6)
            Text(resetText(reset) ?? " ")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if !compact {
                forecastLine
            }
        }
        .help(paceHelp)
    }

    // "Used up ~15:40 at this pace" when that's before the reset, otherwise
    // "~72% at reset" when the projection is meaningfully above today's value.
    @ViewBuilder private var forecastLine: some View {
        Group {
            if let out = forecast?.runsOutAt {
                Text("Used up ~\(clockText(out)) at this pace")
                    .foregroundStyle(Color.orange)
            } else if let f = forecast, let v = value, f.atReset >= v + 3 {
                Text("~\(Int(f.atReset.rounded()))% at reset, at this pace")
                    .foregroundStyle(.tertiary)
            } else {
                Text(" ")
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var paceHelp: String {
        var lines: [String] = []
        if let e = elapsedFraction(reset: reset, window: window) {
            lines.append("The marker shows how much of this window has passed (\(Int((e * 100).rounded()))%). Usage left of it is on pace.")
        }
        if let f = forecast {
            if let out = f.runsOutAt {
                lines.append("At the current rate this limit is used up around \(clockText(out)), before it resets.")
            } else {
                lines.append("At the current rate it reaches about \(Int(f.atReset.rounded()))% by the reset (the faint part of the bar).")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// Why a lane has no meters: not signed in, an error, or nothing loaded yet.
struct LaneNote: View {
    let usage: Usage?
    var provider: any Provider = Providers.claude
    var signIn: (() -> Void)? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let usage {
                Image(systemName: symbol(usage))
                // With the button beside it, the note can be short.
                // An app that renews its own sign-in only needs opening.
                let renews = usage.error == "session expired" && provider.renewsSignIn
                Text(usage.needsSignIn && signIn != nil
                     ? (renews ? "Sign-in expired" : usage.error == "session expired" ? "Signed out" : "Not signed in")
                     : text(usage))
                    .help(why(usage))
                if usage.needsSignIn, let signIn {
                    noteButton(renews ? "Open" : "Open and sign in", action: signIn)
                } else if usage.error != nil, provider.isKnown, let retry {
                    noteButton("Try again", action: retry)
                }
            } else {
                ProgressView().controlSize(.mini)
                Text("Loading usage…")
            }
        }
        .font(.caption)
        .foregroundStyle(usage?.needsSignIn == true ? Color.orange : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func symbol(_ u: Usage) -> String {
        if u.needsSignIn { return "person.crop.circle.badge.exclamationmark" }
        if u.error != nil { return "exclamationmark.triangle" }
        return "chart.bar"
    }

    private func noteButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold))
            }
            .fontWeight(.medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Brand.coral)
    }

    // The tooltip: what happened, in plain words, and what helps.
    private func why(_ u: Usage) -> String {
        guard let e = u.error else { return "" }
        let service = provider.usageService, app = provider.name
        if !provider.isKnown {
            return "This profile runs “\(provider.id)”, an app this version of Lanes doesn't know. Update Lanes to open it and see its usage."
        }
        if u.needsSignIn {
            return e == "session expired"
                ? (provider.renewsSignIn
                   ? "This profile's \(app) sign-in needs renewing, which \(app) does when it runs. Open it (and sign in if it asks) to see its usage."
                   : "\(service) signed this profile out. Open it and sign in again to see its usage.")
                : "This profile isn't signed in to \(app) yet. Open it and sign in to see its usage."
        }
        if e == "no Keychain access" {
            return "Lanes needs the key in “\(provider.keychainItem ?? "")” to read usage, and macOS said no. Try again and choose Always Allow; Settings → Status has more."
        }
        if e == "\(app)'s Keychain item is missing" {
            return "\(provider.desktopName) creates this item the first time it runs. Open \(app) once, then try again."
        }
        if e == "timed out" { return "\(service) took too long to answer. Lanes tries again on its own every few minutes." }
        if u.formatChanged { return "\(service) answered in a way Lanes doesn't understand; a Lanes update usually fixes it." }
        return "The usage check failed (\(e)). Lanes tries again on its own every few minutes."
    }

    private func text(_ u: Usage) -> String {
        if u.needsSignIn { return "Sign in to see usage" }
        if let e = u.error { return "Usage unavailable: \(e)" }
        return "No usage yet"
    }
}

// Shows a meter per limit (Claude's pair) when there are numbers, otherwise
// why there aren't.
struct UsagePair: View {
    let usage: Usage?
    let tint: Color
    var provider: any Provider = Providers.claude
    var compact = false
    var spacing: CGFloat = 16
    // What the lane's note offers when there are no numbers.
    var signIn: (() -> Void)? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        if let u = usage, u.error == nil, !u.hasNoData {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(u.limits) { l in
                        MeterCell(label: l.label, value: l.used, reset: l.reset,
                                  window: l.window, tint: tint, forecast: l.pace, compact: compact)
                    }
                }
                if let since = u.staleSince {
                    StaleNote(since: since, error: u.staleError, fromLocalRecord: u.fromLocalRecord, provider: provider)
                }
            }
        } else {
            LaneNote(usage: usage, provider: provider, signIn: signIn, retry: retry)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Under meters that show the previous numbers because the last check failed.
struct StaleNote: View {
    let since: Date
    let error: String?
    var fromLocalRecord = false
    var provider: any Provider = Providers.claude

    var body: some View {
        Label("As of \(clockText(since)): couldn't refresh", systemImage: "exclamationmark.arrow.circlepath")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(error.map {
                "The last usage check failed (\($0)). "
                    + (fromLocalRecord
                       ? "These numbers are the last ones \(provider.desktopName) recorded itself, shown for up to an hour."
                       : "Lanes keeps showing the previous numbers for up to an hour.")
            } ?? "")
    }
}

// Shown when every profile's usage check fails in a way that suggests
// claude.ai changed its usage endpoint, which only a Lanes update can fix.
struct UsageBrokenBanner: View {
    @ObservedObject var store: ProfileStore
    var provider: any Provider = Providers.claude

    var body: some View {
        let service = provider.usageService
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lanes can't read usage from \(service)")
                    .font(.callout.weight(.semibold))
                Text("\(service) may have changed how it reports usage. Launching profiles still works; a Lanes update usually brings the numbers back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let v = store.availableUpdate {
                Button(store.isUpdating ? "Updating…" : "Install \(v)") { store.installUpdate() }
                    .disabled(store.isUpdating)
            } else {
                Button(store.isCheckingForUpdate ? "Checking…" : "Check for Update") { store.checkForUpdate() }
                    .disabled(store.isCheckingForUpdate)
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.25)))
    }
}

// "● Running" in green, or a quiet "Stopped".
struct RunState: View {
    let running: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(running ? "Running" : "Stopped")
        }
        .font(.caption)
        .foregroundStyle(running ? Color.green : Color.secondary)
    }
}

// A keyboard shortcut drawn as a key cap.
struct KeyCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }
}

// A borderless button that lights up on hover: panel actions, icon buttons.
struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    var padding = EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, cornerRadius: cornerRadius, padding: padding)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let padding: EdgeInsets
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// Mirrors slugify + displayify in bin/lanes: "client acme" → "Client Acme".
// Used to preview the launcher name and catch duplicates before creating.
func profileDisplayName(_ raw: String) -> String {
    raw.lowercased()
        .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

func tildePath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

// The Settings button's gear, with an orange dot when Settings > Status has
// something that needs a look.
struct SettingsGear: View {
    let flagged: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: "gearshape")
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if flagged {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: 2, y: -1)
                }
            }
    }

    // With something to look at, Settings opens on Status.
    static func prepare(_ store: ProfileStore) {
        if store.healthNeedsAttention { UserDefaults.standard.set(SettingsView.Tab.status.rawValue, forKey: "settingsTab") }
    }
}
