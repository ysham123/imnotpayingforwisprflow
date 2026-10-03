import AppKit

final class RefusingTextView: NSTextView {
    override func paste(_ sender: Any?) { }
}

@main struct InsertionFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 620, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Local Dictation test fixture"
        let first = NSTextView(frame: NSRect(x: 20, y: 290, width: 580, height: 100))
        let second = NSTextView(frame: NSRect(x: 20, y: 170, width: 580, height: 100))
        let refusing = RefusingTextView(frame: NSRect(x: 20, y: 70, width: 580, height: 80))
        let secure = NSSecureTextField(frame: NSRect(x: 20, y: 25, width: 280, height: 28))
        for view in [first, second, refusing] { view.font = .systemFont(ofSize: 18); window.contentView!.addSubview(view) }
        window.contentView!.addSubview(secure)
        let main = NSMenu(); let edit = NSMenuItem(); let submenu = NSMenu(title: "Edit")
        submenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        main.addItem(edit); main.setSubmenu(submenu, for: edit); app.mainMenu = main
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        var lastID = -1
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = command["id"] as? Int, id != lastID else { return }
                lastID = id
                if command["quit"] as? Bool == true { app.terminate(nil); return }
                let field = command["field"] as? Int ?? 0
                let views = [first, second, refusing]
                if let value = command["value"] as? String, field < views.count { views[field].string = value }
                if let editable = command["editable"] as? Bool, field < views.count { views[field].isEditable = editable }
                if command["focus"] as? Bool == true {
                    app.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(field == 3 ? secure : views[field])
                }
                if let location = command["location"] as? Int, field < views.count {
                    views[field].setSelectedRange(NSRange(location: location, length: command["length"] as? Int ?? 0))
                }
                let reply: [String: Any] = ["id": id, "pid": ProcessInfo.processInfo.processIdentifier,
                    "values": views.map { $0.string }, "locations": views.map { $0.selectedRange().location }]
                try! JSONSerialization.data(withJSONObject: reply).write(to: directory.appendingPathComponent("reply.json"), options: .atomic)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime((window, timer)) { app.run() }
    }
}
