import AppKit

@main struct InsertionSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        setbuf(stdout, nil)
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("Passed 11 native insertion/clipboard regressions"); exit(0) }
            catch { fputs("INSERTION TEST FAILED: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    static func check(_ value: Bool, _ message: String = "Assertion failed") throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    @MainActor static var sequence = 0
    @MainActor static var fixturePID: pid_t = 0
    static var directory: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
    @MainActor static func command(_ properties: [String: Any]) async throws -> [String: Any] {
        sequence += 1
        var request = properties; request["id"] = sequence
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("reply.json")),
               let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["id"] as? Int == sequence {
                fixturePID = pid_t(reply["pid"] as! Int)
                return reply
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "Fixture timeout", code: 1)
    }
    @MainActor static func seed(_ value: String, location: Int, length: Int = 0, field: Int = 0, editable: Bool = true) async throws {
        _ = try await command(["field": field, "value": value, "location": location, "length": length, "focus": true, "editable": editable])
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID, "Fixture is not frontmost; abort without inspecting another app")
    }
    @MainActor static func run() async throws {
        guard TextInserter.accessibilityGranted() else { throw NSError(domain: "Test runner needs Accessibility", code: 1) }
        let inserter = TextInserter(), board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            board.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem(); for (type, data) in entries { item.setData(data, forType: type) }; return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        func capture() throws -> TextInserter.Target {
            try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID)
            return try inserter.captureTarget()
        }
        let rich = NSPasteboardItem(); rich.setString("original clipboard", forType: .string)
        rich.setData(Data([1,2,3]), forType: .init("org.localdictation.test"))
        let extra = NSPasteboardItem(); extra.setString("second item", forType: .string)
        board.clearContents(); board.writeObjects([rich, extra])
        try await seed("🙂 café end", location: 8)
        let result = try await inserter.insert(text: "TEST ", into: capture())
        try check(result == .verified)
        let reply = try await command([:])
        try check((reply["values"] as! [String])[0] == "🙂 café TEST end")
        try check(board.pasteboardItems?.count == 2 && board.data(forType: .init("org.localdictation.test")) == Data([1,2,3]))
        print("PASS Unicode caret and rich clipboard restoration")
        try await seed("before wrong after", location: 7, length: 5)
        let replaced = try await inserter.insert(text: "right", into: capture())
        try check(replaced == .verified)
        print("PASS selection replacement")
        try await seed("same text", location: 0, length: 4)
        let identical = try await inserter.insert(text: "same", into: capture())
        try check(identical == .verified)
        print("PASS identical replacement")
        try await seed("hello", location: 5)
        let moved = try capture()
        _ = try await command(["location": 0])
        do { try await inserter.insert(text: "oops", into: moved); throw NSError(domain: "Moved caret accepted", code: 1) } catch TextInserter.InsertionError.targetChanged { }
        print("PASS moved caret rejection")
        try await seed("hello", location: 5)
        let different = try capture()
        try await seed("hello", location: 5, field: 1)
        do { try await inserter.insert(text: "oops", into: different); throw NSError(domain: "Different field accepted", code: 1) } catch TextInserter.InsertionError.targetChanged { }
        print("PASS identical other field rejection")
        try await seed("", location: 0, field: 3)
        do { _ = try capture(); throw NSError(domain: "Secure field accepted", code: 1) } catch TextInserter.InsertionError.secureField { }
        print("PASS secure field rejection")
        try await seed("read only", location: 0, editable: false)
        let readOnly = try capture()
        try check(!readOnly.canInsertAutomatically)
        print("PASS read-only recovery")
        try await seed("refused", location: 7, field: 2)
        do { try await inserter.insert(text: "oops", into: capture()); throw NSError(domain: "Refused paste verified", code: 1) } catch TextInserter.InsertionError.pasteNotAccepted { }
        print("PASS refused paste detection")
        try await seed("", location: 0)
        let destination = try capture()
        let external = Task { @MainActor in
            try await Task.sleep(nanoseconds: 350_000_000)
            board.clearContents(); board.setString("external copy", forType: .string)
        }
        _ = try await inserter.insert(text: "one", into: destination)
        _ = try await external.value
        try check(board.string(forType: .string) == "external copy")
        print("PASS external clipboard ownership")
        try await seed("", location: 0)
        let firstTarget = try capture()
        let pending = Task { @MainActor in try await inserter.insert(text: "one", into: firstTarget) }
        try await Task.sleep(nanoseconds: 300_000_000)
        pending.cancel()
        do { try await inserter.insert(text: "two", into: firstTarget); throw NSError(domain: "Overlapping paste accepted", code: 1) } catch TextInserter.InsertionError.pasteInProgress { }
        await inserter.waitForPendingPaste()
        try check(!inserter.hasPendingPaste && board.string(forType: .string) == "external copy")
        _ = try await pending.value
        try check(board.string(forType: .string) == "external copy")
        print("PASS cancellation restoration and overlapping transaction rejection")
    }
}
