import Foundation

/// Recognizes completed Fn taps without depending on macOS event objects.
/// Timestamps must use the same monotonic clock for every call.
public struct HotkeyGesture: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case processing
        /// A result exists but has never been dispatched to an editor.
        case pending
    }

    public enum Action: Equatable, Sendable {
        case start
        case stop
        case placePending
        case resolvePending
    }

    public private(set) var phase: Phase = .idle

    private let doubleTapInterval: TimeInterval
    private let maximumTapDuration: TimeInterval
    private let rearmInterval: TimeInterval
    private var fnDownAt: TimeInterval?
    private var currentTapIsEligible = false
    private var firstTapAt: TimeInterval?
    private var acceptTapsAfter: TimeInterval = -.infinity

    /// A timer may call advance(at:) at this deadline. A second press suspends
    /// placement until it is released, so a slow double tap cannot paste early.
    public var pendingActionDeadline: TimeInterval? {
        guard phase == .pending, fnDownAt == nil, let firstTapAt else { return nil }
        return firstTapAt + doubleTapInterval
    }

    public init(
        doubleTapInterval: TimeInterval = 0.35,
        maximumTapDuration: TimeInterval = 0.22,
        rearmInterval: TimeInterval = 0.35
    ) {
        precondition(doubleTapInterval > 0)
        precondition(maximumTapDuration > 0)
        precondition(rearmInterval >= 0)
        self.doubleTapInterval = doubleTapInterval
        self.maximumTapDuration = maximumTapDuration
        self.rearmInterval = rearmInterval
    }

    @discardableResult
    public mutating func handleFnDown(at time: TimeInterval) -> Action? {
        // Duplicate flagsChanged notifications do not begin another tap.
        guard fnDownAt == nil else { return nil }
        if phase == .pending, let firstTapAt, time > firstTapAt + doubleTapInterval {
            // An overdue timer must never paste while another tap is starting.
            self.firstTapAt = nil
        }
        fnDownAt = time
        currentTapIsEligible = phase != .processing && time >= acceptTapsAfter
        return nil
    }

    @discardableResult
    public mutating func handleFnUp(at time: TimeInterval) -> Action? {
        guard let beganAt = fnDownAt else { return nil }
        let eligible = currentTapIsEligible
        fnDownAt = nil
        currentTapIsEligible = false

        let duration = time - beganAt
        guard eligible, duration >= 0, duration <= maximumTapDuration else {
            firstTapAt = nil
            return nil
        }

        switch phase {
        case .processing:
            return nil
        case .listening:
            // Immediately block further taps, including the second stop tap.
            phase = .processing
            firstTapAt = nil
            acceptTapsAfter = time + rearmInterval
            return .stop
        case .pending:
            if let firstTapAt, beganAt >= firstTapAt,
               beganAt - firstTapAt <= doubleTapInterval {
                self.firstTapAt = nil
                acceptTapsAfter = time + rearmInterval
                return .resolvePending
            }
            firstTapAt = time
            return nil
        case .idle:
            if let firstTapAt,
               time >= firstTapAt,
               time - firstTapAt <= doubleTapInterval {
                phase = .listening
                self.firstTapAt = nil
                return .start
            }
            firstTapAt = time
            return nil
        }
    }

    /// Completes a pending single tap after the double-tap window, exactly once.
    @discardableResult
    public mutating func advance(at time: TimeInterval) -> Action? {
        guard let deadline = pendingActionDeadline, time >= deadline else { return nil }
        firstTapAt = nil
        phase = .processing
        acceptTapsAfter = time + rearmInterval
        return .placePending
    }

    /// Invalidates gestures after pointer activity or a focus change.
    public mutating func invalidate() {
        fnDownAt = nil
        currentTapIsEligible = false
        firstTapAt = nil
    }

    /// Fn used with another key or modifier must remain an ordinary shortcut.
    @discardableResult
    public mutating func handleOtherKey() -> Action? {
        firstTapAt = nil
        currentTapIsEligible = false
        return nil
    }

    /// Syncs external recording state and discards any incomplete gesture.
    @discardableResult
    public mutating func setPhase(_ newPhase: Phase, at time: TimeInterval) -> Action? {
        guard newPhase != phase else { return nil }
        phase = newPhase
        fnDownAt = nil
        currentTapIsEligible = false
        firstTapAt = nil
        if newPhase == .idle {
            // A delayed second stop tap cannot become the first restart tap.
            acceptTapsAfter = max(acceptTapsAfter, time + rearmInterval)
        }
        return nil
    }
}
