import Foundation

/// Owns a single dictation and an optional unsent result. Delivery receipts may
/// outlive a session, but cannot change the state of a newer recording.
public struct DictationSessionState: Sendable {
    public enum Phase: Sendable { case loading, idle, listening, processing, pending, failedRecording }
    public private(set) var phase: Phase = .loading
    public private(set) var id = UUID()
    public private(set) var pendingText: String?
    public private(set) var lastText: String?
    public private(set) var hasFailedRecording = false
    public private(set) var dispatched: Set<UUID> = []

    public init() {}

    public mutating func ready() {
        if phase == .loading { phase = .idle }
    }

    public mutating func begin() -> UUID? {
        guard phase == .idle, pendingText == nil, !hasFailedRecording else { return nil }
        id = UUID(); phase = .listening
        return id
    }

    @discardableResult public mutating func process(_ token: UUID) -> Bool {
        guard token == id, phase == .listening else { return false }
        phase = .processing; return true
    }

    public mutating func beginPlacement() -> UUID? {
        guard phase == .pending, pendingText != nil else { return nil }
        id = UUID(); phase = .processing
        return id
    }

    @discardableResult public mutating func hold(_ text: String, for token: UUID) -> Bool {
        guard token == id, phase == .processing, !dispatched.contains(token), !text.isEmpty else { return false }
        hasFailedRecording = false; pendingText = text; phase = .pending
        return true
    }

    @discardableResult public mutating func didDispatch(_ text: String, for token: UUID) -> Bool {
        guard token == id, phase == .processing, !dispatched.contains(token) else { return false }
        hasFailedRecording = false
        dispatched.insert(token); lastText = text; pendingText = nil; phase = .idle
        return true
    }

    /// False means the receipt belongs to an older session; the caller must not
    /// change current presentation. Removing it still releases delivery tracking.
    public mutating func finishDelivery(_ token: UUID) -> Bool {
        dispatched.remove(token)
        return token == id && phase == .idle
    }

    @discardableResult public mutating func finish(_ token: UUID) -> Bool {
        guard token == id, !dispatched.contains(token) else { return false }
        phase = hasFailedRecording ? .failedRecording : (pendingText == nil ? .idle : .pending)
        return true
    }

    public mutating func cancel() {
        id = UUID()
        phase = hasFailedRecording ? .failedRecording : (pendingText == nil ? .idle : .pending)
    }

    @discardableResult public mutating func failRecording(_ token: UUID) -> Bool {
        guard token == id, phase == .processing, pendingText == nil, !dispatched.contains(token) else { return false }
        hasFailedRecording = true; phase = .failedRecording
        return true
    }

    public mutating func beginRetry() -> UUID? {
        guard phase == .failedRecording, hasFailedRecording else { return nil }
        id = UUID(); phase = .processing
        return id
    }

    public mutating func discardRecording() {
        guard phase == .failedRecording else { return }
        hasFailedRecording = false; id = UUID(); phase = .idle
    }

    /// Once recognition returns, retries no longer own audio. Any result is text.
    public mutating func recognized(_ token: UUID) {
        guard token == id, phase == .processing else { return }
        hasFailedRecording = false
    }

    public mutating func resolvePending(copied: Bool) {
        guard phase == .pending else { return }
        if copied { lastText = pendingText }
        pendingText = nil; id = UUID(); phase = .idle
    }
}
