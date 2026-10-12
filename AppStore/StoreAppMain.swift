import AppKit
import AVFoundation
import CryptoKit
import DictationCore

@main
struct StoreAppMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = StoreAppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

/// The Store edition delivers through the requestor's Services pasteboard.
/// It never inspects another app, installs a global event tap, or posts keys.
@MainActor
final class StoreAppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum Phase { case idle, starting, testing, recording, processing }
    private var phase = Phase.idle
    private var token = UUID()
    private var ready = false
    private var setupTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private let recorder = AudioRecorder()
    private var transcriber: WhisperTranscriber?
    private var correction: LocalCorrectionService?
    private var correctionReady = false
    private var sessionMode = DictationMode.clean
    private var sessionVocabulary = VocabularySnapshot.empty
    private var serviceActive = false
    private var serviceText: String?
    private var serviceFailure: String?
    private var started: TimeInterval?
    private var elapsedTimer: Timer?
    private var microphoneTimer: Timer?
    private var statusItem: NSStatusItem?
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "Download the local models to get started.")
    private let detail = NSTextField(wrappingLabelWithString: "One download, about 3.4 GB. Keep 8 GB free. Speech stays on this Mac.")
    private let setupButton = NSButton(title: "Download models", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let microphone = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphoneTest = NSButton(title: "Test microphone", target: nil, action: nil)
    private let microphoneStatus = NSTextField(wrappingLabelWithString: "")
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progress = NSProgressIndicator()
    private let level = NSLevelIndicator()
    private let editor = NSTextView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu(); configureWindow()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        recorder.onAutomaticStop = { [weak self] in
            guard let self else { return }
            if self.phase == .testing { self.finishMicrophoneTest() } else { self.finishRecording() }
        }
        recorder.onLevel = { [weak self] rms in self?.level.doubleValue = min(1, Double(rms) * 12) }
        refreshMicrophones()
#if DEBUG
        if CommandLine.arguments.contains("--store-diagnostics") {
            let paths = try? RuntimePaths.application()
            var report: [String: Any] = ["models": paths?.models.path ?? "", "bundle": Bundle.main.bundleIdentifier ?? "",
                                       "servicesOnly": true, "usesAccessibility": false, "postsGlobalInput": false]
            if let index = CommandLine.arguments.firstIndex(of: "--outside-marker"), index + 1 < CommandLine.arguments.count {
                report["outsideMarkerReadDenied"] = FileManager.default.contents(atPath: CommandLine.arguments[index + 1]) == nil
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) {
                print(String(decoding: data, as: UTF8.self))
            }
            NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--service-smoke") || CommandLine.arguments.contains("--service-runtime-smoke") {
            ready = true; update("Synthetic Services test ready."); return
        }
        if CommandLine.arguments.contains("--runtime-smoke") {
            Task { await runRuntimeSmoke() }; return
        }
        if CommandLine.arguments.contains("--download-smoke") {
            Task { await runDownloadSmoke() }; return
        }
#endif
        showHome()
        if let paths = try? RuntimePaths.application(), ModelStore.hasCachedFiles(paths) { beginSetup() }
    }

#if DEBUG
    private func runDownloadSmoke() async {
        do {
            let paths = try RuntimePaths.application()
            let directory = paths.models.deletingLastPathComponent().appendingPathComponent("DownloadSmoke-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let license = try Data(contentsOf: paths.resources.appendingPathComponent("Licenses/whisper.cpp.txt"))
            let digest = SHA256.hash(data: license).map { String(format: "%02x", $0) }.joined()
            let url = URL(string: "https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.8.3/LICENSE")!
            let asset = ModelStore.Asset(path: "license.txt", label: "Tiny HTTPS fixture", bytes: Int64(license.count), sha256: digest, url: url, inlineUTF8: nil)
            let manifest = ModelStore.Manifest(formatVersion: 1, identifier: "store-network-fixture", files: [asset])
            let store = ModelStore(paths: RuntimePaths(resources: paths.resources, models: directory), manifest: manifest,
                                   downloader: { asset, file in try await StoreModelDownloader.download(asset, to: file) })
            try await store.prepare { _ in }
            guard try Data(contentsOf: directory.appendingPathComponent("license.txt")) == license else { throw DictationError.message("The HTTPS fixture failed its digest check.") }
            let oversized = ModelStore.Asset(path: "oversized.txt", label: "Oversize rejection", bytes: 1, sha256: digest, url: url, inlineUTF8: nil)
            let rejected = directory.appendingPathComponent("oversized.txt")
            var failed = false
            do { try await StoreModelDownloader.download(oversized, to: rejected) }
            catch { failed = true }
            guard failed, !FileManager.default.fileExists(atPath: rejected.path) else { throw DictationError.message("An oversized download was published.") }
            print("{\"sandboxedHTTPSDownload\":true,\"manifestDigestVerified\":true,\"oversizeRejected\":true,\"downloadedModelWeights\":false}")
            NSApp.terminate(nil)
        } catch { fputs("Store download check failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    /// Debug-only acceptance check using synthesized speech in the app container.
    /// It requests no microphone permission and never starts AudioRecorder.
    private func runRuntimeSmoke() async {
        do {
            let paths = try RuntimePaths.application()
            let store = ModelStore(paths: paths, downloader: { _, _ in
                throw RuntimeSetupError.message("The offline test requires preseeded models; downloads are disabled.")
            })
            try await store.prepare { _ in }
            let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
            let speech = WhisperTranscriber(resources: paths.resources, models: paths.models,
                                           executableURL: helpers.appendingPathComponent("whisper-worker"))
            transcriber = speech
            try await speech.prepare()
            let data = try Data(contentsOf: paths.models.deletingLastPathComponent().appendingPathComponent("StoreSmoke.f32"))
            guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { throw DictationError.message("Invalid synthetic audio.") }
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let original = try await speech.transcribe(samples)
            let logURL = paths.models.deletingLastPathComponent().appendingPathComponent("StoreSmokeOllama.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let diagnostics = try FileHandle(forWritingTo: logURL)
            defer { try? diagnostics.close() }
            let cleanup = LocalCorrectionService(resources: paths.resources, models: paths.models,
                endpoint: URL(string: "http://127.0.0.1:11439")!, executableURL: helpers.appendingPathComponent("ollama"), diagnosticOutput: diagnostics)
            correction = cleanup
            try await cleanup.rewarm()
            let result = try await CleanupCoordinator(client: cleanup.makeCleanupClient()).clean(original)
            guard original.lowercased().contains("local dictation"), original.lowercased().contains("private"),
                  result.fallbackReasons.isEmpty else { throw DictationError.message("The sandboxed models did not return the expected synthetic phrase and cleanup.") }
            let report: [String: Any] = ["sandboxedWhisper": true, "sandboxedCleanup": true, "recordedAudio": false,
                "downloadedModels": false, "syntheticTranscript": original, "cleanedSyntheticTranscript": result.text]
            let output = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
            print(String(decoding: output, as: UTF8.self))
            speech.shutdown(); await cleanup.suspend(); NSApp.terminate(nil)
        } catch {
            fputs("Store runtime check failed: \(error.localizedDescription)\n", stderr)
            transcriber?.shutdown(); await correction?.suspend(); exit(1)
        }
    }
#endif

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHome(); return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        setupTask?.cancel(); operation?.cancel(); recorder.cancel()
        transcriber?.shutdown(); correction?.stop(); elapsedTimer?.invalidate()
        microphoneTimer?.invalidate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if phase != .idle || serviceActive { cancelSession() }
        return true
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu(); let root = NSMenuItem(); root.submenu = appMenu; menu.addItem(root)
        appMenu.addItem(withTitle: "About Local Dictation", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let services = NSMenu(); let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; appMenu.addItem(servicesItem); NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Local Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(); let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editRoot.submenu = edit
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                     ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        menu.addItem(editRoot); NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Local Dictation")
        let tray = NSMenu()
        let home = NSMenuItem(title: "Open Local Dictation", action: #selector(openHome), keyEquivalent: ""); home.target = self; tray.addItem(home)
        tray.addItem(.separator()); tray.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = tray
    }

    private func configureWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Local Dictation"
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.delegate = self; window.center()
        window.contentMinSize = NSSize(width: 660, height: 740)
        let title = NSTextField(labelWithString: "Your voice. On your Mac.")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let logo = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([logo.widthAnchor.constraint(equalToConstant: 42), logo.heightAnchor.constraint(equalToConstant: 42)])
        let heading = NSStackView(views: [logo, title]); heading.orientation = .horizontal; heading.spacing = 12
        let intro = NSTextField(wrappingLabelWithString: "Click a text field in a supported app, then choose Services → Dictate with Local Dictation from that app’s menu. Stop here to insert the result there.")
        intro.textColor = .secondaryLabelColor; intro.font = .systemFont(ofSize: 13)
        let help = NSButton(title: "Set a Services shortcut…", target: self, action: #selector(openServicesSettings))
        help.bezelStyle = .rounded
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.style = .bar; progress.isHidden = true
        setupButton.target = self; setupButton.action = #selector(setupPressed); setupButton.bezelStyle = .rounded
        microphone.target = self; microphone.action = #selector(microphoneChanged)
        microphoneTest.target = self; microphoneTest.action = #selector(testMicrophone)
        microphoneTest.bezelStyle = .rounded
        microphoneStatus.font = .systemFont(ofSize: 12); microphoneStatus.textColor = .secondaryLabelColor
        microphoneStatus.isHidden = true
        mode.addItems(withTitles: ["Clean up wording", "Original transcript"])
        mode.selectItem(at: DictationPreferences.mode == .clean ? 0 : 1)
        mode.target = self; mode.action = #selector(modeChanged)
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh microphones")!,
                               target: self, action: #selector(refreshMicrophones))
        refresh.bezelStyle = .rounded
        let inputs = NSStackView(views: [NSTextField(labelWithString: "Microphone"), microphone, refresh, microphoneTest])
        inputs.orientation = .horizontal; inputs.spacing = 10
        let modes = NSStackView(views: [NSTextField(labelWithString: "Result"), mode]); modes.orientation = .horizontal; modes.spacing = 10
        level.levelIndicatorStyle = .continuousCapacity; level.minValue = 0; level.maxValue = 1; level.doubleValue = 0
        recordButton.target = self; recordButton.action = #selector(recordPressed); recordButton.bezelStyle = .rounded
        recordButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancelPressed); cancelButton.bezelStyle = .rounded; cancelButton.keyEquivalent = "\u{1b}"
        copyButton.target = self; copyButton.action = #selector(copyPressed); copyButton.bezelStyle = .rounded
        let actions = NSStackView(views: [recordButton, cancelButton, copyButton]); actions.orientation = .horizontal; actions.spacing = 10
        editor.isRichText = false; editor.isEditable = true; editor.font = .systemFont(ofSize: 15)
        editor.textContainerInset = NSSize(width: 12, height: 12); editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = editor
        let footer = NSTextField(wrappingLabelWithString: "Services inserts only into participating editors. In other apps, record here and use Copy. No account or Accessibility access is required.")
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, intro, help, status, detail, progress, setupButton, inputs, microphoneStatus, modes, level, actions, scroll, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor), detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            microphoneStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor), level.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        updateButtons()
    }

    @objc private func openHome() { showHome() }
    private func showHome() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func openServicesSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Services")!)
    }
    @objc private func refreshMicrophones() {
        let saved = DictationPreferences.inputUID
        microphone.removeAllItems(); microphone.addItem(withTitle: "System default")
        for device in AudioInputProvider.devices() {
            microphone.addItem(withTitle: device.name); microphone.lastItem?.representedObject = device.uid
        }
        if let saved, let item = microphone.itemArray.first(where: { $0.representedObject as? String == saved }) { microphone.select(item) }
        else { microphone.selectItem(at: 0) }
    }
    @objc private func microphoneChanged() { DictationPreferences.inputUID = microphone.selectedItem?.representedObject as? String }
    @objc private func modeChanged() { DictationPreferences.mode = mode.indexOfSelectedItem == 0 ? .clean : .verbatim }
    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    @objc private func testMicrophone() {
        guard phase == .idle, !serviceActive else { return }
        phase = .starting; token = UUID(); let id = token
        microphoneStatus.isHidden = false; microphoneStatus.stringValue = "Preparing a five-second microphone test…"
        updateButtons()
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed = await microphoneAllowed()
            guard token == id, !Task.isCancelled else { return }
            guard allowed else { fail("Allow Microphone access in System Settings → Privacy & Security → Microphone, then test again."); return }
            do {
                try recorder.start(inputUID: DictationPreferences.inputUID)
                phase = .testing; microphoneStatus.stringValue = "Speak for five seconds. Watch the level meter. This test is not transcribed or saved."
                microphoneTimer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finishMicrophoneTest() }
                }
                RunLoop.main.add(microphoneTimer!, forMode: .common); updateButtons()
            } catch { fail(error.localizedDescription) }
        }
    }
    private func finishMicrophoneTest() {
        guard phase == .testing else { return }
        microphoneTimer?.invalidate(); microphoneTimer = nil
        do {
            let captured = try recorder.stop()
            microphoneStatus.stringValue = captured.warning ?? "Microphone test complete. The audio was discarded."
            phase = .idle; updateButtons()
        } catch { fail(error.localizedDescription) }
    }
    @objc private func setupPressed() {
        if setupTask != nil { setupTask?.cancel(); update("Pausing setup…"); return }
        beginSetup()
    }

    private func beginSetup() {
        guard setupTask == nil, phase == .idle else { return }
        progress.isHidden = false; setupButton.title = "Pause download"; ready = false
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { setupTask = nil; setupButton.title = "Retry setup"; progress.isHidden = true; updateButtons() }
            do {
                let paths = try RuntimePaths.application()
                let controller = self
                let store = ModelStore(paths: paths, downloader: { asset, url in
                    try await StoreModelDownloader.download(asset, to: url) { bytes in
                        Task { @MainActor in
                            controller.detail.stringValue = "\(asset.label): \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))"
                        }
                    }
                })
                try await store.prepare { [weak self] event in
                    self?.update(event.stage == .ready ? "Starting the speech engine…" : "\(event.stage == .downloading ? "Downloading" : "Checking") \(event.label)…")
                    self?.progress.doubleValue = event.fraction
                }
                try Task.checkCancellation()
                let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
                let transcriber = WhisperTranscriber(resources: paths.resources, models: paths.models,
                                                     executableURL: helpers.appendingPathComponent("whisper-worker"))
                self.transcriber = transcriber
                try await transcriber.prepare()
                let correction = LocalCorrectionService(resources: paths.resources, models: paths.models,
                    endpoint: URL(string: "http://127.0.0.1:11439")!, executableURL: helpers.appendingPathComponent("ollama"))
                self.correction = correction
                correctionReady = false
                for attempt in 0..<3 {
                    update(attempt == 0 ? "Preparing local cleanup…" : "Local cleanup is taking longer to start…")
                    do { try await correction.rewarm(); correctionReady = true; break }
                    catch { try Task.checkCancellation(); if !LocalCorrectionService.shouldRecover(after: error) { break } }
                }
                ready = true; setupButton.isHidden = true
                update("Ready to dictate.")
                detail.stringValue = correctionReady ? "Models are on this Mac. Choose a text field and start the dictation service."
                    : "Speech is ready. Cleanup is unavailable, so the original transcript will be used."
            } catch is CancellationError {
                transcriber?.shutdown(); await correction?.suspend(); transcriber = nil; correction = nil
                update("Setup paused. Click Retry setup when you’re ready.")
            }
            catch { update(error.localizedDescription); transcriber?.shutdown(); await correction?.suspend() }
        }
        updateButtons()
    }

    @objc func dictateText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard ready, setupTask == nil, phase == .idle, !serviceActive else {
            error.pointee = "Open Local Dictation and finish setup before starting a dictation service."; showHome(); return
        }
        serviceActive = true; serviceText = nil; serviceFailure = nil
        let deadline = Timer(timeInterval: 595, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelSession()
                self.serviceFailure = "The editor's dictation request expired. Any recognized text remains below; use Copy."
                self.update(self.serviceFailure!)
            }
        }
        RunLoop.main.add(deadline, forMode: .common)
        defer { deadline.invalidate() }
        showHome()
#if DEBUG
        if CommandLine.arguments.contains("--service-smoke") {
            let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.complete("Text returned by the Store edition.") }
            }
            RunLoop.main.add(timer, forMode: .common)
        } else if CommandLine.arguments.contains("--service-runtime-smoke") {
            startSyntheticService()
        } else { startRecording() }
#else
        startRecording()
#endif
        NSApp.runModal(for: window)
        defer { serviceActive = false; updateButtons() }
        guard let text = serviceText, !text.isEmpty else {
            error.pointee = (serviceFailure ?? "Dictation was cancelled. No text was inserted.") as NSString; return
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: NSPasteboard.PasteboardType("NSStringPboardType")) else {
            error.pointee = "The editor could not receive the transcript. It remains in Local Dictation; use Copy."; return
        }
        window.orderOut(nil)
#if DEBUG
        if CommandLine.arguments.contains("--service-runtime-smoke") {
            Task { @MainActor in
                transcriber?.shutdown(); await correction?.suspend(); NSApp.terminate(nil)
            }
        }
#endif
    }

#if DEBUG
    private func startSyntheticService() {
        phase = .processing; update("Transcribing a synthetic test on this Mac…"); updateButtons()
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let paths = try RuntimePaths.application()
                let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
                let speech = WhisperTranscriber(resources: paths.resources, models: paths.models,
                                               executableURL: helpers.appendingPathComponent("whisper-worker"))
                transcriber = speech
                try await speech.prepare()
                let data = try Data(contentsOf: paths.models.deletingLastPathComponent().appendingPathComponent("StoreSmoke.f32"))
                guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { throw DictationError.message("Invalid synthetic audio.") }
                let original = try await speech.transcribe(data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
                let cleanup = LocalCorrectionService(resources: paths.resources, models: paths.models,
                    endpoint: URL(string: "http://127.0.0.1:11439")!, executableURL: helpers.appendingPathComponent("ollama"))
                correction = cleanup; try await cleanup.rewarm()
                let outcome = try await CleanupCoordinator(client: cleanup.makeCleanupClient()).clean(original)
                try Task.checkCancellation()
                guard outcome.fallbackReasons.isEmpty else { throw DictationError.message("Synthetic cleanup failed.") }
                complete(outcome.text)
            } catch { fail(error.localizedDescription) }
        }
    }
#endif

    @objc private func recordPressed() { phase == .recording ? finishRecording() : startRecording() }
    private func startRecording() {
        guard ready, phase == .idle else { return }
        phase = .starting; token = UUID(); let id = token
        sessionMode = DictationPreferences.mode; sessionVocabulary = VocabularyPreferences.load()
        update("Preparing the microphone…"); updateButtons()
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed = await microphoneAllowed()
            guard token == id, !Task.isCancelled else { return }
            guard allowed else {
                fail("Microphone access is required. Allow Local Dictation in System Settings → Privacy & Security → Microphone."); return
            }
            do {
                try recorder.start(inputUID: DictationPreferences.inputUID)
                phase = .recording; started = ProcessInfo.processInfo.systemUptime
                detail.stringValue = recorder.inputNotice ?? recorder.activeInputName ?? "Microphone"
                elapsedTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let started = self.started else { return }
                        let seconds = Int(ProcessInfo.processInfo.systemUptime - started)
                        self.update(String(format: "Listening · %d:%02d", seconds / 60, seconds % 60))
                    }
                }
                RunLoop.main.add(elapsedTimer!, forMode: .common); updateButtons()
            } catch { fail(error.localizedDescription) }
        }
    }

    private func finishRecording() {
        guard phase == .recording, let transcriber else { return }
        elapsedTimer?.invalidate(); elapsedTimer = nil
        do {
            let audio = try recorder.stop()
            phase = .processing; let id = token; update("Transcribing on this Mac…"); updateButtons()
            operation = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let original = try await transcriber.transcribe(audio.samples, vocabulary: sessionVocabulary)
                    try Task.checkCancellation(); guard token == id else { return }
                    editor.string = original
                    var result = original
                    if sessionMode == .clean, correctionReady, let correction {
                        update("Cleaning up the transcript…")
                        let outcome = try await CleanupCoordinator(client: correction.makeCleanupClient()).clean(original, vocabulary: sessionVocabulary)
                        result = outcome.text
                        if !outcome.fallbackReasons.isEmpty { detail.stringValue = "Original wording was kept where cleanup was unavailable." }
                    }
                    try Task.checkCancellation(); guard token == id else { return }
                    if let warning = audio.warning { detail.stringValue = warning }
                    complete(result)
                } catch is CancellationError { }
                catch { guard token == id else { return }; fail(error.localizedDescription) }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func complete(_ text: String) {
        phase = .idle; editor.string = text; update(text.isEmpty ? "No speech detected. Try again." : "Transcript ready.")
        serviceText = text.isEmpty ? nil : text
        if serviceActive { NSApp.stopModal() }
        updateButtons()
    }
    private func fail(_ message: String) {
        recorder.cancel(); phase = .idle; serviceFailure = message; update(message)
        elapsedTimer?.invalidate(); elapsedTimer = nil
        microphoneTimer?.invalidate(); microphoneTimer = nil
        if !microphoneStatus.isHidden { microphoneStatus.stringValue = message }
        if serviceActive { NSApp.stopModal() }
        updateButtons()
    }
    @objc private func cancelPressed() { cancelSession() }
    private func cancelSession() {
        let processing = phase == .processing
        token = UUID(); operation?.cancel(); if processing { transcriber?.cancel() }
        fail("Dictation cancelled. No text was inserted.")
    }
    @objc private func copyPressed() {
        guard !editor.string.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(editor.string, forType: .string)
        update("Copied the text shown below.")
    }
    private func update(_ message: String) { status.stringValue = message }
    private func updateButtons() {
        recordButton.isEnabled = ready && setupTask == nil && (phase == .idle || phase == .recording)
        recordButton.title = phase == .recording ? (serviceActive ? "Stop & Insert" : "Stop") : "Record"
        cancelButton.isEnabled = phase != .idle || serviceActive
        microphone.isEnabled = phase == .idle && !serviceActive; mode.isEnabled = microphone.isEnabled
        microphoneTest.isEnabled = phase == .idle && !serviceActive
        copyButton.isEnabled = !serviceActive && phase == .idle && !editor.string.isEmpty
        editor.isEditable = !serviceActive && phase == .idle
    }
}
