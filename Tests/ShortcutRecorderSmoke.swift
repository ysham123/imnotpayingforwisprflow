import AppKit
import Carbon
import DictationCore

/// Dispatches NSEvents only through this fixture's own NSApplication. It never
/// posts global CGEvents, registers a shortcut, or reads another app's UI.
@main
struct ShortcutRecorderSmoke {
    @MainActor
    final class TypingView: NSView {
        var typed: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { typed.append(event.characters ?? "") }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command) { return true }
            return super.performKeyEquivalent(with: event)
        }
    }

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await run()
                print("Passed 8 isolated shortcut recorder routing/lifecycle regressions")
                exit(0)
            } catch {
                fputs("SHORTCUT RECORDER TEST FAILED: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }

    @MainActor
    static func waitUntil(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(condition(), message)
    }

    @MainActor
    static func postKey(to window: NSWindow, code: UInt16, characters: String,
                        modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code) else {
            throw NSError(domain: "Cannot construct owned shortcut event", code: 1)
        }
        NSApp.postEvent(event, atStart: false)
    }

    @MainActor
    static func views<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? [])
            + root.subviews.flatMap { views(of: type, in: $0) }
    }

    @MainActor
    static func cancelButton(in sheet: NSWindow) throws -> NSButton {
        guard let content = sheet.contentView,
              let button = views(of: NSButton.self, in: content).first(where: { $0.title == "Cancel" }) else {
            throw NSError(domain: "Owned shortcut sheet has no Cancel button", code: 1)
        }
        return button
    }

    @MainActor
    static func containsFeedback(_ text: String, sheet: NSWindow) -> Bool {
        guard let content = sheet.contentView else { return false }
        return views(of: NSTextField.self, in: content).contains { $0.stringValue == text }
    }

    @MainActor
    static func run() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.title = "Local Dictation shortcut recorder synthetic fixture"
        parent.isReleasedWhenClosed = false
        parent.center()
        let outside = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        outside.title = "Owned outside-window typing fixture"
        outside.isReleasedWhenClosed = false
        let typing = TypingView(frame: outside.contentView!.bounds)
        outside.contentView = typing
        defer { outside.orderOut(nil); parent.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        parent.makeKeyAndOrderFront(nil)
        try await waitUntil("Fixture could not become active", { NSApp.isActive })

        let recorder = ShortcutRecorder()
        let original = ShortcutConfiguration.custom(keyCode: 0,
            modifiers: UInt32(cmdKey | controlKey), displayName: "A")
        var saved = original
        var candidates: [ShortcutConfiguration] = []
        var completions = 0
        var rejection: String?

        func begin() async throws -> NSWindow {
            parent.makeKeyAndOrderFront(nil)
            recorder.begin(on: parent, accept: { candidate in
                candidates.append(candidate)
                if let rejection { return rejection }
                saved = candidate
                return nil
            }, completion: { completions += 1 })
            try await waitUntil("Recorder did not present its sheet", {
                parent.attachedSheet != nil && parent.attachedSheet?.isKeyWindow == true && NSApp.isActive
            })
            guard let sheet = parent.attachedSheet else { throw NSError(domain: "Missing recorder sheet", code: 1) }
            sheet.contentView?.layoutSubtreeIfNeeded()
            try check(sheet.frame.width <= parent.frame.width && sheet.frame.height <= parent.frame.height,
                      "Shortcut sheet exceeds the setup window")
            let button = try cancelButton(in: sheet)
            guard let content = sheet.contentView else { throw NSError(domain: "Missing sheet content", code: 1) }
            try check(content.bounds.contains(button.convert(button.bounds, to: content)),
                      "Recorder Cancel button is clipped")
            return sheet
        }
        func completed(_ count: Int) async throws {
            try await waitUntil("Recorder failed to finish/clean up", {
                completions == count && parent.attachedSheet == nil
            })
        }

        // Cancel paths exercise the actual sheet completion and local monitor.
        var sheet = try await begin()
        try postKey(to: sheet, code: 53, characters: "\u{1b}")
        try await completed(1)
        try check(candidates.isEmpty && saved == original, "Escape changed the saved shortcut")
        print("PASS posted Escape cancels and preserves previous configuration")

        sheet = try await begin()
        try cancelButton(in: sheet).performClick(nil)
        try await completed(2)
        try check(candidates.isEmpty && saved == original, "Cancel changed the saved shortcut")
        print("PASS Cancel button and reopening after Escape")

        sheet = try await begin()
        let invalid = ShortcutConfiguration.custom(keyCode: 0, modifiers: 0, displayName: "A")
        try postKey(to: sheet, code: 0, characters: "a")
        try await waitUntil("Invalid chord did not show feedback", {
            containsFeedback(invalid.validationError!, sheet: sheet)
        })
        try check(candidates.isEmpty && saved == original && parent.attachedSheet === sheet,
                  "Invalid chord reached acceptance or dismissed its sheet")
        try postKey(to: sheet, code: 100, characters: "\u{f70b}", repeatKey: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(candidates.isEmpty && parent.attachedSheet === sheet,
                  "A repeated function key was accepted")
        try cancelButton(in: sheet).performClick(nil)
        try await completed(3)
        print("PASS invalid chord feedback and autorepeat leave sheet open")

        sheet = try await begin()
        rejection = "Synthetic registration conflict; choose another shortcut."
        let chord = ShortcutConfiguration.custom(keyCode: 40,
            modifiers: UInt32(cmdKey | controlKey), displayName: "K")
        try postKey(to: sheet, code: 40, characters: "k", modifiers: [.command, .control])
        try await waitUntil("Acceptance failure was not shown", {
            candidates.count == 1 && containsFeedback(rejection!, sheet: sheet)
        })
        try check(saved == original && parent.attachedSheet === sheet && completions == 3,
                  "A rejected registration changed the previous configuration")
        print("PASS acceptance failure keeps sheet and previous configuration")

        rejection = nil
        try postKey(to: sheet, code: 40, characters: "k", modifiers: [.command, .control])
        try await completed(4)
        try check(candidates == [chord, chord] && saved == chord,
                  "Command/Control chord was not routed with its correct key code, modifiers, and label")
        print("PASS accepted posted Command/Control chord has correct configuration")

        sheet = try await begin()
        let candidateCount = candidates.count
        outside.makeKeyAndOrderFront(nil)
        outside.makeFirstResponder(typing)
        try await waitUntil("Owned outside window did not become key", { outside.isKeyWindow })
        try postKey(to: outside, code: 6, characters: "z")
        try await waitUntil("Outside normal typing was swallowed", { typing.typed == ["z"] })
        try postKey(to: outside, code: 40, characters: "k", modifiers: [.command, .control])
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(candidates.count == candidateCount && saved == chord && parent.attachedSheet === sheet,
                  "Outside-window shortcut input reached the recorder")
        outside.orderOut(nil); sheet.makeKeyAndOrderFront(nil)
        try cancelButton(in: sheet).performClick(nil)
        try await completed(5)
        print("PASS outside-window typing and valid chord are not captured")

        _ = try await begin()
        NSApp.deactivate()
        try await completed(6)
        try check(saved == chord && candidates.count == candidateCount,
                  "Resigning active changed the previous configuration")
        print("PASS actual resign-active cancels and cleans up recorder")

        NSApp.activate(ignoringOtherApps: true)
        parent.makeKeyAndOrderFront(nil)
        try await waitUntil("Owned fixture could not reactivate", { NSApp.isActive })
        sheet = try await begin()
        let functionKey = ShortcutConfiguration.custom(keyCode: 100, modifiers: 0, displayName: "F8")
        try postKey(to: sheet, code: 100, characters: "\u{f70b}")
        try await completed(7)
        try check(saved == functionKey && candidates.count == candidateCount + 1,
                  "Recorder could not reopen cleanly after activation change, or had duplicate monitors")
        print("PASS reopening after deactivation accepts one correctly named function key")
    }
}
