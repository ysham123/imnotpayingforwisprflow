import Foundation

public enum SetupStep: Int, CaseIterable, Sendable {
    case welcome, microphone, accessibility, inputMonitoring, models, shortcut, practice, complete
    public var permission: String? {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        default: return nil
        }
    }
}

/// Readiness comes from production probes. A button click is never a grant.
public struct SetupReadiness: Sendable {
    public var microphone = false
    public var accessibility = false
    public var inputMonitoring = false
    public var modelsReady = false
    public var listenerActive = false
    public var shortcut: ShortcutConfiguration = .fn
    public init() {}
    public func granted(_ step: SetupStep) -> Bool {
        switch step {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        default: return false
        }
    }
    public var firstMissingPermission: SetupStep? {
        [.microphone, .accessibility, .inputMonitoring].first { !granted($0) }
    }
    public var ready: Bool { firstMissingPermission == nil && modelsReady && listenerActive }
}

/// Keeps permission confirmation, shortcut detection, and a real recognition
/// result separate. Nothing stores a practice transcript or audio on disk.
public struct SetupFlow: Sendable {
    public private(set) var step: SetupStep = .welcome
    public private(set) var verifiedShortcut: ShortcutConfiguration?
    public private(set) var practiceToken: UUID?
    public private(set) var practiceSucceeded = false
    public init() {}

    public mutating func reconcile(_ readiness: SetupReadiness) {
        if verifiedShortcut != readiness.shortcut || !readiness.listenerActive {
            if verifiedShortcut != nil { practiceSucceeded = false }
            verifiedShortcut = nil
            if step == .practice || step == .complete, practiceToken == nil { step = .shortcut }
        }
        if step != .welcome, let missing = readiness.firstMissingPermission,
           missing.rawValue < step.rawValue {
            step = missing; practiceToken = nil; practiceSucceeded = false
        } else if step.rawValue >= SetupStep.shortcut.rawValue, !readiness.modelsReady,
                  practiceToken == nil {
            step = .models; practiceSucceeded = false
        }
    }

    @discardableResult public mutating func advance(_ readiness: SetupReadiness) -> Bool {
        reconcile(readiness)
        switch step {
        case .welcome, .microphone, .accessibility, .inputMonitoring:
            if step != .welcome, !readiness.granted(step) { return false }
            step = readiness.firstMissingPermission ?? (readiness.modelsReady ? .shortcut : .models)
        case .models:
            guard readiness.modelsReady else { return false }
            step = .shortcut
        case .shortcut:
            guard readiness.ready, verifiedShortcut == readiness.shortcut else { return false }
            step = .practice
        case .practice:
            guard readiness.ready, verifiedShortcut == readiness.shortcut,
                  practiceSucceeded, practiceToken == nil else { return false }
            step = .complete
        case .complete: return false
        }
        return true
    }

    @discardableResult public mutating func detectShortcut(_ readiness: SetupReadiness) -> Bool {
        guard step == .shortcut, readiness.listenerActive else { return false }
        verifiedShortcut = readiness.shortcut; return true
    }

    public mutating func beginPractice(_ token: UUID) {
        guard step == .practice else { return }
        practiceToken = token; practiceSucceeded = false
    }

    @discardableResult public mutating func finishPractice(_ text: String, token: UUID) -> Bool {
        guard step == .practice, practiceToken == token else { return false }
        practiceToken = nil
        practiceSucceeded = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return practiceSucceeded
    }

    public mutating func cancelPractice() { practiceToken = nil; practiceSucceeded = false }

    public mutating func back() {
        guard practiceToken == nil, step != .welcome, step != .complete else { return }
        step = SetupStep(rawValue: step.rawValue - 1) ?? .welcome
    }
}

public struct SetupDownloadEstimate: Sendable {
    private var previousBytes: Int64?
    private var previousTime: TimeInterval?
    public private(set) var bytesPerSecond: Double?
    public init() {}
    public mutating func reset() { previousBytes = nil; previousTime = nil; bytesPerSecond = nil }
    public mutating func sample(bytes: Int64, now: TimeInterval) {
        defer { previousBytes = bytes; previousTime = now }
        guard let last = previousBytes, let time = previousTime, now > time,
              bytes > last else { bytesPerSecond = nil; return }
        let rate = Double(bytes - last) / (now - time)
        bytesPerSecond = bytesPerSecond.map { $0 * 0.75 + rate * 0.25 } ?? rate
    }
    public func remaining(total: Int64, completed: Int64) -> TimeInterval? {
        guard total > completed, let rate = bytesPerSecond, rate > 0 else { return nil }
        return Double(total - completed) / rate
    }
}
