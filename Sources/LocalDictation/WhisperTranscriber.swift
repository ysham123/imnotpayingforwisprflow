import Foundation
import Darwin

enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Serial process boundary keeps audio and model work away from AppKit.
final class WhisperTranscriber {
    private let queue = DispatchQueue(label: "localdictation.whisper", qos: .userInitiated)
    private var process: Process?
    private let processLock = NSLock()
    private var cancellationGeneration: UInt64 = 0
    private var input: FileHandle?
    private var output: FileHandle?
    private let executable: URL
    private let model: URL

    private let startupTimeout: TimeInterval
    private let requestTimeout: TimeInterval

    init(resources: URL, startupTimeout: TimeInterval = 90, requestTimeout: TimeInterval = 120) {
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        executable = resources.appendingPathComponent("whisper-worker")
        model = resources.appendingPathComponent("Models/ggml-large-v3-turbo-q8_0.bin")
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
                    } catch { self.reset(); continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel(expectedGeneration: generation) })
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        let generation = currentGeneration()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try self.checkGeneration(generation)
                        try self.ensureRunning(expectedGeneration: generation)
                        try self.checkGeneration(generation)
                        guard !samples.isEmpty, samples.count <= 1_920_000, let input = self.input else {
                            throw DictationError.message("The dictation audio was empty or too long.")
                        }
                        var count = UInt32(samples.count).littleEndian
                        var packet = withUnsafeBytes(of: &count) { Data($0) }
                        samples.withUnsafeBytes { packet.append(contentsOf: $0) }
                        let deadline = ProcessInfo.processInfo.systemUptime + self.requestTimeout
                        try self.write(packet, to: input.fileDescriptor, deadline: deadline, generation: generation)
                        let result = try self.readJSON(deadline: deadline, generation: generation)
                        try self.checkGeneration(generation)
                        if let error = result["error"] as? String { throw DictationError.message(error) }
                        guard let text = result["text"] as? String else {
                            throw DictationError.message("The speech engine returned an invalid result.")
                        }
                        continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                    } catch { self.reset(); continuation.resume(throwing: error) }
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
        if process?.isRunning == true { return }
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
        var data = Data(), byte: UInt8 = 0
        while data.count <= 128_000 {
            try waitForIO(fd, events: Int16(POLLIN), deadline: deadline, generation: generation)
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count == 1 else { break }
            if byte == 10 {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
                return json
            }
            data.append(byte)
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

    private func reset() {
        processLock.lock(); let worker = process; process = nil; processLock.unlock()
        if let worker { Self.terminate(worker) }
        try? input?.close(); try? output?.close()
        input = nil; output = nil
    }
}
