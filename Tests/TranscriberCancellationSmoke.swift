import Foundation

@main struct TranscriberCancellationSmoke {
    static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let log = resources.appendingPathComponent("Models/ggml-large-v3-turbo-q8_0.bin.log")
        let engine = WhisperTranscriber(resources: resources)
        defer { engine.shutdown() }

        let preCanceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.transcribe([0.1])
        }
        do { _ = try await preCanceled.value; fatalError("Pre-canceled request ran") }
        catch is CancellationError { }
        precondition(!FileManager.default.fileExists(atPath: log.path))

        // Occupy the serial queue while a second request waits behind model startup.
        let preparation = Task { try await engine.prepare() }
        try await waitFor("start", in: log)
        let queued = Task { try await engine.transcribe([0.1]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        queued.cancel(); engine.cancel()
        do { _ = try await queued.value; fatalError("Canceled queued request ran") }
        catch is CancellationError { }
        _ = try? await preparation.value
        let firstLog = try String(contentsOf: log)
        precondition(firstLog.components(separatedBy: "start\n").count - 1 == 1,
                     "Canceled queued work restarted the worker")
        precondition(!firstLog.contains("infer"), "Canceled queued work ran inference")

        let recovered = try await engine.transcribe([0.1])
        precondition(recovered == "recognized speech")

        let running = Task { try await engine.transcribe([0.2]) }
        try await waitFor("infer\ninfer", in: log)
        running.cancel(); engine.cancel()
        do { _ = try await running.value; fatalError("Canceled running request succeeded") }
        catch { }
        let recoveredAgain = try await engine.transcribe([0.3])
        precondition(recoveredAgain == "recognized speech")
        await engine.suspend()
        try await engine.rewarm()
        let afterSuspend = try await engine.transcribe([0.4])
        precondition(afterSuspend == "recognized speech")

        // Cancellation of a preparation queued behind an active request must
        // not revive the old worker or leave unread bytes on the new pipe.
        let request = Task { try await engine.transcribe([0.5]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let stalePreparation = Task { try await engine.prepare() }
        stalePreparation.cancel()
        _ = try? await request.value
        do { try await stalePreparation.value; fatalError("Canceled preparation succeeded") }
        catch is CancellationError { }
        try await engine.rewarm()
        let afterStalePreparation = try await engine.transcribe([0.6])
        precondition(afterStalePreparation == "recognized speech")
        precondition(engine.lastTiming != nil)
        print("Passed 6 cancellation/recovery scenarios, including suspend/rewarm and stale preparation")
    }

    static func waitFor(_ text: String, in log: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? String(contentsOf: log).contains(text)) == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        fatalError("Timed out waiting for worker test marker: \(text)")
    }
}
