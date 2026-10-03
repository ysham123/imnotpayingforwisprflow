import AppKit

@main struct InsertionSmoke {
    @MainActor static func main() {
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--check-permission" {
            if TextInserter.accessibilityGranted() { exit(0) }
            fputs("Synthetic native runner needs Accessibility permission. No fixture was opened and no user apps were inspected.\n", stderr)
            exit(2)
        }
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let app = NSApplication.shared
        setbuf(stdout, nil)
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("Passed 13 native insertion/clipboard regressions"); exit(0) }
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
    static var token: String { CommandLine.arguments[2] }
    @MainActor static func command(_ properties: [String: Any]) async throws -> [String: Any] {
        sequence += 1
        var request = properties; request["id"] = sequence; request["token"] = token
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("reply.json")),
               let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               reply["id"] as? Int == sequence, reply["token"] as? String == token,
               let reportedPID = reply["pid"] as? Int {
                if fixturePID == 0 { fixturePID = pid_t(reportedPID) }
                try check(fixturePID == pid_t(reportedPID), "Fixture process changed")
                return reply
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "Fixture timeout", code: 1)
    }
    @MainActor static func seed(_ value: String, location: Int, length: Int = 0, field: Int = 0, editable: Bool = true) async throws {
        var reply = try await command(["field": field, "value": value, "location": location, "length": length, "focus": true, "editable": editable])
        try await Task.sleep(nanoseconds: 150_000_000)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID,
               reply["active"] as? Bool == true, reply["keyWindow"] as? Bool == true { break }
            reply = try await command(["field": field, "focus": true])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(reply["active"] as? Bool == true && reply["keyWindow"] as? Bool == true,
                  "Fixture window is not active; no AX inspection performed")
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
            return try inserter.captureTarget(expectedProcessIdentifier: fixturePID)
        }
        let rich = NSPasteboardItem(); rich.setString("original clipboard", forType: .string)
        rich.setData(Data([1,2,3]), forType: .init("org.localdictation.test"))
        let extra = NSPasteboardItem(); extra.setString("second item", forType: .string)
        board.clearContents(); board.writeObjects([rich, extra])
        try await seed("🙂 café end", location: 8)
        let unicodeTarget = try capture()
        let result = try await inserter.insert(text: "TEST ", into: unicodeTarget)
        let reply = try await command([:])
        try check(result == .verified, "Unicode insertion unconfirmed in own fixture: \(reply)")
        try check((reply["values"] as! [String])[0] == "🙂 café TEST end")
        try check((reply["pasteCounts"] as! [Int])[0] == 1, "Unicode insertion dispatched multiple pastes")
        try check(board.pasteboardItems?.count == 2 && board.data(forType: .init("org.localdictation.test")) == Data([1,2,3]))
        print("PASS Unicode caret and rich clipboard restoration")
        try await seed("before wrong after", location: 7, length: 5)
        let replaced = try await inserter.insert(text: "right", into: capture())
        let replacementReply = try await command([:])
        try check(replaced == .verified, "Selection insertion unconfirmed in own fixture: \(replacementReply)")
        try check((replacementReply["pasteCounts"] as! [Int])[0] == 1, "Selection replacement repeated paste")
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
        try await seed("destination untouched", location: 21, field: 1)
        try await seed("source untouched", location: 16)
        let racing = try capture()
        let raceClipboard = NSPasteboardItem()
        raceClipboard.setString("focus race clipboard", forType: .string)
        raceClipboard.setData(Data([4, 5, 6]), forType: .init("org.localdictation.test"))
        let raceExtra = NSPasteboardItem(); raceExtra.setString("focus race second item", forType: .string)
        board.clearContents(); board.writeObjects([raceClipboard, raceExtra])
        func clipboardBytes() -> [[String: Data]] {
            (board.pasteboardItems ?? []).map { item in
                item.types.reduce(into: [String: Data]()) { contents, type in
                    if let data = item.data(forType: type) { contents[type.rawValue] = data }
                }
            }
        }
        let expectedClipboard = clipboardBytes()
        let armed = try await command(["switchFocusOnStagedValueRead": true])
        let previousPasteKeyEvents = armed["pasteKeyEvents"] as! Int
        do {
            try await inserter.insert(text: "must not paste", into: racing)
            throw NSError(domain: "Focus changed during final validation was accepted", code: 1)
        } catch TextInserter.InsertionError.targetChanged { }
        let racingReply = try await command(["field": 1])
        try check(racingReply["stagedReadActions"] as? Int == 1, "Focus race was not injected after clipboard staging")
        try check(racingReply["firstResponderIsField"] as? Bool == true, "Focus race did not reach the second own editor")
        try check(racingReply["pasteKeyEvents"] as? Int == previousPasteKeyEvents, "Final validation race dispatched Command-V")
        try check((racingReply["pasteCounts"] as! [Int]).prefix(2).allSatisfy { $0 == 0 }, "Final validation race delivered a paste")
        try check((racingReply["values"] as! [String]).prefix(2).elementsEqual(["source untouched", "destination untouched"]), "Final validation race changed fixture text")
        try check(clipboardBytes() == expectedClipboard, "Final validation race did not restore all clipboard bytes")
        print("PASS focus switch during final AXValue validation rejects paste and restores clipboard")
        try await seed("source untouched", location: 16)
        let caretRacing = try capture()
        let caretArmed = try await command(["moveCaretOnStagedValueRead": true])
        let previousCaretPasteKeyEvents = caretArmed["pasteKeyEvents"] as! Int
        do {
            try await inserter.insert(text: "must not paste", into: caretRacing)
            throw NSError(domain: "Caret moved during final validation was accepted", code: 1)
        } catch TextInserter.InsertionError.targetChanged { }
        let caretReply = try await command(["field": 0])
        try check(caretReply["stagedReadActions"] as? Int == 1, "Caret race was not injected after clipboard staging")
        try check(caretReply["firstResponderIsField"] as? Bool == true && (caretReply["locations"] as! [Int])[0] == 0,
                  "Caret race did not move selection inside the captured editor")
        try check(caretReply["pasteKeyEvents"] as? Int == previousCaretPasteKeyEvents, "Final validation caret race dispatched Command-V")
        try check((caretReply["pasteCounts"] as! [Int]).prefix(2).allSatisfy { $0 == 0 }, "Final validation caret race delivered a paste")
        try check((caretReply["values"] as! [String]).prefix(2).elementsEqual(["source untouched", "destination untouched"]), "Final validation caret race changed fixture text")
        try check(clipboardBytes() == expectedClipboard, "Final validation caret race did not restore all clipboard bytes")
        print("PASS caret move during final AXValue validation rejects paste and restores clipboard")
        try await seed("", location: 0, field: 3)
        do { _ = try capture(); throw NSError(domain: "Secure field accepted", code: 1) } catch TextInserter.InsertionError.secureField { }
        print("PASS secure field rejection")
        try await seed("read only", location: 0, editable: false)
        let readOnly = try capture()
        try check(!readOnly.canInsertAutomatically)
        print("PASS read-only recovery")
        try await seed("refused", location: 7, field: 2)
        let refused = try await inserter.insert(text: "oops", into: capture())
        try check(refused == .sentWithoutVerification, "Unchanged text must not prove paste failure or success")
        let refusedReply = try await command([:])
        try check((refusedReply["values"] as! [String])[2] == "refused")
        try check((refusedReply["pasteCounts"] as! [Int])[2] == 1, "Refused paste was retried")
        print("PASS unconfirmed paste preserves recovery without retry")
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
