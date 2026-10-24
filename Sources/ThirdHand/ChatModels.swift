import Foundation

struct ChatApp: Codable, Hashable {
    let name: String
    let bundleID: String
}

enum TaskState: String, Codable {
    /// `waiting` means the plan is ready and the task is waiting to use the screen.
    case queued, running, waiting, done, failed, stopped
}

/// How a task may use the screen. Return sends on screen, ⇧Return in the background: input goes to the
/// app's window (or a Chromium app's debugging connection) without bringing it forward.
enum ExecutionMode: String, Codable {
    case onScreen, background

    init(from decoder: Decoder) throws {
        // Older builds also stored "auto", which always ended up on screen.
        self = ExecutionMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .onScreen
    }

    var label: String { self == .background ? "Background" : "On screen" }
    var symbol: String { self == .background ? "moon" : "display" }
}

/// What a waiting task's card asks for.
enum WaitingPrompt: String, Codable {
    /// Borrow the screen (background mode in apps without background control).
    case screen
    /// Relaunch a Chromium app with a debugging port for background control.
    case relaunch
}

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, task }

    var id = UUID()
    var date = Date()
    var role: Role
    /// The user's words, or a task's final summary or failure reason.
    var text: String
    var app: ChatApp?
    var state: TaskState?
    /// Live progress while a task runs.
    var status: String?
    var seconds: Double?
    var mode: ExecutionMode?
    /// The planned steps shown while a task waits for the screen.
    var plan: [String]?
    /// Set when the task waited for the user to be idle before using the screen.
    var waitedForIdle: Bool?
    var awaiting: WaitingPrompt?
    /// Set when the task ran through the app's debugging connection, without the screen.
    var ranInBackground: Bool?
    /// Timing and call counts from RunMetrics, for experiments.
    var metrics: [String: Int]?
}

struct ChatThread: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    /// A message without an @mention runs in this app.
    var lastApp: ChatApp?
    var updated = Date()
}

/// Threads persisted as JSON in Application Support.
@MainActor
final class ThreadStore: ObservableObject {
    @Published var threads: [ChatThread] = []
    @Published var selection: UUID?
    private let url: URL?

    init(url: URL? = ThreadStore.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            guard let saved = try? JSONDecoder().decode([ChatThread].self, from: data) else {
                // Keep unreadable history aside so the next save doesn't overwrite it.
                Self.setAside(url)
                return
            }
            // A task can't still be running after a relaunch.
            threads = saved.map { thread in
                var thread = thread
                for index in thread.messages.indices where [.queued, .running, .waiting].contains(thread.messages[index].state) {
                    thread.messages[index].state = .stopped
                    thread.messages[index].status = nil
                    thread.messages[index].text = "Stopped when Third Hand quit."
                }
                return thread
            }
        }
        selection = sorted.first?.id
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Third Hand/threads.json")
    }

    nonisolated static func setAside(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            Log.info("Threads unreadable; kept them at \(aside.lastPathComponent)")
        } catch {
            Log.info("Threads unreadable and couldn't be kept aside error_type=\(String(reflecting: type(of: error)))")
        }
    }

    var sorted: [ChatThread] { threads.sorted { $0.updated > $1.updated } }

    func thread(_ id: UUID?) -> ChatThread? { threads.first { $0.id == id } }

    @discardableResult
    func newThread(app: ChatApp? = nil) -> UUID {
        let thread = ChatThread(title: "New thread", lastApp: app)
        threads.append(thread)
        selection = thread.id
        save()
        return thread.id
    }

    func delete(_ id: UUID) {
        threads.removeAll { $0.id == id }
        if selection == id { selection = sorted.first?.id }
        save()
    }

    func deleteAll() {
        threads.removeAll()
        selection = nil
        save()
    }

    func append(_ message: ChatMessage, to threadID: UUID) {
        update(threadID) { thread in
            if thread.messages.isEmpty, message.role == .user { thread.title = String(message.text.prefix(48)) }
            thread.messages.append(message)
            if let app = message.app { thread.lastApp = app }
        }
    }

    func updateMessage(_ id: UUID, in threadID: UUID, _ change: (inout ChatMessage) -> Void) {
        update(threadID) { thread in
            if let index = thread.messages.firstIndex(where: { $0.id == id }) { change(&thread.messages[index]) }
        }
    }

    private func update(_ threadID: UUID, _ change: (inout ChatThread) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        change(&threads[index])
        threads[index].updated = Date()
        save()
    }

    /// Earlier finished turns in a thread, oldest first, as short lines for the planner.
    func context(for threadID: UUID, before messageID: UUID, limit: Int = 8) -> [String] {
        guard let thread = thread(threadID),
              let end = thread.messages.firstIndex(where: { $0.id == messageID }) else { return [] }
        var lines: [String] = []
        var request: ChatMessage?
        for message in thread.messages[..<end] {
            if message.role == .user { request = message; continue }
            guard let request, let state = message.state, [.done, .failed, .stopped].contains(state) else { continue }
            let app = message.app.map { " in \($0.name)" } ?? ""
            lines.append("User\(app): \(request.text.prefix(300)) → \(state.rawValue): \(message.text.prefix(300))")
        }
        return Array(lines.suffix(limit))
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(threads).write(to: url, options: .atomic)
        } catch {
            Log.info("Thread save failed error_type=\(String(reflecting: type(of: error)))")
        }
    }
}

enum MentionParser {
    /// The first "@App Name" matching a known app (longest name wins), and the request without it.
    static func parse(_ text: String, appNames: [String]) -> (app: String?, prompt: String) {
        let names = appNames.sorted { $0.count > $1.count }
        var searchStart = text.startIndex
        while let at = text[searchStart...].firstIndex(of: "@") {
            defer { searchStart = text.index(after: at) }
            // Only at the start or after whitespace, so addresses like me@notes.com aren't mentions.
            if at > text.startIndex, !text[text.index(before: at)].isWhitespace { continue }
            let rest = text[text.index(after: at)...]
            for name in names where rest.lowercased().hasPrefix(name.lowercased()) {
                let end = rest.index(rest.startIndex, offsetBy: name.count)
                guard end == rest.endIndex || !(rest[end].isLetter || rest[end].isNumber) else { continue }
                let prompt = (text[..<at] + text[end...])
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return (name, prompt)
            }
        }
        return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The partial mention being typed at the end of the draft, if any.
    static func partial(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let partial = draft[draft.index(after: at)...]
        guard partial.count <= 30, !partial.contains("\n"), !partial.hasSuffix(" ") || partial.isEmpty else { return nil }
        return String(partial)
    }
}
