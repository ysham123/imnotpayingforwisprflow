import Foundation

@main struct NativeRecordingPolicyCheck {
    static func main() {
        precondition(Int(RecordingPolicy.sampleRate * RecordingPolicy.maximumDuration) == RecordingPolicy.maximumSamples)
        print("\(Int(RecordingPolicy.sampleRate)) \(RecordingPolicy.maximumSamples)")
    }
}
