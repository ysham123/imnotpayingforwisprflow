import Foundation
import AVFoundation
import Darwin

/// Explicit benchmark tool: uses supplied fixture audio, an isolated local
/// service, and numeric measurements. It never prints or saves transcripts.
@main struct BackendBenchmark {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 6, let runs = Int(args[4]), runs > 0,
              let idleSeconds = Double(args[5]), idleSeconds >= 0 else {
            throw DictationError.message("Usage: benchmark resources audio.wav report.json runs idle_seconds")
        }
        let resources = URL(fileURLWithPath: args[1])
        let models = ProcessInfo.processInfo.environment["LOCAL_DICTATION_MODELS"]
            .map { URL(fileURLWithPath: $0) } ?? resources.appendingPathComponent("Models")
        let warmRuns = args.count > 6 ? (Int(args[6]) ?? runs) : runs
        guard warmRuns > 0 else { throw DictationError.message("Warm run count must be positive.") }
        let fixture = try samples(URL(fileURLWithPath: args[2]))
        guard fixture.count >= 4_000, fixture.count * 3 <= 1_920_000 else {
            throw DictationError.message("Fixture must be 0.25–40 seconds; long case repeats it three times.")
        }
        let endpoint = URL(string: "http://127.0.0.1:11439")!
        // Never reuse or unload somebody else's service on the benchmark port.
        var probe = URLRequest(url: endpoint.appendingPathComponent("api/version"))
        probe.timeoutInterval = 0.3
        if (try? await URLSession.shared.data(for: probe)) != nil {
            throw DictationError.message("Benchmark port 11439 is occupied; stop that benchmark first.")
        }
        let server = Process()
        server.executableURL = resources.appendingPathComponent("ollama")
        server.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11439"
        environment["OLLAMA_MODELS"] = models.appendingPathComponent("ollama").path
        environment["OLLAMA_NO_CLOUD"] = "1"; environment["OLLAMA_NOPRUNE"] = "1"
        environment["OLLAMA_NUM_PARALLEL"] = "1"; environment["OLLAMA_KEEP_ALIVE"] = "-1"
        server.environment = environment
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            server.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if server.isRunning { _ = kill(server.processIdentifier, SIGKILL) }
            }
        }
        #if BASELINE
        let cleanup = CleanupClient(baseURL: endpoint)
        #else
        let lease = CorrectionServiceLease(endpoint: endpoint)
        lease.activate(server)
        let cleanup = CleanupClient(baseURL: endpoint, ownedServiceLease: lease)
        #endif
        var ready = false
        for _ in 0..<60 {
            if await cleanup.isAvailable() { ready = true; break }
            guard server.isRunning else { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard ready else { throw DictationError.message("Isolated benchmark service did not start.") }
        var rows = [[String: Any]]()
        for (length, audio) in [("short", fixture), ("long", Array(repeating: fixture, count: 3).flatMap { $0 })] {
            for condition in ["warm", "cold", "idle", "post_cancel"] {
                let conditionRuns = condition == "warm" ? warmRuns : runs
                #if BASELINE
                let engine = WhisperTranscriber(resources: resources)
                #else
                let engine = WhisperTranscriber(resources: resources, models: models)
                #endif
                defer { engine.shutdown() }
                if condition != "cold" {
                    try await engine.prepare()
                    // Warm both weights and an actual speech inference before
                    // measuring the persistent worker used by normal dictation.
                    _ = try await engine.transcribe(audio)
                    await cleanup.preload()
                }
                for run in 0..<conditionRuns {
                    if condition == "cold" {
                        engine.cancel()
                        try await Task.sleep(nanoseconds: 600_000_000)
                        var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
                        request.httpMethod = "POST"; request.timeoutInterval = 10
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.httpBody = try JSONSerialization.data(withJSONObject: ["model":"qwen3:4b", "keep_alive":0, "stream":false])
                        let (_, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw DictationError.message("Could not unload isolated benchmark model.")
                        }
                    } else if condition != "warm" {
                        try await engine.prepare(); await cleanup.preload()
                    }
                    if condition == "idle", idleSeconds > 0 {
                        try await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000))
                    }
                    if condition == "post_cancel" {
                        let canceled = Task { try await engine.transcribe(audio) }
                        try await Task.sleep(nanoseconds: 50_000_000)
                        canceled.cancel(); engine.cancel(); _ = try? await canceled.value
                    }
                    let started = ProcessInfo.processInfo.systemUptime
                    let raw = try await engine.transcribe(audio)
                    let recognized = ProcessInfo.processInfo.systemUptime
                    var cleaned = raw, cleanupSucceeded = 1
                    do { cleaned = try await cleanup.clean(raw) } catch { cleanupSucceeded = 0 }
                    let finished = ProcessInfo.processInfo.systemUptime
                    var row: [String: Any] = ["condition":condition, "length":length, "run":run,
                        "audio_seconds":Double(audio.count) / 16_000, "idle_seconds":condition == "idle" ? idleSeconds : 0,
                        "asr_seconds":recognized - started, "cleanup_seconds":finished - recognized,
                        "total_seconds":finished - started, "cleanup_success":cleanupSucceeded,
                        "raw_characters":raw.count, "cleaned_characters":cleaned.count]
                    #if !BASELINE
                    if let timing = engine.lastTiming {
                        row["asr_startup_seconds"] = timing.startupSeconds
                        row["asr_write_seconds"] = timing.writeSeconds
                        row["asr_recognition_seconds"] = timing.recognitionSeconds
                    }
                    if let timing = cleanup.lastTiming, cleanupSucceeded == 1 {
                        row["metadata_seconds"] = timing.metadataSeconds
                        row["validation_seconds"] = timing.validationSeconds
                        row["model_load_seconds"] = timing.loadSeconds
                        row["prompt_seconds"] = timing.promptSeconds
                        row["generation_seconds"] = timing.generationSeconds
                        row["input_tokens"] = timing.inputTokens
                        row["output_tokens"] = timing.outputTokens
                    }
                    #endif
                    rows.append(row)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    print("\(length) \(condition) \(run + 1)/\(conditionRuns): \(String(format: "%.3f", finished - started))s success=\(cleanupSucceeded)")
                    fflush(stdout)
                }
                engine.shutdown()
                try await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        var summaries = [[String: Any]]()
        for length in ["short", "long"] {
            for condition in ["warm", "cold", "idle", "post_cancel"] {
                let group = rows.filter { $0["length"] as? String == length && $0["condition"] as? String == condition }
                var summary: [String: Any] = ["length":length, "condition":condition, "runs":group.count]
                for metric in ["asr_seconds", "cleanup_seconds", "total_seconds", "metadata_seconds", "model_load_seconds", "prompt_seconds", "generation_seconds"] {
                    let values = group.compactMap { $0[metric] as? Double }.sorted()
                    guard !values.isEmpty else { continue }
                    let middle = values.count / 2
                    summary[metric + "_median"] = values.count % 2 == 0 ? (values[middle - 1] + values[middle]) / 2 : values[middle]
                    summary[metric + "_p95"] = values[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)]
                }
                summaries.append(summary)
            }
        }
        let report: [String: Any] = ["schema_version":1, "idle_seconds":idleSeconds, "warm_runs":warmRuns, "rows":rows, "summary":summaries]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    }

    static func samples(_ path: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: path)
        guard file.length > 0, file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 40) else {
            throw DictationError.message("Benchmark audio fixture must be at most 40 seconds.")
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate + 4096))!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        converter.downmix = true
        var supplied = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
