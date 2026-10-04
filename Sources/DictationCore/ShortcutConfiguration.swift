import Foundation

/// Virtual key codes and Carbon modifier bits are stable across launches. The
/// label is presentation only; registration never depends on keyboard text.
public enum ShortcutConfiguration: Codable, Equatable, Sendable {
    case fn
    case custom(keyCode: UInt32, modifiers: UInt32, displayName: String)

    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12
    public static let supportedModifiers = command | shift | option | control
    public static let functionKeyCodes: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                                     103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    public var displayName: String {
        switch self {
        case .fn: return "Fn / Globe"
        case let .custom(_, modifiers, label):
            return [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
                .filter { modifiers & $0.0 != 0 }.map { $0.1 }.joined() + label
        }
    }

    public var validationError: String? {
        guard case let .custom(keyCode, modifiers, label) = self else { return nil }
        guard keyCode <= 127, !(54...63).contains(keyCode), keyCode != 53 else {
            return "Choose a key other than Fn, Escape, or a modifier key."
        }
        guard modifiers & ~Self.supportedModifiers == 0 else { return "That modifier combination is not supported." }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.count <= 40, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return "The shortcut needs a readable key name."
        }
        guard Self.functionKeyCodes.contains(keyCode) || modifiers & (Self.command | Self.control | Self.option) != 0 else {
            return "Include Command, Control, or Option, or use an F1–F20 key."
        }
        // Leave familiar editing, window management, and system navigation
        // available in every editor, including their Shift variants.
        let withoutShift = modifiers & ~Self.shift
        let commandKeys: Set<UInt32> = [0, 4, 6, 7, 8, 9, 12, 13, 46, 48, 49, 50]
        if withoutShift == Self.command && commandKeys.contains(keyCode) {
            return "That shortcut is reserved for typing, editing, or macOS navigation."
        }
        if keyCode == 49 && modifiers & Self.command != 0 ||
            keyCode == 12 && withoutShift == Self.command | Self.control {
            return "That shortcut is reserved by macOS."
        }
        return nil
    }

    /// Labels can change with an input source without requiring reregistration.
    public func hasSameBinding(as other: Self) -> Bool {
        switch (self, other) {
        case (.fn, .fn): return true
        case let (.custom(key, modifiers, _), .custom(otherKey, otherModifiers, _)):
            return key == otherKey && modifiers == otherModifiers
        default: return false
        }
    }
}
