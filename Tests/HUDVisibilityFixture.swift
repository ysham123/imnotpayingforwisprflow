import AppKit

private final class FixtureOverlay: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class FixtureState {
    var fullScreenSettled = false
}

/// Owned editor, floating browser-like surface, and real native full-screen
/// Space for HUD ordering tests. It never opens or inspects user documents.
@main struct HUDVisibilityFixture {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let token = CommandLine.arguments[2]
        let identity: [String: Any] = ["token": token, "pid": ProcessInfo.processInfo.processIdentifier]
        try! JSONSerialization.data(withJSONObject: identity).write(to: directory.appendingPathComponent("fixture.json"), options: .atomic)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 620, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Local Dictation HUD test editor"
        window.collectionBehavior.insert(.fullScreenPrimary)
        let field = NSTextView(frame: NSRect(x: 20, y: 170, width: 580, height: 200))
        field.font = .systemFont(ofSize: 18)
        field.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(field)
        let overlay = FixtureOverlay(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.level = .modalPanel
        overlay.backgroundColor = .systemIndigo
        overlay.hidesOnDeactivate = false
        overlay.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .fullScreenAuxiliary]
        let dialog = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                             styleMask: [.titled], backing: .buffered, defer: false)
        dialog.title = "HUD test dialog"
        let dialogField = NSTextField(string: "Owned dialog field")
        dialogField.frame = NSRect(x: 20, y: 35, width: 320, height: 24)
        dialog.contentView!.addSubview(dialogField)
        let state = FixtureState()
        let observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { state.fullScreenSettled = true }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { state.fullScreenSettled = false }
            }
        ]
        let menu = NSMenu()
        let application = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Fixture")
        applicationMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(application); menu.setSubmenu(applicationMenu, for: application); app.mainMenu = menu
        DispatchQueue.main.async { window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true) }
        var lastID = -1
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      command["token"] as? String == token,
                      let id = command["id"] as? Int, id != lastID else { return }
                lastID = id
                if command["quit"] as? Bool == true { app.terminate(nil); return }
                if let value = command["value"] as? String { field.string = value }
                if command["focus"] as? Bool == true {
                    app.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
                }
                if let location = command["location"] as? Int {
                    field.setSelectedRange(NSRange(location: location, length: command["length"] as? Int ?? 0))
                }
                if let frame = command["overlayFrame"] as? [Double], frame.count == 4 {
                    overlay.setFrame(NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), display: false)
                }
                if let level = command["overlayLevel"] as? Int { overlay.level = NSWindow.Level(rawValue: level) }
                if let show = command["overlay"] as? Bool {
                    if show { overlay.orderFrontRegardless() } else { overlay.orderOut(nil) }
                }
                if let show = command["dialog"] as? Bool {
                    if show, window.attachedSheet == nil {
                        window.beginSheet(dialog)
                        dialog.makeFirstResponder(dialogField)
                    } else if !show, window.attachedSheet != nil {
                        window.endSheet(dialog); dialog.orderOut(nil); window.makeFirstResponder(field)
                    }
                }
                if let fullScreen = command["fullScreen"] as? Bool,
                   fullScreen != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                let reply: [String: Any] = ["id": id, "token": token, "pid": ProcessInfo.processInfo.processIdentifier,
                    "values": [field.string], "locations": [field.selectedRange().location],
                    "active": app.isActive, "keyWindow": window.isKeyWindow,
                    "firstResponderIsField": window.firstResponder === field,
                    "keyWindowNumber": app.keyWindow?.windowNumber ?? -1,
                    "overlayWindowNumber": overlay.windowNumber, "fullScreen": state.fullScreenSettled,
                    "dialogWindowNumber": dialog.windowNumber,
                    "windowFrame": [window.frame.minX, (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.maxY,
                                    window.frame.width, window.frame.height]]
                try! JSONSerialization.data(withJSONObject: reply).write(to: directory.appendingPathComponent("reply.json"), options: .atomic)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime((window, overlay, dialog, timer, observers)) { app.run() }
    }
}
