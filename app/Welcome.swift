// The first launch: three short steps in a sheet on the Lanes window. Where
// Lanes lives, the two things macOS will ask (and why), and the first lane.
// The Keychain and notification prompts wait for the second step, so they
// never show up unexplained.

import SwiftUI
import AppKit

struct WelcomeSheet: View {
    @ObservedObject var store: ProfileStore
    @State private var step: Int
    @Environment(\.dismiss) private var dismiss

    init(store: ProfileStore, step: Int = 0) {
        self.store = store
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: hello
                case 1: permissions
                default: firstLane
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle().fill(i == step ? Brand.coral : Color.primary.opacity(0.15)).frame(width: 6, height: 6)
                    }
                }
                Spacer()
                buttons
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(Color.primary.opacity(0.04))
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 520)
        .tint(Brand.coral)
        // Closed early (Esc): still ask, so usage and alerts start working.
        .onDisappear { store.finishWelcome() }
    }

    // MARK: Steps

    private var hello: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Welcome to Lanes").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Every Claude account in its own lane: its own login, chats and colored icon, all running at once. Lanes keeps an eye on each one's 5-hour and weekly limits and points you to the one with the most room.")
                .fixedSize(horizontal: false, vertical: true)
            point("menubar.rectangle", "Lanes lives in the menu bar",
                  "Click its icon, or press ⌥⌘P from any app, to see every lane and open one.")
            point("bolt.fill", "One shortcut to the roomiest lane",
                  "⌥⌘B opens the profile with the most room left.")
        }
    }

    private var permissions: some View {
        let claude = Providers.claude
        let keychain: String = "To read usage, Lanes needs the key \(claude.name) uses to protect its sign-in. Choose **Always Allow** so macOS asks only once. Lanes only reads it, and your session is only ever sent to \(claude.usageService)."
        return VStack(alignment: .leading, spacing: 14) {
            Text("Two things macOS will ask").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Right after you continue. Here's what they are, so neither is a surprise.")
                .foregroundStyle(.secondary)
            point("key.fill", "Access to “\(claude.keychainItem ?? "")”", LocalizedStringKey(keychain))
            point("bell.badge.fill", "Notifications",
                  "For a heads-up when a limit is close or about to run out, and when it resets. You pick the levels in Settings.")
        }
    }

    private var firstLane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your lanes").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("**Default** is the Claude you already have. Add a lane for each other account; it gets its own Claude in Spotlight and the Dock, in its own color.")
                .fixedSize(horizontal: false, vertical: true)
            point("person.crop.circle.badge.plus", "Sign in once per lane",
                  "The first time a lane opens, sign in with that account. Lanes sends the sign-in link back to the lane that asked for it.")
            if Providers.chatgpt.isInstalled {
                point("square.stack.3d.up.fill", "ChatGPT, too",
                      "Lanes can also run ChatGPT profiles: New Profile → App. For their usage it reads the profile's own auth.json, never refreshes it, and only sends it to \(Providers.chatgpt.usageService).")
            }
            point("stethoscope", "If something's off",
                  "Settings → Status checks everything Lanes depends on and fixes what it can. In the Terminal: lanes doctor.")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch step {
        case 0:
            Button("Continue") { withAnimation { step = 1 } }
                .keyboardShortcut(.defaultAction)
        case 1:
            Button("Continue") {
                store.finishWelcome()
                withAnimation { step = 2 }
            }
            .keyboardShortcut(.defaultAction)
        default:
            Button("Done") { dismiss() }
            Button("Add a Lane…") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { store.showAdd = true }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Brand.coral)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
