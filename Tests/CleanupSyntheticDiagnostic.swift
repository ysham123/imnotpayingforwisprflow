import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Opt-in diagnostic: only the hash-verified public synthetic fixture 101.
/// Unlike the numeric benchmark, this deliberately prints its synthetic text.
@main struct CleanupSyntheticDiagnostic {
    struct Word: Decodable { let preferred: String; let aliases: [String] }
    struct Fixture: Decodable { let id: Int; let file: String; let audioSHA256: String; let audioSeconds: Double }
    struct Manifest: Decodable {
        let schema: Int
        let definitionSHA256: String
        let generatorSHA256: String
        let vocabulary: [Word]
        let cases: [Fixture]
    }

    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Synthetic diagnostic stopped: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let port = Int(args[5]), (1024...65535).contains(port) else {
            throw DictationError.message("Usage: cleanup-synthetic-diagnostic resources models fixtures source-root port")
        }
        let resources = URL(fileURLWithPath: args[1]), models = URL(fileURLWithPath: args[2])
        let fixtures = URL(fileURLWithPath: args[3]), sourceRoot = URL(fileURLWithPath: args[4])
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        guard manifest.schema == 1,
              try manifest.definitionSHA256 == sha256(sourceRoot.appendingPathComponent("Tests/UpgradeFixtures.json")),
              try manifest.generatorSHA256 == sha256(sourceRoot.appendingPathComponent("Scripts/generate-upgrade-fixtures.py")),
              let fixture = manifest.cases.first(where: { $0.id == 101 }), fixture.file == "101.wav" else {
            throw DictationError.message("Expected an unchanged generated public fixture manifest with case 101.")
        }
        let path = fixtures.appendingPathComponent("101.wav")
        guard try sha256(path) == fixture.audioSHA256 else { throw DictationError.message("Synthetic audio hash mismatch.") }
        let samples = try readSamples(path)
        guard abs(Double(samples.count) / 16_000 - fixture.audioSeconds) < 0.000_1 else {
            throw DictationError.message("Synthetic audio duration mismatch.")
        }
        let vocabulary = try VocabularySnapshot(entries: manifest.vocabulary.map {
            try VocabularyEntry.normalized(preferredSpelling: $0.preferred, aliases: $0.aliases)
        }, revision: 1)
        let systemPrompt = try readSystemPrompt(sourceRoot.appendingPathComponent("Sources/LocalDictation/CleanupClient.swift"))
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var probe = URLRequest(url: endpoint.appendingPathComponent("api/version")); probe.timeoutInterval = 0.3
        if (try? await session.data(for: probe)) != nil { throw DictationError.message("Diagnostic port is occupied.") }
        let service = LocalCorrectionService(resources: resources, models: models, endpoint: endpoint)
        let client = service.makeCleanupClient()
        let engine = WhisperTranscriber(resources: resources, models: models)
        var terminating = false
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            Darwin.signal(number, SIG_IGN)
            let signal = DispatchSource.makeSignalSource(signal: number, queue: .main)
            signal.setEventHandler {
                MainActor.assumeIsolated {
                    guard !terminating else { return }
                    terminating = true; engine.cancel()
                    Task { @MainActor in await engine.suspend(); await service.suspend(); exit(130) }
                }
            }
            signal.resume(); return signal
        }
        defer { signals.forEach { $0.cancel() } }
        do {
            try await engine.prepare(); try await service.start(); await client.preload()
            let raw = try await engine.transcribe(samples, vocabulary: vocabulary).trimmingCharacters(in: .whitespacesAndNewlines)
            print("PUBLIC SYNTHETIC CASE 101 ASR: \(raw)")
            let input = try JSONSerialization.data(withJSONObject: ["custom_vocabulary": vocabulary.cleanupHints(for: raw), "dictated_text": raw], options: [.sortedKeys])
            let schema: [String: Any] = ["type": "object", "properties": ["cleaned_text": ["type": "string"]],
                "required": ["cleaned_text"], "additionalProperties": false]
            let body: [String: Any] = ["model": client.model, "system": systemPrompt,
                "prompt": "Correct the dictated_text value in the following JSON data. Return only the required JSON object.\n\(String(decoding: input, as: UTF8.self))\n/no_think",
                "stream": false, "think": false, "keep_alive": -1, "format": schema,
                "options": ["num_ctx": 4096, "num_predict": 512, "temperature": 0]]
            var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            print("QWEN HTTP STATUS: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            print("QWEN PRE-VALIDATION JSON: \(String(decoding: data, as: UTF8.self))")
            if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = reply["response"] as? String,
               let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               object.count == 1, let corrected = object["cleaned_text"] as? String {
                let reason = (reply["done_reason"] as? String ?? "").lowercased()
                let truncated = ["length", "max_tokens", "limit"].contains(reason) || (reply["eval_count"] as? Int ?? 0) >= 512
                print("RESPONSE ENVELOPE: done=\(reply["done"] as? Bool == true), truncated=\(truncated), bytes=\(text.utf8.count)")
                do { print("VALIDATION ACCEPTED: \(try CleanupClient.validate(corrected, against: raw, vocabulary: vocabulary))") }
                catch { print("VALIDATION REJECTED: \(String(reflecting: error))") }
            } else { print("RESPONSE ENVELOPE: missing or invalid cleaned_text object") }
            await engine.suspend(); await service.suspend()
        } catch {
            await engine.suspend(); await service.suspend(); throw error
        }
    }

    static func readSystemPrompt(_ path: URL) throws -> String {
        let source = try String(contentsOf: path, encoding: .utf8)
        guard let start = source.range(of: "private static let systemPrompt = \"\"\"\n"),
              let end = source.range(of: "\n    \"\"\"", range: start.upperBound..<source.endIndex) else {
            throw DictationError.message("Could not extract the current production system prompt.")
        }
        return source[start.upperBound..<end.lowerBound].components(separatedBy: "\n").map {
            $0.hasPrefix("    ") ? String($0.dropFirst(4)) : $0
        }.joined(separator: "\n")
    }

    static func sha256(_ path: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
    }

    static func readSamples(_ path: URL) throws -> [Float] {
        let audio = try AVAudioFile(forReading: path, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
              audio.length > 0, audio.length <= 480_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw DictationError.message("Expected short mono 16 kHz public synthetic fixture 101.")
        }
        try audio.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw DictationError.message("Unreadable synthetic audio.") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
