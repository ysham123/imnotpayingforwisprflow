import Foundation
import Darwin

@main struct CorrectionLifecycleSmoke {
    @MainActor static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let port = CommandLine.arguments[2]
        let service = LocalCorrectionService(resources: resources, endpoint: URL(string: "http://127.0.0.1:\(port)")!)
        let client = service.makeCleanupClient()
        let first = Task { try await service.start() }
        let second = Task { try await service.start() }
        try await first.value; try await second.value
        let starts = resources.appendingPathComponent("starts")
        func startCount() throws -> Int { try String(contentsOf: starts).split(separator: "\n").count }
        precondition(tryCount(startCount) == 1, "Concurrent start launched two servers")
        try await service.rewarm()
        let firstPID = Int32(try String(contentsOf: resources.appendingPathComponent("pid")).trimmingCharacters(in: .whitespacesAndNewlines))!
        await service.suspend()
        precondition(kill(firstPID, 0) != 0, "Suspend returned while old child was alive")
        try await service.rewarm()
        precondition(tryCount(startCount) == 2, "Immediate rewarm reused a retiring server")
        let result = try await client.clean("Hello.")
        precondition(result == "Hello.")
        await service.suspend()

        let canceled = Task { try await service.start() }
        try await Task.sleep(nanoseconds: 10_000_000)
        canceled.cancel(); await service.suspend()
        _ = try? await canceled.value
        try await service.rewarm()
        let recovered = try await client.clean("Hello.")
        precondition(recovered == "Hello.")
        await service.suspend()
        print("Passed 4 correction lifecycle regressions: shared start, bounded suspend, immediate rewarm, canceled-start recovery")
    }

    static func tryCount(_ operation: () throws -> Int) -> Int {
        do { return try operation() } catch { fatalError("Missing service lifecycle marker") }
    }
}
