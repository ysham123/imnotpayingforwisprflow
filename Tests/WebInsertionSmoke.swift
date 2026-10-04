import AppKit
import ApplicationServices

@main struct WebInsertionSmoke {
    @MainActor static func main() {
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--check-permission" {
            if TextInserter.accessibilityGranted() { exit(0) }
            fputs("Synthetic web insertion runner needs Accessibility permission. No fixture was opened and no user apps were inspected.\n", stderr)
            exit(2)
        }
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let app = NSApplication.shared
        setbuf(stdout, nil)
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("Passed 16 synthetic \(engine) insertion regressions"); exit(0) }
            catch { fputs("WEB INSERTION TEST FAILED: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor static var sequence = 0
    @MainActor static var fixturePID: pid_t = 0
    @MainActor static var remoteElementObserved = false
    @MainActor static var engine = "web"
    static var directory: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
    static var token: String { CommandLine.arguments[2] }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }

    @MainActor static func command(_ properties: [String: Any]) async throws -> [String: Any] {
        sequence += 1
        var request = properties; request["id"] = sequence; request["token"] = token
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("reply.json")),
               let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               reply["id"] as? Int == sequence, reply["token"] as? String == token {
                guard reply["error"] == nil, let reportedPID = reply["pid"] as? Int else {
                    throw NSError(domain: "Fixture command failed", code: 1)
                }
                if fixturePID == 0 { fixturePID = pid_t(reportedPID) }
                try check(fixturePID == pid_t(reportedPID), "Fixture process changed")
                if let reportedEngine = reply["engine"] as? String {
                    try check(["WebKit", "Electron"].contains(reportedEngine), "Unknown synthetic fixture engine")
                    engine = reportedEngine
                }
                return reply
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "Web fixture timeout", code: 1)
    }

    @MainActor static func requireFixtureFocus() throws {
        try check(fixturePID > 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID,
                  "Synthetic fixture is not frontmost; abort without inspecting another app")
    }

    @MainActor static func seed(_ field: String, _ value: String, location: Int, length: Int = 0) async throws {
        var reply = try await command(["field": field, "value": value, "location": location, "length": length, "focus": true])
        try await Task.sleep(nanoseconds: 200_000_000)
        // LaunchServices and window activation can settle later than the DOM
        // focus command. Wait on our fixture's own state, without warming AX.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID,
               reply["appActive"] as? Bool == true, reply["keyWindow"] as? Bool == true { break }
            reply = try await command(["focus": true])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(reply["appActive"] as? Bool == true && reply["keyWindow"] as? Bool == true,
                  "Synthetic fixture window did not become active; no AX inspection performed")
        try requireFixtureFocus()
    }

    @MainActor static func capture(_ inserter: TextInserter) throws -> TextInserter.Target {
        try requireFixtureFocus()
        let target = try inserter.captureTarget(expectedProcessIdentifier: fixturePID)
        try check(target.processIdentifier == fixturePID, "Target escaped fixture application")
        if let element = target.focusedElement {
            var elementPID: pid_t = 0
            if AXUIElementGetPid(element, &elementPID) == .success && elementPID != fixturePID {
                remoteElementObserved = true
            }
        }
        return target
    }

    /// Diagnose synthetic focus metadata only. Follow the fixture application's
    /// explicit focus and parent links; never search windows or other apps and
    /// never read AXValue/AXSelectedText or text-marker bytes.
    @MainActor static func inspectFixtureFocusMetadata() throws {
        try requireFixtureFocus()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func read(_ name: String, _ element: AXUIElement) throws -> (AXError, CFTypeRef?) {
            try requireFixtureFocus()
            guard ProcessInfo.processInfo.systemUptime < deadline else { return (.cannotComplete, nil) }
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (status, value)
        }
        func link(_ name: String, _ element: AXUIElement) throws -> AXUIElement? {
            let (status, value) = try read(name, element)
            guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func summary(_ element: AXUIElement, label: String) throws {
            try requireFixtureFocus()
            var pid: pid_t = 0
            let pidStatus = AXUIElementGetPid(element, &pid)
            let (roleStatus, role) = try read(kAXRoleAttribute, element)
            let (subroleStatus, subrole) = try read(kAXSubroleAttribute, element)
            var valueWritable = DarwinBoolean(false), rangeWritable = DarwinBoolean(false)
            let valueStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueWritable)
            let rangeStatus = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeWritable)
            let (selectionStatus, selection) = try read(kAXSelectedTextRangeAttribute, element)
            var rangeDescription = "unavailable"
            if let selection, CFGetTypeID(selection) == AXValueGetTypeID() {
                let value = selection as! AXValue
                var range = CFRange()
                if AXValueGetType(value) == .cfRange && AXValueGetValue(value, .cfRange, &range) {
                    rangeDescription = "\(range.location):\(range.length)"
                }
            }
            var flags: [String] = []
            for name in ["AXEditable", "AXReadOnly", kAXEnabledAttribute, "AXProtected"] {
                let (status, value) = try read(name, element)
                let description = (value as? Bool).map(String.init) ?? "absent"
                flags.append("\(name)=\(description)(\(status.rawValue))")
            }
            print("SYNTHETIC AX \(label): pid=\(pid)(\(pidStatus.rawValue)) role=\(role as? String ?? "absent")(\(roleStatus.rawValue)) subrole=\(subrole as? String ?? "absent")(\(subroleStatus.rawValue)) valueSettable=\(valueWritable.boolValue)(\(valueStatus.rawValue)) rangeSettable=\(rangeWritable.boolValue)(\(rangeStatus.rawValue)) selectedRange=\(rangeDescription)(\(selectionStatus.rawValue)) \(flags.joined(separator: " "))")
        }
        let app = AXUIElementCreateApplication(fixturePID)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var leaf = try link(kAXFocusedUIElementAttribute, app)
        if leaf == nil, let window = try link(kAXFocusedWindowAttribute, app) {
            leaf = try link(kAXFocusedUIElementAttribute, window)
        }
        guard var current = leaf else { print("SYNTHETIC AX fixture exposed no explicit focused element"); return }
        var visited: [AXUIElement] = []
        for depth in 0..<6 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  !visited.contains(where: { CFEqual($0, current) }) else { break }
            visited.append(current)
            try summary(current, label: "focus[\(depth)]")
            guard let next = try link(kAXFocusedUIElementAttribute, current), !CFEqual(next, current) else { break }
            current = next
        }
        visited.removeAll()
        for depth in 0..<8 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  !visited.contains(where: { CFEqual($0, current) }) else { break }
            visited.append(current)
            try summary(current, label: "parent[\(depth)]")
            guard let next = try link(kAXParentAttribute, current), !CFEqual(next, current) else { break }
            current = next
        }
    }

    @MainActor static func expectValue(_ field: String, _ expected: String, pasteCount: Int = 1) async throws {
        let reply = try await command([:])
        let actual = (reply["values"] as? [String: String])?[field]
        try check(actual == expected, "Incorrect synthetic \(field) contents: expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
        try check((reply["pasteCounts"] as? [String: Int])?[field] == pasteCount, "Synthetic \(field) received an unexpected number of paste events")
    }

    @MainActor static func paste(_ inserter: TextInserter, field: String, original: String,
                                 location: Int, length: Int = 0, text: String, expected: String) async throws {
        try await seed(field, original, location: location, length: length)
        let target = try capture(inserter)
        if !target.canInsertAutomatically {
            let reply = try await command([:])
            print("SYNTHETIC \(engine) focus: activeField=\(reply["active"] ?? "absent") appActive=\(reply["appActive"] ?? "absent") keyWindow=\(reply["keyWindow"] ?? "absent")")
            try inspectFixtureFocusMetadata()
        }
        try check(target.canInsertAutomatically, "Synthetic \(field) was not discovered as editable")
        if field == "generic", let element = target.focusedElement {
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            print("Generic synthetic editor: role=\(target.role), AXValue writable=\(status == .success && settable.boolValue)")
        }
        _ = try await inserter.insert(text: text, into: target)
        try await expectValue(field, expected)
    }

    @MainActor static func run() async throws {
        guard TextInserter.accessibilityGranted() else {
            throw NSError(domain: "Synthetic test runner needs Accessibility permission; no user apps were inspected", code: 1)
        }
        _ = try await command([:])
        try await seed("input", "", location: 0)
        let inserter = TextInserter(), board = NSPasteboard.general
        // Save bytes only for restoration. Assertions below read only clipboard
        // contents seeded by this fixture, and never print clipboard data.
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem(); for (type, data) in entries { item.setData(data, forType: type) }; return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        board.clearContents(); board.setString("synthetic clipboard sentinel", forType: .string)

        try await paste(inserter, field: "input", original: "🙂 café end", location: 8, text: "TEST ", expected: "🙂 café TEST end")
        print("PASS \(engine) input Unicode caret")
        try await paste(inserter, field: "textarea", original: "before wrong after", location: 7, length: 5, text: "right", expected: "before right after")
        print("PASS \(engine) textarea selection replacement")
        try await paste(inserter, field: "rich", original: "hello ", location: 6, text: "world", expected: "hello world")
        print("PASS ARIA contenteditable")
        try await paste(inserter, field: "plain", original: "plain ", location: 6, text: "editor", expected: "plain editor")
        print("PASS contenteditable without ARIA textbox role")
        try await paste(inserter, field: "generic", original: "group ", location: 6, text: "editor", expected: "group editor")
        print("PASS explicitly generic group contenteditable")
        try await paste(inserter, field: "nested", original: "before wrong after", location: 7, length: 5, text: "right", expected: "before right after")
        print("PASS selection across nested inline spans")
        try await paste(inserter, field: "rich", original: "line one\nline two", location: 17, text: "\nline three", expected: "line one\nline two\nline three")
        print("PASS multiline contenteditable")
        try await paste(inserter, field: "rich", original: "same text", location: 0, length: 4, text: "same", expected: "same text")
        print("PASS identical rich-editor replacement without duplicate paste")
        try await paste(inserter, field: "delayedDOM", original: "wait ", location: 5, text: "complete", expected: "wait complete")
        print("PASS delayed DOM/AX update after 1.6 seconds")
        try await paste(inserter, field: "delayedRead", original: "clipboard ", location: 10, text: "read", expected: "clipboard read")
        let deferred = try await command([:])
        try check(deferred["nativeDeferredRequests"] as? Int == 1, "Delayed native clipboard read dispatched more than once")
        try check(board.string(forType: .string) == "synthetic clipboard sentinel", "Synthetic clipboard was not restored")
        print("PASS native clipboard consumption after 1.6 seconds and restoration")

        try await seed("readonly", "cannot edit", location: 0)
        let readonly = try capture(inserter)
        try check(!readonly.canInsertAutomatically, "Read-only web field accepted")
        try await expectValue("readonly", "cannot edit", pasteCount: 0)
        print("PASS read-only web field rejection")
        try await seed("readonlyTextbox", "cannot edit", location: 0)
        let readonlyTextbox = try capture(inserter)
        try check(!readonlyTextbox.canInsertAutomatically, "Read-only ARIA textbox accepted")
        try await expectValue("readonlyTextbox", "cannot edit", pasteCount: 0)
        print("PASS read-only ARIA textbox with visible DOM selection rejection")
        try await seed("password", "", location: 0)
        do { _ = try capture(inserter); throw NSError(domain: "Password web field accepted", code: 1) }
        catch TextInserter.InsertionError.secureField { }
        try await expectValue("password", "", pasteCount: 0)
        print("PASS password web field rejection")
        try await seed("rich", "same", location: 4)
        let changed = try capture(inserter)
        try await seed("plain", "same", location: 4)
        do { _ = try await inserter.insert(text: "oops", into: changed); throw NSError(domain: "Other rich field accepted", code: 1) }
        catch TextInserter.InsertionError.targetChanged { }
        try await expectValue("plain", "same", pasteCount: 0)
        print("PASS identical different web field rejection")
        for field in ["input", "rich"] {
            try await seed(field, "anchor ", location: 7)
            inserter.primeFrontmostAccessibility()
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let anchor = inserter.beginCapture(expectedProcessIdentifier: fixturePID) else {
                throw NSError(domain: "Warm synthetic \(engine) \(field) identity anchor unavailable", code: 1)
            }
            let pinned = try await inserter.inspect(anchor)
            var dispatched = 0, verified = 0
            _ = try await inserter.insert(text: "placed", into: pinned,
                onDispatched: { dispatched += 1 }, onVerified: { verified += 1 })
            try await expectValue(field, "anchor placed", pasteCount: 1)
            try check(dispatched == 1, "Anchored web placement dispatched repeatedly")
            // Marker-only editors may lack a value/range API for verification;
            // DOM acceptance above still proves one owned-fixture insertion.
            try check(verified <= 1, "Anchored web verification callback repeated")
            print("PASS \(engine) asynchronous pinned \(field) capture and explicit placement")
        }
        print(remoteElementObserved ? "Observed and validated remote \(engine) editor process" : "\(engine) editor was presented under fixture application PID on this macOS version")
    }
}
