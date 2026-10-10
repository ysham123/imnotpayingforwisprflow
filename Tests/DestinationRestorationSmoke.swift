import Foundation

@main
struct DestinationRestorationSmoke {
    enum Failure: Error { case moved, changed, interrupted, refused }
    struct Assertion: Error, CustomStringConvertible { let description: String }
    @MainActor
    static func main() async {
        do {
            try await exercise()
            print("Passed 8 destination restoration regression groups")
        } catch {
            fputs("FAIL \(error)\n", stderr); exit(1)
        }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Assertion(description: message) }
    }

    @MainActor
    static func exercise() async throws {
        var events: [String] = []
        var current = true, unchanged = true, interrupted = false
        var interruptAt: String?, refuseRestore = false, refuseFinal = false
        func barrier() throws { if interrupted { throw Failure.interrupted } }
        func prepare() async throws -> String {
            try await DestinationRestoration.prepare("original-field",
                check: barrier,
                validateCurrent: { field in
                    events.append("validate:\(field)")
                    await Task.yield()
                    if interruptAt == "current" { interrupted = true }
                    if !current || (refuseFinal && field == "restored-field") { throw Failure.moved }
                },
                validateOriginal: { field in
                    events.append("read:\(field)")
                    await Task.yield()
                    if !unchanged { throw Failure.changed }
                    if interruptAt == "read" { interrupted = true }
                },
                activate: {
                    events.append("activate")
                    await Task.yield()
                    if interruptAt == "activate" { interrupted = true }
                },
                restore: { field in
                    events.append("restore:\(field)")
                    await Task.yield()
                    if refuseRestore { throw Failure.refused }
                    if interruptAt == "restore" { interrupted = true }
                    current = true
                    return "restored-field"
                })
        }
        let untouched = try await prepare()
        try check(untouched == "original-field" && events == ["validate:original-field"], "Stable field was refocused")
        print("PASS unchanged focused destination avoids focus mutations")

        events = []; current = false
        let returned = try await prepare()
        try check(returned == "restored-field", "Restored target was discarded")
        try check(events == ["validate:original-field", "read:original-field", "activate", "restore:original-field", "validate:restored-field"],
                  "Original content was not checked before activation, or final validation was omitted")
        print("PASS switched focus returns only the original destination after content and final checks")

        events = []; current = false; unchanged = false
        do { _ = try await prepare(); throw Assertion(description: "Edited destination was accepted") }
        catch Failure.changed { }
        try check(events == ["validate:original-field", "read:original-field"], "Changed content caused a focus mutation")
        print("PASS changed or missing original aborts before activation")

        unchanged = true
        for point in ["current", "read", "activate", "restore"] {
            events = []; current = false; interrupted = false; interruptAt = point
            do { _ = try await prepare(); throw Assertion(description: "Input at \(point) was ignored") }
            catch Failure.interrupted { }
            let expectedCounts = ["current": 1, "read": 2, "activate": 3, "restore": 4]
            try check(events.count == expectedCounts[point], "Continued work after input at \(point): \(events)")
        }
        print("PASS new physical input stops delivery across all four async boundaries")

        events = []; current = true; interrupted = false; interruptAt = "current"
        do { _ = try await prepare(); throw Assertion(description: "Current-field validation swallowed input") }
        catch Failure.interrupted { }
        try check(events.count == 1, "Current-field interruption attempted restoration")
        print("PASS input during the fast path cannot fall through into restoration")

        events = []; current = false; interrupted = false; interruptAt = nil; refuseRestore = true
        do { _ = try await prepare(); throw Assertion(description: "Failed focus setter was accepted") }
        catch Failure.refused { }
        try check(events.last == "restore:original-field", "Continued after failed focus restoration")
        print("PASS unsupported restoration cannot reach paste handoff")

        events = []; current = false; refuseRestore = false; refuseFinal = true
        do { _ = try await prepare(); throw Assertion(description: "Final identity mismatch was accepted") }
        catch Failure.moved { }
        try check(events.last == "validate:restored-field", "Final restored field was not validated")
        print("PASS final identity mismatch fails without returning a deliverable target")

        events = []; refuseFinal = false
        let canceled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await prepare()
        }
        do { _ = try await canceled.value; throw Assertion(description: "Canceled request completed") }
        catch is CancellationError { }
        try check(events.isEmpty, "Already canceled work reached an operation")
        print("PASS canceled request performs no destination operations")
    }
}
