import AppKit
import CoreGraphics
import DictationCore
import Foundation

@main
struct PermissionSmoke {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        var tapCalls = 0
        var port: CFMachPort?
        var enables: [Bool] = []
        var allowed = false
        var createPort = false
        var createSource = false
        var enabled = false
        let environment = FnHotkey.ListenerEnvironment(permission: { allowed }, createTap: { _, _ in
            tapCalls += 1
            guard createPort else { return nil }
            var context = CFMachPortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            port = CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, &context, nil)
            return port
        }, createSource: { createSource ? CFMachPortCreateRunLoopSource(kCFAllocatorDefault, $0, 0) : nil },
        enable: { _, value in enables.append(value) }, enabled: { _ in enabled })
        let listener = FnHotkey(environment: environment)
        func startError() -> HotkeyStartError? {
            if case .failure(let error) = listener.startResult(onAction: { _ in fatalError("No fixture key events") }) { return error }
            return nil
        }
        check(startError() == .permissionDenied, "Denied input must report permission failure")
        check(tapCalls == 0 && !listener.isActive, "Denied input must not create a listener")
        allowed = true
        check(startError() == .eventTapUnavailable, "Allowed input with no tap must offer retry")
        check(listener.lastStartError == .eventTapUnavailable, "Keep precise startup failure")
        createPort = true
        check(startError() == .runLoopSourceUnavailable, "Run-loop creation failure must stay distinct")
        check(port != nil && !CFMachPortIsValid(port!), "Failed source must invalidate its port")
        createSource = true
        check(startError() == .eventTapDisabled, "A disabled tap must not claim readiness")
        check(!listener.isActive && enables.suffix(2) == [true, false], "Failed enable must release the tap")
        enabled = true
        check(startError() == nil && listener.isActive, "Retry can recover without changing grants")
        check(listener.lastStartError == nil, "Recovered listener must clear stale errors")
        listener.stop()
        check(!listener.isActive && !CFMachPortIsValid(port!), "Stop releases the recovered port")

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-permissions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("readiness.json")
        let diagnostics = PermissionDiagnostics(destination: file)
        let healthy = PermissionDiagnostics.Readiness(microphone: 3, accessibility: true, inputMonitoring: true,
                                                       listenerActive: true, listenerError: nil)
        diagnostics.record(healthy)
        diagnostics.record(healthy)
        func rows() throws -> [[String: Any]] {
            try JSONSerialization.jsonObject(with: diagnostics.export()) as! [[String: Any]]
        }
        check(try rows().count == 1, "Identical readiness must not flood diagnostics")
        for i in 0..<100 {
            diagnostics.record(.init(microphone: 3, accessibility: true, inputMonitoring: true,
                                     listenerActive: i.isMultiple(of: 2), listenerError: i.isMultiple(of: 2) ? nil : "event_tap_unavailable"))
        }
        let records = try rows()
        check(records.count == 64, "Persistent diagnostics must remain bounded")
        let permitted = Set(["date", "launch", "pid", "event", "bundlePath", "bundleIdentifier", "version", "build",
                             "executableSHA256", "codeHash", "designatedRequirement", "readiness"])
        check(records.allSatisfy { Set($0.keys).isSubset(of: permitted) }, "Diagnostics must contain only installation and readiness fields")
        let readinessKeys = Set(["microphone", "accessibility", "inputMonitoring", "listenerActive", "listenerError"])
        check(records.allSatisfy { Set(($0["readiness"] as! [String: Any]).keys).isSubset(of: readinessKeys) }, "No input or transcript fields")
        check((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              "Only the owner may read diagnostics")
        let reopened = PermissionDiagnostics(destination: file)
        reopened.record(healthy)
        check(try rows().count == 64, "A new launch must preserve bounded history")
        check((try rows().last?["launch"] as? String) != (records.last?["launch"] as? String), "Each launch has its own identifier")
        try Data("corrupt fixture".utf8).write(to: file)
        reopened.record(healthy, event: .listenerRetry, force: true)
        check(try rows().count == 1, "Malformed old diagnostics must never block recording")
        print("Passed \(checks) listener fault, recovery, and private diagnostics checks")
    }
}
