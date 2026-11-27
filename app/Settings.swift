// Settings: a small window in the shape of a macOS settings window: a row
// of tabs, one short pane each, the window sized to the pane.

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    @AppStorage("settingsTab") private var tab: Tab = .general
    @Environment(\.openWindow) private var openWindow
    // The screenshot renderer picks the pane to draw.
    var initialTab: Tab? = nil

    enum Tab: String, CaseIterable, Identifiable {
        case general, alerts, shortcuts, updates, status
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "General"
            case .alerts: "Alerts"
            case .shortcuts: "Shortcuts"
            case .updates: "Updates"
            case .status: "Status"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .alerts: "bell.badge"
            case .shortcuts: "command"
            case .updates: "arrow.down.circle"
            case .status: "stethoscope"
            }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $tab, flagged: store.healthNeedsAttention ? [.status] : [])
            Divider()
            Form { pane }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .toggleStyle(.switch)
                .tint(Brand.coral)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 500)
        .onAppear {
            if let initialTab { tab = initialTab }
            store.checkHealth()
            store.checkStatusLine()
        }
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case .general: general
        case .alerts: alerts
        case .shortcuts: shortcuts
        case .updates: updates
        case .status: status
        }
    }

    // MARK: Panes

    @ViewBuilder private var general: some View {
        Section {
            Toggle(isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })) {
                described("Open Lanes at login", "Keeps usage, alerts and link routing running.")
            }
            Picker("Check usage every", selection: $store.usageInterval) {
                ForEach([60.0, 120, 300, 600, 900], id: \.self) { s in
                    Text("\(Int(s / 60)) min").tag(s)
                }
            }
        }
        Section {
            LabeledContent {
                if store.isUpdatingStatusLine {
                    ProgressView().controlSize(.small)
                } else if !store.statusLineOff.isEmpty {
                    Button("Turn On") { store.confirmStatusLine(on: true) }
                } else if !store.statusLineOn.isEmpty {
                    Button("Turn Off") { store.confirmStatusLine(on: false) }
                }
            } label: {
                described("Usage in Claude Code's status line", store.statusLineSummary)
            }
        } header: {
            Text("Claude Code")
        } footer: {
            note("In the Terminal, lanes claude <name> runs Claude Code on a profile's account.")
        }
        Section {
            Toggle(isOn: $store.routeLinks) {
                described("Send claude:// links to the right profile",
                          "Sign-in and “open in app” links go to the profile they belong to. Off, macOS hands them to whichever Claude is running.")
            }
        } footer: {
            HStack(alignment: .top) {
                note("No telemetry. Usage is read from \(Providers.claude.usageService) with each profile's own session, and stays on this Mac.")
                Button("Show Welcome") {
                    store.showWelcome = true
                    openWindow(id: "main")
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(Brand.coral)
                .fixedSize()
            }
        }
    }

    @ViewBuilder private var alerts: some View {
        Section {
            Toggle(isOn: $store.alertsEnabled) {
                described("Usage alerts",
                          "When a 5-hour or weekly limit passes a level below, and when a limit you were close to resets. Their buttons open the profile with the most room, or mute a limit until it resets.")
            }
        } footer: {
            HStack {
                Spacer()
                Button("Send Test Alert") { store.sendTestAlert() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(Brand.coral)
                    .disabled(!store.alertsEnabled)
            }
        }
        Section {
            LabeledContent("Alert at") {
                HStack(spacing: 6) {
                    Picker("First level", selection: $store.alertWarn) {
                        ForEach(ProfileStore.warnLevels, id: \.self) { Text("\(Int($0))%").tag($0) }
                    }
                    Text("and").foregroundStyle(.secondary)
                    Picker("Second level", selection: $store.alertUrgent) {
                        ForEach(ProfileStore.urgentLevels.filter { $0 > store.alertWarn }, id: \.self) {
                            Text("\(Int($0))%").tag($0)
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle(isOn: $store.paceAlertsEnabled) {
                described("Warn when on pace to run out",
                          "When, at its recent rate, a limit will be used up well before it resets: within 45 minutes for the 5-hour limit, within a day for the weekly one.")
            }
        }
        .disabled(!store.alertsEnabled)
    }

    @ViewBuilder private var shortcuts: some View {
        Section {
            shortcut("Show the menu bar panel", "⌥⌘P", $store.shortcutEnabled)
            shortcut("Open the profile with the most room", "⌥⌘B", $store.bestShortcutEnabled)
        } footer: {
            note("They work from any app. Turn one off if another app already uses it.")
        }
    }

    @ViewBuilder private var updates: some View {
        Section {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lanes \(version)").font(.headline)
                    updateStatus
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let v = store.availableUpdate, !store.isUpdating {
                    Button("Install \(v)") { store.installUpdate() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Check Now") { store.checkForUpdate() }
                        .disabled(store.isCheckingForUpdate || store.isUpdating)
                }
            }
            .padding(.vertical, 2)
            Toggle(isOn: $store.autoUpdate) {
                described("Install updates automatically",
                          "Lanes checks GitHub every few hours, installs a new version and reopens. Off, it only tells you in the menu bar panel.")
            }
        } footer: {
            HStack {
                note("Update checks only ask GitHub for the latest version.")
                Spacer()
                Button("What's New") { WhatsNewWindow.show() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(Brand.coral)
            }
        }
    }

    @ViewBuilder private var status: some View {
        let issues = store.healthIssues
        Section {
            if store.health.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            } else if issues.isEmpty {
                Label("Everything Lanes needs is in place.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(issues) { healthRow($0) }
        } header: {
            if !issues.isEmpty {
                Text(issues.count == 1 ? "1 thing to look at" : "\(issues.count) things to look at")
            }
        }
        let fine = store.health.filter { $0.status == .ok }
        if !fine.isEmpty {
            Section {
                ForEach(fine) { healthRow($0) }
            } footer: {
                HStack {
                    note("The same checks from the Terminal: lanes doctor")
                    Spacer()
                    Button("Check Again") { store.checkHealth() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .foregroundStyle(Brand.coral)
                        .disabled(store.isCheckingHealth)
                }
            }
        }
    }

    private func healthRow(_ c: HealthCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: c.status == .ok ? "checkmark.circle.fill"
                  : c.status == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(c.status == .ok ? Color.green : c.status == .warn ? Color.orange : Color.red)
            if c.status == .ok {
                Text(c.title).foregroundStyle(.secondary)
            } else {
                described(c.title, c.detail)
            }
            Spacer()
            if c.status != .ok, let fix = c.fix, let title = c.fixTitle {
                Button(title) { store.fix(fix) }
            }
        }
    }

    @ViewBuilder private var updateStatus: some View {
        if store.isUpdating {
            Text("Installing the update…")
        } else if let error = store.updateError {
            Text(error).foregroundStyle(.red)
        } else if store.isCheckingForUpdate {
            Text("Checking…")
        } else if let v = store.availableUpdate {
            Text("Lanes \(v) is available.")
        } else if let date = store.lastUpdateCheck {
            Text("Up to date · checked \(date.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("Not checked yet")
        }
    }

    // MARK: Pieces

    private func described(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcut(_ title: String, _ keys: String, _ on: Binding<Bool>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                KeyCap(keys: keys).opacity(on.wrappedValue ? 1 : 0.5)
                Toggle(title, isOn: on).labelsHidden()
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// The row of tabs across the top, as in System Settings-era preference
// windows: a symbol over a label, the selected one tinted.
private struct TabBar: View {
    @Binding var selection: SettingsView.Tab
    var flagged: Set<SettingsView.Tab> = []

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsView.Tab.allCases) { t in
                let on = t == selection
                Button { selection = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 17, weight: .regular))
                            .frame(height: 22)
                            .overlay(alignment: .topTrailing) {
                                if flagged.contains(t) {
                                    Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: 4, y: -1)
                                }
                            }
                        Text(t.title).font(.system(size: 11))
                    }
                    .frame(width: 66, height: 48)
                    .foregroundStyle(on ? AnyShapeStyle(Brand.coral) : AnyShapeStyle(.secondary))
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.primary.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}
