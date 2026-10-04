import Foundation
import Darwin
#if canImport(DictationCore)
import DictationCore
#endif

enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Serial process boundary keeps audio and model work away from AppKit.
final class WhisperTranscriber {
    struct Timing: Sendable {
        let startupSeconds: Double
        let writeSeconds: Double
        let recognitionSeconds: Double
        let totalSeconds: Double
    }
    private let queue = DispatchQueue(label: "localdictation.whisper", qos: .userInitiated)
    private var process: Process?
    private let processLock = NSLock()
    private var cancellationGeneration: UInt64 = 0
    private var workerGeneration: UInt64?
    private var timing: Timing?
    private var vocabularyOverflowIDs: Set<UUID> = []
    private var workerProtocol = 1
    private var input: FileHandle?
    private var output: FileHandle?
    // A worker may split a JSON line over writes or coalesce multiple lines.
    // Retain the unread suffix rather than doing a syscall for every byte.
    private var readBuffer = Data()
    private let executable: URL
    private let model: URL

    private let startupTimeout: TimeInterval
    private let requestTimeout: TimeInterval

    init(resources: URL, models: URL? = nil, startupTimeout: TimeInterval = 90, requestTimeout: TimeInterval = 120) {
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        executable = resources.appendingPathComponent("whisper-worker")
        model = (models ?? resources.appendingPathComponent("Models")).appendingPathComponent("ggml-large-v3-turbo-q8_0.bin")
    }

    var lastTiming: Timing? {
        processLock.lock(); defer { processLock.unlock() }
        return timing
    }

    var lastVocabularyOverflowIDs: Set<UUID> {
        processLock.lock(); defer { processLock.unlock() }; return vocabularyOverflowIDs
    }

    func rewarm() async throws { try await prepare() }

    /// Releases model memory and invalidates queued work before returning.
    func suspend() async {
        await withCheckedContinuation { continuation in
            // Publish cancellation and its queue barrier atomically, so a new
            // generation cannot enqueue a warmup ahead of the memory release.
            processLock.lock()
            cancellationGeneration &+= 1
            let worker = process
            queue.async { self.reset(); continuation.resume() }
            processLock.unlock()
            if let worker { Self.terminate(worker) }
        }
    }

    func prepare() async throws {
        try Task.checkCancellation()
        let generation = currentGeneration()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try self.ensureRunning(expectedGeneration: generation)
                        try self.checkGeneration(generation)
                        continuation.resume()
                    } catch { self.reset(expectedGeneration: generation); continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel(expectedGeneration: generation) })
    }

    func transcribe(_ samples: [Float], vocabulary: VocabularySnapshot = .empty) async throws -> String {
        try Task.checkCancellation()
        let vocabulary = try VocabularySnapshot(entries: vocabulary.entries, revision: vocabulary.revision)
        let generation = currentGeneration()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let started = ProcessInfo.processInfo.systemUptime
                        try self.checkGeneration(generation)
                        try self.ensureRunning(expectedGeneration: generation)
                        try self.checkGeneration(generation)
                        let prepared = ProcessInfo.processInfo.systemUptime
                        guard !samples.isEmpty, samples.count <= 1_920_000, let input = self.input else {
                            throw DictationError.message("The dictation audio was empty or too long.")
                        }
                        var count = UInt32(samples.count).littleEndian
                        var packet = withUnsafeBytes(of: &count) { Data($0) }
                        if self.workerProtocol == 2 {
                            var hintCount = UInt32(vocabulary.entries.count).littleEndian
                            withUnsafeBytes(of: &hintCount) { packet.append(contentsOf: $0) }
                            for entry in vocabulary.entries {
                                packet.append(contentsOf: entry.id.uuidString.utf8)
                                let term = Data(entry.preferredSpelling.utf8)
                                var length = UInt32(term.count).littleEndian
                                withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
                                packet.append(term)
                            }
                        }
                        samples.withUnsafeBytes { packet.append(contentsOf: $0) }
                        let deadline = ProcessInfo.processInfo.systemUptime + self.requestTimeout
                        try self.write(packet, to: input.fileDescriptor, deadline: deadline, generation: generation)
                        let written = ProcessInfo.processInfo.systemUptime
                        let result = try self.readJSON(deadline: deadline, generation: generation)
                        try self.checkGeneration(generation)
                        if let error = result["error"] as? String { throw DictationError.message(error) }
                        guard let text = result["text"] as? String else {
                            throw DictationError.message("The speech engine returned an invalid result.")
                        }
                        var overflow = Set(vocabulary.entries.map(\.id))
                        if self.workerProtocol == 2 {
                            guard let reported = result["vocabulary_overflow"] as? [String] else {
                                throw DictationError.message("The speech engine returned invalid vocabulary status.")
                            }
                            let ids = reported.compactMap(UUID.init(uuidString:))
                            guard ids.count == reported.count, Set(ids).isSubset(of: overflow) else {
                                throw DictationError.message("The speech engine returned invalid vocabulary IDs.")
                            }
                            overflow = Set(ids)
                        }
                        let finished = ProcessInfo.processInfo.systemUptime
                        self.processLock.lock()
                        self.timing = Timing(startupSeconds: prepared - started, writeSeconds: written - prepared,
                                             recognitionSeconds: finished - written, totalSeconds: finished - started)
                        self.vocabularyOverflowIDs = overflow
                        self.processLock.unlock()
                        continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                    } catch { self.reset(expectedGeneration: generation); continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel(expectedGeneration: generation) })
    }

    func shutdown() {
        // Termination also interrupts a recognition request; its caller handles the error.
        cancel()
        queue.async { self.reset() }
    }

    func cancel() {
        cancel(expectedGeneration: nil)
    }

    private func cancel(expectedGeneration: UInt64?) {
        processLock.lock()
        if let expectedGeneration, expectedGeneration != cancellationGeneration {
            processLock.unlock(); return
        }
        cancellationGeneration &+= 1
        let worker = process
        processLock.unlock()
        if let worker { Self.terminate(worker) }
    }

    private func currentGeneration() -> UInt64 {
        processLock.lock(); defer { processLock.unlock() }
        return cancellationGeneration
    }

    private func checkGeneration(_ generation: UInt64) throws {
        guard generation == currentGeneration() else { throw CancellationError() }
    }

    private func ensureRunning(expectedGeneration: UInt64) throws {
        try checkGeneration(expectedGeneration)
        // A recently terminated child can still report isRunning while its
        // pipes drain. It belongs to the canceled generation and cannot be reused.
        if process?.isRunning == true, workerGeneration == expectedGeneration { return }
        reset()
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: model.path) else {
            throw DictationError.message("The bundled speech engine or model is missing. Restore the complete app.")
        }
        let task = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        task.executableURL = executable; task.arguments = [model.path]
        task.standardInput = stdinPipe; task.standardOutput = stdoutPipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        processLock.lock()
        if expectedGeneration != cancellationGeneration {
            processLock.unlock(); Self.terminate(task); throw CancellationError()
        }
        process = task
        workerGeneration = expectedGeneration
        processLock.unlock()
        input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        // Close the parent's unused pipe ends so terminated workers produce EOF.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        for handle in [input!, output!] {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                throw DictationError.message("Could not configure the speech engine connection.")
            }
        }
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reply = try readJSON(deadline: ProcessInfo.processInfo.systemUptime + startupTimeout,
                                 generation: expectedGeneration)
        guard reply["ready"] as? Bool == true else {
            throw DictationError.message(reply["error"] as? String ?? "The speech engine could not start.")
        }
        let version = (reply["protocol"] as? Int) ?? 1
        guard version == 1 || version == 2 else {
            throw DictationError.message("The speech worker protocol is unsupported. Restore the complete app.")
        }
        workerProtocol = version
    }

    private func waitForIO(_ fd: Int32, events: Int16, deadline: TimeInterval,
                           generation: UInt64) throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            try checkGeneration(generation)
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let remaining = max(1, min(100, Int((deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            let result = poll(&descriptor, 1, Int32(remaining))
            if result < 0 { if errno == EINTR { continue }; break }
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { break }
            }
        }
        try checkGeneration(generation)
        throw DictationError.message("The speech engine stopped responding. Try dictating again.")
    }

    private func write(_ data: Data, to fd: Int32, deadline: TimeInterval,
                       generation: UInt64) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try waitForIO(fd, events: Int16(POLLOUT), deadline: deadline, generation: generation)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(16_384, bytes.count - offset))
                if count > 0 { offset += count }
                else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                else { throw DictationError.message("The speech engine disconnected. Try dictating again.") }
            }
        }
    }

    private func readJSON(deadline: TimeInterval, generation: UInt64) throws -> [String: Any] {
        guard let output else { throw DictationError.message("The speech engine is unavailable.") }
        let fd = output.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            try checkGeneration(generation)
            if let newline = readBuffer.firstIndex(of: 10) {
                let length = readBuffer.distance(from: readBuffer.startIndex, to: newline)
                guard length <= 128_000 else { break }
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { break }
                return json
            }
            guard readBuffer.count <= 128_000 else { break }
            try waitForIO(fd, events: Int16(POLLIN), deadline: deadline, generation: generation)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { break }
            readBuffer.append(contentsOf: chunk.prefix(count))
        }
        throw DictationError.message("The speech engine returned an invalid response. Try dictating again.")
    }

    private static func terminate(_ worker: Process) {
        guard worker.isRunning else { return }
        worker.terminate()
        // A wedged helper must not retain a model or a pipe forever. Process
        // tracks termination, preventing escalation after this child exits.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if worker.isRunning { _ = Darwin.kill(worker.processIdentifier, SIGKILL) }
        }
    }

    private func reset(expectedGeneration: UInt64? = nil) {
        processLock.lock()
        if let expectedGeneration, let workerGeneration, workerGeneration != expectedGeneration {
            processLock.unlock(); return
        }
        let worker = process; process = nil; workerGeneration = nil; timing = nil
        vocabularyOverflowIDs.removeAll(); processLock.unlock()
        if let worker { Self.terminate(worker) }
        try? input?.close(); try? output?.close()
        input = nil; output = nil
        readBuffer.removeAll(keepingCapacity: true)
        workerProtocol = 1
    }
}
