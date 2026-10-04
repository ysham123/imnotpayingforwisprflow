import Foundation
#if canImport(DictationCore)
import DictationCore
#endif

enum VocabularyPreferences {
    static let storageKey = "dictation.vocabulary.v1"
    static func load(from defaults: UserDefaults = .standard) -> VocabularySnapshot {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(VocabularySnapshot.self, from: data),
              let validated = try? VocabularySnapshot(entries: decoded.entries, revision: decoded.revision) else { return .empty }
        return validated
    }
    @discardableResult
    static func save(_ snapshot: VocabularySnapshot, to defaults: UserDefaults = .standard) -> Bool {
        guard let validated = try? VocabularySnapshot(entries: snapshot.entries, revision: snapshot.revision),
              let data = try? JSONEncoder().encode(validated) else { return false }
        defaults.set(data, forKey: storageKey); return true
    }
}
