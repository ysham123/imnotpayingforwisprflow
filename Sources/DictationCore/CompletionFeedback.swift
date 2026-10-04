import Foundation

/// A delivery receipt may arrive after its brief confirmation has disappeared.
/// Once dismissed, that receipt must not bring the floating indicator back.
public struct CompletionFeedback: Sendable {
    private var token: UUID?
    private var visible = false
    private var verified = false

    public init() {}

    public mutating func begin(_ token: UUID) {
        self.token = token; visible = true; verified = false
    }

    public func isVisible(for token: UUID) -> Bool { self.token == token && visible }

    public mutating func confirm(_ token: UUID) -> Bool {
        guard self.token == token, !verified else { return false }
        verified = true
        return visible
    }

    public mutating func dismiss(_ token: UUID) {
        if self.token == token { visible = false }
    }
}
