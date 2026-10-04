import AppKit
import Carbon
import DictationCore

/// Captures a shortcut only inside its sheet. It never installs a global key
/// logger, and releasing focus or pressing Escape preserves the old shortcut.
@MainActor
final class ShortcutRecorder {
    private var monitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var alert: NSAlert?

    func begin(on parent: NSWindow,
               accept: @escaping (ShortcutConfiguration) -> String?,
               completion: @escaping () -> Void) {
        guard alert == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Choose a dictation shortcut"
        alert.informativeText = "Press a key with Command, Control, or Option, or use a function key such as F8. Press Escape to cancel."
        alert.addButton(withTitle: "Cancel")
        let feedback = NSTextField(wrappingLabelWithString: "Waiting for your shortcut…")
        feedback.frame = NSRect(x: 0, y: 0, width: 390, height: 48)
        feedback.font = .systemFont(ofSize: 13)
        feedback.setAccessibilityLabel("Shortcut recording status")
        alert.accessoryView = feedback
        self.alert = alert

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak parent] event in
            guard let self, let parent, let sheet = self.alert?.window,
                  NSApp.isActive, event.window === sheet else { return event }
            if event.keyCode == 53 {
                parent.endSheet(sheet, returnCode: .cancel)
                return nil
            }
            guard !event.isARepeat else { return nil }
            let candidate = Self.configuration(for: event)
            if let problem = candidate.validationError ?? accept(candidate) {
                feedback.stringValue = problem
                feedback.textColor = .systemOrange
                NSAccessibility.post(element: feedback, notification: .announcementRequested,
                                     userInfo: [.announcement: problem,
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            } else {
                parent.endSheet(sheet, returnCode: .OK)
            }
            return nil
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self, weak parent] _ in
            MainActor.assumeIsolated {
                if let sheet = self?.alert?.window { parent?.endSheet(sheet, returnCode: .cancel) }
            }
        }
        alert.beginSheetModal(for: parent) { [weak self] _ in
            guard let self else { return }
            if let monitor = self.monitor { NSEvent.removeMonitor(monitor) }
            if let observer = self.activationObserver { NotificationCenter.default.removeObserver(observer) }
            self.monitor = nil
            self.activationObserver = nil
            self.alert = nil
            completion()
        }
    }

    private static func configuration(for event: NSEvent) -> ShortcutConfiguration {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let names: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            64: "F17", 79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6",
            98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
            106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
            115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End",
            120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        return .custom(keyCode: UInt32(event.keyCode), modifiers: modifiers, displayName: label)
    }
}
