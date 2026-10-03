import Foundation

@MainActor
final class LocalCorrectionService {
    static let endpoint = URL(string: "http://127.0.0.1:11437")!
    private var process: Process?
    private let resources: URL
    init(resources: URL) { self.resources = resources }

    func start() async throws {
        let client = CleanupClient(baseURL: Self.endpoint)
        if await client.isAvailable() { return }
        let executable = resources.appendingPathComponent("ollama")
        let models = resources.appendingPathComponent("Models/ollama")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: models.path) else {
            throw DictationError.message("The bundled correction model is missing. Restore the complete app.")
        }
        let task = Process()
        task.executableURL = executable; task.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:11437"
        env["OLLAMA_MODELS"] = models.path
        env["OLLAMA_KEEP_ALIVE"] = "10m"
        env["OLLAMA_NUM_PARALLEL"] = "1"
        env["OLLAMA_NO_CLOUD"] = "1"
        env["OLLAMA_NOPRUNE"] = "1"
        task.environment = env
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); process = task
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        do {
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                if await client.isAvailable() { return }
                if !task.isRunning { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch {
            stop()
            throw error
        }
        stop()
        throw DictationError.message("Local correction could not start. Check that another app is not using port 11437.")
    }

    func stop() { if process?.isRunning == true { process?.terminate() }; process = nil }
}
