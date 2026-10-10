import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Opt-in real-model benchmark over the checked-in public synthetic recipes.
/// Reports hashes, timings and categorical marker counts, never transcripts.
@main struct UpgradeModelBenchmark {
    struct Marker: Decodable {
        let group: String
        let pattern: String
        let raw: Int
        let clean: Int
        let caseSensitive: Bool
    }
    struct Fixture: Decodable {
        let id: Int
        let name: String
        let file: String
        let audioSHA256: String
        let audioSeconds: Double
        let speechSeconds: Double
        let explicitPauseSeconds: Double
        let quietPause: Bool
        let rate: Int
        let markers: [Marker]
    }
    struct Word: Decodable { let preferred: String; let aliases: [String] }
    struct Manifest: Decodable {
        let schema: Int
        let definitionSHA256: String
        let voice: String
        let vocabulary: [Word]
        let cases: [Fixture]
    }

    #if BASELINE
    static let variant = "baseline"
    static let maximumSamples = 1_920_000
    #else
    static let variant = "candidate"
    static let maximumSamples = RecordingPolicy.maximumSamples
    #endif

    @MainActor static func main() async {
        do { try await run() }
        catch {
            fputs("Upgrade benchmark stopped: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 10, let shortRuns = Int(args[5]), let longRuns = Int(args[6]),
              (1...100).contains(shortRuns), (1...40).contains(longRuns),
              let port = Int(args[8]), (1024...65535).contains(port) else {
            throw DictationError.message("Usage: upgrade-model-benchmark resources models fixtures report.json short_runs long_runs case_ids|all port source_sha256")
        }
        let resources = URL(fileURLWithPath: args[1]), models = URL(fileURLWithPath: args[2])
        let fixtures = URL(fileURLWithPath: args[3]), destination = URL(fileURLWithPath: args[4])
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        guard manifest.schema == 1 else { throw DictationError.message("Unsupported synthetic manifest.") }
        let ids = args[7] == "all" ? Set(manifest.cases.map(\.id)) : Set(args[7].split(separator: ",").compactMap { Int($0) })
        let cases = manifest.cases.filter { ids.contains($0.id) }
        guard !cases.isEmpty, cases.count == ids.count else { throw DictationError.message("Unknown synthetic fixture ID.") }
        let vocabulary = try VocabularySnapshot(entries: manifest.vocabulary.map {
            try VocabularyEntry.normalized(preferredSpelling: $0.preferred, aliases: $0.aliases)
        }, revision: 1)
        let workerHash = try sha256(resources.appendingPathComponent("whisper-worker"))
        var rows: [[String: Any]] = [], skipped: [[String: Any]] = []
        var audio: [(Fixture, [Float])] = []
        for test in cases {
            guard URL(fileURLWithPath: test.file).lastPathComponent == test.file else {
                throw DictationError.message("Synthetic manifest audio path must be a filename.")
            }
            let path = fixtures.appendingPathComponent(test.file)
            guard try sha256(path) == test.audioSHA256 else {
                throw DictationError.message("Synthetic fixture hash changed. Regenerate before comparing builds.")
            }
            let samples = try readSamples(path)
            guard abs(Double(samples.count) / 16_000 - test.audioSeconds) < 0.000_1 else {
                throw DictationError.message("Synthetic fixture duration does not match its manifest.")
            }
            if samples.count > maximumSamples {
                skipped.append(["case": test.id, "reason": "durationUnsupported", "audio_seconds": test.audioSeconds])
            } else { audio.append((test, samples)) }
        }
        func save() throws {
            try writeReport(rows: rows, skipped: skipped, manifest: manifest, workerHash: workerHash,
                            sourceHash: args[9], shortRuns: shortRuns, longRuns: longRuns, to: destination)
        }
        try save()
        if audio.isEmpty { return }

        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        var probe = URLRequest(url: endpoint.appendingPathComponent("api/version")); probe.timeoutInterval = 0.3
        if (try? await URLSession.shared.data(for: probe)) != nil {
            throw DictationError.message("Isolated benchmark port is occupied; no external service was used.")
        }
        let service = LocalCorrectionService(resources: resources, models: models, endpoint: endpoint)
        let cleanup = service.makeCleanupClient()
        let engine = WhisperTranscriber(resources: resources, models: models)
        var terminating = false
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    guard !terminating else { return }
                    terminating = true; engine.cancel()
                    Task { @MainActor in
                        await engine.suspend(); await service.suspend(); exit(130)
                    }
                }
            }
            source.resume(); return source
        }
        defer { for source in signals { source.cancel() } }
        do {
            try await engine.prepare()
            try await service.start()
            await cleanup.preload()
            for (test, samples) in audio {
                // Warm the same utterance, vocabulary and cleanup path once
                // before measurements. Startup time is excluded from warm rows.
                let warmRaw = try await engine.transcribe(samples, vocabulary: vocabulary)
                _ = try await cleaned(warmRaw, mode: "clean", client: cleanup, vocabulary: vocabulary)
                let repetitions = test.id == 101 ? shortRuns : longRuns
                for run in 0..<repetitions {
                    for mode in run % 2 == 0 ? ["clean", "verbatim"] : ["verbatim", "clean"] {
                        let started = ProcessInfo.processInfo.systemUptime
                        var row: [String: Any] = ["variant": variant, "case": test.id, "mode": mode, "run": run,
                            "audio_sha256": test.audioSHA256, "audio_seconds": test.audioSeconds,
                            "speech_seconds": test.speechSeconds, "explicit_pause_seconds": test.explicitPauseSeconds,
                            "quiet_pause": test.quietPause ? 1 : 0, "synthetic_rate": test.rate]
                        do {
                            let raw = try await engine.transcribe(samples, vocabulary: vocabulary)
                            let recognized = ProcessInfo.processInfo.systemUptime
                            let result = try await cleaned(raw, mode: mode, client: cleanup, vocabulary: vocabulary)
                            let finished = ProcessInfo.processInfo.systemUptime
                            row["asr_seconds"] = recognized - started
                            row["cleanup_seconds"] = finished - recognized
                            row["total_seconds"] = finished - started
                            row["cleanup_fallback"] = result.reasons.isEmpty ? 0 : 1
                            row["fallback_reasons"] = result.reasons
                            row["cleanup_completed_chunks"] = result.completed
                            row["cleanup_total_chunks"] = result.total
                            row["raw_characters"] = raw.count; row["final_characters"] = result.text.count
                            row["no_speech"] = raw.isEmpty ? 1 : 0; row["failed"] = 0
                            row["vocabulary_overflow_count"] = engine.lastVocabularyOverflowIDs.count
                            for (key, value) in quality(raw, markers: test.markers, clean: false) { row["raw_" + key] = value }
                            for (key, value) in quality(result.text, markers: test.markers, clean: mode == "clean") { row["final_" + key] = value }
                            if let timing = engine.lastTiming {
                                row["asr_startup_seconds"] = timing.startupSeconds
                                row["asr_write_seconds"] = timing.writeSeconds
                                row["asr_recognition_seconds"] = timing.recognitionSeconds
                            }
                        } catch {
                            if error is CancellationError { throw error }
                            row["failed"] = 1; row["error_code"] = "processingFailed"
                            row["total_seconds"] = ProcessInfo.processInfo.systemUptime - started
                        }
                        rows.append(row); try save()
                        print("\(variant) case \(test.id), \(mode), run \(run + 1)/\(repetitions): failed=\(row["failed"]!)")
                        fflush(stdout)
                    }
                }
            }
            await engine.suspend(); await service.suspend()
        } catch {
            await engine.suspend(); await service.suspend()
            throw error
        }
    }

    static func cleaned(_ raw: String, mode: String, client: CleanupClient, vocabulary: VocabularySnapshot)
        async throws -> (text: String, reasons: [String], completed: Int, total: Int) {
        guard mode == "clean", !raw.isEmpty else { return (raw, [], 0, 0) }
        #if BASELINE
        do { return (try await client.clean(raw, vocabulary: vocabulary), [], 1, 1) }
        catch {
            if error is CancellationError { throw error }
            let reason: String
            switch error as? CleanupError {
            case .inputTooLong: reason = "inputTooLong"
            case .timedOut: reason = "deadline"
            case .serviceUnavailable: reason = "serviceUnavailable"
            default: reason = "validationRejected"
            }
            return (raw, [reason], 1, 1)
        }
        #else
        let outcome = try await CleanupCoordinator(client: client).clean(raw, vocabulary: vocabulary)
        return (outcome.text, outcome.fallbackReasons, outcome.completedChunks, outcome.totalChunks)
        #endif
    }

    static func quality(_ text: String, markers: [Marker], clean: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        var flags: [Int] = []
        for group in ["amounts", "identifiers", "negation", "vocabulary", "canonical"] {
            let selected = markers.filter { $0.group == group }
            let outcomes = selected.map { marker -> Int in
                guard let regex = try? NSRegularExpression(pattern: marker.pattern, options: marker.caseSensitive ? [] : [.caseInsensitive]) else { return 0 }
                let count = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                return count == (clean ? marker.clean : marker.raw) ? 1 : 0
            }
            result[group + "_checks"] = selected.count
            result[group + "_passed"] = outcomes.reduce(0, +)
            flags.append(contentsOf: outcomes)
        }
        result["marker_flags"] = flags
        result["all_markers_passed"] = !flags.isEmpty && flags.allSatisfy { $0 == 1 } ? 1 : 0
        return result
    }

    static func readSamples(_ path: URL) throws -> [Float] {
        let audio = try AVAudioFile(forReading: path, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
              audio.length > 0, audio.length <= 4_800_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw DictationError.message("Expected a generated mono 16 kHz fixture of at most five minutes.")
        }
        try audio.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw DictationError.message("Fixture has no readable audio samples.") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func sha256(_ path: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    static func writeReport(rows: [[String: Any]], skipped: [[String: Any]], manifest: Manifest,
                            workerHash: String, sourceHash: String, shortRuns: Int, longRuns: Int, to destination: URL) throws {
        var summary: [[String: Any]] = []
        for fixture in manifest.cases {
            for mode in ["clean", "verbatim"] {
                let group = rows.filter { $0["case"] as? Int == fixture.id && $0["mode"] as? String == mode }
                guard !group.isEmpty else { continue }
                let successful = group.filter { $0["failed"] as? Int == 0 }
                var entry: [String: Any] = ["case": fixture.id, "mode": mode, "audio_sha256": fixture.audioSHA256,
                    "samples": group.count, "successful_samples": successful.count, "failed_samples": group.count - successful.count,
                    "cleanup_fallbacks": successful.reduce(0) { $0 + ($1["cleanup_fallback"] as? Int ?? 0) },
                    "all_markers_passed_runs": successful.reduce(0) { $0 + ($1["final_all_markers_passed"] as? Int ?? 0) }]
                for field in ["asr_seconds", "cleanup_seconds", "total_seconds"] {
                    let values = successful.compactMap { $0[field] as? Double }
                    if !values.isEmpty {
                        entry[field + "_median"] = percentile(values, 0.5)
                        entry[field + "_p95"] = percentile(values, 0.95)
                    }
                }
                summary.append(entry)
            }
        }
        let report: [String: Any] = ["schema": 1, "variant": variant, "source_sha256": sourceHash,
            "worker_sha256": workerHash, "fixture_definition_sha256": manifest.definitionSHA256,
            "synthetic_voice": manifest.voice, "warm_short_runs": shortRuns, "warm_long_runs": longRuns,
            "percentile_method": "nearest_rank", "measurement": "warm_backend_excluding_microphone_and_delivery",
            "quality_scope": "synthetic_categorical_markers_not_accuracy_or_semantic_equivalence",
            "rows": rows, "summary": summary, "skipped": skipped]
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
    }
}
