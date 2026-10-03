import AppKit
import AVFoundation
import DictationCore
import Foundation

@main
struct AppMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppController()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private enum Phase { case loading, idle, listening, processing }
    private var phase: Phase = .loading
    private let hotkey = FnHotkey()
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private var transcriber: WhisperTranscriber!
    private var correctionService: LocalCorrectionService!
    private var cleanup: CleanupClient!
    private var item: NSStatusItem!
    private var statusMenu: NSMenuItem!
    private var copyMenu: NSMenuItem!
    private var cancelMenu: NSMenuItem!
    private var retryMenu: NSMenuItem!
    private var setupWindow: NSWindow?
    private var setupStatus: NSTextField?
    private var timer: Timer?
    private var listeningTimer: Timer?
    private var target: TextInserter.Target?
    private var session = UUID()
    private var processingTask: Task<Void, Never>?
    private var lastText: String?
    private var engineReady = false
    private var correctionReady = false
    private var correctionTask: Task<Void, Never>?
    private var correctionStatus = "Correction is starting"
    private var recoveryNeeded = false
    private var isTerminating = false
    private var monitoring = false
    private var lastPermissionState: String?
    private var status = "Starting local models…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resources = ProcessInfo.processInfo.environment["LOCAL_DICTATION_RESOURCES"]
            .map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL!
        transcriber = WhisperTranscriber(resources: resources)
        correctionService = LocalCorrectionService(resources: resources)
        cleanup = CleanupClient(baseURL: LocalCorrectionService.endpoint)
        configureMenu()
        if CommandLine.arguments.contains("--diagnostics") {
            runDiagnostics(resources: resources); return
        }
        if CommandLine.arguments.contains("--paste-test") {
            runPasteTest(); return
        }
        Task { await prepareEngines() }
        recorder.onAutomaticStop = { [weak self] in self?.finishDictation() }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        refreshPermissions()
        if !allPermissions { showSetup() }
    }

    private var missingPermissions: [String] {
        var missing: [String] = []
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { missing.append("Microphone") }
        if !TextInserter.accessibilityGranted() { missing.append("Accessibility") }
        if !FnHotkey.permissionGranted { missing.append("Input Monitoring") }
        return missing
    }

    private var allPermissions: Bool { missingPermissions.isEmpty }

    private var permissionStatus: String {
        let missing = missingPermissions
        if !missing.isEmpty { return "Setup required: " + missing.joined(separator: ", ") }
        return monitoring ? (correctionReady ? "Ready · double-tap Fn" : "Ready · correction unavailable or starting") : "Fn listener could not start · check Input Monitoring"
    }

    private func configureMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        statusMenu = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        menu.addItem(statusMenu); menu.addItem(.separator())
        let setup = NSMenuItem(title: "Setup…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self; menu.addItem(setup)
        copyMenu = NSMenuItem(title: "Copy last result", action: #selector(copyLast), keyEquivalent: "")
        copyMenu.target = self; copyMenu.isEnabled = false; menu.addItem(copyMenu)
        cancelMenu = NSMenuItem(title: "Cancel dictation", action: #selector(cancelDictation), keyEquivalent: "")
        cancelMenu.target = self; cancelMenu.isEnabled = false; menu.addItem(cancelMenu)
        retryMenu = NSMenuItem(title: "Retry local engines", action: #selector(retryEngines), keyEquivalent: "")
        retryMenu.target = self; menu.addItem(retryMenu)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Local Dictation", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        menu.autoenablesItems = false
        item.menu = menu
        updateStatus(status)
    }

    private func updateStatus(_ message: String) {
        status = message; statusMenu?.title = message
        let icon = phase == .listening ? "mic.fill" : (phase == .processing || phase == .loading ? "ellipsis.circle" : (recoveryNeeded ? "doc.on.clipboard" : "mic"))
        item?.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: message)
        item?.button?.contentTintColor = phase == .listening ? .systemRed : nil
        item?.button?.toolTip = "Local Dictation: \(message)"
        copyMenu?.isEnabled = lastText != nil
        cancelMenu?.isEnabled = phase == .listening || phase == .processing
        retryMenu?.isEnabled = phase == .idle
        updateSetupStatus()
    }

    private func prepareEngines() async {
        phase = .loading; engineReady = false; updateStatus("Starting local models…")
        do {
            try await transcriber.prepare()
            engineReady = true; phase = .idle; hotkey.setPhase(.idle)
            lastPermissionState = nil
            refreshPermissions()
            startCorrection()
        } catch {
            phase = .idle; hotkey.setPhase(.idle); updateStatus(error.localizedDescription)
        }
    }

    private func startCorrection() {
        guard correctionTask == nil else { return }
        correctionTask = Task { [weak self] in
            guard let self else { return }
            defer { correctionTask = nil; updateSetupStatus() }
            do {
                try await correctionService.start()
                await cleanup.preload()
                correctionReady = await cleanup.isAvailable()
                correctionStatus = correctionReady ? "Correction: ready" : "Correction unavailable; original transcript will be used"
            } catch {
                correctionReady = false
                correctionStatus = "Correction: \(error.localizedDescription)"
            }
            // Do not erase insertion errors or a result waiting to be copied.
            if phase == .idle, !recoveryNeeded, status.hasPrefix("Ready") {
                lastPermissionState = permissionStatus
                updateStatus(permissionStatus)
            }
        }
    }

    @objc private func retryEngines() {
        guard phase == .idle else { return }
        if !engineReady { Task { await prepareEngines() } }
        else { startCorrection() }
    }

    private func refreshPermissions() {
        guard !isTerminating, !CommandLine.arguments.contains("--diagnostics") else { return }
        inserter.primeFrontmostAccessibility()
        if monitoring && !hotkey.isActive { hotkey.stop(); monitoring = false }
        if !FnHotkey.permissionGranted && monitoring {
            hotkey.stop(); monitoring = false
        }
        if FnHotkey.permissionGranted && !monitoring {
            monitoring = hotkey.start { [weak self] action in
                switch action { case .start: self?.startDictation(); case .stop: self?.finishDictation() }
            }
            hotkey.setPhase(phase == .listening ? .listening : (phase == .idle ? .idle : .processing))
        }
        if !allPermissions && (phase == .listening || phase == .processing) {
            cancelDictation(); updateStatus("Permission changed · open Setup")
        }
        // Refresh on readiness changes without erasing errors or copy-recovery
        // messages on every timer tick. Partial grants also change this value.
        if phase == .idle, engineReady {
            let readiness = missingPermissions.joined(separator: ",") + " listener=\(monitoring)"
            if readiness != lastPermissionState {
                lastPermissionState = readiness
                updateStatus(permissionStatus)
            }
        }
        updateSetupStatus()
    }

    private func startDictation() {
        guard phase == .idle, engineReady, allPermissions, monitoring else {
            hotkey.setPhase(phase == .idle ? .idle : .processing)
            updateStatus(engineReady ? permissionStatus : "Local models are not ready · open Setup")
            if !allPermissions { showSetup() }
            return
        }
        do {
            let destination = try inserter.captureTarget()
            try recorder.start()
            session = UUID(); target = destination; lastText = nil; recoveryNeeded = false; phase = .listening
            hotkey.setPhase(.listening)
            updateStatus(destination.canInsertAutomatically ? "Listening · tap Fn to finish" : "Listening · result will be available to copy")
            listeningTimer?.invalidate()
            listeningTimer = Timer(timeInterval: 115, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishDictation() }
            }
            RunLoop.main.add(listeningTimer!, forMode: .common)
        } catch { hotkey.setPhase(.idle); updateStatus(error.localizedDescription) }
    }

    private func finishDictation() {
        guard phase == .listening, let destination = target else { return }
        listeningTimer?.invalidate(); listeningTimer = nil
        let token = session
        do {
            let audio = try recorder.stop()
            phase = .processing; hotkey.setPhase(.processing); updateStatus("Transcribing locally…")
            processingTask = Task { [weak self] in
                guard let self, token == session, !Task.isCancelled else { return }
                do {
                    try Task.checkCancellation()
                    let raw = try await transcriber.transcribe(audio.samples)
                    guard token == session, !Task.isCancelled else { return }
                    if raw.isEmpty { complete("No speech detected"); return }
                    lastText = raw
                    var result = raw, correctionFailure: String?
                    if correctionReady {
                        updateStatus("Correcting locally…")
                        do { result = try await cleanup.clean(raw) }
                        catch { correctionFailure = error.localizedDescription }
                    } else {
                        correctionFailure = "Correction unavailable; original transcript used"
                        startCorrection()
                    }
                    guard token == session, !Task.isCancelled else { return }
                    lastText = result
                    guard destination.canInsertAutomatically else {
                        recoveryNeeded = true
                        complete("Text ready · use Copy last result for this app")
                        return
                    }
                    updateStatus("Inserting text…")
                    let insertion = try await inserter.insert(text: result, into: destination)
                    guard token == session, !Task.isCancelled else { return }
                    if insertion == .sentWithoutVerification {
                        complete("Paste sent · check the text box; result available to copy")
                    } else if let warning = audio.warning {
                        complete("Inserted captured speech · \(warning)")
                    } else if let correctionFailure {
                        complete("Inserted original transcript · \(correctionFailure)")
                    } else { complete(permissionStatus) }
                } catch {
                    guard token == session, !Task.isCancelled else { return }
                    recoveryNeeded = lastText != nil
                    complete(error.localizedDescription)
                }
            }
        } catch { complete(error.localizedDescription) }
    }

    private func complete(_ message: String) {
        phase = .idle; target = nil; hotkey.setPhase(.idle); updateStatus(message)
    }

    @objc private func cancelDictation() {
        session = UUID(); processingTask?.cancel(); processingTask = nil
        transcriber.cancel()
        listeningTimer?.invalidate(); listeningTimer = nil; recorder.cancel()
        complete("Canceled · double-tap Fn when ready")
    }

    @objc private func copyLast() {
        if let lastText { inserter.copyForRecovery(text: lastText); recoveryNeeded = false; updateStatus("Copied last result") }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        guard inserter.hasPendingPaste else { return .terminateNow }
        isTerminating = true
        processingTask?.cancel(); hotkey.stop(); timer?.invalidate()
        phase = .processing; updateStatus("Restoring clipboard before quitting…")
        Task { @MainActor in
            await inserter.waitForPendingPaste()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); listeningTimer?.invalidate(); hotkey.stop()
        processingTask?.cancel(); correctionTask?.cancel(); recorder.cancel(); transcriber.shutdown(); correctionService.stop()
    }

    @objc private func showSetup() {
        if let setupWindow { NSApp.activate(ignoringOtherApps: true); setupWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Local Dictation"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Speak into any text box")
        title.font = .systemFont(ofSize: 23, weight: .semibold); stack.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "Click a text box. Double-tap Fn / Globe to start. Tap again to finish and insert corrected text.")
        subtitle.font = .systemFont(ofSize: 14); stack.addArrangedSubview(subtitle)
        let permissions = NSStackView(); permissions.orientation = .horizontal; permissions.spacing = 8
        for (label, action) in [("Microphone", #selector(allowMicrophone)), ("Accessibility", #selector(allowAccessibility)), ("Input Monitoring", #selector(allowMonitoring))] {
            let button = NSButton(title: label, target: self, action: action); button.bezelStyle = .rounded
            permissions.addArrangedSubview(button)
        }
        stack.addArrangedSubview(permissions)
        let statusLabel = NSTextField(wrappingLabelWithString: "Checking permissions…")
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor
        setupStatus = statusLabel; stack.addArrangedSubview(statusLabel)
        let keyboard = NSTextField(wrappingLabelWithString: "In Keyboard settings, set “Press 🌐 key to” to “Do Nothing” and make sure Apple Dictation does not use Fn / Globe. Quit Wispr Flow while using the same Fn key.")
        keyboard.font = .systemFont(ofSize: 13); stack.addArrangedSubview(keyboard)
        let keyboardButton = NSButton(title: "Open Keyboard Settings", target: self, action: #selector(openKeyboard))
        keyboardButton.bezelStyle = .rounded; stack.addArrangedSubview(keyboardButton)
        let footer = NSTextField(wrappingLabelWithString: "Runs on your Mac. Audio stays temporary. No recordings or transcript history are saved.")
        footer.font = .systemFont(ofSize: 12); footer.textColor = .secondaryLabelColor; stack.addArrangedSubview(footer)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        setupWindow = window; updateSetupStatus()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

    private func updateSetupStatus() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        setupStatus?.stringValue = "Microphone: \(mic ? "allowed" : "needed")   Accessibility: \(TextInserter.accessibilityGranted() ? "allowed" : "needed")\nInput Monitoring: \(FnHotkey.permissionGranted ? "allowed" : "needed")\nFn listener: \(monitoring ? "active" : "not active")\n\(correctionStatus)\n\(status)"
    }

    @objc private func allowMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        } else { openPreferences("Privacy_Microphone") }
    }
    @objc private func allowAccessibility() {
        TextInserter.requestAccessibility(); openPreferences("Privacy_Accessibility")
    }
    @objc private func allowMonitoring() {
        FnHotkey.requestPermission(); openPreferences("Privacy_ListenEvent")
    }
    @objc private func openKeyboard() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
    private func openPreferences(_ section: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)")!)
    }

    private func runDiagnostics(resources: URL) {
        Task {
            do {
                try await transcriber.prepare(); try await correctionService.start()
                print("Speech engine loaded; microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), accessibility=\(TextInserter.accessibilityGranted()), monitoring=\(FnHotkey.permissionGranted)")
                let phrases = ["Let's meet on Thursday, sorry, Friday at three.",
                    "I need to send, um, send the document tomorrow.",
                    "The total is fifteen, actually fifty dollars.",
                    "Do not delete the file. Send it to Yosef tomorrow."]
                let expected = ["Let's meet on Friday at three.", "I need to send the document tomorrow.",
                    "The total is fifty dollars.", "Do not delete the file. Send it to Yosef tomorrow."]
                await cleanup.preload()
                for (index, phrase) in phrases.enumerated() {
                    let started = Date()
                    let corrected = try await cleanup.clean(phrase)
                    print("CORRECTION \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(corrected)")
                    guard corrected == expected[index] else {
                        throw DictationError.message("Correction did not match expected result for sample \(index + 1)")
                    }
                }
                let silent = try await transcriber.transcribe(Array(repeating: 0, count: 16_000))
                guard silent.isEmpty else { throw DictationError.message("Silence produced text") }
                print("Silence: passed")
                if let index = CommandLine.arguments.firstIndex(of: "--audio"), CommandLine.arguments.count > index + 1 {
                    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                    let file = try AVAudioFile(forReading: url)
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                    try file.read(into: input)
                    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate + 4096))!
                    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
                    var supplied = false, conversionError: NSError?
                    converter.convert(to: output, error: &conversionError) { _, status in
                        if supplied { status.pointee = .endOfStream; return nil }
                        supplied = true; status.pointee = .haveData; return input
                    }
                    if let conversionError { throw conversionError }
                    let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
                    let started = Date(); let raw = try await transcriber.transcribe(samples)
                    print("TRANSCRIPTION \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(raw)")
                    let finished = try await cleanup.clean(raw)
                    print("END TO END \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(finished)")
                }
                NSApp.terminate(nil)
            } catch { fputs("DIAGNOSTICS FAILED: \(error.localizedDescription)\n", stderr); NSApp.terminate(nil); exit(1) }
        }
    }

    private func runPasteTest() {
        Task {
            do {
                let args = CommandLine.arguments
                guard let index = args.firstIndex(of: "--paste-test"), args.count > index + 1 else {
                    throw DictationError.message("A test string is required")
                }
                inserter.primeFrontmostAccessibility()
                try await Task.sleep(nanoseconds: 2_500_000_000)
                let destination = try inserter.captureTarget()
                let original = NSPasteboard.general.string(forType: .string)
                let result = try await inserter.insert(text: args[index + 1], into: destination)
                let restored = NSPasteboard.general.string(forType: .string) == original
                print("PASTE TEST: role=\(destination.role), result=\(result), clipboard restored=\(restored)")
                guard restored else { throw DictationError.message("Clipboard was not restored") }
                NSApp.terminate(nil)
            } catch {
                fputs("PASTE TEST FAILED: \(error.localizedDescription)\n", stderr)
                NSApp.terminate(nil); exit(1)
            }
        }
    }
}
