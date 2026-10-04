import Foundation
import DictationCore

enum HotkeyPreferences {
    static let storageKey = "dictation.shortcut.v1"

    static func load(from defaults: UserDefaults = .standard) -> ShortcutConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              let configuration = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
              configuration.validationError == nil else { return .fn }
        return configuration
    }

    @discardableResult
    static func save(_ configuration: ShortcutConfiguration, to defaults: UserDefaults = .standard) -> Bool {
        guard configuration.validationError == nil,
              let data = try? JSONEncoder().encode(configuration) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }
}
