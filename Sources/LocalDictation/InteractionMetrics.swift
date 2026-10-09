import Foundation

/// Content-free, memory-only measurements. A user must explicitly export them.
@MainActor
final class InteractionMetrics {
    private struct Sample {
        var began: TimeInterval
        var marks: [String: Double] = [:]
        var outcome = "active"
        var metadata: [String: String] = [:]
        var numeric: [String: Double] = [:]
    }
    private var samples: [UUID: Sample] = [:]
    private var order: [UUID] = []

    func begin(_ id: UUID) {
        samples[id] = Sample(began: ProcessInfo.processInfo.systemUptime)
        order.append(id)
        while order.count > 100 { samples.removeValue(forKey: order.removeFirst()) }
    }

    func mark(_ stage: String, _ id: UUID) {
        guard var value = samples[id], value.marks[stage] == nil else { return }
        value.marks[stage] = (ProcessInfo.processInfo.systemUptime - value.began) * 1_000
        samples[id] = value
    }

    func finish(_ outcome: String, _ id: UUID) {
        guard samples[id] != nil else { return }
        samples[id]?.outcome = outcome
    }

    /// Only bounded categories and numeric facts belong here, never user content.
    func recording(mode: String, duration: TimeInterval, retry: Bool, _ id: UUID) {
        guard samples[id] != nil else { return }
        samples[id]?.metadata["mode"] = mode == "verbatim" ? "verbatim" : "clean"
        samples[id]?.metadata["recovery"] = retry ? "retry" : "initial"
        samples[id]?.numeric["audioSeconds"] = max(0, duration)
    }

    func cleanup(completed: Int, total: Int, fallbacks: [String], _ id: UUID) {
        guard samples[id] != nil else { return }
        samples[id]?.numeric["cleanupCompleted"] = Double(completed)
        samples[id]?.numeric["cleanupTotal"] = Double(total)
        samples[id]?.numeric["cleanupFallbacks"] = Double(fallbacks.count)
        let known: Set<String> = ["validation", "service", "deadline", "requestLimit", "oversized", "originalRequested", "unavailable", "protectedSpanTooLong", "validationRejected", "serviceUnavailable", "assemblyRejected", "passageTooLong"]
        samples[id]?.metadata["fallback"] = Set(fallbacks.map { known.contains($0) ? $0 : "validation" }).sorted().joined(separator: ",")
    }

    func export() throws -> Data {
        let rows: [[String: Any]] = order.compactMap { id in
            guard let sample = samples[id] else { return nil }
            var durations = sample.marks
            if let stopped = durations["stopped"] {
                for stage in ["transcribed", "corrected", "dispatched", "verifiedVisible", "nextCaptureReady"] {
                    if let end = sample.marks[stage] { durations["stopTo_" + stage] = max(0, end - stopped) }
                }
            }
            return ["milliseconds": durations, "outcome": sample.outcome,
                    "categories": sample.metadata, "measurements": sample.numeric]
        }
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "sessions": rows], options: [.prettyPrinted, .sortedKeys])
    }
}
