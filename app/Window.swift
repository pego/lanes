// The Lanes window: every profile as a numbered lane on a track, with its
// usage at a glance. Click a lane to open its drawer: a week of history,
// where its data lives, its color, and removal.

import SwiftUI
import AppKit
import Charts

struct LanesWindow: View {
    @ObservedObject var store: ProfileStore
    @State private var expanded: String?
    @State private var removing: Profile?
    @State private var confirmWipe: Profile?
    @Environment(\.openWindow) private var openWindow

    init(store: ProfileStore, expanded: String? = nil) {
        self.store = store
        _expanded = State(initialValue: expanded)
    }

    // SwiftUI opens the window at launch; a menu bar app shouldn't. Only the
    // first appearance is swallowed, and only if nothing asked for the window.
    private static var launchHandled = false
    private func hideLaunchWindow() {
        guard store.live, !Self.launchHandled else { return }
        Self.launchHandled = true
        guard !store.showAdd, !store.showWelcome, store.removeRequest == nil else { return }
        // By title, or by the scene id SwiftUI puts in the window identifier,
        // in case a hidden title bar ever leaves the title empty.
        DispatchQueue.main.async {
            NSApp.windows.first {
                $0.title == "Lanes" || $0.identifier?.rawValue.hasPrefix("main") == true
            }?.close()
        }
    }

    private func takeRemoveRequest() {
        if let p = store.removeRequest {
            removing = p
            store.removeRequest = nil
        }
    }

    // The first color no profile wears yet, so new lanes are told apart.
    private var freeColor: String {
        ProfileColor.all.first { c in !store.profiles.contains { $0.colorName == c.name } }?.name ?? "blue"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if store.usageLooksBroken {
                    UsageBrokenBanner(store: store)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                track
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            footer
        }
        .frame(minWidth: 720, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear {
            store.setUp()
            takeRemoveRequest()
            hideLaunchWindow()
        }
        .onReceive(store.$removeRequest) { _ in takeRemoveRequest() }
        .sheet(isPresented: $store.showWelcome) { WelcomeSheet(store: store) }
        .sheet(isPresented: $store.showAdd) {
            AddSheet(existing: store.profiles.map(\.name), routesLinks: store.routeLinks,
                     initialColor: freeColor) { name, color in store.add(name, color: color) }
        }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { p in
            Button("Remove Launcher Only") { store.remove(p, deleteData: false) }
            Button("Delete Everything…", role: .destructive) { confirmWipe = p }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("“Launcher Only” removes the Spotlight app but keeps chats, login and settings on disk. The lane stays here and can be fully removed later.")
        }
        .alert(
            "Delete all data for “\(confirmWipe?.name ?? "")”?",
            isPresented: Binding(get: { confirmWipe != nil }, set: { if !$0 { confirmWipe = nil } }),
            presenting: confirmWipe
        ) { p in
            Button("Delete", role: .destructive) { store.remove(p, deleteData: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Chats, login and settings will be permanently erased. This can't be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lanes")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(store.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            Button { store.refresh(); store.refreshUsage() } label: {
                Group {
                    if store.isRefreshingUsage {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)))
            .keyboardShortcut("r")
            .help("Refresh usage (⌘R)")
            Button { SettingsGear.prepare(store); openWindow(id: "settings") } label: {
                SettingsGear(flagged: store.healthNeedsAttention, size: 18)
            }
            .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)))
            .keyboardShortcut(",")
            .help(store.healthNeedsAttention ? "Settings (⌘,): something needs a look" : "Settings (⌘,)")
            Button { store.showAdd = true } label: {
                Label("New Profile", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.coral)
            .controlSize(.large)
            .keyboardShortcut("n")
        }
        .padding(.horizontal, 28)
        .padding(.top, 42)
        .padding(.bottom, 16)
    }

    // MARK: Track

    private var track: some View {
        VStack(spacing: 0) {
            LaneMarking(dashed: false, opacity: 0.22)
            ForEach(Array(store.profiles.enumerated()), id: \.element.id) { i, p in
                LaneRow(
                    number: i + 1,
                    profile: p,
                    running: store.running.contains(p.id),
                    usage: store.usage[p.id],
                    isRoomiest: store.roomiestProfile()?.id == p.id,
                    expanded: expanded == p.id,
                    toggle: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            expanded = expanded == p.id ? nil : p.id
                        }
                    },
                    launch: { store.launch(p) },
                    reveal: { store.revealData(p) },
                    remove: p.isDefault ? nil : { removing = p },
                    retry: { store.refreshUsage() }
                ) {
                    LaneDetail(
                        profile: p,
                        history: store.history[p.name] ?? [],
                        models: store.usage[p.id]?.models ?? [],
                        alertAt: store.alertWarn,
                        version: store.claudeVersion(of: p),
                        dataPath: store.dataPath(of: p),
                        reveal: { store.revealData(p) },
                        export: { store.exportHistory(p) },
                        setColor: p.isDefault ? nil : { store.setColor(p, color: $0) },
                        remove: p.isDefault ? nil : { removing = p }
                    )
                }
                LaneMarking()
            }
            NewLaneRow(number: store.profiles.count + 1) { store.showAdd = true }
            LaneMarking(dashed: false, opacity: 0.22)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Label { UpdatedAgo(date: store.lastUsageUpdate, prefix: "Usage updated") } icon: { Image(systemName: "clock") }
            Spacer(minLength: 12)
            if !store.outdatedProfiles.isEmpty {
                Label(driftText, systemImage: "arrow.down.circle")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Profiles update themselves. One behind your main Claude catches up the next time it launches.")
            } else if !store.installedVersion.isEmpty {
                Text("Claude \(store.installedVersion)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider() }
    }

    private var driftText: String {
        let names = store.outdatedProfiles.joined(separator: ", ")
        let many = store.outdatedProfiles.count > 1
        return "\(names) \(many ? "catch" : "catches") up to Claude \(store.installedVersion) on next launch"
    }
}

// MARK: - Lane

struct LaneRow<Detail: View>: View {
    let number: Int
    let profile: Profile
    let running: Bool
    let usage: Usage?
    let isRoomiest: Bool
    let expanded: Bool
    let toggle: () -> Void
    let launch: () -> Void
    let reveal: () -> Void
    let remove: (() -> Void)?
    var retry: (() -> Void)? = nil
    @ViewBuilder let detail: () -> Detail
    @State private var hovering = false

    private var tint: Color { profile.color.swatch }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint.opacity(running ? 1 : 0.55))
                    .frame(width: 34, alignment: .leading)
                TintedClaudeIcon(color: profile.color, size: 42, provider: profile.provider)
                identity
                    .frame(width: 168, alignment: .leading)
                UsagePair(usage: usage, tint: tint, provider: profile.provider, signIn: launch, retry: retry)
                    .frame(maxWidth: 340)
                Spacer(minLength: 12)
                actions
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if expanded {
                detail()
                    .padding(.leading, 14 + 34 + 14)
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tint.opacity(expanded ? 0.09 : (hovering ? 0.055 : 0)))
        )
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button(running ? "Focus" : "Launch", action: launch)
            Button(expanded ? "Hide Details" : "Show Details", action: toggle)
            Button("Reveal Data Folder in Finder", action: reveal)
            if let remove {
                Divider()
                Button("Remove…", role: .destructive, action: remove)
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(profile.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if isRoomiest {
                    Text("Most room")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tint.opacity(0.16)))
                        .fixedSize()
                }
            }
            HStack(spacing: 6) {
                RunState(running: running)
                if profile.isDefault {
                    Text("· main install").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if running {
                Button(action: launch) { Text("Focus").frame(minWidth: 58) }
                    .buttonStyle(.bordered)
            } else {
                Button(action: launch) { Text("Launch").frame(minWidth: 58) }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            }
            Button(action: toggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(HoverButtonStyle(padding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)))
            .help(expanded ? "Hide details" : "History, data folder and color")
        }
    }
}

// MARK: - Lane drawer

// How far back the drawer's chart looks.
enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month"
    var id: String { rawValue }
    var span: TimeInterval {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return UsageHistory.keep
        }
    }
}

struct LaneDetail: View {
    let profile: Profile
    let history: [UsageSample]
    var models: [ModelLimit] = []
    var alertAt: Double = 80
    let version: String?
    let dataPath: String
    let reveal: () -> Void
    var export: (() -> Void)? = nil
    let setColor: ((String) -> Void)?
    let remove: (() -> Void)?
    @State private var range: HistoryRange = .week

    private var tint: Color { profile.color.swatch }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Picker("Range", selection: $range) {
                        ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    Spacer()
                    legend
                    if let export {
                        Button(action: export) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.borderless)
                            .disabled(history.isEmpty)
                            .help("Export the last 30 days as CSV")
                    }
                }
                UsageHistoryChart(samples: history, tint: tint, range: range, alertAt: alertAt)
                    .frame(height: 118)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 14) {
                fact("Data folder") {
                    HStack(alignment: .top, spacing: 6) {
                        Text(tildePath(dataPath))
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Button(action: reveal) { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                    }
                }
                fact("Claude") {
                    Text(version.map { "Version \($0)" }
                         ?? (profile.isDefault ? "Not installed" : "Set up on first launch"))
                }
                if !models.isEmpty {
                    fact("Weekly, per model") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(models) { m in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(m.label)
                                        Spacer()
                                        Text("\(Int(m.used.rounded()))%")
                                            .monospacedDigit()
                                            .foregroundStyle(m.used >= 75 ? usageColor(m.used, tint: tint) : .primary)
                                    }
                                    .font(.caption)
                                    LaneMeter(value: m.used, tint: tint,
                                              pace: elapsedFraction(reset: m.reset, window: LimitWindow.week), height: 4)
                                }
                                .help(resetText(m.reset).map { "\(m.label): its own weekly limit, \($0)." } ?? "")
                            }
                        }
                    }
                }
                if let setColor {
                    fact("Color") {
                        ColorSwatches(selected: profile.colorName, size: 16, pick: setColor)
                    }
                }
                if let remove {
                    Button(role: .destructive, action: remove) {
                        Label("Remove Profile…", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }
            .frame(width: 230, alignment: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(range == .month ? "5-hour peak" : "5 hours") { Capsule().fill(tint).frame(width: 12, height: 3) }
            legendItem("Week") {
                LaneMarking(opacity: 0.6).frame(width: 12)
            }
        }
    }

    private func legendItem<S: View>(_ title: String, @ViewBuilder swatch: () -> S) -> some View {
        HStack(spacing: 5) {
            swatch()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func fact<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            value().font(.callout)
        }
    }
}

// Day and week: 5-hour usage as a filled line in the lane's color, the weekly
// limit as a dashed line. Month: one bar per day for that day's 5-hour peak,
// and the weekly limit's daily high as a dashed line. Both draw the first
// alert level as a faint rule.
struct UsageHistoryChart: View {
    let samples: [UsageSample]
    let tint: Color
    var range: HistoryRange = .week
    var alertAt: Double = 80

    // English names, like the rest of the app.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let weekday = formatter("EEE")
    private static let hour = formatter("HH:mm")
    private static let dayMonth = formatter("d MMM")

    struct DayPeak: Identifiable {
        let day: Date
        let h: Double?
        let w: Double?
        var id: Date { day }
    }

    static func dailyPeaks(_ pts: [UsageSample]) -> [DayPeak] {
        let cal = Calendar.current
        return Dictionary(grouping: pts) { cal.startOfDay(for: $0.t) }
            .map { day, s in DayPeak(day: day, h: s.compactMap(\.h).max(), w: s.compactMap(\.w).max()) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        let start = Date().addingTimeInterval(-range.span)
        let pts = samples.filter { $0.t >= start && ($0.h != nil || $0.w != nil) }
        if pts.count < 2 {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line").font(.title3)
                Text("History fills in as Lanes checks usage, one reading every ten minutes.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        } else if range == .month {
            monthChart(Self.dailyPeaks(pts), start: start)
        } else {
            lineChart(pts, start: start)
        }
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: [0, 50, 100]) { v in
            AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.system(size: 9)) }
        }
    }

    private var alertRule: some ChartContent {
        RuleMark(y: .value("Alert", alertAt))
            .foregroundStyle(Color.primary.opacity(0.18))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }

    private func monthChart(_ days: [DayPeak], start: Date) -> some View {
        let cal = Calendar.current
        // Through the end of today, so today's bar isn't cut in half.
        let from = cal.startOfDay(for: max(start, days[0].day))
        let to = cal.startOfDay(for: Date()).addingTimeInterval(86400)
        return Chart {
            alertRule
            ForEach(days) { d in
                if let h = d.h {
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("5-hour peak", h))
                        .foregroundStyle(usageColor(h, tint: tint).opacity(0.85))
                        .cornerRadius(2)
                }
                if let w = d.w {
                    LineMark(x: .value("Day", d.day, unit: .day), y: .value("Week", w), series: .value("Limit", "Week"))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: from...to)
        .chartYAxis { yAxis }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel {
                    if let d = v.as(Date.self) { Text(Self.dayMonth.string(from: d)).font(.system(size: 9)) }
                }
            }
        }
    }

    private func lineChart(_ pts: [UsageSample], start: Date) -> some View {
        Chart {
            alertRule
            ForEach(pts, id: \.t) { s in
                if let h = s.h {
                    AreaMark(x: .value("Time", s.t), y: .value("5 hours", h))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.t), y: .value("5 hours", h), series: .value("Limit", "5 hours"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.monotone)
                }
                if let w = s.w {
                    LineMark(x: .value("Time", s.t), y: .value("Week", w), series: .value("Limit", "Week"))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: max(start, pts[0].t)...Date())
        .chartYAxis { yAxis }
        .chartXAxis {
            if range == .day {
                AxisMarks(values: .stride(by: .hour, count: 6)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                    AxisValueLabel {
                        if let d = v.as(Date.self) { Text(Self.hour.string(from: d)).font(.system(size: 9)) }
                    }
                }
            } else {
                AxisMarks(values: .stride(by: .day)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                    AxisValueLabel(centered: true) {
                        if let d = v.as(Date.self) { Text(Self.weekday.string(from: d)).font(.system(size: 9)) }
                    }
                }
            }
        }
    }
}

// MARK: - New lane

struct NewLaneRow: View {
    let number: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(hovering ? 0.35 : 0.18))
                    .frame(width: 34, alignment: .leading)
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary.opacity(hovering ? 0.45 : 0.25),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("New profile").font(.system(size: 15, weight: .semibold))
                    Text("Another Claude with its own login, chats and Dock color")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KeyCap(keys: "⌘N")
            }
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering ? 0.045 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - New profile sheet

struct AddSheet: View {
    let existing: [String]
    let routesLinks: Bool
    let create: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorName: String
    @FocusState private var nameFocused: Bool

    init(existing: [String], routesLinks: Bool, initialColor: String, initialName: String = "",
         create: @escaping (String, String) -> Void) {
        self.existing = existing
        self.routesLinks = routesLinks
        self.create = create
        _colorName = State(initialValue: initialColor)
        _name = State(initialValue: initialName)
    }

    private var color: ProfileColor { ProfileColor.named(colorName) }
    private var display: String { profileDisplayName(name) }

    private var problem: String? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if display.isEmpty { return "Use at least one letter or digit." }
        if display == "Default" { return "“Default” is your main Claude. Pick another name." }
        if existing.contains(where: { $0.caseInsensitiveCompare(display) == .orderedSame }) {
            return "You already have a profile called “\(display)”."
        }
        return nil
    }

    private var canCreate: Bool { !display.isEmpty && problem == nil }

    var body: some View {
        VStack(spacing: 0) {
            preview
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Name")
                    TextField("Work, Personal, Client Acme…", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($nameFocused)
                        .onSubmit(submit)
                    Text(problem ?? " ")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Color")
                    ColorSwatches(selected: colorName, size: 22) { colorName = $0 }
                }
                Label {
                    Text(routesLinks
                         ? "It starts empty and signs in on its own. When you log in, Lanes hands the sign-in link back to this profile, even with others open."
                         : "It starts empty and signs in on its own. Before its first sign-in, quit every other Claude: the login link goes to whichever one is running.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 18)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Profile", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(color.swatch)
                    .disabled(!canCreate)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }

    // How the profile will look where you'll meet it: Spotlight and the Dock.
    private var preview: some View {
        ZStack {
            LinearGradient(colors: [color.swatch.opacity(0.42), color.swatch.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                TintedClaudeIcon(color: color, size: 76)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                Text("Claude \(display.isEmpty ? "…" : display)")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text("How it shows up in Spotlight and the Dock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .frame(height: 180)
        .animation(.easeOut(duration: 0.2), value: colorName)
    }

    private func submit() {
        guard canCreate else { return }
        create(display, colorName)
        dismiss()
    }
}

// MARK: - Bits

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

struct ColorSwatches: View {
    let selected: String
    var size: CGFloat = 18
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: size * 0.45) {
            ForEach(ProfileColor.all) { c in
                Button { pick(c.name) } label: {
                    ZStack {
                        Circle().fill(c.swatch)
                        if c.name == selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: size * 0.5, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(c.name == selected ? 0.5 : 0), lineWidth: 1.5)
                        .padding(-3))
                }
                .buttonStyle(.plain)
                .help(c.name.capitalized)
            }
        }
        .padding(3)
    }
}
