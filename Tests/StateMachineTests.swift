import XCTest
@testable import ClaudeMonitor

final class StateMachineTests: XCTestCase {
    func test_sessionStartCreatesWaiting() {
        XCTAssertEqual(StateMachine.transition(from: nil, for: .sessionStart), .waiting)
    }

    func test_userPromptSubmitGoesToWorking() {
        XCTAssertEqual(StateMachine.transition(from: .waiting, for: .userPromptSubmit), .working)
        XCTAssertEqual(StateMachine.transition(from: .needsYou, for: .userPromptSubmit), .working)
    }

    func test_stopGoesToWaiting() {
        XCTAssertEqual(StateMachine.transition(from: .working, for: .stop), .waiting)
    }

    func test_notificationGoesToNeedsYou() {
        XCTAssertEqual(StateMachine.transition(from: .working, for: .notification), .needsYou)
        XCTAssertEqual(StateMachine.transition(from: .waiting, for: .notification), .needsYou)
    }

    func test_sessionEndGoesToFinished() {
        for state in [SessionState.working, .waiting, .needsYou] {
            XCTAssertEqual(StateMachine.transition(from: state, for: .sessionEnd), .finished,
                           "from \(state) on sessionEnd should be finished")
        }
    }

    func test_finishedIsTerminal() {
        for hook in [HookName.userPromptSubmit, .stop, .notification, .sessionEnd] {
            XCTAssertEqual(StateMachine.transition(from: .finished, for: hook), .finished,
                           "finished should not transition on \(hook)")
        }
    }

    func test_unknownSessionWithNonStartEventSynthesizesStartThenApplies() {
        // A UserPromptSubmit from unknown session: create as waiting, then apply -> working.
        XCTAssertEqual(StateMachine.transition(from: nil, for: .userPromptSubmit), .working)
        XCTAssertEqual(StateMachine.transition(from: nil, for: .stop), .waiting)
        XCTAssertEqual(StateMachine.transition(from: nil, for: .notification), .needsYou)
        XCTAssertEqual(StateMachine.transition(from: nil, for: .sessionEnd), .finished)
    }

    func test_backgroundWorkingLabelIsWorking() {
        XCTAssertEqual(SessionState.backgroundWorking.displayLabel, "Working")
    }

    func test_stopWithActiveBackgroundTasksGoesToBackgroundWorking() {
        XCTAssertEqual(
            StateMachine.transition(from: .working, for: .stop, backgroundTasksActive: 2),
            .backgroundWorking)
    }

    func test_stopWithZeroBackgroundTasksGoesToWaiting() {
        XCTAssertEqual(
            StateMachine.transition(from: .working, for: .stop, backgroundTasksActive: 0),
            .waiting)
        XCTAssertEqual(StateMachine.transition(from: .working, for: .stop), .waiting) // default arg
    }

    func test_backgroundWorkingGoesToWorkingOnUserPromptSubmit() {
        XCTAssertEqual(
            StateMachine.transition(from: .backgroundWorking, for: .userPromptSubmit),
            .working)
    }

    func test_backgroundWorkingGoesToFinishedOnSessionEnd() {
        XCTAssertEqual(
            StateMachine.transition(from: .backgroundWorking, for: .sessionEnd),
            .finished)
    }
}
