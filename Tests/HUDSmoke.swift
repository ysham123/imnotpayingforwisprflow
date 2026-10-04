import AppKit

/// Uses an isolated native editor and floating surfaces; never types into a user app.
@main struct HUDSmoke {
    @MainActor static func main() {
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--check-permission" {
            if CGPreflightPostEventAccess() && AXIsProcessTrusted() { exit(0) }
            fputs("HUD click regression needs Accessibility permission for its runner. No fixture was opened.\n", stderr)
            exit(2)
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--check-geometry" {
            do { try assertDisplaySelection(); print("Passed 7 display geometry checks"); exit(0) }
            catch { fputs("HUD GEOMETRY FAILED: \(error)\n", stderr); exit(1) }
        }
        guard CommandLine.arguments.count == 3 else { exit(2) }
        NSApplication.shared.setActivationPolicy(.accessory)
        setbuf(stdout, nil)
        Task { @MainActor in
            do { try await run(); print("Passed 13 HUD visibility, Space, display, focus, and announcement regression groups"); exit(0) }
            catch {
                fputs("HUD TEST FAILED: \(error)\nActivation trace: \(activationTrace.joined(separator: "; "))\n", stderr)
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor static var sequence = 0
    @MainActor static var fixturePID: pid_t = 0
    @MainActor static var activationTrace: [String] = []
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
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try check(frontPID == fixturePID,
                  "Editor lost foreground: frontPID=\(String(describing: frontPID)), fixturePID=\(fixturePID), hudPID=\(ProcessInfo.processInfo.processIdentifier), fixtureActive=\(String(describing: reply["active"])), fixtureKey=\(String(describing: reply["keyWindow"])), hudKey=\(hud.panel.isKeyWindow)")
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
        hud.panel.contentView?.layoutSubtreeIfNeeded()
        hud.panel.displayIfNeeded()
        // Match this panel's committed WindowServer bounds, not a guessed
        // delay. Layout can resize it after the prior state was displayed.
        let geometryDeadline = ProcessInfo.processInfo.systemUptime + 3
        var stableSamples = 0
        while stableSamples < 3, ProcessInfo.processInfo.systemUptime < geometryDeadline {
            hud.panel.contentView?.layoutSubtreeIfNeeded()
            hud.panel.displayIfNeeded()
            let frame = hud.panel.frame
            let expected = CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                                  width: frame.width, height: frame.height)
            stableSamples = committedBounds(of: hud.panel) == expected ? stableSamples + 1 : 0
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try check(stableSamples == 3, "HUD WindowServer geometry did not settle: \(String(describing: committedBounds(of: hud.panel)))")
        guard let content = hud.panel.contentView, let button = findButton(id, in: content),
              !button.isHidden else { throw NSError(domain: "HUD button unavailable: \(id)", code: 1) }
        try check(!button.acceptsFirstResponder && !button.needsPanelToBecomeKey,
                  "HUD button requests keyboard focus")
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let global = hud.panel.convertPoint(toScreen: center)
        let point = CGPoint(x: global.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - global.y)
        var receivedEvents: [String] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            if event.window === hud.panel { receivedEvents.append("\(event.type.rawValue):\(event.locationInWindow)") }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let source = CGEventSource(stateID: .combinedSessionState)
        activationTrace.append("click \(id) at \(ProcessInfo.processInfo.systemUptime)")
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw NSError(domain: "Cannot create HUD click", code: 1)
            }
            event.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 35_000_000)
        }
        activationTrace.append("click completed \(id), received=\(didReceive()) at \(ProcessInfo.processInfo.systemUptime)")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !didReceive(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(didReceive(), "Actual mouse click did not invoke \(id); button=\(button.frame), expectedLocal=\(center), appFrame=\(hud.panel.frame), serverFrame=\(String(describing: committedBounds(of: hud.panel))), received=\(receivedEvents)")
        try await assertEditorRetainedFocus(hud)
    }

    @MainActor static func committedBounds(of panel: NSPanel) -> CGRect? {
        guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]],
              let bounds = entries.first?[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
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

    @MainActor static func assertTopmost(_ hud: DictationHUD) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var covering: [Int] = []
        repeat {
            let frame = hud.panel.frame
            covering = [CGFloat(0.25), 0.5, 0.75].map {
                NSWindow.windowNumber(at: NSPoint(x: frame.minX + frame.width * $0, y: frame.midY),
                                      belowWindowWithWindowNumber: 0)
            }
            if hud.panel.isVisible, hud.panel.isOnActiveSpace,
               covering.allSatisfy({ $0 == hud.panel.windowNumber }) { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw NSError(domain: "HUD is not topmost: visible=\(hud.panel.isVisible) activeSpace=\(hud.panel.isOnActiveSpace) frame=\(hud.panel.frame) level=\(hud.panel.level.rawValue) panel=\(hud.panel.windowNumber) covering=\(covering)", code: 1)
    }

    @MainActor static func waitForFullScreen(_ expected: Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            let reply = try await command([:])
            if reply["fullScreen"] as? Bool == expected { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "Owned fixture did not finish full-screen transition", code: 1)
    }

    @MainActor static func waitForDialog() async throws -> Int {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            let reply = try await command([:])
            if let window = reply["dialogWindowNumber"] as? Int,
               reply["keyWindowNumber"] as? Int == window { return window }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw NSError(domain: "Owned fixture dialog did not become key", code: 1)
    }

    @MainActor static func assertDisplaySelection() throws {
        let displays = [DictationHUD.ScreenRegion(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                        .init(id: 2, frame: CGRect(x: -1280, y: 0, width: 1280, height: 1024)),
                        .init(id: 3, frame: CGRect(x: 0, y: -900, width: 1440, height: 900)),
                        .init(id: 4, frame: CGRect(x: 1920, y: 0, width: 1512, height: 982))]
        try check(DictationHUD.displayID(intersecting: CGRect(x: -1000, y: 100, width: 800, height: 700), regions: displays) == 2,
                  "Window on left display was resolved using primary coordinates")
        try check(DictationHUD.displayID(intersecting: CGRect(x: 100, y: -800, width: 1000, height: 600), regions: displays) == 3,
                  "Window above primary display was not resolved")
        try check(DictationHUD.displayID(intersecting: CGRect(x: 2100, y: 100, width: 1000, height: 700), regions: displays) == 4,
                  "Logical Retina display coordinates were rescaled")
        try check(DictationHUD.displayID(intersecting: CGRect(x: -200, y: 100, width: 800, height: 700), regions: displays) == 1,
                  "Spanning window did not use largest visible intersection")
        try check(DictationHUD.displayID(intersecting: CGRect(x: 9000, y: 0, width: 100, height: 100), regions: displays) == nil,
                  "Offscreen geometry should keep fallback")
        try check(DictationHUD.displayID(intersecting: .zero, regions: displays) == nil, "Empty geometry accepted")
        try check(DictationHUD.displayID(intersecting: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100), regions: displays) == nil,
                  "Nonfinite geometry accepted")
    }

    @MainActor static func run() async throws {
        guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else { throw NSError(domain: "HUD runner needs Accessibility", code: 1) }
        let activations = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                activationTrace.append("foregroundPID=\(String(describing: pid)) at \(ProcessInfo.processInfo.systemUptime)")
            }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(activations) }
        _ = try await command(["value": "hello world", "location": 5, "focus": true])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID { break }
            _ = try await command(["focus": true])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID,
                  "Fixture is not frontmost; no AX inspection performed")
        let owned = try await command([:])
        guard let ownedFrame = owned["windowFrame"] as? [Double], ownedFrame.count == 4,
              let leaf = AXInspection(budget: 0.2).anchorLeaf(in: fixturePID) else {
            throw NSError(domain: "Cannot anchor owned fixture window", code: 1)
        }
        let originalFrame = CGRect(x: ownedFrame[0], y: ownedFrame[1], width: ownedFrame[2], height: ownedFrame[3])
        let anchor = TextInserter.Anchor(processIdentifier: fixturePID, focusedLeaf: leaf, cursorElement: leaf,
                                         selection: nil, selectionMarker: nil, epoch: 0, owner: UUID())
        let inspector = TargetInspector()
        try check(await inspector.originWindowFrame(anchor) == originalFrame, "Original AX window geometry differs from owned fixture")
        let canceledOrigin = Task { await inspector.originWindowFrame(anchor) }
        canceledOrigin.cancel()
        try check(await canceledOrigin.value == nil, "Canceled origin request returned geometry")
        print("PASS origin window geometry is anchored, asynchronous, and cancellation-aware")
        var announcements: [String] = []
        let hud = DictationHUD(announce: { announcements.append($0) })
        defer { hud.hide() }
        let sourceScreen = DictationHUD.activeScreen
        for state in [DictationHUD.State.starting, .listening, .transcribing, .correcting,
                      .inserting, .ready, .inserted, .pasteSent, .error] {
            hud.show(state, on: sourceScreen)
            hud.updateLevel(0.2)
            try await Task.sleep(nanoseconds: 35_000_000)
            try await assertEditorRetainedFocus(hud)
            try await assertTopmost(hud)
            let height = hud.panel.contentView!.bounds.height
            try check(hud.panel.contentView!.layer?.cornerRadius == height / 2,
                      "HUD is not a true capsule in state \(state)")
            if [.starting, .listening, .transcribing, .correcting, .inserting].contains(state) {
                try check(hud.panel.frame.width <= 292 && height <= 50, "Active dictation capsule is oversized")
            }
            if [.listening, .ready, .inserted, .pasteSent].contains(state) {
                let filename: String
                switch state {
                case .ready: filename = "ready.png"
                case .inserted: filename = "inserted.png"
                case .pasteSent: filename = "paste-sent.png"
                default: filename = "listening.png"
                }
                try savePreview(hud, named: filename)
            }
        }
        print("PASS all nine HUD states preserve external editor and caret")
        print("PASS each state has capsule geometry and active dictation stays within its compact footprint")
        try check(hud.panel.level == .statusBar && hud.panel.collectionBehavior.contains(.canJoinAllApplications) &&
                  hud.panel.collectionBehavior.contains(.canJoinAllSpaces) &&
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
        let before = announcements.count
        hud.show(.ready, message: "Insert, copy, or discard your previous text")
        try check(announcements.count == before + 1 &&
                  announcements.last?.contains("Insert, copy, or discard") == true,
                  "Pending double-tap guidance was not announced")
        hud.show(.ready, message: "Insert, copy, or discard your previous text")
        try check(announcements.count == before + 1, "Repeated identical guidance was announced again")
        hud.show(.ready, message: "Text saved · finish permission setup to place it")
        try check(announcements.count == before + 2 &&
                  announcements.last?.contains("permission setup") == true,
                  "Changed permission guidance was not announced")
        hud.show(.listening)
        let beforeMeter = announcements.count
        for value in [Float(0), 0.1, 0.7, 1, 0] { hud.updateLevel(value) }
        try check(announcements.count == beforeMeter, "Audio level updates produced announcements")
        try await assertEditorRetainedFocus(hud)
        print("PASS changed pending guidance is announced; repeated guidance and meter updates remain silent")

        try assertDisplaySelection()
        print("PASS origin display selection handles negative coordinates, vertical and Retina display layouts")
        hud.show(.listening)
        let frame = hud.panel.frame.insetBy(dx: -50, dy: -30)
        _ = try await command(["overlayFrame": [frame.minX, frame.minY, frame.width, frame.height],
                               "overlay": true])
        try await assertTopmost(hud)
        _ = try await command(["overlayLevel": NSWindow.Level.statusBar.rawValue - 1, "overlay": true])
        try await assertTopmost(hud)
        try await assertEditorRetainedFocus(hud)
        print("PASS capsule stays above browser-like floating surfaces and near-status overlays without activation")

        let retired = UUID()
        hud.beginSession(retired, fallbackScreen: sourceScreen)
        hud.show(.listening)
        hud.hide()
        hud.refreshVisibility(for: retired)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApplication.shared)
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(!hud.panel.isVisible && hud.state == nil, "Space refresh revived dismissed feedback")
        let current = UUID()
        hud.beginSession(current, fallbackScreen: sourceScreen)
        hud.show(.listening)
        hud.panel.orderOut(nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        try await assertTopmost(hud)
        hud.panel.orderOut(nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApplication.shared)
        try await assertTopmost(hud)
        let currentFrame = hud.panel.frame
        hud.pinOrigin(CGRect(x: -10000, y: -10000, width: 20000, height: 20000), for: retired)
        hud.refreshVisibility(for: retired)
        try check(hud.sessionID == current && hud.state == .listening && hud.panel.frame == currentFrame,
                  "Previous session's origin/refresh changed current listening HUD")
        try await assertTopmost(hud)
        _ = try await command(["overlay": false])
        print("PASS stale origin/Space completions cannot revive feedback or move a new session")

        _ = try await command(["dialog": true])
        let dialogNumber = try await waitForDialog()
        try check(await inspector.originWindowFrame(anchor) == originalFrame, "Original AX geometry rebound to newly focused dialog")
        hud.show(.listening)
        hud.refreshVisibility(for: current)
        try await assertTopmost(hud)
        let retained = try await command([:])
        try check(retained["keyWindowNumber"] as? Int == dialogNumber &&
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID && !hud.panel.isKeyWindow,
                  "HUD took focus from an app dialog")
        _ = try await command(["dialog": false, "focus": true])
        try await assertEditorRetainedFocus(hud)
        print("PASS HUD ordering preserves an app dialog's key window")

        _ = try await command(["fullScreen": true])
        try await waitForFullScreen(true)
        hud.refreshVisibility(for: current)
        try await assertTopmost(hud)
        try await assertEditorRetainedFocus(hud)
        _ = try await command(["fullScreen": false])
        try await waitForFullScreen(false)
        hud.refreshVisibility(for: current)
        try await assertTopmost(hud)
        try await assertEditorRetainedFocus(hud)
        print("PASS native full-screen Space entry/exit keeps capsule visible and editor focused")
    }
}
