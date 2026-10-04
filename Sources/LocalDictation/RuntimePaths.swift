import Foundation

/// Executables are sealed in the app. Downloaded weights are always external.
struct RuntimePaths: Sendable {
    let resources: URL
    let models: URL

    var whisperWorker: URL { resources.appendingPathComponent("whisper-worker") }
    var whisperModel: URL { models.appendingPathComponent("ggml-large-v3-turbo-q8_0.bin") }
    var ollamaExecutable: URL { resources.appendingPathComponent("ollama") }
    var ollamaModels: URL { models.appendingPathComponent("ollama", isDirectory: true) }

    static func application(bundle: Bundle = .main) throws -> RuntimePaths {
        guard let resources = bundle.resourceURL,
              let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first else {
            throw RuntimeSetupError.message("The application or Application Support folder is unavailable.")
        }
        let development = bundle.bundleIdentifier?.hasSuffix(".development") == true
        let folder = development ? "Local Dictation Development" : "Local Dictation"
        return RuntimePaths(resources: resources,
                            models: support.appendingPathComponent(folder, isDirectory: true)
                                .appendingPathComponent("Models", isDirectory: true))
    }
}

enum RuntimeSetupError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
