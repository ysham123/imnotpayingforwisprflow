import AppKit

/// Uses the existing isolated native fixture; never types into a user app.
@main struct HUDSmoke {
    @MainActor static func main() {
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--check-permission" {
            if CGPreflightPostEventAccess() { exit(0) }
            fputs("HUD click regression needs Accessibility permission for its runner. No fixture was opened.\n", stderr)
            exit(2)
        }
        guard CommandLine.arguments.count == 3 else { exit(2) }
        NSApplication.shared.setActivationPolicy(.accessory)
        setbuf(stdout, nil)
        Task { @MainActor in
            do { try await run(); print("Passed 5 external-editor HUD regressions"); exit(0) }
            catch { fputs("HUD TEST FAILED: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static var sequence = 0
    @MainActor static var fixturePID: pid_t = 0
    static var directory: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
    static var token: String { CommandLine.arguments[2] }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }

    @MainActor static func command(_ properties: [String: Any]) async throws -> [String: Any] {
        sequence += 1
        var request = properties
        request["id"] = sequence
        request["token"] = token
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("reply.json")),
               let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               reply["id"] as? Int == sequence, reply["token"] as? String == token,
               let pid = reply["pid"] as? Int {
                if fixturePID == 0 { fixturePID = pid_t(pid) }
                try check(fixturePID == pid_t(pid), "Fixture identity changed")
                return reply
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "HUD fixture timeout", code: 1)
    }

    @MainActor static func assertEditorRetainedFocus(_ hud: DictationHUD) async throws {
        let reply = try await command([:])
        try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID, "HUD activated its app")
        try check(reply["active"] as? Bool == true && reply["keyWindow"] as? Bool == true,
                  "HUD took the editor's key window")
        try check(reply["firstResponderIsField"] as? Bool == true, "HUD changed the editor's first responder")
        try check((reply["locations"] as? [Int])?.first == 5, "HUD moved the editor's caret")
        try check((reply["values"] as? [String])?.first == "hello world", "HUD altered editor text")
        try check(!hud.panel.isKeyWindow && !hud.panel.canBecomeKey && !hud.panel.canBecomeMain,
                  "HUD can take keyboard focus")
    }

    @MainActor static func findButton(_ id: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
        return view.subviews.lazy.compactMap { findButton(id, in: $0) }.first
    }

    @MainActor static func click(_ id: String, hud: DictationHUD, didReceive: () -> Bool) async throws {
        // Let WindowServer commit a state-driven resize before deriving the
        // global click point; an immediate posted event uses the old origin.
        try await Task.sleep(nanoseconds: 120_000_000)
        hud.panel.contentView?.layoutSubtreeIfNeeded()
        guard let content = hud.panel.contentView, let button = findButton(id, in: content),
              !button.isHidden else { throw NSError(domain: "HUD button unavailable: \(id)", code: 1) }
        try check(!button.acceptsFirstResponder && !button.needsPanelToBecomeKey,
                  "HUD button requests keyboard focus")
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let global = hud.panel.convertPoint(toScreen: center)
        let point = CGPoint(x: global.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - global.y)
        let source = CGEventSource(stateID: .combinedSessionState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw NSError(domain: "Cannot create HUD click", code: 1)
            }
            event.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 35_000_000)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !didReceive(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(didReceive(), "Actual mouse click did not invoke \(id)")
        try await assertEditorRetainedFocus(hud)
    }

    @MainActor static func savePreview(_ hud: DictationHUD, named name: String) throws {
        guard let view = hud.panel.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { return }
        let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name)
        try data.write(to: output)
        print("HUD preview: \(output.path)")
    }

    @MainActor static func run() async throws {
        guard CGPreflightPostEventAccess() else { throw NSError(domain: "HUD runner needs Accessibility", code: 1) }
        _ = try await command(["value": "hello world", "location": 5, "focus": true])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID { break }
            _ = try await command(["focus": true])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let hud = DictationHUD()
        defer { hud.hide() }
        let sourceScreen = DictationHUD.activeScreen
        for state in [DictationHUD.State.starting, .listening, .transcribing, .correcting,
                      .inserting, .ready, .inserted, .pasteSent, .error] {
            hud.show(state, on: sourceScreen)
            hud.updateLevel(0.2)
            try await Task.sleep(nanoseconds: 35_000_000)
            try await assertEditorRetainedFocus(hud)
            if state == .listening || state == .ready {
                try savePreview(hud, named: state == .ready ? "ready.png" : "listening.png")
            }
        }
        print("PASS all nine HUD states preserve external editor and caret")
        try check(hud.panel.collectionBehavior.contains(.canJoinAllSpaces) &&
                  hud.panel.collectionBehavior.contains(.fullScreenAuxiliary), "HUD lacks Spaces/full-screen support")
        if let sourceScreen {
            try check(sourceScreen.visibleFrame.contains(hud.panel.frame), "HUD is outside its display")
        }
        print("PASS HUD remains inside its display and supports full-screen Spaces")
        var canceled = 0, copied = 0, discarded = 0
        hud.onCancel = { canceled += 1 }
        hud.onCopy = { copied += 1 }
        hud.onDiscard = { discarded += 1 }
        hud.show(.listening)
        try await click("dictation-cancel", hud: hud) { canceled == 1 }
        print("PASS real Cancel click keeps the external editor focused")
        hud.show(.ready)
        try await click("dictation-copy", hud: hud) { copied == 1 }
        print("PASS real Copy click keeps the external editor focused")
        try await click("dictation-discard", hud: hud) { discarded == 1 }
        print("PASS real Discard click keeps the external editor focused")
    }
}
