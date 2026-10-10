import DictationCore
import Foundation

/// UserDefaults uses the current app bundle's domain, keeping development builds
/// separate from the installed app when they have a different bundle identifier.
enum DictationPreferences {
    static let modeKey = "dictation.mode.v1"
    static let inputUIDKey = "dictation.inputUID.v1"

    static var mode: DictationMode {
        get { loadMode() }
        set { saveMode(newValue) }
    }

    static var inputUID: String? {
        get { loadInputUID() }
        set { saveInputUID(newValue) }
    }

    static func loadMode(from defaults: UserDefaults = .standard) -> DictationMode {
        defaults.string(forKey: modeKey).flatMap(DictationMode.init(rawValue:)) ?? .clean
    }

    static func saveMode(_ mode: DictationMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    static func loadInputUID(from defaults: UserDefaults = .standard) -> String? {
        guard let uid = defaults.string(forKey: inputUIDKey), !uid.isEmpty else { return nil }
        return uid
    }

    static func saveInputUID(_ uid: String?, to defaults: UserDefaults = .standard) {
        if let uid, !uid.isEmpty { defaults.set(uid, forKey: inputUIDKey) }
        else { defaults.removeObject(forKey: inputUIDKey) }
    }
}
