import AVFoundation
import AudioToolbox
import Foundation
import OSLog
#if canImport(DictationCore)
import DictationCore
#endif

/// Settings can exercise button dispatch without requesting permission or
/// opening a real microphone in its UI regression fixture.
@MainActor
protocol MicrophonePreview: AnyObject {
    var isRecording: Bool { get }
    var activeInputName: String? { get }
    var inputNotice: String? { get }
    var onAutomaticStop: (() -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    func start(inputUID: String?) throws
    func cancel()
}

/// Captures microphone audio only while a dictation session is active. Audio is
/// resampled to mono 16 kHz in memory and is never written to disk.
@MainActor
final class AudioRecorder: MicrophonePreview {
    static let sampleRate = Double(RecordingPolicy.sampleRate)
    static let maximumDuration: TimeInterval = RecordingPolicy.maximumDuration

    private var engine: AVAudioEngine?
    private var session: CaptureSession?
    private var configurationObserver: NSObjectProtocol?
    private var inputMonitor: AudioInputMonitor?
    private var sessionID: UUID?
    private var configurationRecovery = CaptureConfigurationRecovery()
    private static let logger = Logger(subsystem: "com.localdictation.app", category: "AudioCapture")
    private(set) var isRecording = false
    private(set) var activeInputName: String?
    private(set) var inputNotice: String?
    var onAutomaticStop: (() -> Void)?
    /// Raw RMS (0...1), at most ten updates per second; never contains speech.
    var onLevel: ((Float) -> Void)?

    struct Recording {
        let samples: [Float]
        let warning: String?
    }

    func start(inputUID: String? = nil) throws {
        guard !isRecording else { throw RecordingError.alreadyRecording }
        let resolution = try AudioInputProvider.resolve(uid: inputUID)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else { throw RecordingError.unavailableInput }
        var deviceID = resolution.device.id
        let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0, &deviceID,
                                         UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            throw RecordingError.startFailed("The selected microphone could not be opened (\(status)).")
        }
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
            maximumSamples: RecordingPolicy.maximumSamples,
            onLevel: { [weak self] level in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == token, self.isRecording else { return }
                    self.onLevel?(level)
                }
            },
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
        configurationRecovery = CaptureConfigurationRecovery()
        isRecording = true
        activeInputName = resolution.device.name
        inputNotice = resolution.fallbackNotice
        onLevel?(0)
        inputMonitor = AudioInputMonitor(deviceID: resolution.device.id) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == token, self.isRecording else { return }
                self.session?.interrupt(.inputChanged)
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            guard let engine else { return }
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == token,
                      self.isRecording, session.isCapturing else { return }
                // This notification also describes output changes and delayed
                // startup configuration. It does not prove the mic changed.
                let matches = AudioInputProvider.currentDeviceID(of: engine.inputNode.audioUnit) == resolution.device.id
                    && engine.inputNode.outputFormat(forBus: 0).isEqual(inputFormat)
                switch self.configurationRecovery.handle(
                    inputAvailable: AudioInputProvider.isAlive(resolution.device.id),
                    inputMatches: matches, engineRunning: engine.isRunning
                ) {
                case .keepRecording:
                    Self.logger.info("Audio configuration settled; compatible input is still running")
                case .restart:
                    // Apple may stop the engine when the output reconfigures.
                    // Restart only the same input/format, without replacing the
                    // tap, converter, captured prefix, or recording deadline.
                    do {
                        try engine.start()
                        Self.logger.info("Audio engine restarted with the same input format")
                    } catch {
                        session.interrupt(.captureInterrupted("The audio engine could not restart. \(error.localizedDescription)"))
                    }
                case .inputChanged:
                    Self.logger.info("Audio capture stopped because the input changed or disconnected")
                    session.interrupt(.inputChanged)
                case .restartLimitReached:
                    session.interrupt(.captureInterrupted("The audio engine repeatedly stopped. Try recording again."))
                }
            }
        }
    }

    func stop(reason: String? = nil) throws -> Recording {
        guard let engine, let session, isRecording else { throw RecordingError.notRecording }
        removeConfigurationObserver()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.session = nil
        sessionID = nil
        isRecording = false
        onLevel?(0)
        let recording = try session.finish()
        return Recording(samples: recording.samples, warning: recording.warning ?? reason)
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
        onLevel?(0)
    }

    private func removeConfigurationObserver() {
        inputMonitor = nil
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
        case captureInterrupted(String)
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already running."
            case .notRecording: return "There is no recording to stop."
            case .unavailableInput: return "The microphone has no usable input format. Check your audio input in System Settings."
            case .startFailed(let reason): return "Could not start the microphone: \(reason)"
            case .conversionFailed(let reason): return "Could not process microphone audio: \(reason)"
            case .recordingTooLong: return "The 5-minute limit was reached. The speech captured so far was kept."
            case .inputChanged: return "The microphone changed. The speech captured so far was kept."
            case .captureInterrupted(let reason): return "\(reason) The speech captured so far was kept."
            case .emptyRecording: return "No microphone audio was captured."
            }
        }
    }
}

/// Configuration notifications may be harmless, or may require a restart.
/// A real input change must always finish the prefix; repeated engine failure
/// must never leave an endless restart loop or an apparently live microphone.
struct CaptureConfigurationRecovery {
    enum Action: Equatable { case keepRecording, restart, inputChanged, restartLimitReached }
    private(set) var restartAttempts = 0
    mutating func handle(inputAvailable: Bool, inputMatches: Bool, engineRunning: Bool) -> Action {
        guard inputAvailable, inputMatches else { return .inputChanged }
        if engineRunning { return .keepRecording }
        guard restartAttempts < 2 else { return .restartLimitReached }
        restartAttempts += 1
        return .restart
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
    private let onLevel: @Sendable (Float) -> Void
    private var levelMeter: AudioLevelMeter

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat,
         inputSampleRate: Double, maximumSamples: Int,
         onLevel: @escaping @Sendable (Float) -> Void = { _ in },
         onBoundary: @escaping @Sendable () -> Void = {}) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.inputSampleRate = inputSampleRate
        self.maximumSamples = maximumSamples
        self.onBoundary = onBoundary
        self.onLevel = onLevel
        levelMeter = AudioLevelMeter(sampleRate: outputFormat.sampleRate)
        samples.reserveCapacity(min(maximumSamples, 160_000))
    }

    func capture(_ input: AVAudioPCMBuffer) {
        lock.lock()
        var notify = false
        var levelToNotify: Float?
        defer {
            lock.unlock()
            if let levelToNotify { onLevel(levelToNotify) }
            if notify { onBoundary() }
        }
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
        let acceptedSamples = UnsafeBufferPointer(start: channel, count: accepted)
        samples.append(contentsOf: acceptedSamples)
        levelToNotify = levelMeter.consume(acceptedSamples)
        if samples.count == maximumSamples { failure = .recordingTooLong; notify = true }
    }

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished && failure == nil
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

/// Bounded, allocation-free meter used on the audio tap. Samples remain in the
/// capture buffer; only one RMS scalar can leave each 100 ms audio window.
struct AudioLevelMeter {
    private let minimumFrames: Int
    private var frames = 0
    private var energy: Double = 0

    init(sampleRate: Double) {
        minimumFrames = max(1, Int(sampleRate / 10))
    }

    mutating func consume(_ samples: UnsafeBufferPointer<Float>) -> Float? {
        for sample in samples {
            let value = sample.isFinite ? Double(min(1, max(-1, sample))) : 0
            energy += value * value
        }
        frames += samples.count
        guard frames >= minimumFrames else { return nil }
        let rms = Float(sqrt(energy / Double(frames)))
        frames = 0
        energy = 0
        return rms
    }
}
