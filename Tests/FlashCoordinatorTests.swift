import XCTest
@testable import ClaudeMonitor

final class FlashCoordinatorTests: XCTestCase {
    private func session(_ id: String, _ state: SessionState) -> Session {
        Session(id: id, cwd: "/p/\(id)", tty: "/dev/ttys001", pid: 1,
                state: state, enteredStateAt: Date(timeIntervalSince1970: 0), lastPromptPreview: nil)
    }

    func test_transitionIntoWaitingProducesFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .working)])
        let flashes = c.update(sessions: [session("a", .waiting)])
        XCTAssertNotNil(flashes["a"])
    }

    func test_transitionIntoNeedsYouProducesFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .working)])
        let flashes = c.update(sessions: [session("a", .needsYou)])
        XCTAssertNotNil(flashes["a"])
    }

    func test_resolvingFromNeedsYouToWorkingProducesFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .needsYou)])
        let flashes = c.update(sessions: [session("a", .working)])
        XCTAssertNotNil(flashes["a"])
    }

    func test_sessionStartDoesNotFlash() {
        var c = FlashCoordinator()
        let flashes = c.update(sessions: [session("a", .waiting)])  // new session in waiting
        XCTAssertNil(flashes["a"])
    }

    func test_transitionIntoFinishedDoesNotFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .working)])
        let flashes = c.update(sessions: [session("a", .finished)])
        XCTAssertNil(flashes["a"])
    }

    func test_sameStateNoFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .waiting)])
        let flashes = c.update(sessions: [session("a", .waiting)])
        XCTAssertNil(flashes["a"])
    }

    func test_flashIdsAccumulateAcrossUpdates() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .working), session("b", .working)])
        let step2 = c.update(sessions: [session("a", .waiting), session("b", .working)])
        XCTAssertNotNil(step2["a"])
        let step3 = c.update(sessions: [session("a", .waiting), session("b", .needsYou)])
        XCTAssertEqual(step3["a"], step2["a"], "unchanged session keeps its last flash id")
        XCTAssertNotNil(step3["b"])
    }
}
