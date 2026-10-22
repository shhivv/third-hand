import AppKit
import SwiftUI

/// Monochrome palette: black surfaces, hairline borders, white text, one accent.
enum Theme {
    static let background = Color.black
    static let sidebar = Color(white: 0.043)
    static let surface = Color(white: 0.075)
    static let raised = Color(white: 0.11)
    static let border = Color(white: 0.16)
    static let text = Color(white: 0.96)
    static let secondary = Color(white: 0.55)
    static let tertiary = Color(white: 0.36)
    static let accent = Color(red: 0.55, green: 0.64, blue: 1.0)
    static let success = Color(red: 0.36, green: 0.84, blue: 0.55)
    static let failure = Color(red: 1.0, green: 0.42, blue: 0.42)
}

struct MainView: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var store: ThreadStore
    @ObservedObject var setup: AppDelegate

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(chat: chat, store: store, setup: setup)
                .frame(width: 250)
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(spacing: 0) {
                if setup.showingSettings {
                    SettingsView(setup: setup)
                } else {
                    if !setup.isReady { SetupBanner(setup: setup) }
                    if let id = store.selection, let thread = store.thread(id) {
                        ThreadView(chat: chat, thread: thread)
                    } else {
                        EmptyState(chat: chat)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.background)
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 480)
        .preferredColorScheme(.dark)
        .onChange(of: store.selection) { setup.showingSettings = false }
    }
}

private struct SetupBanner: View {
    @ObservedObject var setup: AppDelegate

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.yellow).frame(width: 7, height: 7)
            Text("Finish setup to let Third Hand control apps").font(.system(size: 13))
            Spacer()
            Button("Finish Setup") { setup.showSetup() }.buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 12)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

private struct EmptyState: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.fill").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.secondary)
            Text("Tag an app. Tell it what to do.").font(.system(size: 20, weight: .semibold))
            Text("“@Spotify play something chill” · “@Notes start a grocery list”\nPress Control–Space in any app to start a thread with it.")
                .font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(Theme.secondary).lineSpacing(3)
            Button("New thread") { chat.newThread() }.buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut("n")
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var setup: AppDelegate

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.system(size: 20, weight: .semibold))
                    Text(setup.isReady ? "Ready when you are." : "Finish these to let Third Hand control apps.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }

                section("Permissions") {
                    row(setup.accessibilityReady, "Accessibility", setup.accessibilityReady ? "Enabled" : "Needed to read and control apps") {
                        Button(setup.accessibilityReady ? "Open Settings" : "Enable") {
                            if setup.accessibilityReady { setup.openPrivacySettings("Privacy_Accessibility") } else { setup.promptAccessibility() }
                        }.buttonStyle(PillButtonStyle(prominent: !setup.accessibilityReady))
                    }
                    divider
                    row(setup.screenReady, "Screen Recording", setup.screenReady ? "Enabled" : "Needed for on-device text recognition") {
                        Button(setup.screenReady ? "Open Settings" : "Enable") {
                            if setup.screenReady { setup.openPrivacySettings("Privacy_ScreenCapture") } else { setup.promptScreenRecording() }
                        }.buttonStyle(PillButtonStyle(prominent: !setup.screenReady))
                    }
                    divider
                    row(setup.shortcutReady, "Control–Space", setup.shortcutReady ? "Starts a thread with the app in front" : "Waiting for Accessibility access") {
                        EmptyView()
                    }
                }

                section("Accounts") {
                    row(setup.codexReady, "ChatGPT",
                        setup.codexAccount ?? (setup.codexSigningIn ? "Finish signing in in your browser…" : "Plans each step using your ChatGPT plan")) {
                        if setup.codexReady {
                            Button("Sign Out") { setup.signOutOfChatGPT() }.buttonStyle(PillButtonStyle())
                        } else {
                            Button("Sign in with ChatGPT") { setup.signInWithChatGPT() }
                                .buttonStyle(PillButtonStyle(prominent: true)).disabled(setup.codexSigningIn)
                        }
                    }
                    divider
                    row(setup.keyReady, "Jev API key", setup.keyReady ? "Loaded from Keychain" : "Needs setup or Keychain approval") {
                        Button(setup.keyReady ? "Change" : "Set Key") { setup.promptAPIKey() }
                            .buttonStyle(PillButtonStyle(prominent: !setup.keyReady))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Screen reading stays on-device. ChatGPT plans each step and writes any text; Jev finds the control. Your request and screen text are sent to OpenAI and TypeSafe.")
                    Text("If macOS asks you to quit and reopen after enabling access, reopen this copy of Third Hand.")
                    Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineSpacing(2)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 48).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 40) }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
    }

    private func row<Accessory: View>(_ ok: Bool, _ title: String, _ detail: String,
                                      @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16)).foregroundStyle(ok ? Theme.success : Color.yellow)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var store: ThreadStore
    @ObservedObject var setup: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Third Hand").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                Button { chat.newThread() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(IconButtonStyle()).help("New thread (⌘N)")
            }
            .padding(.leading, 16).padding(.trailing, 10)
            .padding(.top, 40).padding(.bottom, 12)

            Text("THREADS").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 16).padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.sorted) { thread in
                        ThreadRow(thread: thread, selected: store.selection == thread.id, catalog: chat.catalog)
                            .onTapGesture { store.selection = thread.id; setup.showingSettings = false }
                            .contextMenu { Button("Delete Thread", role: .destructive) { chat.deleteThread(thread.id) } }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            Button { setup.showingSettings ? (setup.showingSettings = false) : setup.showSetup() } label: {
                HStack(spacing: 8) {
                    Circle().fill(setup.isReady ? Theme.success : Color.yellow).frame(width: 7, height: 7)
                    Text(setup.codexAccount ?? "Settings").font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .foregroundStyle(setup.showingSettings ? Theme.text : Theme.secondary)
                .background(setup.showingSettings ? Theme.raised.opacity(0.5) : .clear)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(Theme.sidebar)
    }
}

private struct ThreadRow: View {
    let thread: ChatThread
    let selected: Bool
    let catalog: AppCatalog
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let app = thread.lastApp {
                    Image(nsImage: catalog.icon(for: app.bundleID)).resizable()
                } else {
                    Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                if let last = thread.messages.last(where: { $0.role == .task }) {
                    Text(last.status ?? last.text).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if thread.messages.contains(where: { $0.state == .waiting }) {
                Image(systemName: "hourglass").font(.system(size: 10)).foregroundStyle(Theme.accent)
            } else if thread.messages.contains(where: { $0.state == .running }) {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.raised : hovering ? Theme.surface : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Conversation

private struct ThreadView: View {
    @ObservedObject var chat: ChatController
    let thread: ChatThread

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let app = thread.lastApp {
                    Image(nsImage: chat.catalog.icon(for: app.bundleID)).resizable().frame(width: 16, height: 16)
                }
                Text(thread.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
            .frame(height: 52, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(thread.messages) { message in
                            MessageRow(message: message, catalog: chat.catalog,
                                       onStop: { chat.stop(messageID: message.id, in: thread.id) },
                                       onChoose: { chat.choose($0, messageID: message.id) })
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: thread.messages.last) { _, last in
                    if let last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear { if let last = thread.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Composer(chat: chat, threadID: thread.id, lastApp: thread.lastApp)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let catalog: AppCatalog
    let onStop: () -> Void
    let onChoose: (ChatController.ScreenChoice) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(message.date, style: .time).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    if let seconds = message.seconds, message.state == .done {
                        Text(String(format: "· %.0fs", seconds)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    if message.role == .task, let chip = modeChip { chip }
                }
                if message.role == .user {
                    Text(Self.highlighted(message.text)).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                } else {
                    taskBody
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        message.role == .user ? "You" : message.app?.name ?? "Third Hand"
    }

    @ViewBuilder private var avatar: some View {
        Group {
            if message.role == .user {
                Circle().fill(Theme.raised).overlay(Image(systemName: "person.fill").font(.system(size: 12)).foregroundStyle(Theme.secondary))
            } else if let app = message.app {
                Image(nsImage: catalog.icon(for: app.bundleID)).resizable()
            } else {
                Circle().fill(Theme.raised).overlay(Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Theme.secondary))
            }
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder private var taskBody: some View {
        switch message.state {
        case .queued, .running:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message.status ?? "Working…").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Button("Stop", action: onStop).buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        case .waiting:
            if message.awaiting == .relaunch {
                RelaunchCard(message: message, onChoose: onChoose, onStop: onStop)
            } else {
                TakeoverCard(message: message, onChoose: onChoose, onStop: onStop)
            }
        case .done:
            VStack(alignment: .leading, spacing: 4) {
                result(icon: "checkmark", color: Theme.success, text: message.text)
                if let metrics = message.metrics { MetricsLine(metrics: metrics) }
            }
        case .failed:
            result(icon: "xmark", color: Theme.failure, text: message.text)
        case .stopped:
            result(icon: "stop.fill", color: Theme.tertiary, text: message.text)
        case nil:
            Text(message.text).font(.system(size: 14))
        }
    }

    /// How the task used (or will use) the screen.
    private var modeChip: AnyView? {
        guard let mode = message.mode else { return nil }
        let (label, symbol): (String, String) = {
            if message.ranInBackground == true { return ("Background", "moon") }
            if message.waitedForIdle == true { return ("On screen · after idle", "moon.zzz") }
            return (mode.label, mode.symbol)
        }()
        return AnyView(
            Label(label, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.border))
        )
    }

    private func result(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text(text).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                .foregroundStyle(message.state == .stopped ? Theme.secondary : Theme.text)
        }
    }

    /// Shows the first @mention in the accent color.
    static func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        if let range = text.range(of: #"@[^\s@]+"#, options: .regularExpression),
           let attributedRange = Range(range, in: attributed) {
            attributed[attributedRange].foregroundColor = Theme.accent
            attributed[attributedRange].font = .system(size: 14, weight: .semibold)
        }
        return attributed
    }
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var chat: ChatController
    let threadID: UUID
    let lastApp: ChatApp?
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    private var draft: Binding<String> {
        Binding(get: { chat.drafts[threadID] ?? "" }, set: { chat.drafts[threadID] = $0 })
    }

    private var suggestions: [AppEntry] {
        MentionParser.partial(in: draft.wrappedValue).map { chat.catalog.suggestions(for: $0) } ?? []
    }

    private var canSend: Bool { !draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, entry in
                        Button { complete(with: entry) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: chat.catalog.icon(for: entry.bundleID)).resizable().frame(width: 18, height: 18)
                                Text(entry.name).font(.system(size: 13))
                                Spacer()
                                if !chat.catalog.isRunning(entry.bundleID) {
                                    Text("opens").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(index == highlighted ? Theme.raised : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("", text: draft, prompt: Text(placeholder).foregroundStyle(Theme.tertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.return, phases: .down) { press in
                        // Return runs on screen (onSubmit); ⇧Return runs in the background.
                        guard press.modifiers.contains(.shift), suggestions.isEmpty else { return .ignored }
                        send(mode: .background)
                        return .handled
                    }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.tab) {
                        guard let entry = suggestions[safe: highlighted] else { return .ignored }
                        complete(with: entry)
                        return .handled
                    }
                    .padding(.vertical, 3)
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.black : Theme.tertiary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(canSend ? Theme.text : Theme.raised))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Theme.tertiary : Theme.border))
            HStack(spacing: 14) {
                KeyHint(keys: "↩", text: "run on screen")
                KeyHint(keys: "⇧↩", text: "run in background")
            }
            .padding(.leading, 4)
        }
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 4)
        .onAppear { focusAtEnd() }
        .onChange(of: chat.focusRequest) { _, _ in focusAtEnd() }
        .onChange(of: draft.wrappedValue) { _, _ in highlighted = 0 }
    }

    /// Focusing a text field selects its contents on macOS; put the caret after a prefilled "@App " instead.
    private func focusAtEnd() {
        focused = true
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private var placeholder: String {
        lastApp.map { "Message \($0.name), or @mention another app" } ?? "@mention an app and say what to do"
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + delta + suggestions.count) % suggestions.count
        return .handled
    }

    private func submit() {
        if let entry = suggestions[safe: highlighted] { complete(with: entry); return }
        send(mode: .onScreen)
    }

    private func send(mode: ExecutionMode) {
        guard canSend else { return }
        chat.send(in: threadID, mode: mode)
        focused = true
    }

    private func complete(with entry: AppEntry) {
        var text = draft.wrappedValue
        if let at = text.lastIndex(of: "@") { text = String(text[..<at]) }
        draft.wrappedValue = text + "@\(entry.name) "
        focused = true
    }
}

// MARK: - Screen use

private struct TakeoverCard: View {
    let message: ChatMessage
    let onChoose: (ChatController.ScreenChoice) -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz").font(.system(size: 12)).foregroundStyle(Theme.accent)
                Text("\(message.app?.name ?? "This app") needs the screen").font(.system(size: 13, weight: .semibold))
            }
            if let plan = message.plan, !plan.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.tertiary)
                            Text(step).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            Text("\(message.app?.name ?? "This app") can't be controlled in the background, so this will use the screen when you step away.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                Button("Take over now") { onChoose(.now) }.buttonStyle(PillButtonStyle(prominent: true))
                Button("Cancel", action: onStop).buttonStyle(PillButtonStyle())
                Spacer()
                Text(message.status ?? "").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

/// "codex 1× 4.2s · jev 3× 0.9s · 5 actions (3 in goals)" for comparing runs.
private struct MetricsLine: View {
    let metrics: [String: Int]

    var body: some View {
        let seconds = { (key: String) in String(format: "%.1fs", Double(metrics[key] ?? 0) / 1000) }
        let goals = metrics["goal_actions"].map { $0 > 0 ? " (\($0) in goals)" : "" } ?? ""
        Text("codex \(metrics["codex_calls"] ?? 0)× \(seconds("codex_ms")) · jev \(metrics["jev_calls"] ?? 0)× \(seconds("jev_ms")) · \(metrics["actions"] ?? 0) actions\(goals)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.tertiary)
    }
}

private struct RelaunchCard: View {
    let message: ChatMessage
    let onChoose: (ChatController.ScreenChoice) -> Void
    let onStop: () -> Void

    var body: some View {
        let name = message.app?.name ?? "This app"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("Relaunch \(name) for background control?").font(.system(size: 13, weight: .semibold))
            }
            Text("\(name) will quit and reopen with a local debugging connection, so Third Hand can work in it without taking over your screen. Anything playing or unsaved in \(name) stops. While it's open this way, other apps on this Mac could connect to it too.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Relaunch \(name)") { onChoose(.relaunch) }.buttonStyle(PillButtonStyle(prominent: true))
                Button("Run on screen instead") { onChoose(.onScreenInstead) }.buttonStyle(PillButtonStyle())
                Button("Cancel", action: onStop).buttonStyle(PillButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

private struct KeyHint: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys).font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
            Text(text).font(.system(size: 10))
        }
        .foregroundStyle(Theme.tertiary)
    }
}

// MARK: - Controls

private struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.black : Theme.text)
            .padding(.horizontal, prominent ? 16 : 10).padding(.vertical, prominent ? 7 : 4)
            .background(Capsule().fill(prominent ? Theme.text : Theme.raised))
            .overlay(Capsule().stroke(prominent ? .clear : Theme.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.secondary)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.raised : .clear))
            .contentShape(Rectangle())
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
