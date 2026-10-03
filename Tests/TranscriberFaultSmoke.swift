import Foundation
import Darwin

@main struct TranscriberFaultSmoke {
    static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = resources.appendingPathComponent("mode")
        for fault in ["startup", "stall", "oversized", "malformed", "eof"] {
            try fault.write(to: mode, atomically: true, encoding: .utf8)
            let engine = WhisperTranscriber(resources: resources, startupTimeout: 0.7, requestTimeout: 0.7)
            let started = ProcessInfo.processInfo.systemUptime
            do {
                if fault == "startup" { try await engine.prepare() }
                else { _ = try await engine.transcribe(Array(repeating: 0.1, count: 200_000)) }
                fatalError("Fault \(fault) was accepted")
            } catch { }
            precondition(ProcessInfo.processInfo.systemUptime - started < 3, "Fault was not bounded")
            let pid = Int32(try String(contentsOf: resources.appendingPathComponent("pid")).trimmingCharacters(in: .whitespacesAndNewlines))!
            try await Task.sleep(nanoseconds: 800_000_000)
            precondition(kill(pid, 0) != 0, "Failed worker was not terminated")
            try "healthy".write(to: mode, atomically: true, encoding: .utf8)
            let recovered = try await engine.transcribe([0.1])
            precondition(recovered == "recovered")
            engine.shutdown()
            print("PASS \(fault) is bounded, terminated, and recoverable")
        }
        print("Passed 5 speech worker fault regressions")
    }
}
