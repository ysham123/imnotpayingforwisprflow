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

        // A rejected model response must not restart an otherwise healthy child.
        let beforeRejection = try startCount()
        let rejectionMarker = resources.appendingPathComponent("reject-output")
        try Data().write(to: rejectionMarker)
        do {
            _ = try await client.clean("Do not delete the file.")
            fatalError("Expected an unsafe correction to be rejected")
        } catch {
            precondition(!LocalCorrectionService.shouldRecover(after: error), "Validation rejection requested recovery")
        }
        try FileManager.default.removeItem(at: rejectionMarker)
        let unchanged = try await client.clean("Hello.")
        precondition(unchanged == "Hello." && tryCount(startCount) == beforeRejection)
        let nonRecoverable: [Error] = [CleanupError.inputTooLong, CleanupError.invalidResponse,
                                     CleanupError.truncatedResponse, CleanupError.unrelatedResponse,
                                     CleanupError.changedProtectedText, CancellationError(), URLError(.cancelled)]
        for error in nonRecoverable {
            precondition(!LocalCorrectionService.shouldRecover(after: error))
        }
        precondition(LocalCorrectionService.shouldRecover(after: CleanupError.timedOut))

        // Simulate an app-owned helper dying after readiness was established.
        // A new successful correction must come from a newly launched child.
        let exitedPID = Int32(try String(contentsOf: resources.appendingPathComponent("pid")).trimmingCharacters(in: .whitespacesAndNewlines))!
        precondition(kill(exitedPID, SIGKILL) == 0)
        for _ in 0..<100 {
            if kill(exitedPID, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(kill(exitedPID, 0) != 0, "Injected child exit did not complete")
        do {
            _ = try await client.clean("Hello.")
            fatalError("A dead service unexpectedly corrected text")
        } catch {
            precondition(LocalCorrectionService.shouldRecover(after: error), "Helper exit did not request recovery")
        }
        try await service.rewarm()
        let afterExit = try await client.clean("Hello.")
        precondition(afterExit == "Hello." && tryCount(startCount) == beforeRejection + 1,
                     "Failed correction did not recover with a replacement helper")
        await service.suspend()
        print("Passed 6 correction lifecycle regressions: shared start, bounded suspend, immediate rewarm, canceled-start recovery, rejection classification, exited-child recovery")
    }

    static func tryCount(_ operation: () throws -> Int) -> Int {
        do { return try operation() } catch { fatalError("Missing service lifecycle marker") }
    }
}
