import XCTest
import ApplicationServices
@testable import ThirdHand

@MainActor
final class ControllerTests: XCTestCase {
    func testTerminalTextWithLineBreaksIsDetected() {
        XCTAssertTrue(TaskRunner.submitsLines("cd foo\nrm -rf build"))
        XCTAssertTrue(TaskRunner.submitsLines("ls\r"))
        XCTAssertTrue(TaskRunner.submitsLines("ls\u{2028}pwd"))
        XCTAssertFalse(TaskRunner.submitsLines("git status --short"))
        XCTAssertFalse(TaskRunner.submitsLines(nil))
    }

    private func element(enabled: Bool = true) -> AccessibilityElement {
        AccessibilityElement(id: 1, role: "AXTextField", label: "Search", value: "", enabled: enabled,
                             actions: [], axElement: AXUIElementCreateSystemWide())
    }

    func testUnicodeTypingEventsHaveNoShortcutModifiers() throws {
        for character: Character in ["a", "é", "🎵"] {
            let (down, up) = try InputController.textEvents(for: character)
            XCTAssertEqual(down.flags, [])
            XCTAssertEqual(up.flags, [])
            var buffer = [UniChar](repeating: 0, count: 8)
            var count = 0
            down.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &count, unicodeString: &buffer)
            XCTAssertEqual(String(utf16CodeUnits: buffer, count: count), String(character))
        }
    }

    func testWindowSelectionIgnoresFrontmostTemporaryWindow() {
        let main = CGRect(x: -1200, y: 25, width: 1200, height: 800)
        let popup = CGRect(x: -700, y: 80, width: 200, height: 30)
        let selected = WindowSnapshot.selectWindow([(2, popup), (1, main)], focusedFrame: main)
        XCTAssertEqual(selected?.id, 1)
        XCTAssertEqual(selected?.frame, main)
    }

    func testWindowSelectionRejectsUnrelatedWindowWhenFocusedWindowIsUnavailable() {
        let other = CGRect(x: 0, y: 0, width: 200, height: 100)
        let focused = CGRect(x: 500, y: 100, width: 1200, height: 800)
        XCTAssertNil(WindowSnapshot.selectWindow([(2, other)], focusedFrame: focused))
        XCTAssertEqual(WindowSnapshot.selectWindow([(2, other)], focusedFrame: nil)?.id, 2)
    }

    func testRejectsMissingTextAndInvalidTargets() {
        XCTAssertThrowsError(try AgentDecision(operation: "TYPE_TEXT", targetIndex: "1").validate(elements: [element()], hasScreenshot: false))
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", targetIndex: "2").validate(elements: [element()], hasScreenshot: false))
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", targetIndex: "1").validate(elements: [element(enabled: false)], hasScreenshot: false))
    }

    func testTextCannotTargetNonEditableControls() {
        let button = AccessibilityElement(id: 1, role: "AXButton", label: "Play", value: nil,
            enabled: true, actions: [], axElement: AXUIElementCreateSystemWide())
        XCTAssertThrowsError(try AgentDecision(operation: "TYPE_TEXT", targetIndex: "1", textValue: "hello")
            .validate(elements: [button], hasScreenshot: false))
    }

    func testVisualActionsRequireImageAndBoundedCoordinates() throws {
        let decision = AgentDecision(operation: "CLICK", x: 0.2, y: 0.8)
        try decision.validate(elements: [], hasScreenshot: true)
        XCTAssertThrowsError(try decision.validate(elements: [], hasScreenshot: false))
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", x: 1.1, y: 0.8).validate(elements: [], hasScreenshot: true))
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", x: 0.5).validate(elements: [], hasScreenshot: true))
    }

    func testShortcutValidation() throws {
        try AgentDecision(operation: "KEY_PRESS", key: "f3").validate(elements: [], hasScreenshot: false)
        XCTAssertThrowsError(try AgentDecision(operation: "KEY_PRESS", key: "shell").validate(elements: [], hasScreenshot: false))
        XCTAssertThrowsError(try AgentDecision(operation: "KEY_PRESS", key: "a", modifiers: ["invalid"]).validate(elements: [], hasScreenshot: false))
    }

    func testOCRLabelsCannotBecomeClickTargetsWithoutVisualGrounding() {
        let label = AccessibilityElement(id: 1, role: "AXStaticText", label: "Search", value: nil, enabled: true, actions: [], axElement: nil)
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", targetIndex: "1").validate(elements: [label], hasScreenshot: false))
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", targetIndex: "1", x: 0.5, y: 0.5).validate(elements: [label], hasScreenshot: true))
    }

    func testCoordinatesOnDisplayLeftOfPrimary() {
        let snapshot = WindowSnapshot(windowID: 1, frame: CGRect(x: -1920, y: 100, width: 1000, height: 800), image: nil)
        XCTAssertEqual(snapshot.point(x: 0, y: 0), CGPoint(x: -1920, y: 100))
        XCTAssertEqual(snapshot.point(x: 1, y: 1), CGPoint(x: -921, y: 899))
        XCTAssertTrue(snapshot.frame.contains(snapshot.point(x: 1, y: 1)))
    }

    func testOCRTextUsesExplicitClickTextRatherThanPretendingToBeAButton() throws {
        let text = AccessibilityElement(id: 10, role: "AXStaticText", label: "Save", value: nil,
            enabled: true, actions: [], axElement: nil, frame: CGRect(x: 20, y: 20, width: 40, height: 20), source: "ocr")
        XCTAssertNil(JevClient.targets([text])["CLICK"])
        XCTAssertNil(JevClient.targets([text])["TYPE_TEXT"])
        XCTAssertNotNil(JevClient.targets([text])["CLICK_TEXT"]?["10"])
        try AgentDecision(operation: "CLICK_TEXT", targetIndex: "10").validate(elements: [text], hasScreenshot: false)
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK_TEXT", targetIndex: "1").validate(elements: [element()], hasScreenshot: false))
    }
}
