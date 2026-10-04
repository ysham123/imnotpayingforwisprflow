import Foundation

/// Carbon is the only action source for a registered custom shortcut. A held
/// chord fires once on release, and cannot rearm through a phase transition.
public struct CustomHotkeyGesture: Sendable {
    public private(set) var phase: HotkeyGesture.Phase = .idle
    private var isDown = false
    private var eligible = false
    private var acceptAfter: TimeInterval = -.infinity
    private let rearmInterval: TimeInterval

    public init(rearmInterval: TimeInterval = 0.35) {
        precondition(rearmInterval >= 0)
        self.rearmInterval = rearmInterval
    }

    public mutating func press(at time: TimeInterval) {
        guard !isDown else { return }
        isDown = true
        eligible = phase != .processing && time >= acceptAfter
    }

    public mutating func release(at time: TimeInterval) -> HotkeyGesture.Action? {
        guard isDown else { return nil }
        isDown = false
        defer { eligible = false }
        guard eligible else { return nil }
        acceptAfter = time + rearmInterval
        switch phase {
        case .idle: phase = .listening; return .start
        case .listening: phase = .processing; return .stop
        case .pending: phase = .processing; return .placePending
        case .processing: return nil
        }
    }

    public mutating func setPhase(_ phase: HotkeyGesture.Phase, at time: TimeInterval) {
        guard phase != self.phase else { return }
        self.phase = phase
        eligible = false
        if phase == .idle { acceptAfter = max(acceptAfter, time + rearmInterval) }
    }

    public mutating func invalidate() { eligible = false }

    /// Settings may register while the captured key is still held. That whole
    /// physical press belongs to the recorder, including any late repeats.
    public mutating func suppressUntilRelease() { isDown = true; eligible = false }
}

/// Separates the shortcut's physical modifier/key edges from changes that
/// could invalidate an editor target. It never produces dictation actions.
public struct CustomHotkeyInputFilter: Sendable {
    public enum EventKind { case keyDown, keyUp, flagsChanged, pointer }
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var ownKeyDown = false

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// True means physical activity unrelated to the assigned shortcut.
    public mutating func interrupts(_ kind: EventKind, keyCode code: UInt32,
                                    modifiers flags: UInt32, isPhysical: Bool) -> Bool {
        guard isPhysical else { return false }
        switch kind {
        case .pointer: return true
        case .keyDown:
            if code == keyCode && flags == modifiers { ownKeyDown = true; return false }
            // Repeats after the shortcut's modifiers are released may become
            // ordinary typing. Treat them as input rather than hiding a change.
            return true
        case .keyUp:
            if code == keyCode && ownKeyDown { ownKeyDown = false; return false }
            // The matching down event already invalidated the destination.
            return false
        case .flagsChanged:
            let modifier: UInt32
            switch code {
            case 54, 55: modifier = ShortcutConfiguration.command
            case 56, 60: modifier = ShortcutConfiguration.shift
            case 58, 61: modifier = ShortcutConfiguration.option
            case 59, 62: modifier = ShortcutConfiguration.control
            case 63 where ShortcutConfiguration.functionKeyCodes.contains(keyCode): return false
            default: return true
            }
            return modifiers & modifier == 0
        }
    }
}
