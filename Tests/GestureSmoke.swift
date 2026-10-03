import DictationCore
import Foundation

/// Runs with the standalone macOS Command Line Tools, without XCTest.
@main
enum GestureSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String,
                               line: UInt = #line) throws {
        if try !condition() { throw Failure(description: "line \(line): \(message)") }
    }

    private static func tap(_ gesture: inout HotkeyGesture, at time: TimeInterval,
                            duration: TimeInterval = 0.05) throws -> HotkeyGesture.Action? {
        try expect(gesture.handleFnDown(at: time) == nil, "Press alone emitted an action")
        return gesture.handleFnUp(at: time + duration)
    }

    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("double-tap starts and single-tap stops", startAndStop),
            ("double-tap stop emits once", doubleStop),
            ("late stop tap cannot restart", rearmGuard),
            ("double-tap uses completed tap timing", completedTapTiming),
            ("holds do not start or stop", heldKey),
            ("other keys invalidate pending start", interleavedKey),
            ("Fn combinations do not stop", combinationWhileListening),
            ("repeat notifications are not taps", repeatsAndUnmatchedRelease),
            ("processing ignores gestures", processingLock),
            ("phase change discards partial tap", externalPhaseChange),
            ("same phase preserves current tap", unchangedPhase),
            ("backward timestamps reject taps", backwardTimestamp),
            ("third tap stops without another start", tripleTap),
            ("recorded Fn and Globe sequence starts and stops", recordedGlobeSequence),
            ("real key between Fn taps still cancels", mappedOtherKey),
            ("unpaired or late Globe events still cancel", unpairedGlobe),
            ("Globe with modifiers remains a chord", modifiedGlobe),
            ("duplicate Globe events cannot hide a chord", duplicateGlobe),
            ("ordinary tap duration works but a hold does not", mappedTapDuration)
        ]
        do {
            for (name, body) in cases {
                try body()
                print("PASS: \(name)")
            }
            print("All \(cases.count) shortcut cases passed.")
        } catch {
            fputs("Shortcut smoke checks failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func startAndStop() throws {
        var gesture = HotkeyGesture()
        try expect(try tap(&gesture, at: 1) == nil, "One idle tap started recording")
        try expect(try tap(&gesture, at: 1.2) == .start, "Double tap did not start")
        try expect(gesture.phase == .listening, "Start did not lock listening state")
        try expect(try tap(&gesture, at: 2) == .stop, "One listening tap did not stop")
        try expect(gesture.phase == .processing, "Stop did not lock processing state")
    }

    private static func doubleStop() throws {
        var gesture = HotkeyGesture()
        gesture.setPhase(.listening, at: 0)
        try expect(try tap(&gesture, at: 1) == .stop, "First stop tap failed")
        try expect(try tap(&gesture, at: 1.2) == nil, "Second stop tap emitted an action")
        try expect(gesture.phase == .processing, "Second stop tap rearmed recording")
    }

    private static func rearmGuard() throws {
        var gesture = HotkeyGesture()
        gesture.setPhase(.listening, at: 0)
        try expect(try tap(&gesture, at: 1) == .stop, "Stop failed")
        gesture.setPhase(.idle, at: 1.08)
        try expect(try tap(&gesture, at: 1.2) == nil, "Delayed stop tap was not ignored")
        try expect(try tap(&gesture, at: 1.5) == nil, "Delayed stop tap counted toward restart")
        try expect(try tap(&gesture, at: 1.7) == .start, "Fresh double tap failed after rearm")
    }

    private static func completedTapTiming() throws {
        var gesture = HotkeyGesture()
        try expect(try tap(&gesture, at: 1) == nil, "First tap started recording")
        try expect(try tap(&gesture, at: 1.38) == nil, "Expired completed-tap interval started recording")
        try expect(try tap(&gesture, at: 1.55) == .start, "Recent completed tap did not start")
    }

    private static func heldKey() throws {
        var gesture = HotkeyGesture()
        try expect(try tap(&gesture, at: 1) == nil, "First tap started recording")
        try expect(try tap(&gesture, at: 1.2, duration: 0.5) == nil, "Hold completed a double tap")
        try expect(try tap(&gesture, at: 2) == nil, "Hold left a pending start tap")
        gesture.setPhase(.listening, at: 3)
        try expect(try tap(&gesture, at: 4, duration: 0.5) == nil, "Hold stopped recording")
        try expect(gesture.phase == .listening, "Hold changed listening state")
    }

    private static func interleavedKey() throws {
        var gesture = HotkeyGesture()
        try expect(try tap(&gesture, at: 1) == nil, "First tap started recording")
        gesture.handleOtherKey()
        try expect(try tap(&gesture, at: 1.2) == nil, "Interleaved key did not clear first tap")
        gesture.handleFnDown(at: 1.4)
        gesture.handleOtherKey()
        try expect(gesture.handleFnUp(at: 1.45) == nil, "Fn combination completed a start")
        try expect(try tap(&gesture, at: 1.6) == nil, "Combination left a pending tap")
        try expect(try tap(&gesture, at: 1.8) == .start, "Fresh double tap failed")
    }

    private static func combinationWhileListening() throws {
        var gesture = HotkeyGesture()
        gesture.setPhase(.listening, at: 0)
        gesture.handleFnDown(at: 1)
        gesture.handleOtherKey()
        try expect(gesture.handleFnUp(at: 1.05) == nil, "Fn combination stopped recording")
        try expect(gesture.phase == .listening, "Fn combination changed phase")
        try expect(try tap(&gesture, at: 2) == .stop, "Clean stop tap failed after combination")
    }

    private static func repeatsAndUnmatchedRelease() throws {
        var gesture = HotkeyGesture()
        try expect(gesture.handleFnUp(at: 0) == nil, "Unmatched release became a tap")
        gesture.handleFnDown(at: 1)
        gesture.handleFnDown(at: 1.04)
        try expect(gesture.handleFnUp(at: 1.05) == nil, "Repeated down counted twice")
        try expect(gesture.handleFnUp(at: 1.06) == nil, "Repeated release counted twice")
        try expect(try tap(&gesture, at: 1.2) == .start, "Valid second tap failed")
    }

    private static func processingLock() throws {
        var gesture = HotkeyGesture()
        gesture.setPhase(.processing, at: 0)
        try expect(try tap(&gesture, at: 1) == nil, "Processing accepted a tap")
        try expect(try tap(&gesture, at: 1.2) == nil, "Processing accepted a double tap")
        try expect(gesture.phase == .processing, "Gesture escaped processing lock")
    }

    private static func externalPhaseChange() throws {
        var gesture = HotkeyGesture()
        gesture.handleFnDown(at: 1)
        gesture.setPhase(.processing, at: 1.01)
        gesture.setPhase(.idle, at: 1.02)
        try expect(gesture.handleFnUp(at: 1.05) == nil, "State change retained incomplete tap")
        try expect(try tap(&gesture, at: 1.5) == nil, "Incomplete tap counted toward restart")
        try expect(try tap(&gesture, at: 1.7) == .start, "Fresh double tap failed after state change")
    }

    private static func unchangedPhase() throws {
        var gesture = HotkeyGesture()
        gesture.setPhase(.listening, at: 0)
        gesture.handleFnDown(at: 1)
        gesture.setPhase(.listening, at: 1.01)
        try expect(gesture.handleFnUp(at: 1.05) == .stop, "Same-phase sync discarded stop tap")
    }

    private static func backwardTimestamp() throws {
        var gesture = HotkeyGesture()
        gesture.handleFnDown(at: 1)
        try expect(gesture.handleFnUp(at: 0.9) == nil, "Backward timestamp completed a tap")
        try expect(try tap(&gesture, at: 2) == nil, "Invalid timestamp left a pending tap")
    }

    private static func tripleTap() throws {
        var gesture = HotkeyGesture()
        try expect(try tap(&gesture, at: 1) == nil, "First tap started")
        try expect(try tap(&gesture, at: 1.2) == .start, "Second tap did not start")
        try expect(try tap(&gesture, at: 1.4) == .stop, "Third tap did not stop")
        try expect(try tap(&gesture, at: 1.6) == nil, "Extra tap restarted recording")
    }

    private static func mappedTap(_ mapper: inout FnKeyEventMapper, at time: TimeInterval,
                                  duration: TimeInterval = 0.1) -> HotkeyGesture.Action? {
        _ = mapper.handle(.flagsChanged, keyCode: 63, functionDown: true,
                          otherModifiersHeld: false, at: time)
        return mapper.handle(.flagsChanged, keyCode: 63, functionDown: false,
                             otherModifiersHeld: false, at: time + duration)
    }

    private static func globe(_ mapper: inout FnKeyEventMapper, at time: TimeInterval,
                              modifiers: Bool = false) {
        _ = mapper.handle(.keyDown, keyCode: 179, functionDown: false,
                          otherModifiersHeld: modifiers, at: time)
    }

    private static func recordedGlobeSequence() throws {
        var mapper = FnKeyEventMapper()
        try expect(mappedTap(&mapper, at: 32.893, duration: 0.121) == nil, "First Fn tap started")
        globe(&mapper, at: 33.014)
        try expect(mappedTap(&mapper, at: 33.080, duration: 0.137) == .start,
                   "macOS Globe companion canceled recorded double-tap")
        globe(&mapper, at: 33.217)
        try expect(mapper.phase == .listening, "Companion changed listening state")
        try expect(mappedTap(&mapper, at: 34) == .stop, "Next Fn tap did not stop")
        globe(&mapper, at: 34.101)
        try expect(mapper.phase == .processing, "Stop companion changed processing state")
    }

    private static func mappedOtherKey() throws {
        var mapper = FnKeyEventMapper()
        _ = mappedTap(&mapper, at: 1)
        globe(&mapper, at: 1.101)
        _ = mapper.handle(.keyDown, keyCode: 0, functionDown: false,
                          otherModifiersHeld: false, at: 1.15)
        try expect(mappedTap(&mapper, at: 1.2) == nil, "Real key between taps was ignored")
    }

    private static func unpairedGlobe() throws {
        var mapper = FnKeyEventMapper()
        globe(&mapper, at: 0.5)
        try expect(mappedTap(&mapper, at: 1) == nil, "Unpaired Globe counted as first tap")
        globe(&mapper, at: 1.16)
        try expect(mappedTap(&mapper, at: 1.2) == nil, "Late Globe was incorrectly filtered")
    }

    private static func modifiedGlobe() throws {
        var mapper = FnKeyEventMapper()
        _ = mappedTap(&mapper, at: 1)
        globe(&mapper, at: 1.101, modifiers: true)
        try expect(mappedTap(&mapper, at: 1.2) == nil, "Modified Globe was incorrectly filtered")
    }

    private static func duplicateGlobe() throws {
        var mapper = FnKeyEventMapper()
        _ = mappedTap(&mapper, at: 1)
        globe(&mapper, at: 1.101)
        globe(&mapper, at: 1.102)
        try expect(mappedTap(&mapper, at: 1.2) == nil, "Two Globe events were filtered for one release")
    }

    private static func mappedTapDuration() throws {
        var mapper = FnKeyEventMapper()
        _ = mappedTap(&mapper, at: 1, duration: 0.3)
        globe(&mapper, at: 1.301)
        try expect(mappedTap(&mapper, at: 1.45, duration: 0.3) == .start,
                   "Normal 300 ms taps failed")
        globe(&mapper, at: 1.751)
        try expect(mappedTap(&mapper, at: 2, duration: 0.6) == nil, "Long hold stopped recording")
        try expect(mappedTap(&mapper, at: 3, duration: 0.2) == .stop, "Tap did not stop after hold")
    }
}
