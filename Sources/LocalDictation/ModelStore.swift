import Foundation
import CryptoKit
import Darwin

/// Only files matching the manifest sealed into this app become model inputs.
actor ModelStore {
    struct Progress: Sendable {
        enum Stage: String, Sendable { case checking, migrating, downloading, ready }
        let stage: Stage
        let label: String
        let completedBytes: Int64
        let totalBytes: Int64
        var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
    }
    struct Asset: Codable, Sendable {
        let path: String
        let label: String
        let bytes: Int64
        let sha256: String
        let url: URL?
        let inlineUTF8: String?
    }
    struct Manifest: Codable, Sendable {
        let formatVersion: Int
        let identifier: String
        let files: [Asset]
    }
    enum DownloadFailure: LocalizedError {
        case resumeUnsupported
        var errorDescription: String? {
            "The model server could not resume this download. Retry model setup."
        }
    }
    private let paths: RuntimePaths
    private let migrationSources: [URL]
    private let manifestOverride: Manifest?
    // Tests inject a downloader; production uses the system curl with HTTPS-only
    // redirects and byte-count/hash checks before publication.
    private let downloadOverride: (@Sendable (Asset, URL) async throws -> Void)?
    private var preparing = false

    init(paths: RuntimePaths, migrationSources: [URL] = [], manifest: Manifest? = nil,
         downloader: (@Sendable (Asset, URL) async throws -> Void)? = nil) {
        self.paths = paths
        self.migrationSources = migrationSources + [paths.resources.appendingPathComponent("Models")]
        manifestOverride = manifest; downloadOverride = downloader
    }

    func prepare(progress: @escaping @MainActor (Progress) -> Void) async throws {
        guard !preparing else { throw RuntimeSetupError.message("Models are already being prepared. Wait for the current operation.") }
        preparing = true; defer { preparing = false }
        let manifest = try loadManifest()
        try prepareDirectories()
        let lock = try ModelFileLock(at: paths.models.appendingPathComponent(".prepare.lock"))
        defer { lock.release() }
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        for asset in manifest.files {
            try Task.checkCancellation()
            await progress(Progress(stage: .checking, label: asset.label, completedBytes: completed, totalBytes: total))
            let target = try assetURL(asset.path)
            if try Self.matches(target, asset: asset) {
                completed += asset.bytes; continue
            }
            if try await migrate(asset, to: target) {
                completed += asset.bytes
                await progress(Progress(stage: .migrating, label: asset.label, completedBytes: completed, totalBytes: total))
                continue
            }
            let partial = paths.models.appendingPathComponent(".downloads/" + asset.sha256 + ".part")
            try Self.requireRegularOrAbsent(partial)
            if Self.size(of: partial) > asset.bytes {
                try FileManager.default.removeItem(at: partial)
            }
            if let text = asset.inlineUTF8 {
                try Data(text.utf8).write(to: partial, options: .atomic)
            } else {
                try requireSpace(for: asset, partial: partial)
                // A bad complete partial cannot be reused. A valid complete
                // download is accepted after a previous cancellation/crash.
                var verified = try Self.matches(partial, asset: asset)
                if !verified {
                    if Self.size(of: partial) == asset.bytes { try FileManager.default.removeItem(at: partial) }
                    for attempt in 0..<2 {
                        try Task.checkCancellation()
                        try await download(asset, to: partial, completed: completed, total: total, progress: progress)
                        verified = try Self.matches(partial, asset: asset)
                        if verified { break }
                        try? FileManager.default.removeItem(at: partial)
                        if attempt == 1 { throw RuntimeSetupError.message("\(asset.label) failed its integrity check. Retry model setup.") }
                    }
                }
            }
            guard try Self.matches(partial, asset: asset) else {
                try? FileManager.default.removeItem(at: partial)
                throw RuntimeSetupError.message("\(asset.label) failed its integrity check. Retry model setup.")
            }
            try publish(partial, to: target)
            completed += asset.bytes
        }
        await progress(Progress(stage: .ready, label: "Local models ready", completedBytes: total, totalBytes: total))
    }

    /// Installation can preserve verified v1.2 weights before replacing that app.
    /// Missing/corrupt legacy weights are left alone and downloaded on first run.
    func migrateAvailable() async throws {
        guard !preparing else { throw RuntimeSetupError.message("Models are already being prepared.") }
        preparing = true; defer { preparing = false }
        let manifest = try loadManifest()
        try prepareDirectories()
        let lock = try ModelFileLock(at: paths.models.appendingPathComponent(".prepare.lock"))
        defer { lock.release() }
        for asset in manifest.files {
            try Task.checkCancellation()
            let target = try assetURL(asset.path)
            if try Self.matches(target, asset: asset) { continue }
            _ = try await migrate(asset, to: target)
        }
    }

    private func loadManifest() throws -> Manifest {
        let manifest = try manifestOverride ?? JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: paths.resources.appendingPathComponent("ModelManifest.json")))
        guard manifest.formatVersion == 1, !manifest.identifier.isEmpty, !manifest.files.isEmpty,
              Set(manifest.files.map(\.path)).count == manifest.files.count else {
            throw RuntimeSetupError.message("The bundled model manifest is invalid. Restore the complete app.")
        }
        var total: Int64 = 0
        for asset in manifest.files {
            let components = asset.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }),
                  asset.bytes > 0, asset.bytes <= 8_000_000_000,
                  asset.sha256.count == 64, asset.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  (asset.url != nil) != (asset.inlineUTF8 != nil),
                  asset.url == nil || (asset.url?.scheme == "https" && asset.url?.host != nil &&
                    asset.url?.user == nil && asset.url?.password == nil) else {
                throw RuntimeSetupError.message("The bundled model manifest contains an unsafe file or URL.")
            }
            let sum = total.addingReportingOverflow(asset.bytes)
            guard !sum.overflow else { throw RuntimeSetupError.message("The model manifest size is invalid.") }
            total = sum.partialValue
        }
        return manifest
    }

    private func prepareDirectories() throws {
        try Self.createDirectory(paths.models)
        try Self.createDirectory(paths.models.appendingPathComponent(".downloads"))
    }

    private func assetURL(_ path: String) throws -> URL {
        let result = paths.models.appendingPathComponent(path)
        var directory = paths.models
        for component in path.split(separator: "/").dropLast() {
            directory.appendPathComponent(String(component), isDirectory: true)
            try Self.createDirectory(directory)
        }
        try Self.requireRegularOrAbsent(result)
        return result
    }

    private func migrate(_ asset: Asset, to target: URL) async throws -> Bool {
        for root in migrationSources where root.standardizedFileURL != paths.models.standardizedFileURL {
            let source = root.appendingPathComponent(asset.path)
            guard try Self.matches(source, asset: asset) else { continue }
            let partial = paths.models.appendingPathComponent(".downloads/" + asset.sha256 + ".migrating")
            try Self.requireRegularOrAbsent(partial)
            try? FileManager.default.removeItem(at: partial)
            try Task.checkCancellation()
            do {
                // Clone when possible, copy otherwise. Never move or alter legacy app files.
                if clonefile(source.path, partial.path, 0) != 0 {
                    try? FileManager.default.removeItem(at: partial)
                    try Self.copyCancellable(source, to: partial)
                }
                try Task.checkCancellation()
                guard try Self.matches(partial, asset: asset) else {
                    throw RuntimeSetupError.message("A migrated model failed verification.")
                }
                try publish(partial, to: target)
                return true
            } catch { try? FileManager.default.removeItem(at: partial); throw error }
        }
        return false
    }

    private func publish(_ partial: URL, to target: URL) throws {
        try Task.checkCancellation()
        try Self.requireRegularOrAbsent(target)
        guard Darwin.rename(partial.path, target.path) == 0 else {
            throw RuntimeSetupError.message("Could not save a verified local model. Check available disk space.")
        }
    }

    private func requireSpace(for asset: Asset, partial: URL) throws {
        let remaining = max(0, asset.bytes - Self.size(of: partial))
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: paths.models.path)
        if let available = attrs[.systemFreeSize] as? NSNumber,
           available.int64Value < remaining + 128 * 1024 * 1024 {
            throw RuntimeSetupError.message("Not enough disk space for \(asset.label). Free space and retry; completed downloads are kept.")
        }
    }

    private func download(_ asset: Asset, to partial: URL, completed: Int64, total: Int64,
                          progress: @escaping @MainActor (Progress) -> Void) async throws {
        for attempt in 0..<2 {
            do {
                if let downloadOverride { try await downloadOverride(asset, partial) }
                else { try await downloadCurl(asset, to: partial, completed: completed, total: total, progress: progress) }
                return
            } catch DownloadFailure.resumeUnsupported {
                // curl 33 explicitly means the server cannot satisfy the range.
                // Restart once; cancellation and ordinary network failures keep
                // their useful partial bytes intact.
                guard attempt == 0, Self.size(of: partial) > 0 else {
                    throw DownloadFailure.resumeUnsupported
                }
                try Task.checkCancellation()
                try FileManager.default.removeItem(at: partial)
            }
        }
    }

    private func downloadCurl(_ asset: Asset, to partial: URL, completed: Int64, total: Int64,
                              progress: @escaping @MainActor (Progress) -> Void) async throws {
        guard let url = asset.url else { throw RuntimeSetupError.message("The model download URL is missing.") }
        let child = Process(), cancellation = ModelDownloadCancellation()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        child.arguments = ["--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
            "--tlsv1.2", "--silent", "--show-error", "--connect-timeout", "30", "--max-time", "3600",
            "--retry", "2", "--retry-delay", "1", "--continue-at", "-", "--output", partial.path, url.absoluteString]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        do { try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try cancellation.launch(child)
            while child.isRunning {
                try Task.checkCancellation()
                let bytes = Self.size(of: partial)
                guard bytes <= asset.bytes else {
                    cancellation.cancel()
                    throw RuntimeSetupError.message("The model download was larger than its verified manifest.")
                }
                await progress(Progress(stage: .downloading, label: asset.label,
                                        completedBytes: completed + bytes, totalBytes: total))
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try Task.checkCancellation()
            if child.terminationStatus == 33 { throw DownloadFailure.resumeUnsupported }
            guard child.terminationStatus == 0 else {
                throw RuntimeSetupError.message("\(asset.label) download paused. Check your connection and retry; partial downloads are kept.")
            }
        }, onCancel: { cancellation.cancel() }) }
        catch {
            cancellation.cancel()
            // Do not release the model-file lock while an old curl can still
            // write the partial file that the next retry will resume.
            if child.isRunning { await Task.detached { child.waitUntilExit() }.value }
            throw error
        }
    }

    private static func copyCancellable(_ source: URL, to target: URL) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw RuntimeSetupError.message("The legacy model could not be read.") }
        defer { close(input) }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw RuntimeSetupError.message("The migrated model could not be saved.") }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw RuntimeSetupError.message("Legacy model read failed.") }
            if count == 0 { return }
            var offset = 0
            try buffer.withUnsafeBytes { bytes in
                while offset < count {
                    try Task.checkCancellation()
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw RuntimeSetupError.message("Not enough space to preserve legacy models.") }
                    offset += written
                }
            }
        }
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func requireRegularOrAbsent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw RuntimeSetupError.message("An unexpected link or folder occupies a model file. Check Application Support.")
            }
        } else if errno != ENOENT {
            throw RuntimeSetupError.message("Could not inspect the model storage folder.")
        }
    }

    private static func createDirectory(_ url: URL) throws {
        // Check each existing ancestor, including the model root's parent, so
        // relative asset paths cannot traverse a symlink into another location.
        var current = url
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw RuntimeSetupError.message("Model storage contains an unexpected link or file.")
                }
            } else if errno != ENOENT { throw RuntimeSetupError.message("Model storage could not be inspected.") }
            current.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    static func matches(_ url: URL, asset: Asset) throws -> Bool {
        var initial = stat()
        guard lstat(url.path, &initial) == 0 else {
            if errno == ENOENT { return false }
            throw RuntimeSetupError.message("Could not inspect a local model.")
        }
        guard initial.st_mode & S_IFMT == S_IFREG else {
            throw RuntimeSetupError.message("A model file is an unexpected link or folder.")
        }
        guard initial.st_size == asset.bytes else { return false }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RuntimeSetupError.message("Could not read a local model.") }
        defer { close(descriptor) }
        var opened = stat(); guard fstat(descriptor, &opened) == 0,
            opened.st_ino == initial.st_ino, opened.st_dev == initial.st_dev else { return false }
        var hasher = SHA256(), count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let result = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if result < 0 { if errno == EINTR { continue }; throw RuntimeSetupError.message("Could not finish reading a model.") }
            if result == 0 { break }
            count += Int64(result)
            guard count <= asset.bytes else { return false }
            hasher.update(data: Data(buffer.prefix(result)))
        }
        var final = stat(), named = stat()
        guard fstat(descriptor, &final) == 0, lstat(url.path, &named) == 0,
              final.st_size == initial.st_size, final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              named.st_ino == initial.st_ino, named.st_dev == initial.st_dev,
              count == asset.bytes else { return false }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == asset.sha256
    }
}

private final class ModelFileLock {
    private var descriptor: Int32
    init(at url: URL) throws {
        try ModelStore.requireRegularOrAbsent(url)
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RuntimeSetupError.message("Model storage is not writable.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw RuntimeSetupError.message("Another Local Dictation process is preparing models. Wait and retry.")
        }
    }
    func release() { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}

private final class ModelDownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run(); child = process
    }
    func cancel() {
        lock.lock(); cancelled = true; let process = child; lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
}
