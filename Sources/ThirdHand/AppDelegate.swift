import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var hotkeyManager: HotkeyManager?
    private var didStart = false
    private var mainWindow: NSWindow?
    private var permissionTimer: Timer?
    private var apiKey: String?
    private var codexCredentials: CodexCredentials?
    private var codexSignIn: UUID?
    let chat = ChatController()
    lazy var benchmark = Benchmark(chat: chat)
    @Published var accessibilityReady = false
    @Published var shortcutReady = false
    @Published var screenReady = false
    @Published var keyReady = false
    @Published var codexAccount: String?
    @Published var codexSigningIn = false
    /// The main window shows settings in place of the thread pane.
    @Published var showingSettings = false
    var codexReady: Bool { codexAccount != nil }
    var isReady: Bool { accessibilityReady && keyReady && codexReady }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.info("applicationWillFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("applicationDidFinishLaunching — starting services")
        guard !didStart else { return }
        didStart = true

        hotkeyManager = HotkeyManager { [weak self] in
            self?.handleHotkey()
        }
        chat.credentials = { [weak self] in
            guard let self, AXIsProcessTrusted(), let apiKey = self.apiKey, let codex = self.codexCredentials else { return nil }
            return (apiKey, codex)
        }
        chat.onTaskFinished = { [weak self] in self?.showMain() }
        chat.onSetupNeeded = { [weak self] in self?.showSetup() }
        chat.catalog.refresh()
        showMain()
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        // Read once, outside hotkey handling: a Keychain prompt can steal app focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.apiKey = KeychainHelper.getAPIKey()
            self.keyReady = self.apiKey != nil
            if let tokens = KeychainHelper.getCodexTokens() { self.useCodex(tokens) }
            if !self.isReady { self.showSetup() }
        }

        Log.info("setup done")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    func showMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Third Hand"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(chat: chat, store: chat.store, setup: self))
            window.setFrameAutosaveName("ThirdHandMain")
            if !window.setFrameUsingName("ThirdHandMain") { window.center() }
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSetup() {
        showingSettings = true
        showMain()
    }

    private var lastPermissionState = ""

    private func refreshPermissions() {
        accessibilityReady = AXIsProcessTrusted()
        screenReady = CGPreflightScreenCaptureAccess()
        let permissionState = "accessibility=\(accessibilityReady) screenRecording=\(screenReady)"
        if permissionState != lastPermissionState { Log.info("Permissions " + permissionState); lastPermissionState = permissionState }
        if accessibilityReady && hotkeyManager?.isRunning == false { hotkeyManager?.start() }
        if !accessibilityReady && hotkeyManager?.isRunning == true { hotkeyManager?.stop() }
        shortcutReady = hotkeyManager?.isRunning == true
    }

    func openPrivacySettings(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Hotkey

    /// Opens a new thread with the app that was in front already mentioned.
    @objc func handleHotkey() {
        Log.info("Hotkey fired")
        let front = NSWorkspace.shared.frontmostApplication
        let app = front.flatMap { app -> ChatApp? in
            guard let id = app.bundleIdentifier, !AppTarget.ignoredBundles.contains(id) else { return nil }
            return ChatApp(name: app.localizedName ?? id, bundleID: id)
        }
        Log.info("Hotkey thread app=\(app?.bundleID ?? "none")")
        chat.newThread(app: app)
        showMain()
    }

    // MARK: - Onboarding

    @objc func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openPrivacySettings("Privacy_Accessibility") }
        refreshPermissions()
    }

    func promptScreenRecording() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess() { openPrivacySettings("Privacy_ScreenCapture") }
        refreshPermissions()
    }

    private func useCodex(_ tokens: CodexTokens) {
        let signIn = UUID()
        codexSignIn = signIn
        // A dead refresh token signs out only the sign-in it belongs to, and the UI follows.
        let credentials = CodexCredentials(tokens: tokens, forget: { [weak self] in
            Task { @MainActor in
                guard let self, self.codexSignIn == signIn else { return }
                Log.info("ChatGPT sign-in expired; signed out")
                self.signOutOfChatGPT()
            }
        })
        codexCredentials = credentials
        codexAccount = tokens.email ?? "ChatGPT account"
        Task {
            do {
                let models = try await CodexClient(credentials: credentials).availableModels()
                Log.info("ChatGPT plan models: \(models.joined(separator: ", "))")
                if !models.isEmpty, !models.contains(CodexClient.strongModel) {
                    Log.info("Planner model \(CodexClient.strongModel) is not in this plan's model list")
                }
            } catch { Log.info("ChatGPT model list failed: \(error.localizedDescription)") }
        }
    }

    func signInWithChatGPT() {
        guard !codexSigningIn else { return }
        codexSigningIn = true
        Task {
            defer { codexSigningIn = false }
            do {
                let tokens = try await CodexAuth.signIn(previous: KeychainHelper.getCodexTokens())
                try KeychainHelper.saveCodexTokens(tokens)
                useCodex(tokens)
                Log.info("ChatGPT sign-in succeeded")
                showSetup()
            } catch is CancellationError {
            } catch {
                Log.info("ChatGPT sign-in failed")
                let failure = NSAlert()
                failure.messageText = "Could not sign in with ChatGPT"
                failure.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                failure.runModal()
            }
        }
    }

    func signOutOfChatGPT() {
        KeychainHelper.deleteCodexTokens()
        codexCredentials = nil
        codexSignIn = nil
        codexAccount = nil
    }

    @objc func promptAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Enter API Key"
        alert.informativeText = "Jev API key (TypeSafe), stored in macOS Keychain. Jev finds the control for each step: the step, observed accessibility text, and recent action results are sent to TypeSafe. Screenshots and OCR processing stay on this Mac."
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "apikey_..."
        if let existing = apiKey { field.stringValue = existing }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let k = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty {
                do {
                    try KeychainHelper.saveAPIKey(k)
                    apiKey = k
                    keyReady = true
                }
                catch {
                    let failure = NSAlert()
                    failure.messageText = "Could not save API key"
                    failure.informativeText = error.localizedDescription
                    failure.runModal()
                }
            }
        }
    }
}
