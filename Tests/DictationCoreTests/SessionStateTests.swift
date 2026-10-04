import XCTest
@testable import DictationCore

final class SessionStateTests: XCTestCase {
    func testPendingCannotBeOverwrittenAndFailedPlacementKeepsText() throws {
        var state = DictationSessionState(); state.ready()
        let first = try XCTUnwrap(state.begin()); XCTAssertTrue(state.process(first))
        XCTAssertTrue(state.hold("Keep my words", for: first))
        XCTAssertNil(state.begin())
        let placement = try XCTUnwrap(state.beginPlacement())
        state.cancel()
        XCTAssertEqual(state.phase, .pending)
        XCTAssertEqual(state.pendingText, "Keep my words")
        XCTAssertFalse(state.didDispatch("wrong", for: placement))
        state.resolvePending(copied: true)
        XCTAssertEqual(state.lastText, "Keep my words")
        XCTAssertNotNil(state.begin())
    }

    func testNewCaptureStartsBeforeOldDeliveryFinishes() throws {
        var state = DictationSessionState(); state.ready()
        let first = try XCTUnwrap(state.begin()); state.process(first)
        XCTAssertTrue(state.didDispatch("First", for: first))
        let next = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.finishDelivery(first))
        XCTAssertEqual(state.id, next); XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(state.lastText, "First")
        XCTAssertTrue(state.dispatched.isEmpty)
    }

    func testDispatchedTextCannotBecomePendingOrDispatchTwice() throws {
        var state = DictationSessionState(); state.ready()
        let first = try XCTUnwrap(state.begin()); state.process(first)
        XCTAssertTrue(state.didDispatch("Once", for: first))
        XCTAssertFalse(state.didDispatch("Twice", for: first))
        XCTAssertFalse(state.hold("Again", for: first))
        XCTAssertNil(state.pendingText)
    }

    func testCancellationPreservesPreviousBackupAndRejectsLateResults() throws {
        var state = DictationSessionState(); state.ready()
        let first = try XCTUnwrap(state.begin()); state.process(first)
        state.didDispatch("Backup", for: first); _ = state.finishDelivery(first)
        let next = try XCTUnwrap(state.begin()); state.process(next); state.cancel()
        XCTAssertFalse(state.hold("Late", for: next))
        XCTAssertFalse(state.didDispatch("Late", for: next))
        XCTAssertEqual(state.lastText, "Backup")
        XCTAssertEqual(state.phase, .idle)
    }

    func testDiscardNeverCopiesUnsentText() throws {
        var state = DictationSessionState(); state.ready()
        let first = try XCTUnwrap(state.begin()); state.process(first)
        state.hold("Private draft", for: first); state.resolvePending(copied: false)
        XCTAssertNil(state.pendingText); XCTAssertNil(state.lastText)
        XCTAssertNotNil(state.begin())
    }
}
