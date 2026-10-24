import AppKit

/// Turns chat messages into tasks. Tasks run one at a time: foreground tasks need the screen.
@MainActor
final class ChatController: ObservableObject, TaskRunnerDelegate {
    let store: ThreadStore
    let catalog: AppCatalog
    /// Per-thread composer drafts, so Control–Space can prefill "@App ".
    @Published var drafts: [UUID: String] = [:]
    /// Bumped to move keyboard focus to the composer.
    @Published var focusRequest = 0
    /// Choices on a waiting task's card: take over the screen now, relaunch for background
    /// control, or give up on the background and run on screen.
    enum ScreenChoice { case now, relaunch, onScreenInstead }
    private var screenChoices: [UUID: ScreenChoice] = [:]
    nonisolated static let idleThreshold: TimeInterval = 20

    /// Supplies credentials at send time; nil means setup isn't finished.
    var credentials: () -> (apiKey: String, codex: CodexCredentials)? = { nil }
    /// Called when a task that used the screen ends, to bring the chat back in front.
    var onTaskFinished: () -> Void = {}
    var onSetupNeeded: () -> Void = {}

    private struct Job {
        let threadID: UUID
        let requestID: UUID
        let messageID: UUID
        let app: ChatApp
        let prompt: String
        let mode: ExecutionMode
    }

    private var queue: [Job] = []
    private var current: (job: Job, runner: TaskRunner?, task: Task<Void, Never>?, started: Date)?

    init(store: ThreadStore, catalog: AppCatalog) {
        self.store = store
        self.catalog = catalog
    }

    convenience init() { self.init(store: ThreadStore(), catalog: AppCatalog()) }

    // MARK: - Threads

    func newThread(app: ChatApp? = nil) {
        let id = store.newThread(app: app)
        drafts[id] = app.map { "@\($0.name) " } ?? ""
        focusRequest += 1
    }

    /// Stops the thread's running task and drops its queued ones first: their Stop buttons go with the thread.
    func deleteThread(_ id: UUID) {
        for job in queue where job.threadID == id { stop(messageID: job.messageID, in: id) }
        if let current, current.job.threadID == id { stop(messageID: current.job.messageID, in: id) }
        store.delete(id)
    }

    /// Set to ask before deleting every thread.
    @Published var confirmingDeleteAll = false

    func deleteAllThreads() {
        for job in queue { stop(messageID: job.messageID, in: job.threadID) }
        if let current { stop(messageID: current.job.messageID, in: current.job.threadID) }
        store.deleteAll()
        drafts.removeAll()
    }

    // MARK: - Sending

    /// Sends the draft: Return runs on screen, ⇧Return in the background.
    func send(in threadID: UUID, mode: ExecutionMode = .onScreen) {
        let draft = (drafts[threadID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        let parsed = MentionParser.parse(draft, appNames: catalog.all.map(\.name))
        let mentioned = parsed.app.flatMap { name in catalog.all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.chatApp }
        let app = mentioned ?? store.thread(threadID)?.lastApp
        drafts[threadID] = ""

        let request = ChatMessage(role: .user, text: draft, app: mentioned)
        store.append(request, to: threadID)
        guard let app else {
            store.append(ChatMessage(role: .task, text: "Mention an app with @ so I know where to do this.", state: .failed), to: threadID)
            return
        }
        guard !parsed.prompt.isEmpty else {
            store.append(ChatMessage(role: .task, text: "Tell me what to do in \(app.name).", app: app, state: .failed), to: threadID)
            return
        }
        let message = ChatMessage(role: .task, text: "", app: app, state: .queued, status: "Waiting for the current task…", mode: mode)
        store.append(message, to: threadID)
        queue.append(Job(threadID: threadID, requestID: request.id, messageID: message.id, app: app, prompt: parsed.prompt, mode: mode))
        startNext()
    }

    func stop(messageID: UUID, in threadID: UUID) {
        if let index = queue.firstIndex(where: { $0.messageID == messageID }) {
            queue.remove(at: index)
            finish(threadID: threadID, messageID: messageID, state: .stopped, text: "Stopped before it started.", seconds: nil)
            return
        }
        guard let current, current.job.messageID == messageID else { return }
        if let runner = current.runner { runner.cancel() }
        else {
            current.task?.cancel()
            end(state: .stopped, text: "Stopped.")
        }
    }

    var isBusy: Bool { current != nil }

    // MARK: - Running

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        guard let credentials = credentials() else {
            finish(threadID: job.threadID, messageID: job.messageID, state: .failed,
                   text: "Finish setup first: Accessibility, the Jev API key, and ChatGPT sign-in.", seconds: nil)
            onSetupNeeded()
            startNext()
            return
        }
        let context = store.context(for: job.threadID, before: job.requestID)
        current = (job, nil, nil, Date())
        let running = catalog.isRunning(job.app.bundleID)
        setStatus(running ? "Reading \(job.app.name)…" : "Opening \(job.app.name)…")
        current?.task = Task { [weak self] in
            do {
                guard let self else { return }
                let (app, background) = try await self.launch(for: job)
                guard self.current?.job.messageID == job.messageID else { return }
                guard let target = AppTarget.make(from: app) else {
                    throw ControllerError.invalid("\(job.app.name) can't be controlled.")
                }
                if background { self.store.updateMessage(job.messageID, in: job.threadID) { $0.ranInBackground = true } }
                let runner = TaskRunner(target: target, goal: job.prompt, apiKey: credentials.apiKey,
                                        credentials: credentials.codex, context: context, background: background)
                runner.delegate = self
                let waitForIdle = job.mode == .background && !background
                runner.requestScreen = { [weak self] steps in
                    guard let self else { throw CancellationError() }
                    if waitForIdle { try await self.awaitIdle(for: job, steps: steps) }
                }
                self.current?.runner = runner
                runner.start()
            } catch is CancellationError {
            } catch {
                guard let self, self.current?.job.messageID == job.messageID else { return }
                self.end(state: .failed, text: error.localizedDescription)
            }
        }
    }

    func choose(_ choice: ScreenChoice, messageID: UUID) {
        screenChoices[messageID] = choice
    }

    /// Opens the app for the task. A background task runs through a Chromium app's debugging connection
    /// when it already has one, and otherwise through arc-cua. Where arc-cua can't run, Chromium apps can be
    /// relaunched with debugging and other apps run on screen.
    private func launch(for job: Job) async throws -> (NSRunningApplication, background: Bool) {
        guard job.mode == .background else { return (try await AppCatalog.prepare(job.app), false) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: job.app.bundleID).first { !$0.isTerminated }
        if let running, ElectronDetector.supportsDebugging(bundleID: job.app.bundleID),
           await ElectronDetector.isReadyForBackground(pid: running.processIdentifier) {
            // Background control talks to the page directly; reopening the window would bring the app forward.
            return (running, true)
        }
        if await ArcDriver.connect() != nil {
            // arc-cua brings minimized or hidden windows up out of sight; asking the app to reopen would
            // show them on screen.
            if let running, !WindowSnapshot.axWindows(of: AXUIElementCreateApplication(running.processIdentifier)).isEmpty {
                return (running, true)
            }
            let previous = NSWorkspace.shared.frontmostApplication
            let app = try await AppCatalog.prepare(job.app, hidden: running == nil)
            Task { await AppCatalog.keepBehind(app, restoring: previous) }
            return (app, true)
        }
        guard ElectronDetector.supportsDebugging(bundleID: job.app.bundleID) else {
            return (try await AppCatalog.prepare(job.app), false)
        }
        if running != nil {
            switch try await awaitChoice(for: job, prompt: .relaunch, status: "Needs a relaunch for background control") {
            case .relaunch: break
            default:
                store.updateMessage(job.messageID, in: job.threadID) { $0.mode = .onScreen }
                return (try await AppCatalog.prepare(job.app), false)
            }
        }
        setStatus(running == nil ? "Opening \(job.app.name) for background control…" : "Relaunching \(job.app.name)…")
        return (try await ElectronDetector.relaunchWithDebugging(bundleID: job.app.bundleID, name: job.app.name).app, true)
    }

    /// Shows a card on the task and waits for a choice. Stop cancels the task.
    private func awaitChoice(for job: Job, prompt: WaitingPrompt, status: String, plan: [String]? = nil) async throws -> ScreenChoice {
        defer { screenChoices[job.messageID] = nil }
        store.updateMessage(job.messageID, in: job.threadID) { message in
            message.state = .waiting
            message.awaiting = prompt
            message.status = status
            message.plan = plan
        }
        while true {
            try Task.checkCancellation()
            if let choice = screenChoices[job.messageID] { return choice }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Background mode where background input is unavailable: borrow the screen once the user is idle.
    private func awaitIdle(for job: Job, steps: [PlanStep]) async throws {
        defer { screenChoices[job.messageID] = nil }
        store.updateMessage(job.messageID, in: job.threadID) { message in
            message.state = .waiting
            message.awaiting = .screen
            message.plan = steps.map(\.summary)
        }
        while true {
            try Task.checkCancellation()
            if screenChoices[job.messageID] != nil { return }
            if Self.secondsSinceUserInput() >= Self.idleThreshold {
                store.updateMessage(job.messageID, in: job.threadID) { $0.waitedForIdle = true }
                return
            }
            updateWaiting(job, "Waiting until you're idle to use the screen…")
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func updateWaiting(_ job: Job, _ status: String) {
        guard store.thread(job.threadID)?.messages.first(where: { $0.id == job.messageID })?.status != status else { return }
        store.updateMessage(job.messageID, in: job.threadID) { $0.status = status }
    }

    nonisolated static func secondsSinceUserInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func setStatus(_ status: String) {
        guard let job = current?.job else { return }
        store.updateMessage(job.messageID, in: job.threadID) { message in
            message.state = .running
            message.status = status
        }
    }

    private func end(state: TaskState, text: String) {
        guard let current else { return }
        self.current = nil
        if current.runner != nil {
            let metrics = RunMetrics.current.summary
            store.updateMessage(current.job.messageID, in: current.job.threadID) { $0.metrics = metrics }
        }
        finish(threadID: current.job.threadID, messageID: current.job.messageID, state: state, text: text,
               seconds: Date().timeIntervalSince(current.started))
        // A task that ran on screen returns the user to the chat; a background one leaves them where they are.
        if current.runner?.background != true { onTaskFinished() }
        startNext()
    }

    private func finish(threadID: UUID, messageID: UUID, state: TaskState, text: String, seconds: Double?) {
        store.updateMessage(messageID, in: threadID) { message in
            message.state = state
            message.status = nil
            message.text = text
            message.seconds = seconds
        }
    }

    // MARK: - TaskRunnerDelegate

    func taskRunner(_ r: TaskRunner, status: String) {
        guard current?.runner === r else { return }
        setStatus(status)
    }

    func taskRunnerDone(_ r: TaskRunner, summary: String) {
        guard current?.runner === r else { return }
        end(state: .done, text: summary)
    }

    func taskRunnerFailed(_ r: TaskRunner, error: String) {
        guard current?.runner === r else { return }
        end(state: .failed, text: error)
    }

    func taskRunnerCancelled(_ r: TaskRunner) {
        guard current?.runner === r else { return }
        end(state: .stopped, text: "Stopped.")
    }
}
