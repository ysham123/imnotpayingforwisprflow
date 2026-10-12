import Foundation

/// Exercises actual URLSession cancellation and publication using public data.
/// The fixture is an 8 MB source archive, never executed or used as model weights.
final class DownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var progressed = false

    func install(_ task: Task<Void, Error>) {
        lock.lock(); self.task = task; let pending = progressed; lock.unlock()
        if pending { task.cancel() }
    }
    func observe(_ bytes: Int64) {
        guard bytes >= 16_384 else { return }
        lock.lock(); progressed = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func didProgress() -> Bool {
        lock.lock(); defer { lock.unlock() }; return progressed
    }
    func clear() {
        lock.lock(); task = nil; lock.unlock()
    }
}

@main
struct StoreDownloadSmoke {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RuntimeSetupError.message(message) }
    }
    @discardableResult
    static func rejected(_ operation: () async throws -> Void) async throws -> Error {
        do { try await operation() } catch { return error }
        throw RuntimeSetupError.message("An invalid download unexpectedly succeeded")
    }

    @MainActor
    static func main() async throws {
        // Foundation canonicalizes /private/var back to the /var symlink on
        // macOS. Use the same literal, link-free fixture root as ModelStore tests.
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("LocalDictation-StoreDownloads-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.8.3")!
        let asset = ModelStore.Asset(path: "fixture.bin", label: "Public source fixture", bytes: 7_898_461,
            sha256: "870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a", url: url, inlineUTF8: nil)
        func paths(_ name: String) -> RuntimePaths {
            RuntimePaths(resources: root.appendingPathComponent("Resources"), models: root.appendingPathComponent(name))
        }
        let transport: @Sendable (ModelStore.Asset, URL) async throws -> Void = { asset, file in
            try await StoreModelDownloader.download(asset, to: file)
        }
        let manifest = ModelStore.Manifest(formatVersion: 1, identifier: "public-fixture", files: [asset])
        let cancelledFile = root.appendingPathComponent("cancelled.bin")
        let probe = DownloadCancellation()
        let task = Task {
            try await StoreModelDownloader.download(asset, to: cancelledFile, progress: { probe.observe($0) })
        }
        probe.install(task)
        let cancellation = try await rejected { try await task.value }
        probe.clear()
        try require(cancellation is CancellationError, "Transfer failed without exercising cancellation")
        try require(probe.didProgress(), "Cancellation was not exercised after transfer began")
        try require(!FileManager.default.fileExists(atPath: cancelledFile.path), "A cancelled transfer was published")
        print("PASS cancellation after HTTPS transfer begins, with no publication")

        let beforeStart = Task { try await StoreModelDownloader.download(asset, to: cancelledFile) }
        beforeStart.cancel()
        let earlyCancellation = try await rejected { try await beforeStart.value }
        try require(earlyCancellation is CancellationError, "Before-start cancellation returned the wrong error")
        print("PASS cancellation before transport starts")

        let store = ModelStore(paths: paths("retry"), manifest: manifest, downloader: transport)
        try await store.prepare { _ in }
        try require(FileManager.default.fileExists(atPath: paths("retry").models.appendingPathComponent(asset.path).path), "A verified retry was not published")
        print("PASS retry downloads, checks SHA-256, and publishes verified bytes")

        let offline = ModelStore(paths: paths("retry"), manifest: manifest, downloader: { _, _ in
            throw RuntimeSetupError.message("Verified files should not trigger another download")
        })
        try await offline.prepare { _ in }
        print("PASS subsequent offline cache reuse")

        let corrupt = ModelStore.Asset(path: asset.path, label: asset.label, bytes: asset.bytes,
            sha256: String(repeating: "0", count: 64), url: url, inlineUTF8: nil)
        let corruptStore = ModelStore(paths: paths("wrong-digest"),
            manifest: ModelStore.Manifest(formatVersion: 1, identifier: "bad-digest", files: [corrupt]), downloader: transport)
        let integrity = try await rejected { try await corruptStore.prepare { _ in } }
        try require(integrity.localizedDescription.contains("failed its integrity check"), "The corrupted fixture failed for a reason other than integrity")
        try require(!FileManager.default.fileExists(atPath: paths("wrong-digest").models.appendingPathComponent(asset.path).path), "A wrong digest was published")
        print("PASS wrong digest cannot become a model input")

        let insecure = ModelStore.Asset(path: "insecure.bin", label: "HTTP rejected", bytes: asset.bytes,
            sha256: asset.sha256, url: URL(string: "http://example.invalid/fixture"), inlineUTF8: nil)
        let invalidURL = try await rejected { try await StoreModelDownloader.download(insecure, to: root.appendingPathComponent(insecure.path)) }
        try require(invalidURL.localizedDescription.contains("model URL is invalid"), "HTTP rejection returned the wrong error")
        print("PASS HTTP source rejected before network access")

        let oversized = ModelStore.Asset(path: "oversized.bin", label: "Oversized rejected", bytes: 1,
            sha256: asset.sha256, url: url, inlineUTF8: nil)
        try await rejected { try await StoreModelDownloader.download(oversized, to: root.appendingPathComponent(oversized.path)) }
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(oversized.path).path), "Oversized data was published")
        print("PASS oversized HTTPS response rejected")
    }
}
