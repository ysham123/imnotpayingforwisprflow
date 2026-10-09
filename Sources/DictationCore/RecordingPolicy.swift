import Foundation

public enum RecordingPolicy {
    public static let sampleRate = 16_000.0
    public static let maximumDuration: TimeInterval = 300
    public static let maximumSamples = 4_800_000
    public static let countdownDuration: TimeInterval = 15

    public static func elapsed(started: TimeInterval, now: TimeInterval) -> TimeInterval {
        min(maximumDuration, max(0, now - started))
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
