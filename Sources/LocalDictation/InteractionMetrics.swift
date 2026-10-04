import Foundation

/// Content-free, memory-only measurements. A user must explicitly export them.
@MainActor
final class InteractionMetrics {
    private struct Sample {
        var began: TimeInterval
        var marks: [String: Double] = [:]
        var outcome = "active"
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

    func export() throws -> Data {
        let rows: [[String: Any]] = order.compactMap { id in
            guard let sample = samples[id] else { return nil }
            var durations = sample.marks
            if let stopped = durations["stopped"] {
                for stage in ["transcribed", "corrected", "dispatched", "verifiedVisible", "nextCaptureReady"] {
                    if let end = sample.marks[stage] { durations["stopTo_" + stage] = max(0, end - stopped) }
                }
            }
            return ["milliseconds": durations, "outcome": sample.outcome]
        }
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sessions": rows], options: [.prettyPrinted, .sortedKeys])
    }
}
