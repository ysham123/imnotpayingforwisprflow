import Foundation
import CryptoKit
import Darwin
import Dispatch

/// Explicit integration utility. It uses only the supplied paths, never launches
/// engines. Full downloads require an explicitly named fresh cache destination.
@main
struct ProductionModelStoreSmoke {
    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do {
            let arguments = CommandLine.arguments
            guard [5, 7].contains(arguments.count), ["migrate", "download", "download-full"].contains(arguments[1]) else {
                throw RuntimeSetupError.message("Usage: production-model-store migrate|download|download-full RESOURCES MODELS LEGACY_MODELS [--cancel-after SECONDS]")
            }
            let mode = arguments[1]
            var cancelAfter: Double?
            if arguments.count == 7 {
                guard mode == "download-full", arguments[5] == "--cancel-after",
                      let seconds = Double(arguments[6]), seconds.isFinite,
                      seconds > 0, seconds <= 3_600 else {
                    throw RuntimeSetupError.message("Automatic cancellation requires download-full --cancel-after SECONDS (0 < seconds <= 3600)")
                }
                cancelAfter = seconds
            }
            let resources = URL(fileURLWithPath: arguments[2], isDirectory: true)
            let models = URL(fileURLWithPath: arguments[3], isDirectory: true)
            let legacy = URL(fileURLWithPath: arguments[4], isDirectory: true)
            let manifest = try JSONDecoder().decode(ModelStore.Manifest.self,
                from: Data(contentsOf: resources.appendingPathComponent("ModelManifest.json")))
            let paths = RuntimePaths(resources: resources, models: models)
            let started = ProcessInfo.processInfo.systemUptime
            if mode == "migrate" {
                let sourceStarted = ProcessInfo.processInfo.systemUptime
                for asset in manifest.files {
                    guard try ModelStore.matches(legacy.appendingPathComponent(asset.path), asset: asset) else {
                        throw RuntimeSetupError.message("Installed legacy model failed verification: \(asset.path)")
                    }
                }
                print("SOURCE_VERIFIED files=\(manifest.files.count) bytes=\(manifest.files.reduce(Int64(0)) { $0 + $1.bytes }) seconds=\(elapsed(sourceStarted))")
                let migrationStarted = ProcessInfo.processInfo.systemUptime
                let store = ModelStore(paths: paths, migrationSources: [legacy], downloader: { _, _ in
                    throw RuntimeSetupError.message("Verified migration unexpectedly attempted a download")
                })
                try await store.migrateAvailable()
                print("MIGRATED seconds=\(elapsed(migrationStarted))")
                let reuseStarted = ProcessInfo.processInfo.systemUptime
                try await store.prepare { progress in
                    if progress.stage == .ready { print("READY verifiedBytes=\(progress.completedBytes)") }
                }
                print("OFFLINE_REUSE_VERIFIED seconds=\(elapsed(reuseStarted))")
                for asset in manifest.files {
                    guard try ModelStore.matches(legacy.appendingPathComponent(asset.path), asset: asset) else {
                        throw RuntimeSetupError.message("Legacy source changed during migration: \(asset.path)")
                    }
                }
                print("LEGACY_SOURCE_UNCHANGED files=\(manifest.files.count)")
            } else if mode == "download" {
                let assets = manifest.files.filter { $0.url != nil && $0.bytes <= 16_384 }
                guard assets.count == 4, assets.reduce(Int64(0), { $0 + $1.bytes }) <= 16_384,
                      !FileManager.default.fileExists(atPath: models.path) else {
                    throw RuntimeSetupError.message("Download checks require a fresh isolated folder and exactly four tiny pinned assets")
                }
                let subset = ModelStore.Manifest(formatVersion: manifest.formatVersion,
                    identifier: manifest.identifier + "-https-metadata-check", files: assets)
                let seeded = assets[0]
                let original = try Data(contentsOf: legacy.appendingPathComponent(seeded.path))
                guard Int64(original.count) == seeded.bytes else {
                    throw RuntimeSetupError.message("The metadata prefix fixture is unavailable")
                }
                let partial = models.appendingPathComponent(".downloads/" + seeded.sha256 + ".part")
                try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
                try original.prefix(64).write(to: partial)
                print("HTTPS_PARTIAL_SEEDED bytes=64 sha256=\(seeded.sha256)")
                let store = ModelStore(paths: paths, manifest: subset)
                try await store.prepare { progress in
                    if progress.stage == .ready { print("HTTPS_READY verifiedBytes=\(progress.completedBytes)") }
                }
                for asset in assets {
                    guard try ModelStore.matches(models.appendingPathComponent(asset.path), asset: asset) else {
                        throw RuntimeSetupError.message("Downloaded metadata failed final checksum: \(asset.path)")
                    }
                    print("HTTPS_CHECKSUM_OK bytes=\(asset.bytes) sha256=\(asset.sha256)")
                }
                try await store.prepare { _ in }
                print("HTTPS_OFFLINE_REUSE_OK files=\(assets.count)")
            } else {
                try await fullDownload(paths: paths, legacy: legacy, manifest: manifest, cancelAfter: cancelAfter)
            }
            print("PASS production-model-store mode=\(mode) seconds=\(elapsed(started))")
        } catch is CancellationError {
            print("CANCELLED production-model-store; completed and partial files remain only in its isolated cache folder")
            exit(130)
        } catch {
            print("FAIL production-model-store: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    static func fullDownload(paths: RuntimePaths, legacy: URL, manifest: ModelStore.Manifest,
                             cancelAfter: Double?) async throws {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw RuntimeSetupError.message("The user cache directory is unavailable")
        }
        let cacheRoot = cache.standardizedFileURL.resolvingSymlinksInPath()
        let destination = paths.models.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let prefix = "LocalDictation-fresh-model-test-"
        let directoryName = parent.lastPathComponent
        guard destination.lastPathComponent == "Models", directoryName.hasPrefix(prefix),
              UUID(uuidString: String(directoryName.dropFirst(prefix.count))) != nil,
              parent.deletingLastPathComponent().resolvingSymlinksInPath().path == cacheRoot.path,
              destination.resolvingSymlinksInPath().path == destination.path,
              !FileManager.default.fileExists(atPath: parent.path),
              destination != legacy.standardizedFileURL.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: paths.resources.appendingPathComponent("Models").path) else {
            throw RuntimeSetupError.message("Full download requires a nonexistent ~/Library/Caches/LocalDictation-fresh-model-test-<UUID>/Models folder and a thin app; existing model folders cannot be used")
        }
        guard manifest.files.count == 7, let firstAsset = manifest.files.first,
              firstAsset.url != nil, firstAsset.bytes > 100_000_000 else {
            throw RuntimeSetupError.message("Full download requires the sealed seven-file production manifest")
        }
        var total: Int64 = 0
        for asset in manifest.files {
            guard asset.bytes > 0 else { throw RuntimeSetupError.message("A model byte count is invalid") }
            let sum = total.addingReportingOverflow(asset.bytes)
            guard !sum.overflow else { throw RuntimeSetupError.message("The model byte total overflowed") }
            total = sum.partialValue
        }
        let margin: Int64 = 512 * 1024 * 1024
        let required = total.addingReportingOverflow(margin)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: cacheRoot.path)
        guard !required.overflow, let free = attributes[.systemFreeSize] as? NSNumber,
              free.int64Value >= required.partialValue else {
            throw RuntimeSetupError.message("Full-download fixture needs the complete model bytes plus 512 MiB free disk space")
        }
        print("FULL_PREFLIGHT files=\(manifest.files.count) expectedBytes=\(total) availableBytes=\(free.int64Value) requiredBytes=\(required.partialValue)")
        let store = ModelStore(paths: paths)
        let start = ProcessInfo.processInfo.systemUptime
        var reportedPercent = -1
        var reportedStage: ModelStore.Progress.Stage?
        let progress: @MainActor (ModelStore.Progress) -> Void = { value in
            let percent = Int(value.fraction * 100)
            if percent != reportedPercent || value.stage != reportedStage {
                reportedPercent = percent; reportedStage = value.stage
                print("FULL_PROGRESS stage=\(value.stage.rawValue) percent=\(percent) completedBytes=\(value.completedBytes) totalBytes=\(value.totalBytes) seconds=\(elapsed(start))")
            }
        }
        let cancellationState = FullDownloadCancellation()
        let oldInterrupt = signal(SIGINT, SIG_IGN)
        let oldTerminate = signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        for source in [interrupt, terminate] {
            source.setEventHandler { cancellationState.cancel() }
            source.resume()
        }
        var cancellation: Task<Void, Never>?
        if let seconds = cancelAfter {
            cancellation = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    print("FULL_CANCEL_REQUESTED seconds=\(elapsed(start))")
                    cancellationState.cancel()
                } catch { }
            }
        }
        defer {
            cancellation?.cancel(); interrupt.cancel(); terminate.cancel()
            _ = signal(SIGINT, oldInterrupt); _ = signal(SIGTERM, oldTerminate)
        }
        var interrupted: Task<Void, Error>?
        var boundedCancellationTriggered = false
        var cancellationDeadlineExpired = false
        let firstTransfer = Task { @MainActor in
            try await store.prepare { value in
                progress(value)
                if !boundedCancellationTriggered, value.stage == .downloading,
                   value.completedBytes >= 1_048_576, value.completedBytes < firstAsset.bytes {
                    boundedCancellationTriggered = true
                    print("FULL_BOUNDED_CANCEL_REQUESTED partialBytes=\(value.completedBytes) seconds=\(elapsed(start))")
                    interrupted?.cancel()
                }
            }
        }
        interrupted = firstTransfer
        cancellationState.bind(firstTransfer)
        let deadline = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                cancellationDeadlineExpired = true
                firstTransfer.cancel()
            } catch { }
        }
        defer { deadline.cancel() }
        do {
            try await awaitPreparation(firstTransfer, cancellationState: cancellationState)
            throw RuntimeSetupError.message("Full-download fixture completed without exercising large-transfer cancellation")
        } catch is CancellationError {
            try cancellationState.check()
            guard boundedCancellationTriggered, !cancellationDeadlineExpired else {
                throw RuntimeSetupError.message("The first large transfer did not provide a partial payload within the bounded cancellation window")
            }
        }
        deadline.cancel()
        try requireNoDownloader(in: destination, phase: "cancel")
        let partial = destination.appendingPathComponent(".downloads/" + firstAsset.sha256 + ".part")
        try ModelStore.requireRegularOrAbsent(partial)
        let partialAttributes = try FileManager.default.attributesOfItem(atPath: partial.path)
        guard let partialCount = partialAttributes[.size] as? NSNumber,
              partialCount.int64Value > 0, partialCount.int64Value < firstAsset.bytes,
              !FileManager.default.fileExists(atPath: destination.appendingPathComponent(firstAsset.path).path) else {
            throw RuntimeSetupError.message("Canceled transfer did not retain a safe incomplete partial")
        }
        print("FULL_CANCEL_DRAINED partialBytes=\(partialCount.int64Value) seconds=\(elapsed(start))")
        let resumed = Task { @MainActor in try await store.prepare(progress: progress) }
        cancellationState.bind(resumed)
        try await awaitPreparation(resumed, cancellationState: cancellationState)
        cancellation?.cancel()
        try cancellationState.check()
        try requireNoDownloader(in: destination, phase: "complete")
        print("FULL_DOWNLOAD_PREPARED files=\(manifest.files.count) bytes=\(total) seconds=\(elapsed(start))")
        let verification = ProcessInfo.processInfo.systemUptime
        for (index, asset) in manifest.files.enumerated() {
            try cancellationState.check()
            guard try ModelStore.matches(destination.appendingPathComponent(asset.path), asset: asset) else {
                throw RuntimeSetupError.message("A full-download model failed final SHA-256 verification")
            }
            print("FULL_CHECKSUM_OK file=\(index + 1) bytes=\(asset.bytes) sha256=\(asset.sha256)")
        }
        print("FULL_CHECKSUMS_VERIFIED files=\(manifest.files.count) bytes=\(total) seconds=\(elapsed(verification))")
        let reuse = ProcessInfo.processInfo.systemUptime
        try cancellationState.check()
        let offline = ModelStore(paths: paths, downloader: { _, _ in
            throw RuntimeSetupError.message("Full-download offline reuse unexpectedly attempted network")
        })
        let offlinePreparation = Task { @MainActor in try await offline.prepare { _ in } }
        cancellationState.bind(offlinePreparation)
        try await awaitPreparation(offlinePreparation, cancellationState: cancellationState)
        try cancellationState.check()
        print("FULL_OFFLINE_REUSE_VERIFIED files=\(manifest.files.count) bytes=\(total) seconds=\(elapsed(reuse))")
    }

    static func awaitPreparation(_ task: Task<Void, Error>, cancellationState: FullDownloadCancellation) async throws {
        try await withTaskCancellationHandler(operation: {
            do { try await task.value }
            catch {
                task.cancel()
                _ = try? await task.value
                throw error
            }
        }, onCancel: { cancellationState.cancel() })
    }

    static func requireNoDownloader(in models: URL, phase: String) throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/ps")
        child.arguments = ["-wwaxo", "pid=,comm=,args="]
        child.standardInput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        let output = Pipe(); child.standardOutput = output
        try child.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw RuntimeSetupError.message("Downloader-exit inspection failed") }
        let ownedDirectory = models.appendingPathComponent(".downloads").path
        let owned = String(decoding: data, as: UTF8.self).split(separator: "\n").filter {
            $0.contains("/usr/bin/curl") && $0.contains(ownedDirectory)
        }
        guard owned.isEmpty else { throw RuntimeSetupError.message("A fixture downloader remained after preparation drained; no unrelated processes have been changed") }
        print("FULL_DOWNLOADER_DRAINED phase=\(phase) ownedCount=0")
    }

    static func elapsed(_ start: Double) -> String {
        String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start)
    }
}

final class FullDownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var active: Task<Void, Error>?
    func bind(_ task: Task<Void, Error>) {
        lock.lock(); active = task; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = active; lock.unlock(); task?.cancel()
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
