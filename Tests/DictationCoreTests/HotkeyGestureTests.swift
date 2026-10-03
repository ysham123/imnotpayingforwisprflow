import XCTest
@testable import DictationCore

final class HotkeyGestureTests: XCTestCase {
    private func tap(_ gesture: inout HotkeyGesture, at time: TimeInterval,
                     duration: TimeInterval = 0.05) -> HotkeyGesture.Action? {
        XCTAssertNil(gesture.handleFnDown(at: time))
        return gesture.handleFnUp(at: time + duration)
    }

    func testDoubleCompletedTapStartsAndSingleTapStops() {
        var gesture = HotkeyGesture()
        XCTAssertNil(tap(&gesture, at: 1.0))
        XCTAssertEqual(tap(&gesture, at: 1.2), .start)
        XCTAssertEqual(gesture.phase, .listening)
        XCTAssertEqual(tap(&gesture, at: 2.0), .stop)
        XCTAssertEqual(gesture.phase, .processing)
    }

    func testDoubleStopEmitsOnlyOneStopAndCannotImmediatelyRestart() {
        var gesture = HotkeyGesture()
        gesture.setPhase(.listening, at: 0)
        XCTAssertEqual(tap(&gesture, at: 1), .stop)
        gesture.setPhase(.idle, at: 1.08)
        XCTAssertNil(tap(&gesture, at: 1.2))
        XCTAssertNil(tap(&gesture, at: 1.5))
        XCTAssertEqual(tap(&gesture, at: 1.7), .start)
    }

    func testExpiredFirstTapDoesNotStart() {
        var gesture = HotkeyGesture()
        XCTAssertNil(tap(&gesture, at: 1))
        XCTAssertNil(tap(&gesture, at: 1.5))
        XCTAssertEqual(tap(&gesture, at: 1.7), .start)
    }

    func testHoldingFnDoesNotStartOrStop() {
        var gesture = HotkeyGesture()
        XCTAssertNil(tap(&gesture, at: 1))
        XCTAssertNil(tap(&gesture, at: 1.2, duration: 0.5))
        XCTAssertNil(tap(&gesture, at: 2))
        gesture.setPhase(.listening, at: 3)
        XCTAssertNil(tap(&gesture, at: 4, duration: 0.5))
        XCTAssertEqual(gesture.phase, .listening)
    }

    func testOtherKeyInvalidatesChordAndPendingDoubleTap() {
        var gesture = HotkeyGesture()
        XCTAssertNil(tap(&gesture, at: 1))
        gesture.handleOtherKey()
        XCTAssertNil(tap(&gesture, at: 1.2))
        gesture.handleFnDown(at: 1.4)
        gesture.handleOtherKey()
        XCTAssertNil(gesture.handleFnUp(at: 1.45))
        XCTAssertNil(tap(&gesture, at: 1.6))
        XCTAssertEqual(tap(&gesture, at: 1.8), .start)
    }

    func testFnCombinationDoesNotStopListening() {
        var gesture = HotkeyGesture()
        gesture.setPhase(.listening, at: 0)
        gesture.handleFnDown(at: 1)
        gesture.handleOtherKey()
        XCTAssertNil(gesture.handleFnUp(at: 1.05))
        XCTAssertEqual(gesture.phase, .listening)
        XCTAssertEqual(tap(&gesture, at: 2), .stop)
    }

    func testDuplicateDownAndUnmatchedUpDoNotBecomeExtraTaps() {
        var gesture = HotkeyGesture()
        XCTAssertNil(gesture.handleFnUp(at: 0))
        gesture.handleFnDown(at: 1)
        gesture.handleFnDown(at: 1.04)
        XCTAssertNil(gesture.handleFnUp(at: 1.05))
        XCTAssertNil(gesture.handleFnUp(at: 1.06))
        XCTAssertEqual(tap(&gesture, at: 1.2), .start)
    }

    func testProcessingIgnoresAllTaps() {
        var gesture = HotkeyGesture()
        gesture.setPhase(.processing, at: 0)
        XCTAssertNil(tap(&gesture, at: 1))
        XCTAssertNil(tap(&gesture, at: 1.2))
        XCTAssertEqual(gesture.phase, .processing)
    }

    func testStateChangeDiscardsIncompleteTap() {
        var gesture = HotkeyGesture()
        gesture.handleFnDown(at: 1)
        gesture.setPhase(.processing, at: 1.01)
        gesture.setPhase(.idle, at: 1.02)
        XCTAssertNil(gesture.handleFnUp(at: 1.05))
        XCTAssertNil(tap(&gesture, at: 1.5))
        XCTAssertEqual(tap(&gesture, at: 1.7), .start)
    }

    func testRepeatingCurrentPhaseDoesNotDiscardAValidTap() {
        var gesture = HotkeyGesture()
        gesture.setPhase(.listening, at: 0)
        gesture.handleFnDown(at: 1)
        gesture.setPhase(.listening, at: 1.01)
        XCTAssertEqual(gesture.handleFnUp(at: 1.05), .stop)
    }

    func testBackwardsTimestampCannotCompleteTap() {
        var gesture = HotkeyGesture()
        gesture.handleFnDown(at: 1)
        XCTAssertNil(gesture.handleFnUp(at: 0.9))
        XCTAssertNil(tap(&gesture, at: 2))
    }
}
