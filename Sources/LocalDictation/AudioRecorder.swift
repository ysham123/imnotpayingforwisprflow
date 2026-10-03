import AVFoundation
import Foundation

/// Captures microphone audio only while a dictation session is active. Audio is
/// resampled to mono 16 kHz in memory and is never written to disk.
@MainActor
final class AudioRecorder {
    static let sampleRate = 16_000.0
    static let maximumDuration: TimeInterval = 120

    private var engine: AVAudioEngine?
    private var session: CaptureSession?
    private var configurationObserver: NSObjectProtocol?
    private var sessionID: UUID?
    private(set) var isRecording = false
    var onAutomaticStop: (() -> Void)?

    struct Recording {
        let samples: [Float]
        let warning: String?
    }

    func start() throws {
        guard !isRecording else { throw RecordingError.alreadyRecording }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw RecordingError.unavailableInput }

        // AVAudioConverter performs channel conversion as well as resampling.
        converter.downmix = true
        let token = UUID()
        let session = CaptureSession(
            converter: converter,
            outputFormat: outputFormat,
            inputSampleRate: inputFormat.sampleRate,
            maximumSamples: Int(Self.sampleRate * Self.maximumDuration),
            onBoundary: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == token, self.isRecording else { return }
                    self.onAutomaticStop?()
                }
            }
        )
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            session.capture(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.stop()
            input.removeTap(onBus: 0)
            throw RecordingError.startFailed(error.localizedDescription)
        }
        self.engine = engine
        self.session = session
        sessionID = token
        isRecording = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == token, self.isRecording else { return }
                self.session?.interrupt(.inputChanged)
            }
        }
    }

    func stop() throws -> Recording {
        guard let engine, let session, isRecording else { throw RecordingError.notRecording }
        removeConfigurationObserver()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.session = nil
        sessionID = nil
        isRecording = false
        return try session.finish()
    }

    func cancel() {
        removeConfigurationObserver()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        session?.discard()
        engine = nil
        session = nil
        sessionID = nil
        isRecording = false
    }

    private func removeConfigurationObserver() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    enum RecordingError: LocalizedError {
        case alreadyRecording
        case notRecording
        case unavailableInput
        case startFailed(String)
        case conversionFailed(String)
        case recordingTooLong
        case inputChanged
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already running."
            case .notRecording: return "There is no recording to stop."
            case .unavailableInput: return "The microphone has no usable input format. Check your audio input in System Settings."
            case .startFailed(let reason): return "Could not start the microphone: \(reason)"
            case .conversionFailed(let reason): return "Could not process microphone audio: \(reason)"
            case .recordingTooLong: return "Dictation is limited to 2 minutes. Please record a shorter passage."
            case .inputChanged: return "The microphone changed. The speech captured so far was kept."
            case .emptyRecording: return "No microphone audio was captured."
            }
        }
    }
}

/// The audio tap is called outside the main actor. A lock protects both the
/// converter and the buffer, including teardown while a tap is finishing.
final class CaptureSession: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputSampleRate: Double
    private let maximumSamples: Int
    private var samples: [Float] = []
    private var failure: AudioRecorder.RecordingError?
    private var finished = false
    private let onBoundary: @Sendable () -> Void

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat,
         inputSampleRate: Double, maximumSamples: Int,
         onBoundary: @escaping @Sendable () -> Void = {}) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.inputSampleRate = inputSampleRate
        self.maximumSamples = maximumSamples
        self.onBoundary = onBoundary
        samples.reserveCapacity(min(maximumSamples, 160_000))
    }

    func capture(_ input: AVAudioPCMBuffer) {
        lock.lock()
        var notify = false
        defer { lock.unlock(); if notify { onBoundary() } }
        guard !finished, failure == nil, input.frameLength > 0 else { return }
        guard input.format.isEqual(converter.inputFormat) else {
            failure = .inputChanged; notify = true
            return
        }
        let requiredFrames = ceil(Double(input.frameLength) * outputFormat.sampleRate / inputSampleRate) + 64
        guard requiredFrames.isFinite, requiredFrames > 0,
              requiredFrames <= 160_000,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                             frameCapacity: AVAudioFrameCount(requiredFrames))
        else {
            failure = .conversionFailed("Invalid audio buffer size."); notify = true
            return
        }
        var suppliedInput = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else {
            failure = .conversionFailed(error?.localizedDescription ?? "Audio conversion failed."); notify = true
            return
        }
        guard let channel = output.floatChannelData?[0] else {
            failure = .conversionFailed("The converted audio has no samples."); notify = true
            return
        }
        let count = Int(output.frameLength)
        let accepted = min(count, maximumSamples - samples.count)
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: accepted))
        if samples.count == maximumSamples { failure = .recordingTooLong; notify = true }
    }

    func interrupt(_ reason: AudioRecorder.RecordingError) {
        lock.lock()
        guard !finished, failure == nil else { lock.unlock(); return }
        failure = reason
        lock.unlock()
        onBoundary()
    }

    func finish() throws -> AudioRecorder.Recording {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        guard !samples.isEmpty else { throw failure ?? AudioRecorder.RecordingError.emptyRecording }
        // A sample-rate converter retains a short filter tail. Flush it once
        // recording ends so the end of the final word is not discarded.
        if failure == nil, let tail = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) {
            var error: NSError?
            let status = converter.convert(to: tail, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error || error != nil {
                failure = AudioRecorder.RecordingError.conversionFailed(
                    error?.localizedDescription ?? "Could not finish audio conversion."
                )
            }
            let count = min(Int(tail.frameLength), maximumSamples - samples.count)
            if failure == nil, count > 0, let channel = tail.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
                if Int(tail.frameLength) > count { failure = .recordingTooLong }
            }
        }
        let result = AudioRecorder.Recording(samples: samples, warning: failure?.localizedDescription)
        samples = []
        return result
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        samples.removeAll(keepingCapacity: false)
    }
}
