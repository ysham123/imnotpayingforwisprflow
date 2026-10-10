import Foundation

public enum DictationMode: String, Codable, CaseIterable, Sendable {
    case clean, verbatim

    public var displayName: String { self == .clean ? "Clean" : "Verbatim" }
}

/// Capture options remain stable even if preferences change before a retry.
public struct DictationSessionSnapshot: Sendable {
    public let mode: DictationMode
    public let vocabulary: VocabularySnapshot
    public let inputUID: String?

    public init(mode: DictationMode, vocabulary: VocabularySnapshot, inputUID: String?) {
        self.mode = mode; self.vocabulary = vocabulary; self.inputUID = inputUID
    }
}
