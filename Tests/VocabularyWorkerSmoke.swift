import Foundation

@main struct VocabularyWorkerSmoke {
    static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let models = resources.appendingPathComponent("ExternalModels")
        let first = try VocabularyEntry.normalized(preferredSpelling: "José")
        let second = try VocabularyEntry.normalized(preferredSpelling: "Wispr Flow")
        let vocab = try VocabularySnapshot(entries: [first, second])
        let engine = WhisperTranscriber(resources: resources, models: models, startupTimeout: 2, requestTimeout: 2)
        let text = try await engine.transcribe([0.25, -0.5, 0.75], vocabulary: vocab)
        precondition(text == "recognized" && engine.lastVocabularyOverflowIDs == [second.id])
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("requests.json"))) as! [[String: Any]]
        precondition(record[0]["terms"] as? [String] == ["José", "Wispr Flow"], "UTF8 and saved order retained")
        precondition(record[0]["samples"] as? [Double] == [0.25, -0.5, 0.75], "PCM unchanged by framing")
        precondition(record[0]["external_model"] as? Bool == true, "External model path used")
        _ = try await engine.transcribe([0.25, -0.5, 0.75])
        precondition(engine.lastVocabularyOverflowIDs.isEmpty, "No sticky vocabulary metadata")
        try "badid".write(to: resources.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        do { _ = try await engine.transcribe([0.25, -0.5, 0.75], vocabulary: vocab); fatalError("Invalid overflow ID accepted") } catch { }
        precondition(engine.lastVocabularyOverflowIDs.isEmpty, "Fault clears stale vocabulary status")
        try "healthy".write(to: resources.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        _ = try await engine.transcribe([0.25, -0.5, 0.75], vocabulary: vocab)
        precondition(engine.lastVocabularyOverflowIDs == [second.id], "Recovery retains snapshot")
        engine.shutdown()
        print("Passed 8 vocabulary IPC, external-model, status, and recovery checks")
    }
}
