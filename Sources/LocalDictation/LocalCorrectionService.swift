import Foundation
import Darwin

@MainActor
final class LocalCorrectionService {
    nonisolated static let endpoint = URL(string: "http://127.0.0.1:11437")!
    private var process: Process?
    private var retiring: [Process] = []
    private let resources: URL
    private let models: URL
    private let serviceEndpoint: URL
    private let lease: CorrectionServiceLease
    private var startTask: Task<Void, Error>?
    private var operationGeneration: UInt64 = 0

    init(resources: URL, models: URL? = nil, endpoint: URL = LocalCorrectionService.endpoint) {
        self.resources = resources; serviceEndpoint = endpoint
        self.models = models ?? resources.appendingPathComponent("Models")
        lease = CorrectionServiceLease(endpoint: endpoint)
    }

    func makeCleanupClient(model: String = "qwen3:4b") -> CleanupClient {
        CleanupClient(baseURL: serviceEndpoint, model: model, ownedServiceLease: lease)
    }

    func start() async throws {
        try Task.checkCancellation()
        if let startTask { try await startTask.value; try Task.checkCancellation(); return }
        let generation = operationGeneration
        let task = Task { try await self.startServer(generation: generation) }
        startTask = task
        defer { if operationGeneration == generation { startTask = nil } }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await task.value
            try Task.checkCancellation()
        }, onCancel: { task.cancel() })
    }

    func rewarm() async throws {
        let generation = operationGeneration
        try await start()
        try Task.checkCancellation()
        guard generation == operationGeneration else { throw CancellationError() }
        _ = try await makeCleanupClient().clean("This is a dictation warmup.")
        guard generation == operationGeneration else { throw CancellationError() }
    }

    /// Releases owned weights while preserving the server for a subsequent warmup.
    /// No unload is sent to a service owned by another application.
    func unloadModel() async throws { try await makeCleanupClient().unloadOwnedModel() }

    /// Stops only this app's child server and invalidates outstanding warmups.
    func suspend() async {
        stop()
        try? await drainRetiredProcesses(generation: operationGeneration)
    }

    private func startServer(generation: UInt64) async throws {
        let client = makeCleanupClient()
        try Task.checkCancellation()
        // A server receiving SIGTERM can still answer HTTP briefly. Do not
        // misclassify our retiring child as an external reusable service.
        try await drainRetiredProcesses(generation: generation)
        if await client.isAvailable() {
            try Task.checkCancellation()
            guard generation == operationGeneration else { throw CancellationError() }
            return
        }
        try Task.checkCancellation()
        guard generation == operationGeneration else { throw CancellationError() }
        // A failed health check for our old server must not leave a resident
        // runner behind or create a second child competing for the same port.
        terminateOwnedProcess()
        try await drainRetiredProcesses(generation: generation)
        let executable = resources.appendingPathComponent("ollama")
        let models = self.models.appendingPathComponent("ollama")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: models.path) else {
            throw DictationError.message("The correction engine or local model is missing. Retry model setup.")
        }
        let task = Process()
        task.executableURL = executable; task.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        guard serviceEndpoint.scheme == "http", serviceEndpoint.host == "127.0.0.1",
              let port = serviceEndpoint.port, serviceEndpoint.path.isEmpty,
              serviceEndpoint.user == nil, serviceEndpoint.password == nil,
              serviceEndpoint.query == nil, serviceEndpoint.fragment == nil else {
            throw DictationError.message("Correction requires an app-owned loopback endpoint.")
        }
        env["OLLAMA_HOST"] = "127.0.0.1:\(port)"
        env["OLLAMA_MODELS"] = models.path
        env["OLLAMA_KEEP_ALIVE"] = "-1"
        env["OLLAMA_NUM_PARALLEL"] = "1"
        env["OLLAMA_NO_CLOUD"] = "1"
        env["OLLAMA_NOPRUNE"] = "1"
        task.environment = env
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); process = task; lease.activate(task)
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        do {
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                guard generation == operationGeneration else { throw CancellationError() }
                if await client.isAvailable() {
                    try Task.checkCancellation()
                    guard generation == operationGeneration else { throw CancellationError() }
                    return
                }
                if !task.isRunning { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch {
            if generation == operationGeneration { terminateOwnedProcess() }
            throw error
        }
        if generation == operationGeneration { terminateOwnedProcess() }
        throw DictationError.message("Local correction could not start. Check that another app is not using port 11437.")
    }

    func stop() {
        operationGeneration &+= 1
        startTask?.cancel(); startTask = nil
        terminateOwnedProcess()
    }

    private func terminateOwnedProcess() {
        lease.invalidate()
        let child = process; process = nil
        guard let child, child.isRunning else { return }
        retiring.append(child)
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func drainRetiredProcesses(generation: UInt64) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while retiring.contains(where: { $0.isRunning }) {
            try Task.checkCancellation()
            guard generation == operationGeneration else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw DictationError.message("The previous local correction service is still stopping. Try again shortly.")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        retiring.removeAll()
    }
}
