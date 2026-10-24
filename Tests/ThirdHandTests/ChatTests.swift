import AppKit
import XCTest
@testable import ThirdHand

@MainActor
final class ChatTests: XCTestCase {
    let apps = ["Spotify", "System Settings", "Notes", "Visual Studio Code", "Visual Studio"]

    func testMentionPicksLongestAppNameAndStripsIt() {
        XCTAssertEqual(MentionParser.parse("@Spotify play Skyfall", appNames: apps).app, "Spotify")
        XCTAssertEqual(MentionParser.parse("@Spotify play Skyfall", appNames: apps).prompt, "play Skyfall")
        let multiword = MentionParser.parse("open @visual studio code  and run tests", appNames: apps)
        XCTAssertEqual(multiword.app, "Visual Studio Code")
        XCTAssertEqual(multiword.prompt, "open and run tests")
        XCTAssertEqual(MentionParser.parse("@System Settings turn on dark mode", appNames: apps).app, "System Settings")
    }

    func testMentionRequiresWordBoundaryAndKnownApp() {
        XCTAssertNil(MentionParser.parse("@Spotifyish play", appNames: apps).app)
        XCTAssertNil(MentionParser.parse("email me@notes.com", appNames: apps).app, "Not a mention inside an address")
        let none = MentionParser.parse("  play the next song ", appNames: apps)
        XCTAssertNil(none.app)
        XCTAssertEqual(none.prompt, "play the next song")
    }

    func testPartialMentionForAutocomplete() {
        XCTAssertEqual(MentionParser.partial(in: "@Spo"), "Spo")
        XCTAssertEqual(MentionParser.partial(in: "hey @"), "")
        XCTAssertEqual(MentionParser.partial(in: "@System Se"), "System Se")
        XCTAssertNil(MentionParser.partial(in: "@Spotify "), "A completed mention stops suggesting")
        XCTAssertNil(MentionParser.partial(in: "me@notes"))
        XCTAssertNil(MentionParser.partial(in: "no mention"))
    }

    func testThreadContextListsFinishedTurnsBeforeTheRequest() {
        let store = ThreadStore(url: nil)
        let id = store.newThread()
        let spotify = ChatApp(name: "Spotify", bundleID: "com.spotify.client")
        store.append(ChatMessage(role: .user, text: "@Spotify search Adele", app: spotify), to: id)
        store.append(ChatMessage(role: .task, text: "Searched for Adele.", app: spotify, state: .done), to: id)
        let followUp = ChatMessage(role: .user, text: "play the first song")
        store.append(followUp, to: id)
        let context = store.context(for: id, before: followUp.id)
        XCTAssertEqual(context, ["User in Spotify: @Spotify search Adele → done: Searched for Adele."])
        XCTAssertEqual(store.thread(id)?.lastApp, spotify, "The mentioned app becomes the thread default")
        XCTAssertEqual(store.thread(id)?.title, "@Spotify search Adele")
    }

    func testThreadsPersistAndInterruptedTasksAreMarkedStopped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/threads.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ThreadStore(url: url)
        let id = store.newThread()
        store.append(ChatMessage(role: .user, text: "@Notes new note"), to: id)
        store.append(ChatMessage(role: .task, text: "", state: .running, status: "Typing…"), to: id)
        let reloaded = ThreadStore(url: url)
        let task = try XCTUnwrap(reloaded.thread(id)?.messages.last)
        XCTAssertEqual(task.state, .stopped)
        XCTAssertNil(task.status)
        XCTAssertEqual(reloaded.selection, id)
    }

    func testDeleteAllRemovesEveryThreadAndPersists() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/threads.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ThreadStore(url: url)
        store.newThread()
        store.newThread()
        store.deleteAll()
        XCTAssertTrue(store.threads.isEmpty)
        XCTAssertNil(store.selection)
        XCTAssertTrue(ThreadStore(url: url).threads.isEmpty)
    }

    func testUnreadableThreadsAreKeptAsideInsteadOfOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("threads.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = Data(#"[{"id":"not a uuid"}]"#.utf8)
        try original.write(to: url)
        let store = ThreadStore(url: url)
        XCTAssertTrue(store.threads.isEmpty)
        store.newThread()
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("threads.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(aside[0])), original)
    }

    func testAgentPromptIncludesThreadContext() async throws {
        let planner = ContextPlanner()
        _ = try await CodexAgent(planner: planner, tier: .quick)
            .run(goal: "play the first song", appName: "Spotify", context: ["User in Spotify: search Adele → done: Searched."],
                 layer: EmptyLayer())
        let opening = (((planner.firstInput.first?["content"] as? [[String: Any]])?.first)?["text"] as? String) ?? ""
        XCTAssertTrue(opening.hasPrefix("Earlier in this chat"))
        XCTAssertTrue(opening.contains("search Adele → done: Searched."))
        XCTAssertTrue(opening.contains("Task: play the first song"))
    }
}

@MainActor
final class ScreenGateTests: XCTestCase {
    func testPlanIsOfferedBeforeAnyStepRuns() async throws {
        let layer = GateLayer()
        _ = try await CodexAgent(planner: OnePlan(), tier: .quick).run(goal: "g", appName: "Spotify", layer: layer)
        XCTAssertEqual(layer.events, ["prepare:2", "perform:type", "perform:press"])
    }

    func testDecliningTheScreenSendsNoInput() async {
        let layer = GateLayer()
        layer.decline = true
        do {
            _ = try await CodexAgent(planner: OnePlan(), tier: .quick).run(goal: "g", appName: "Spotify", layer: layer)
            XCTFail("Cancelling at the take-over card stops the task")
        } catch is CancellationError {} catch { XCTFail("Unexpected error \(error)") }
        XCTAssertEqual(layer.events, ["prepare:2"])
    }

    func testOldMessagesWithoutModeStillDecode() throws {
        let json = #"[{"id":"4F0E2C1E-0000-0000-0000-000000000000","title":"t","messages":[{"id":"4F0E2C1E-0000-0000-0000-000000000001","date":0,"role":"task","text":"ok","state":"done"}],"updated":0}]"#
        let threads = try JSONDecoder().decode([ChatThread].self, from: Data(json.utf8))
        XCTAssertNil(threads[0].messages[0].mode)
    }

    func testRemovedAutoModeDecodesAsOnScreen() throws {
        let decoded = try JSONDecoder().decode([ExecutionMode].self, from: Data(#"["auto","background","onScreen"]"#.utf8))
        XCTAssertEqual(decoded, [.onScreen, .background, .onScreen])
    }

    func testBackgroundKeyEvents() {
        let enter = CDPClient.keyEvent("return", modifiers: [])
        XCTAssertEqual(enter?["key"] as? String, "Enter")
        XCTAssertEqual(enter?["windowsVirtualKeyCode"] as? Int, 13)
        XCTAssertEqual(enter?["text"] as? String, "\r")
        let find = CDPClient.keyEvent("f", modifiers: ["command"])
        XCTAssertEqual(find?["code"] as? String, "KeyF")
        XCTAssertEqual(find?["modifiers"] as? Int, 4)
        XCTAssertNil(find?["text"], "Shortcuts don't insert text")
        XCTAssertEqual(CDPClient.keyEvent("a", modifiers: ["shift"])?["text"] as? String, "A")
        XCTAssertNil(CDPClient.keyEvent("f13", modifiers: []))
    }

    func testChromiumAppsSupportBackgroundDebugging() {
        let spotifyInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
        if spotifyInstalled { XCTAssertTrue(ElectronDetector.supportsDebugging(bundleID: "com.spotify.client")) }
        XCTAssertFalse(ElectronDetector.supportsDebugging(bundleID: "com.apple.calculator"))
        XCTAssertEqual(ElectronDetector.debuggingArguments(port: 9333),
                       ["--remote-debugging-port=9333", "--remote-debugging-address=127.0.0.1"], "Loopback only")
        let port = ElectronDetector.freePort()
        XCTAssertNotNil(port)
        XCTAssertGreaterThan(port ?? 0, 1024)
    }
}

@MainActor
private final class OnePlan: Planner {
    func respond(model: String, instructions: String, input: [[String: Any]], tools: [[String: Any]], effort: String) async throws -> CodexResponse {
        let steps: [[String: Any]] = [
            ["action": "type", "target": "Search", "role": "textField", "text": "adele", "key": NSNull(), "direction": NSNull()],
            ["action": "press", "target": NSNull(), "role": NSNull(), "text": NSNull(), "key": "return", "direction": NSNull()]
        ]
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["finishes_task": true, "summary": "Searched.", "steps": steps]), as: UTF8.self)
        return CodexResponse(output: [["type": "function_call", "call_id": "c", "name": "act", "arguments": args]])
    }
}

@MainActor
private final class GateLayer: ActionLayer {
    var events: [String] = []
    var decline = false
    func currentElements() async throws -> [AccessibilityElement] { [] }
    func prepare(for steps: [PlanStep]) async throws {
        events.append("prepare:\(steps.count)")
        if decline { throw CancellationError() }
    }
    func perform(step: PlanStep) async throws -> StepOutcome {
        events.append("perform:\(step.action)")
        return StepOutcome(status: "verified", detail: "", elements: [])
    }
}

@MainActor
private final class ContextPlanner: Planner {
    var firstInput: [[String: Any]] = []
    func respond(model: String, instructions: String, input: [[String: Any]], tools: [[String: Any]], effort: String) async throws -> CodexResponse {
        if firstInput.isEmpty { firstInput = input }
        return CodexResponse(output: [["type": "function_call", "call_id": "c", "name": "done", "arguments": #"{"summary":"ok"}"#]])
    }
}

@MainActor
private final class EmptyLayer: ActionLayer {
    func currentElements() async throws -> [AccessibilityElement] { [] }
    func perform(step: PlanStep) async throws -> StepOutcome { StepOutcome(status: "verified", detail: "", elements: []) }
}

@MainActor
final class UltrafastTests: XCTestCase {
    func el(_ id: Int, _ role: String, _ label: String) -> AccessibilityElement {
        AccessibilityElement(id: id, role: role, label: label, value: nil, enabled: true, actions: [], axElement: nil)
    }

    func testOneRequestAsksDoneOperationAndBothTargets() throws {
        let prepared = try JevClient.nextActionRequest(task: "play Skyfall by Adele",
            elements: [el(1, "AXButton", "Play"), el(2, "AXTextField", "Search"), el(3, "AXStaticText", "Now playing: Hello")],
            appName: "Spotify", history: [])
        let body = try JSONSerialization.jsonObject(with: prepared.data) as! [String: Any]
        let questions = body["questions"] as! [String: [String: Any]]
        XCTAssertEqual(Set(questions.keys), ["done", "operation", "click_target", "type_text_target"])
        let operations = questions["operation"]!["criteria"] as! [String: String]
        XCTAssertNotNil(operations["TYPE_TEXT"])
        XCTAssertNotNil(operations["BLOCKED"])
        XCTAssertEqual(Set(prepared.offered["TYPE_TEXT"]!.keys), ["2"], "Only editable fields can be typed into")
        XCTAssertTrue(((body["state"] as! [String: Any])["screen"] as! String).contains("Now playing: Hello"))
    }

    func testOperationsWithoutCompatibleTargetsAreNotOffered() throws {
        let prepared = try JevClient.nextActionRequest(task: "t", elements: [el(1, "AXButton", "Play")], appName: "App", history: [])
        let body = try JSONSerialization.jsonObject(with: prepared.data) as! [String: Any]
        let questions = body["questions"] as! [String: [String: Any]]
        XCTAssertNil(questions["type_text_target"])
        XCTAssertNil((questions["operation"]!["criteria"] as! [String: String])["TYPE_TEXT"])
    }

    func testDecodingUsesOnlyTheChosenOperationsTarget() throws {
        let offered = ["CLICK": ["1": el(1, "AXButton", "Play")], "TYPE_TEXT": ["2": el(2, "AXTextField", "Search")]]
        let type = try JevClient.decodeNextAction(Data(#"{"answers":{"done":{"noul":0.1},"operation":{"choice":"TYPE_TEXT"},"click_target":{"choice":"1"},"type_text_target":{"choice":"2"}}}"#.utf8), offered: offered)
        XCTAssertEqual(type.operation, "TYPE_TEXT")
        XCTAssertEqual(type.target?.id, 2)
        let none = try JevClient.decodeNextAction(Data(#"{"answers":{"operation":{"choice":"CLICK"},"click_target":{"choice":"__none__"}}}"#.utf8), offered: offered)
        XCTAssertEqual(none.operation, "BLOCKED")
        let wait = try JevClient.decodeNextAction(Data(#"{"answers":{"done":{"noul":0.9},"operation":{"choice":"WAIT"}}}"#.utf8), offered: offered)
        XCTAssertGreaterThanOrEqual(wait.done, JevClient.doneThreshold)
        XCTAssertNil(wait.target)
        XCTAssertThrowsError(try JevClient.decodeNextAction(Data("{}".utf8), offered: offered))
    }

    func testReturnIsNotOfferedTwiceInARowAndFilledFieldsAreSkipped() throws {
        let field = el(2, "AXTextField", "Search")
        let prepared = try JevClient.nextActionRequest(task: "t", elements: [el(1, "AXButton", "Play"), field], appName: "App",
                                                       history: [], lastOperation: "PRESS_RETURN",
                                                       filledFields: [JevClient.fieldKey(field)])
        let body = try JSONSerialization.jsonObject(with: prepared.data) as! [String: Any]
        let questions = body["questions"] as! [String: [String: Any]]
        XCTAssertNil((questions["operation"]!["criteria"] as! [String: String])["PRESS_RETURN"])
        XCTAssertNil(questions["type_text_target"], "A field that already got its text isn't offered")
        XCTAssertTrue((questions["operation"]!["instructions"] as! String).contains("Submit a populated search field"))
    }

    func testLikelyFieldForTextPrefetch() {
        var focused = el(3, "AXTextField", "Name"); focused.focused = true
        XCTAssertEqual(TaskRunner.likelyField(in: [el(1, "AXTextField", "Email"), focused])?.id, 3)
        XCTAssertEqual(TaskRunner.likelyField(in: [el(1, "AXTextField", "Email"), el(2, "AXComboBox", "What do you want to play?")])?.id, 2)
        XCTAssertNil(TaskRunner.likelyField(in: [el(1, "AXTextField", "Email"), el(2, "AXTextField", "Name")]), "Ambiguous: no prefetch")
    }

    func testPlannerHasNoGoalSteps() {
        XCTAssertFalse(PlanStep.actions.contains("goal"))
        XCTAssertThrowsError(try PlanStep.parse(["action": "goal", "text": "x"]).get())
    }

    func testBenchmarkSummary() {
        let rows: [[String: Any]] = [
            ["state": "done", "total_ms": 8000, "codex_calls": 1, "jev_calls": 3, "actions": 4],
            ["state": "failed", "total_ms": 20000, "codex_calls": 4, "jev_calls": 1, "actions": 6]
        ]
        let summary = Benchmark.summarize(rows, variant: "ultrafast")
        XCTAssertTrue(summary.hasPrefix("Benchmark (ultrafast): 1/2 done · median 14.0s · codex 2.5 calls"))
        XCTAssertNotNil(try? JSONEncoder().encode(Benchmark.sample))
    }
}
