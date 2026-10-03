import AppKit

class CountingTextView: NSTextView {
    var pasteCount = 0
    override func paste(_ sender: Any?) { pasteCount += 1; super.paste(sender) }
}
final class RefusingTextView: CountingTextView {
    override func paste(_ sender: Any?) { pasteCount += 1 }
}
final class StagedReadTextView: CountingTextView {
    var actOnStagedValueRead: (() -> Void)?
    var stagedReadActions = 0

    override func accessibilityValue() -> String? {
        let value = super.accessibilityValue()
        // Arm only after target capture, and trigger only after the inserter
        // stages its clipboard item. Earlier validation must retain focus.
        if let action = actOnStagedValueRead,
           NSApplication.shared.isActive, window?.firstResponder === self,
           NSPasteboard.general.types?.contains(.init("org.localdictation.paste-session")) == true {
            actOnStagedValueRead = nil
            stagedReadActions += 1
            action()
        }
        return value
    }
}

@main struct InsertionFixture {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let token = CommandLine.arguments[2]
        let identity: [String: Any] = ["token": token, "pid": ProcessInfo.processInfo.processIdentifier]
        try! JSONSerialization.data(withJSONObject: identity).write(to: directory.appendingPathComponent("fixture.json"), options: .atomic)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 620, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Local Dictation test fixture"
        let first = StagedReadTextView(frame: NSRect(x: 20, y: 290, width: 580, height: 100))
        let second = CountingTextView(frame: NSRect(x: 20, y: 170, width: 580, height: 100))
        let refusing = RefusingTextView(frame: NSRect(x: 20, y: 70, width: 580, height: 80))
        let secure = NSSecureTextField(frame: NSRect(x: 20, y: 25, width: 280, height: 28))
        for view in [first, second, refusing] { view.font = .systemFont(ofSize: 18); window.contentView!.addSubview(view) }
        window.contentView!.addSubview(secure)
        let main = NSMenu()
        let application = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Fixture")
        applicationMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(application); main.setSubmenu(applicationMenu, for: application)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); let submenu = NSMenu(title: "Edit")
        submenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        main.addItem(edit); main.setSubmenu(submenu, for: edit); app.mainMenu = main
        // Show and activate after the event loop starts, so launch events and
        // subsequent fixture focus commands follow the same ordering.
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
        var pasteKeyEvents = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.charactersIgnoringModifiers?.lowercased() == "v", event.modifierFlags.contains(.command) {
                pasteKeyEvents += 1
            }
            return event
        }
        var lastID = -1
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      command["token"] as? String == token,
                      let id = command["id"] as? Int, id != lastID else { return }
                lastID = id
                if command["quit"] as? Bool == true { app.terminate(nil); return }
                let field = command["field"] as? Int ?? 0
                let views = [first, second, refusing]
                if let value = command["value"] as? String, field < views.count {
                    views[field].string = value; views[field].pasteCount = 0
                }
                if let editable = command["editable"] as? Bool, field < views.count { views[field].isEditable = editable }
                if command["focus"] as? Bool == true {
                    app.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(field == 3 ? secure : views[field])
                }
                if let location = command["location"] as? Int, field < views.count {
                    views[field].setSelectedRange(NSRange(location: location, length: command["length"] as? Int ?? 0))
                }
                if command["switchFocusOnStagedValueRead"] as? Bool == true {
                    first.stagedReadActions = 0
                    first.actOnStagedValueRead = { window.makeFirstResponder(second) }
                }
                if command["moveCaretOnStagedValueRead"] as? Bool == true {
                    first.stagedReadActions = 0
                    first.actOnStagedValueRead = { first.setSelectedRange(NSRange(location: 0, length: 0)) }
                }
                let reply: [String: Any] = ["id": id, "token": token, "pid": ProcessInfo.processInfo.processIdentifier,
                    "values": views.map { $0.string }, "locations": views.map { $0.selectedRange().location },
                    "pasteCounts": views.map { $0.pasteCount }, "pasteKeyEvents": pasteKeyEvents,
                    "stagedReadActions": first.stagedReadActions,
                    "active": app.isActive, "keyWindow": window.isKeyWindow,
                    "firstResponderIsField": field < views.count ? window.firstResponder === views[field] : window.firstResponder === secure]
                try! JSONSerialization.data(withJSONObject: reply).write(to: directory.appendingPathComponent("reply.json"), options: .atomic)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime((window, timer, monitor)) { app.run() }
    }
}
