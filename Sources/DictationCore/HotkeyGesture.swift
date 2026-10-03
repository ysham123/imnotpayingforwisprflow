import Foundation

/// Recognizes completed Fn taps without depending on macOS event objects.
/// Timestamps must use the same monotonic clock for every call.
public struct HotkeyGesture: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case processing
    }

    public enum Action: Equatable, Sendable {
        case start
        case stop
    }

    public private(set) var phase: Phase = .idle

    private let doubleTapInterval: TimeInterval
    private let maximumTapDuration: TimeInterval
    private let rearmInterval: TimeInterval
    private var fnDownAt: TimeInterval?
    private var currentTapIsEligible = false
    private var firstTapAt: TimeInterval?
    private var acceptTapsAfter: TimeInterval = -.infinity

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
