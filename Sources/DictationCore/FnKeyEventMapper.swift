import Foundation

/// Maps macOS Fn modifier edges to gestures. On some Apple keyboards a bare
/// Fn release also emits a Globe keyDown (179); that companion is not a chord.
public struct FnKeyEventMapper: Sendable {
    public enum EventKind: Sendable { case flagsChanged, keyDown }

    private var gesture: HotkeyGesture
    private var lastFnReleaseAt: TimeInterval?
    private let companionInterval: TimeInterval = 0.05

    public var phase: HotkeyGesture.Phase { gesture.phase }

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
                                at time: TimeInterval) -> HotkeyGesture.Action? {
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
        gesture.handleOtherKey()
        return nil
    }
}
