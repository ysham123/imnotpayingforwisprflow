import Foundation

/// Maps macOS Fn modifier edges to gestures. On some Apple keyboards a bare
/// Fn release also emits a Globe keyDown (179); that companion is not a chord.
public struct FnKeyEventMapper: Sendable {
    public enum EventKind: Sendable { case flagsChanged, keyDown }

    private var gesture: HotkeyGesture
    private var lastFnReleaseAt: TimeInterval?
    private let companionInterval: TimeInterval = 0.05

    public var phase: HotkeyGesture.Phase { gesture.phase }
    public var pendingActionDeadline: TimeInterval? { gesture.pendingActionDeadline }
    public private(set) var interruptionCount: UInt64 = 0

    public mutating func advance(at time: TimeInterval) -> HotkeyGesture.Action? {
        gesture.advance(at: time)
    }

    public mutating func invalidate() {
        lastFnReleaseAt = nil
        gesture.invalidate()
    }

    public init(doubleTapInterval: TimeInterval = 0.5, maximumTapDuration: TimeInterval = 0.4) {
        gesture = HotkeyGesture(doubleTapInterval: doubleTapInterval,
                                maximumTapDuration: maximumTapDuration,
                                rearmInterval: doubleTapInterval)
    }

    public mutating func setPhase(_ phase: HotkeyGesture.Phase, at time: TimeInterval) {
        if phase != gesture.phase { lastFnReleaseAt = nil }
        gesture.setPhase(phase, at: time)
    }

    public mutating func handle(_ kind: EventKind, keyCode: Int64,
                                functionDown: Bool, otherModifiersHeld: Bool,
                                at time: TimeInterval, isPhysical: Bool = true) -> HotkeyGesture.Action? {
        // A previous paste may still be finishing while the user starts another
        // dictation. Its synthetic Cmd-V must not cancel that user's Fn pair.
        if !isPhysical, keyCode != 63, keyCode != 179 { return nil }
        if kind == .keyDown, keyCode == 179, !functionDown, !otherModifiersHeld,
           let releasedAt = lastFnReleaseAt,
           time >= releasedAt, time - releasedAt <= companionInterval {
            lastFnReleaseAt = nil
            return nil
        }

        if kind == .flagsChanged, keyCode == 63 {
            if functionDown {
                lastFnReleaseAt = nil
                gesture.handleFnDown(at: time)
                if otherModifiersHeld { gesture.handleOtherKey() }
                return nil
            }
            lastFnReleaseAt = time
            return gesture.handleFnUp(at: time)
        }

        lastFnReleaseAt = nil
        interruptionCount &+= 1
        gesture.handleOtherKey()
        return nil
    }
}
