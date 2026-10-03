import AVFoundation
import Foundation

@main struct AudioSmoke {
    static func main() throws {
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        func session(rate: Double, channels: AVAudioChannelCount, maximum: Int = 32_000) -> CaptureSession {
            let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
            let converter = AVAudioConverter(from: input, to: output)!
            converter.downmix = true
            return CaptureSession(converter: converter, outputFormat: output, inputSampleRate: rate, maximumSamples: maximum)
        }
        func buffer(rate: Double = 48_000, channels: AVAudioChannelCount = 2, frames: AVAudioFrameCount = 4_800) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
            let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            result.frameLength = frames
            for c in 0..<Int(channels) { for i in 0..<Int(frames) { result.floatChannelData![c][i] = 0.1 } }
            return result
        }
        let normal = session(rate: 48_000, channels: 2)
        normal.capture(buffer())
        let converted = try normal.finish()
        precondition((1_580...1_620).contains(converted.samples.count), "Resampling lost frames")
        precondition(converted.warning == nil && converted.samples.allSatisfy { $0.isFinite })
        print("PASS stereo 48 kHz → mono 16 kHz with converter tail")
        let limit = session(rate: 16_000, channels: 1, maximum: 1_000)
        limit.capture(buffer(rate: 16_000, channels: 1, frames: 1_500))
        let limited = try limit.finish()
        precondition(limited.samples.count == 1_000 && limited.warning != nil)
        print("PASS sample cap keeps the full prefix")
        let changed = session(rate: 48_000, channels: 2)
        changed.capture(buffer()); changed.capture(buffer(rate: 44_100))
        let recovered = try changed.finish()
        precondition(!recovered.samples.isEmpty && recovered.warning != nil)
        print("PASS format change keeps captured speech")
        let interrupted = session(rate: 48_000, channels: 2)
        interrupted.capture(buffer()); interrupted.interrupt(.inputChanged)
        let prefix = try interrupted.finish()
        precondition(!prefix.samples.isEmpty && prefix.warning != nil)
        print("PASS device interruption keeps captured speech")
        let empty = session(rate: 48_000, channels: 2)
        empty.interrupt(.inputChanged)
        do { _ = try empty.finish(); fatalError("Empty interruption accepted") } catch AudioRecorder.RecordingError.inputChanged { }
        let canceled = session(rate: 48_000, channels: 2)
        canceled.capture(buffer()); canceled.discard(); canceled.capture(buffer())
        do { _ = try canceled.finish(); fatalError("Canceled audio returned") } catch AudioRecorder.RecordingError.emptyRecording { }
        print("PASS empty interruption and discard ignore late buffers")
        print("Passed 6 audio recovery regressions")
    }
}
