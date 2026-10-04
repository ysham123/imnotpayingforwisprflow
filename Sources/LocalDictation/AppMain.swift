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
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var state = DictationSessionState()
    private var phase: DictationSessionState.Phase { state.phase }
    private var session: UUID { state.id }
    private var lastText: String? { state.lastText }
    private let hud = DictationHUD()
    private let metrics = InteractionMetrics()
    private var completionFeedback = CompletionFeedback()
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
    private var discardMenu: NSMenuItem!
    private var retryMenu: NSMenuItem!
    private var retryListenerMenu: NSMenuItem!
    private var listenerFailure: HotkeyStartError?
    private var listenerAttempts = 0
    private var listenerRetryAfter: TimeInterval = 0
    private var lastInputPermission: Bool?
    private let permissionDiagnostics = PermissionDiagnostics()
    private var setupWindow: NSWindow?
    private var setupStatus: NSTextField?
    private var setupSubtitle: NSTextField?
    private var shortcutLabel: NSTextField?
    private var shortcutChangeButton: NSButton?
    private var shortcutResetButton: NSButton?
    private var keyboardHint: NSTextField?
    private let shortcutRecorder = ShortcutRecorder()
    private var shortcutConfiguration = HotkeyPreferences.load()
    private var shortcutFailure: String?
    private var recordingShortcut = false
    private var timer: Timer?
    private var listeningTimer: Timer?
    private var targetTask: Task<TextInserter.Target?, Never>?
    private var dismissTask: Task<Void, Never>?
    private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var pressureSource: DispatchSourceMemoryPressure?
    private var sleeping = false
    private var memoryPressure = false
    private var releaseEnginesWhenIdle: Bool { sleeping || memoryPressure }
    private var suspending = false
    private var processingTask: Task<Void, Never>?
    private var engineReady = false
    private var correctionReady = false
    private var correctionTask: Task<Void, Never>?
    private var correctionGeneration: UInt64 = 0
    private var engineGeneration: UInt64 = 0
    private var wakeRequested = false
    private var copyInProgress = false
    private var correctionStatus = "Correction is starting"
    private var recoveryNeeded = false
    private var isTerminating = false
    private var monitoring = false
    private var lastPermissionState: String?
    private var status = "Starting local models…"
    private let installController = InstallController()
    private var modelStore: ModelStore?
    private var modelPreparationTask: Task<Void, Never>?
    private var modelPreparationStatus: String?
    private var runtimeInitialized = false
    private var vocabulary = VocabularyPreferences.load()
    private var sessionVocabulary = VocabularySnapshot.empty
    private var customWordsController: CustomWordsController?
    private var editingVocabulary = false
    private var modelProgress: NSProgressIndicator?
    private var modelActionButton: NSButton?
    private var listenerRetryButton: NSButton?
    private var permissionButtons: [String: NSButton] = [:]
    private var continueSetupButton: NSButton?
    private var guidedPermissionStep: String?
    private var guidedPermissionSetup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resources = ProcessInfo.processInfo.environment["LOCAL_DICTATION_RESOURCES"]
            .map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL!
        if CommandLine.arguments.contains("--diagnostics") || CommandLine.arguments.contains("--paste-test") {
            configureMenu()
            let models = ProcessInfo.processInfo.environment["LOCAL_DICTATION_MODELS"]
                .map { URL(fileURLWithPath: $0) }
                ?? (ProcessInfo.processInfo.environment["LOCAL_DICTATION_RESOURCES"] != nil
                    ? resources.appendingPathComponent("Models") : (try? RuntimePaths.application().models))
            transcriber = WhisperTranscriber(resources: resources, models: models)
            correctionService = LocalCorrectionService(resources: resources, models: models)
            cleanup = correctionService.makeCleanupClient()
            runtimeInitialized = true
            if CommandLine.arguments.contains("--diagnostics") { runDiagnostics(resources: resources) }
            else { runPasteTest() }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await installController.ensureInstalled() else { NSApp.terminate(nil); return }
            guard claimInstalledInstance() else { NSApp.terminate(nil); return }
            initializeInstalledRuntime()
        }
    }

    private func claimInstalledInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        guard let other = others.first else { return true }
        if let url = other.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
        return false
    }

    private func initializeInstalledRuntime() {
        configureMenu()
        if case .failure(let error) = hotkey.configure(shortcutConfiguration) {
            shortcutFailure = error.localizedDescription
        }
        configureHUD()
        updateShortcutAppearance()
        recorder.onAutomaticStop = { [weak self] in self?.finishDictation() }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        refreshPermissions()
        if !allPermissions || shortcutFailure != nil || listenerFailure != nil || CommandLine.arguments.contains("--setup") { showSetup() }
        beginModelSetup()
    }

    private func beginModelSetup() {
        guard modelPreparationTask == nil, !isTerminating, !runtimeInitialized else { return }
        modelPreparationStatus = "Checking local models…"
        updateStatus(modelPreparationStatus!)
        modelPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { modelPreparationTask = nil; updateSetupStatus() }
            do {
                let paths = try RuntimePaths.application()
                let store = ModelStore(paths: paths)
                modelStore = store
                try await store.prepare { [weak self] progress in
                    guard let self, !self.isTerminating, !Task.isCancelled else { return }
                    let percent = Int(progress.fraction * 100)
                    self.modelPreparationStatus = progress.stage == .downloading
                        ? "Downloading \(progress.label) · \(percent)%" : progress.label
                    self.modelProgress?.doubleValue = progress.fraction
                    self.updateStatus(self.modelPreparationStatus ?? "Preparing local models…")
                    if progress.stage == .downloading, self.setupWindow == nil { self.showSetup() }
                }
                try Task.checkCancellation()
                guard !isTerminating else { return }
                transcriber = WhisperTranscriber(resources: paths.resources, models: paths.models)
                correctionService = LocalCorrectionService(resources: paths.resources, models: paths.models)
                cleanup = correctionService.makeCleanupClient()
                runtimeInitialized = true; modelPreparationStatus = nil
                configureLifecycle()
                await prepareEngines()
            } catch is CancellationError {
                modelPreparationStatus = "Model setup paused · resume when ready"
                updateStatus(modelPreparationStatus!)
            } catch {
                modelPreparationStatus = error.localizedDescription
                updateStatus(modelPreparationStatus!)
                if !isTerminating { showSetup() }
            }
        }
    }

    @objc private func toggleModelSetup() {
        if modelPreparationTask != nil { modelPreparationTask?.cancel() }
        else { beginModelSetup() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && (!allPermissions || shortcutFailure != nil || listenerFailure != nil ||
                     (!runtimeInitialized && modelPreparationTask == nil)) { showSetup() }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === setupWindow,
              allPermissions, monitoring, window.attachedSheet == nil else { return }
        window.orderOut(nil)
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
        if let shortcutFailure { return "Shortcut unavailable · " + shortcutFailure }
        if let listenerFailure { return listenerFailure.localizedDescription }
        return monitoring ? (correctionReady ? "Ready · \(startInstruction)" : "Ready · correction unavailable or starting") : "Shortcut listener is starting…"
    }

    private func configureMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        statusMenu = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        menu.addItem(statusMenu); menu.addItem(.separator())
        let setup = NSMenuItem(title: "Settings…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self; menu.addItem(setup)
        let words = NSMenuItem(title: "Custom Words…", action: #selector(showCustomWords), keyEquivalent: "")
        words.target = self; menu.addItem(words)
        copyMenu = NSMenuItem(title: "Copy last result", action: #selector(copyLast), keyEquivalent: "")
        copyMenu.target = self; copyMenu.isEnabled = false; menu.addItem(copyMenu)
        cancelMenu = NSMenuItem(title: "Cancel dictation", action: #selector(cancelDictation), keyEquivalent: "")
        cancelMenu.target = self; cancelMenu.isEnabled = false; menu.addItem(cancelMenu)
        discardMenu = NSMenuItem(title: "Discard waiting text", action: #selector(discardPending), keyEquivalent: "")
        discardMenu.target = self; discardMenu.isEnabled = false; menu.addItem(discardMenu)
        let diagnostics = NSMenuItem(title: "Export performance measurements…", action: #selector(exportMetrics), keyEquivalent: "")
        diagnostics.target = self; menu.addItem(diagnostics)
        retryMenu = NSMenuItem(title: "Retry local engines", action: #selector(retryEngines), keyEquivalent: "")
        retryMenu.target = self; menu.addItem(retryMenu)
        retryListenerMenu = NSMenuItem(title: "Retry shortcut listener", action: #selector(retryListener), keyEquivalent: "")
        retryListenerMenu.target = self; menu.addItem(retryListenerMenu)
        let permissionReport = NSMenuItem(title: "Export permission diagnostics…", action: #selector(exportPermissionDiagnostics), keyEquivalent: "")
        permissionReport.target = self; menu.addItem(permissionReport)
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
        copyMenu?.isEnabled = !copyInProgress && (phase == .idle || phase == .pending) && (state.pendingText != nil || lastText != nil)
        discardMenu?.isEnabled = phase == .pending
        cancelMenu?.isEnabled = phase == .listening || phase == .processing
        retryMenu?.isEnabled = phase == .idle && !suspending
        retryListenerMenu?.isEnabled = !monitoring && phase == .idle && !isTerminating
        updateSetupStatus()
    }

    private func prepareEngines() async {
        guard !suspending, runtimeInitialized else { return }
        let generation = engineGeneration
        engineReady = false
        if phase == .loading || phase == .idle { updateStatus("Starting local models…") }
        startCorrection()
        do {
            try await transcriber.prepare()
            guard generation == engineGeneration, !Task.isCancelled else { return }
            engineReady = true; state.ready(); syncHotkey()
            lastPermissionState = nil
            refreshPermissions(); suspendEnginesIfIdle()
        } catch {
            guard generation == engineGeneration else { return }
            state.ready(); syncHotkey(); updateStatus(error.localizedDescription)
            suspendEnginesIfIdle()
        }
    }

    private func startCorrection() {
        guard runtimeInitialized, correctionTask == nil, !suspending, !isTerminating else { return }
        correctionGeneration &+= 1
        let generation = correctionGeneration
        correctionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == correctionGeneration { correctionTask = nil; updateSetupStatus() }
            }
            do {
                try await correctionService.start(); try Task.checkCancellation()
                await cleanup.preload(); try Task.checkCancellation()
                let available = await cleanup.isAvailable(); try Task.checkCancellation()
                guard generation == correctionGeneration, !suspending else { return }
                correctionReady = available
                correctionStatus = available ? "Correction: ready" : "Correction unavailable; original transcript will be used"
            } catch {
                guard generation == correctionGeneration, !Task.isCancelled else { return }
                correctionReady = false
                correctionStatus = "Correction: \(error.localizedDescription)"
            }
            if phase == .idle, !recoveryNeeded, status.hasPrefix("Ready") {
                lastPermissionState = permissionStatus
                updateStatus(permissionStatus)
            }
        }
    }

    @objc private func retryEngines() {
        if !runtimeInitialized { beginModelSetup(); return }
        guard phase == .idle else { return }
        if !engineReady { Task { await prepareEngines() } }
        else { startCorrection() }
    }

    @objc private func retryListener() {
        guard !isTerminating, phase == .idle || phase == .loading || phase == .pending else { return }
        hotkey.stop(); monitoring = false
        resumeShortcut()
        if phase == .idle { updateStatus(permissionStatus) }
        else if phase == .pending { showPending() }
    }

    private func refreshPermissions() {
        guard !isTerminating, !CommandLine.arguments.contains("--diagnostics") else { return }
        if recordingShortcut { updateSetupStatus(); return }
        inserter.primeFrontmostAccessibility()
        let inputPermission = FnHotkey.permissionGranted
        if inputPermission != lastInputPermission {
            listenerAttempts = 0; listenerRetryAfter = 0; listenerFailure = nil
            lastInputPermission = inputPermission
        }
        if monitoring && !hotkey.isActive {
            hotkey.stop(); monitoring = false; listenerAttempts = 0; listenerRetryAfter = 0
        }
        if !inputPermission && monitoring {
            hotkey.stop(); monitoring = false
        }
        if inputPermission && !monitoring && shortcutFailure == nil,
           listenerAttempts < 3, ProcessInfo.processInfo.systemUptime >= listenerRetryAfter {
            let result = hotkey.startResult { [weak self] action in
                switch action {
                case .start: self?.startDictation()
                case .stop: self?.finishDictation()
                case .placePending: self?.placePending()
                case .resolvePending: self?.showPending("Insert, copy, or discard your previous text")
                }
            }
            switch result {
            case .success:
                monitoring = true; listenerFailure = nil; listenerAttempts = 0
            case .failure(let error):
                monitoring = false; listenerFailure = error; listenerAttempts += 1
                listenerRetryAfter = ProcessInfo.processInfo.systemUptime + (listenerAttempts == 1 ? 2 : 5)
                if case .registration(let registration) = error { shortcutFailure = registration.localizedDescription }
            }
            syncHotkey()
        }
        permissionDiagnostics.record(.init(microphone: AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
                                          accessibility: TextInserter.accessibilityGranted(),
                                          inputMonitoring: inputPermission, listenerActive: monitoring,
                                          listenerError: listenerFailure?.diagnosticCode))
        if !allPermissions && phase == .listening {
            // Keep the audio already captured. Placement will wait for setup.
            finishDictation()
        }
        // Refresh on readiness changes without erasing errors or copy-recovery
        // messages on every timer tick. Partial grants also change this value.
        if phase == .idle, engineReady {
            let readiness = missingPermissions.joined(separator: ",") + " listener=\(monitoring) error=\(listenerFailure?.diagnosticCode ?? "none")"
            if readiness != lastPermissionState {
                lastPermissionState = readiness
                updateStatus(permissionStatus)
            }
        }
        updateSetupStatus()
        if guidedPermissionSetup { advancePermissionSetup() }
    }

    private func syncHotkey() {
        guard !isTerminating, !editingVocabulary else { hotkey.setPhase(.processing); return }
        switch phase {
        case .idle: hotkey.setPhase(.idle)
        case .listening: hotkey.setPhase(.listening)
        case .pending: hotkey.setPhase(.pending)
        case .loading, .processing: hotkey.setPhase(.processing)
        }
    }

    private func configureHUD() {
        hud.onCancel = { [weak self] in self?.cancelDictation() }
        hud.onCopy = { [weak self] in self?.copyLast() }
        hud.onDiscard = { [weak self] in self?.discardPending() }
        recorder.onLevel = { [weak self] level in self?.hud.updateLevel(level) }
        hotkey.onInputActivity = { [weak self] in
            guard let self else { return }
            self.inserter.invalidateCapture()
            // Let clicks on Copy finish before dismissing the passive panel.
            if !self.hud.panel.frame.contains(NSEvent.mouseLocation) { self.dismissCompletedFeedback() }
        }
        inserter.onFocusChanged = { [weak self] in
            self?.hotkey.invalidateGesture()
            self?.dismissCompletedFeedback()
        }
    }

    private func startDictation() {
        guard !isTerminating else { return }
        if state.pendingText != nil { showPending(); return }
        guard runtimeInitialized, !editingVocabulary else {
            updateStatus(modelPreparationStatus ?? "Finish local model setup first")
            syncHotkey(); return
        }
        guard phase == .idle, allPermissions, monitoring, !suspending, !copyInProgress else {
            syncHotkey()
            updateStatus(suspending ? "Local models are resting · try again shortly" : permissionStatus)
            if !allPermissions { showSetup() }
            return
        }
        let originalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let token = state.begin() else { return }
        sessionVocabulary = vocabulary
        setupWindow?.orderOut(nil)
        metrics.begin(token); dismissTask?.cancel()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        hud.beginSession(token, fallbackScreen: screen)
        hud.show(.starting, on: screen); metrics.mark("indicatorRequested", token)
        do {
            // Audio starts before any field text or editor ancestry is read.
            try recorder.start(); metrics.mark("microphoneReady", token)
            let anchor = originalPID.flatMap { inserter.beginCapture(expectedProcessIdentifier: $0) }
            let origin = Task { [inserter] in
                guard let anchor else { return nil as CGRect? }
                return await inserter.originWindowFrame(for: anchor)
            }
            targetTask = Task { [inserter] in
                guard let anchor else { return nil }
                return try? await inserter.inspect(anchor)
            }
            Task { [weak self] in
                guard let self, let rect = await origin.value, self.session == token else { return }
                self.hud.pinOrigin(rect, for: token)
            }
            syncHotkey(); hud.show(.listening)
            updateStatus("Listening · \(finishInstruction)")
            if !engineReady {
                let generation = engineGeneration
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.transcriber.rewarm()
                        if generation == self.engineGeneration { self.engineReady = true }
                    } catch {
                        if generation == self.engineGeneration { self.engineReady = false }
                    }
                }
            }
            if !correctionReady { startCorrection() }
            listeningTimer?.invalidate()
            listeningTimer = Timer(timeInterval: 115, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishDictation() }
            }
            RunLoop.main.add(listeningTimer!, forMode: .common)
        } catch {
            state.finish(token); syncHotkey(); metrics.finish("microphoneFailed", token)
            updateStatus(error.localizedDescription); hud.show(.error, message: error.localizedDescription)
            dismissHUD(after: 5, for: token)
        }
    }

    private func finishDictation() {
        guard phase == .listening else { return }
        listeningTimer?.invalidate(); listeningTimer = nil
        let token = session
        let vocabularySnapshot = sessionVocabulary
        metrics.mark("stopped", token)
        do {
            let audio = try recorder.stop()
            guard state.process(token) else { return }
            syncHotkey(); updateStatus("Transcribing locally…"); hud.show(.transcribing)
            let capture = targetTask
            processingTask = Task { [weak self] in
                guard let self, token == session, !Task.isCancelled else { return }
                var recoverable: String?
                do {
                    let raw = try await transcriber.transcribe(audio.samples, vocabulary: vocabularySnapshot)
                    guard token == session, !Task.isCancelled else { return }
                    engineReady = true
                    customWordsController?.updateRecognitionStatus(overflowIDs: transcriber.lastVocabularyOverflowIDs)
                    metrics.mark("transcribed", token)
                    if raw.isEmpty { finishWithoutText("No speech detected", token: token); return }
                    recoverable = raw
                    var result = raw, usedOriginal = false
                    if correctionReady {
                        updateStatus("Correcting locally…"); hud.show(.correcting)
                        do { result = try await cleanup.clean(raw, vocabulary: vocabularySnapshot) }
                        catch { usedOriginal = true }
                    } else {
                        usedOriginal = true; startCorrection()
                    }
                    guard token == session, !Task.isCancelled else { return }
                    metrics.mark("corrected", token); recoverable = result
                    guard let destination = await capture?.value, destination.canInsertAutomatically else {
                        hold(result, token: token); return
                    }
                    try Task.checkCancellation()
                    guard token == session else { return }
                    deliver(result, into: destination, token: token,
                            note: audio.warning ?? (usedOriginal ? "Original transcript used" : nil))
                } catch {
                    guard token == session, !Task.isCancelled else { return }
                    if let recoverable { hold(recoverable, token: token) }
                    else { finishWithoutText(error.localizedDescription, token: token) }
                }
            }
        } catch { finishWithoutText(error.localizedDescription, token: token) }
    }

    private func hold(_ text: String, token: UUID) {
        guard state.hold(text, for: token) else { return }
        recoveryNeeded = true; processingTask = nil; targetTask = nil
        metrics.finish("waitingForPlacement", token); showPending()
        suspendEnginesIfIdle()
    }

    private func showPending(_ message: String? = nil) {
        guard state.pendingText != nil else { return }
        dismissTask?.cancel(); syncHotkey()
        updateStatus(message ?? "Text ready · click a text box, then \(placementInstruction)")
        hud.show(.ready, message: message)
    }

    private func placePending() {
        guard !isTerminating else { return }
        guard phase == .pending, let text = state.pendingText else { syncHotkey(); return }
        guard !copyInProgress else { showPending("Finishing clipboard copy…"); return }
        guard allPermissions, monitoring else { showPending("Text saved · finish permission setup to place it"); return }
        guard let token = state.beginPlacement() else { return }
        hud.beginSession(token, fallbackScreen: NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)
        setupWindow?.orderOut(nil)
        metrics.begin(token)
        syncHotkey(); updateStatus("Checking destination…"); hud.show(.inserting)
        let anchor = inserter.beginCapture()
        Task { [weak self, inserter] in
            guard let self, let anchor, let rect = await inserter.originWindowFrame(for: anchor), self.session == token else { return }
            self.hud.pinOrigin(rect, for: token)
        }
        processingTask = Task { [weak self] in
            guard let self else { return }
            guard let anchor, let destination = try? await inserter.inspect(anchor), destination.canInsertAutomatically,
                  token == session, !Task.isCancelled else {
                if token == session { hold(text, token: token) }; return
            }
            deliver(text, into: destination, token: token, note: nil)
        }
    }

    private func deliver(_ text: String, into destination: TextInserter.Target, token: UUID, note: String?) {
        updateStatus("Inserting text…"); hud.show(.inserting)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { deliveryTasks.removeValue(forKey: token); suspendEnginesIfIdle() }
            do {
                let result = try await inserter.insert(text: text, into: destination, onDispatched: { [weak self] in
                    guard let self, state.didDispatch(text, for: token) else { return }
                    metrics.mark("dispatched", token); metrics.mark("nextCaptureReady", token)
                    processingTask = nil; targetTask = nil; recoveryNeeded = false
                    syncHotkey(); updateStatus("Paste sent · \(startInstruction) for another dictation")
                    completionFeedback.begin(token)
                    hud.show(.pasteSent)
                    dismissHUD(after: 1.8, for: token)
                }, onVerified: { [weak self] in
                    guard let self else { return }
                    self.metrics.mark("verifiedVisible", token)
                    guard token == self.session, self.phase == .idle,
                          self.completionFeedback.confirm(token) else { return }
                    self.hud.show(.inserted)
                    self.dismissHUD(after: 0.9, for: token)
                })
                let current = state.finishDelivery(token)
                metrics.finish(result == .verified ? "verified" : "sentUnverified", token)
                guard current else { return }
                if result == .sentWithoutVerification {
                    recoveryNeeded = true
                    updateStatus("Paste sent · check the text box; Copy last result is available")
                } else {
                    updateStatus(note.map { "Inserted · \($0)" } ?? permissionStatus)
                }
            } catch {
                // Cancellation before dispatch preserves an explicitly waiting
                // result. Once dispatched, TextInserter completes its lease.
                guard token == session, !Task.isCancelled else { return }
                hold(text, token: token)
            }
        }
        deliveryTasks[token] = task
        processingTask = task
    }

    private func finishWithoutText(_ message: String, token: UUID) {
        guard state.finish(token) else { return }
        processingTask = nil; targetTask = nil; syncHotkey()
        metrics.finish("noResult", token); updateStatus(message)
        hud.show(.error, message: message); dismissHUD(after: 4, for: token)
        suspendEnginesIfIdle()
    }

    private func dismissHUD(after seconds: Double, for token: UUID) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.session == token, self.phase == .idle else { return }
            self.completionFeedback.dismiss(token)
            self.hud.hide()
        }
    }

    private func dismissCompletedFeedback() {
        guard phase == .idle, state.pendingText == nil,
              let kind = hud.state, [.inserted, .pasteSent, .error].contains(kind) else { return }
        dismissTask?.cancel()
        completionFeedback.dismiss(session)
        hud.hide()
    }

    @objc private func cancelDictation() {
        guard !isTerminating, phase == .listening || phase == .processing else { return }
        let canceled = session
        processingTask?.cancel(); processingTask = nil; targetTask?.cancel(); targetTask = nil
        state.cancel(); engineGeneration &+= 1; engineReady = false; transcriber.cancel()
        listeningTimer?.invalidate(); listeningTimer = nil; recorder.cancel()
        metrics.finish("canceled", canceled); syncHotkey()
        if state.pendingText != nil { showPending() }
        else { updateStatus("Canceled · \(startInstruction) when ready"); hud.hide() }
        if releaseEnginesWhenIdle { suspendEnginesIfIdle() }
        else {
            let generation = engineGeneration
            Task { [weak self] in
                guard let self, !self.isTerminating, !self.suspending,
                      !self.releaseEnginesWhenIdle, generation == self.engineGeneration else { return }
                do {
                    try await self.transcriber.rewarm()
                    guard generation == self.engineGeneration, !Task.isCancelled else { return }
                    self.engineReady = true; self.suspendEnginesIfIdle()
                } catch {}
            }
        }
    }

    @objc private func copyLast() {
        guard !isTerminating, !copyInProgress, phase == .idle || phase == .pending,
              let text = state.pendingText ?? lastText else { return }
        let token = session
        copyInProgress = true; updateStatus("Finishing clipboard copy…")
        if phase == .pending { hud.show(.ready, message: "Finishing clipboard copy…") }
        Task { [weak self] in
            guard let self else { return }
            // A previous editor may not have consumed its dispatched paste yet.
            await inserter.waitForPendingPaste()
            copyInProgress = false
            guard !isTerminating else { return }
            guard token == session else { updateStatus(status); return }
            guard inserter.copyForRecovery(text: text) else {
                if state.pendingText != nil { showPending("Copy failed · your text is still waiting") }
                else {
                    updateStatus("Copy failed · Copy last result is still available")
                    hud.show(.pasteSent, message: "Copy failed · check the text box or try Copy again")
                    dismissHUD(after: 5, for: token)
                }
                return
            }
            if state.pendingText != nil { state.resolvePending(copied: true) }
            recoveryNeeded = false; syncHotkey(); updateStatus("Copied · paste wherever you need it")
            hud.hide(); suspendEnginesIfIdle()
        }
    }

    @objc private func discardPending() {
        guard !isTerminating, phase == .pending else { return }
        state.resolvePending(copied: false); recoveryNeeded = false
        syncHotkey(); hud.hide(); updateStatus(permissionStatus); suspendEnginesIfIdle()
    }

    @objc private func exportMetrics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Local-Dictation-performance.json"
        panel.message = "Timing measurements only. No audio, dictated text, or application names are included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try metrics.export().write(to: url, options: .atomic) }
        catch { updateStatus("Could not export measurements: \(error.localizedDescription)") }
    }

    @objc private func exportPermissionDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Local-Dictation-permissions.json"
        panel.message = "Local launch identities and permission/listener states. Includes the app's installation path; no audio, text, vocabulary, or keystrokes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try permissionDiagnostics.export().write(to: url, options: .atomic) }
        catch { updateStatus("Could not export permission diagnostics: \(error.localizedDescription)") }
    }

    private func configureLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = true
                if self.phase == .listening { self.finishDictation() }
                self.suspendEnginesIfIdle()
            }
        })
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sleeping = false
                if self.suspending { self.wakeRequested = true; return }
                guard !self.memoryPressure else { return }
                if !self.engineReady { await self.prepareEngines() }
                else { self.startCorrection() }
            }
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let events = self.pressureSource?.data else { return }
                self.memoryPressure = events.contains(.warning) || events.contains(.critical)
                self.suspendEnginesIfIdle()
            }
        }
        source.resume(); pressureSource = source
    }

    private func suspendEnginesIfIdle() {
        guard releaseEnginesWhenIdle, !suspending, phase == .idle || phase == .pending || phase == .loading else { return }
        guard engineReady || correctionReady || correctionTask != nil || phase == .loading else { return }
        suspending = true; engineReady = false; correctionReady = false
        engineGeneration &+= 1; correctionGeneration &+= 1
        correctionTask?.cancel(); correctionTask = nil
        Task { [weak self] in
            guard let self else { return }
            await transcriber.suspend(); await correctionService.suspend()
            suspending = false; state.ready(); syncHotkey()
            correctionStatus = "Models resting · reload on next dictation"
            if wakeRequested {
                wakeRequested = false
                if !releaseEnginesWhenIdle { await prepareEngines() }
            } else if phase == .idle { updateStatus(permissionStatus) }
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        var copyOnQuit: String?
        if state.pendingText != nil {
            let alert = NSAlert()
            alert.messageText = "Keep your waiting dictation?"
            alert.informativeText = "This text is held only in memory. Copy it before quitting, or discard it."
            alert.addButton(withTitle: "Copy and Quit")
            alert.addButton(withTitle: "Discard and Quit")
            alert.addButton(withTitle: "Cancel")
            let answer = alert.runModal()
            if answer == .alertThirdButtonReturn { return .terminateCancel }
            if answer == .alertFirstButtonReturn { copyOnQuit = state.pendingText }
        }
        let preparingModels = modelPreparationTask
        guard inserter.hasPendingPaste || preparingModels != nil else {
            if let copyOnQuit, !inserter.copyForRecovery(text: copyOnQuit) {
                showPending("Copy failed · your text is still waiting")
                return .terminateCancel
            }
            return .terminateNow
        }
        isTerminating = true
        // Cancellation terminates curl, but its asynchronous drain must finish
        // before exit releases the model-file lock. Otherwise an immediate
        // relaunch could resume a partial file still owned by the old child.
        preparingModels?.cancel()
        processingTask?.cancel(); targetTask?.cancel(); state.cancel(); recorder.cancel()
        // Keep the timer/listener alive until termination is confirmed, so a
        // failed Copy and Quit can return to a fully usable pending session.
        hotkey.setPhase(.processing)
        updateStatus(preparingModels != nil ? "Finishing model setup cleanup before quitting…" : "Restoring clipboard before quitting…")
        Task { @MainActor in
            await preparingModels?.value
            await inserter.waitForPendingPaste()
            if let copyOnQuit, !inserter.copyForRecovery(text: copyOnQuit) {
                isTerminating = false; syncHotkey()
                showPending("Copy failed · your text is still waiting")
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); listeningTimer?.invalidate(); hotkey.stop(); dismissTask?.cancel()
        pressureSource?.cancel()
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        processingTask?.cancel(); targetTask?.cancel(); correctionTask?.cancel(); modelPreparationTask?.cancel()
        recorder.cancel(); transcriber?.shutdown(); correctionService?.stop()
    }

    private var usesFn: Bool { shortcutConfiguration == .fn }
    private var startInstruction: String {
        usesFn ? "double-tap Fn" : "press \(shortcutConfiguration.displayName)"
    }
    private var finishInstruction: String {
        usesFn ? "tap Fn to finish" : "press \(shortcutConfiguration.displayName) to finish"
    }
    private var placementInstruction: String {
        usesFn ? "tap Fn once" : "press \(shortcutConfiguration.displayName) once"
    }

    private func updateShortcutAppearance() {
        shortcutLabel?.stringValue = shortcutConfiguration.displayName
        hud.finishInstruction = usesFn ? "Tap Fn to finish" : "Press \(shortcutConfiguration.displayName) to finish"
        hud.placementInstruction = usesFn ? "Click a text box · tap Fn"
            : "Click a text box · press \(shortcutConfiguration.displayName)"
        setupSubtitle?.stringValue = usesFn
            ? "Click a text box. Double-tap Fn / Globe to start. Tap again to finish. If you click away, your text waits: select a text box and tap Fn once to place it."
            : "Click a text box. Press \(shortcutConfiguration.displayName) once to start and again to finish. If you click away, select the intended text box and press the same shortcut to place your waiting text."
        keyboardHint?.stringValue = usesFn
            ? "In Keyboard settings, set “Press 🌐 key to” to “Do Nothing” and make sure Apple Dictation does not use Fn / Globe. Quit Wispr Flow while using the same Fn key."
            : "Your shortcut is reserved while Local Dictation is running. Choose a combination you do not use in other apps. Function keys may require Fn depending on your keyboard settings."
        updateSetupStatus()
    }

    @objc private func changeShortcut() {
        guard phase == .idle, !recordingShortcut, !copyInProgress, !isTerminating,
              let window = setupWindow else { return }
        recordingShortcut = true
        hotkey.stop(); monitoring = false
        updateStatus("Choosing a shortcut · Escape to cancel")
        shortcutRecorder.begin(on: window, accept: { [weak self] candidate in
            guard let self else { return "Setup closed. Try again." }
            switch self.hotkey.configure(candidate) {
            case .failure(let error): return error.localizedDescription
            case .success:
                guard HotkeyPreferences.save(candidate) else { return "This shortcut could not be saved." }
                self.shortcutConfiguration = candidate
                self.shortcutFailure = nil
                self.updateShortcutAppearance()
                return nil
            }
        }, completion: { [weak self] in
            guard let self else { return }
            self.recordingShortcut = false
            self.resumeShortcut()
            if !NSApp.isActive, self.allPermissions, self.monitoring { self.setupWindow?.orderOut(nil) }
        })
    }

    @objc private func resetShortcut() {
        guard phase == .idle, !recordingShortcut, !copyInProgress, !isTerminating else { return }
        hotkey.stop(); monitoring = false
        shortcutConfiguration = .fn
        _ = HotkeyPreferences.save(.fn)
        resumeShortcut()
    }

    private func resumeShortcut() {
        switch hotkey.configure(shortcutConfiguration) {
        case .success: shortcutFailure = nil
        case .failure(let error): shortcutFailure = error.localizedDescription
        }
        lastPermissionState = nil
        listenerAttempts = 0; listenerRetryAfter = 0; listenerFailure = nil
        updateShortcutAppearance()
        refreshPermissions()
        if shortcutFailure != nil { updateStatus(permissionStatus) }
    }

    @objc private func showSetup() {
        if let setupWindow { NSApp.activate(ignoringOtherApps: true); setupWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 730),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Local Dictation"; window.isReleasedWhenClosed = false; window.center()
        window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Speak into any text box")
        title.font = .systemFont(ofSize: 23, weight: .semibold); stack.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "Click a text box. Double-tap Fn / Globe to start. Tap again to finish. If you click away, your text waits: select a text box and tap Fn once to place it.")
        subtitle.font = .systemFont(ofSize: 14); stack.addArrangedSubview(subtitle)
        setupSubtitle = subtitle
        let shortcutHeading = NSTextField(labelWithString: "Dictation shortcut")
        shortcutHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        let shortcut = NSTextField(labelWithString: shortcutConfiguration.displayName)
        shortcut.font = .systemFont(ofSize: 13, weight: .medium)
        shortcutLabel = shortcut
        let change = NSButton(title: "Change…", target: self, action: #selector(changeShortcut))
        change.bezelStyle = .rounded; shortcutChangeButton = change
        let reset = NSButton(title: "Use Fn / Globe", target: self, action: #selector(resetShortcut))
        reset.bezelStyle = .rounded; shortcutResetButton = reset
        let shortcutRow = NSStackView(views: [shortcut, change, reset])
        shortcutRow.spacing = 10; shortcutRow.alignment = .centerY
        let shortcutSection = NSStackView(views: [shortcutHeading, shortcutRow])
        shortcutSection.orientation = .vertical; shortcutSection.alignment = .leading; shortcutSection.spacing = 6
        stack.addArrangedSubview(shortcutSection)
        let wordsButton = NSButton(title: "Custom Words…", target: self, action: #selector(showCustomWords))
        wordsButton.bezelStyle = .rounded; stack.addArrangedSubview(wordsButton)
        let permissionTitle = NSTextField(labelWithString: "One-time permissions")
        permissionTitle.font = .systemFont(ofSize: 13, weight: .semibold); stack.addArrangedSubview(permissionTitle)
        let permissions = NSStackView(); permissions.orientation = .vertical; permissions.alignment = .leading; permissions.spacing = 5
        for (label, action) in [("Microphone", #selector(allowMicrophone)), ("Accessibility", #selector(allowAccessibility)), ("Input Monitoring", #selector(allowMonitoring))] {
            let button = NSButton(title: label, target: self, action: action); button.bezelStyle = .rounded
            permissionButtons[label] = button
            let purpose: String
            switch label {
            case "Microphone": purpose = "Hear you while dictating"
            case "Accessibility": purpose = "Place text into your chosen field"
            default: purpose = "Detect your shortcut across apps"
            }
            let explanation = NSTextField(labelWithString: purpose); explanation.font = .systemFont(ofSize: 12)
            explanation.textColor = .secondaryLabelColor
            let row = NSStackView(views: [button, explanation]); row.spacing = 10; row.alignment = .centerY
            permissions.addArrangedSubview(row)
        }
        stack.addArrangedSubview(permissions)
        let finishSetup = NSButton(title: "Continue setup", target: self, action: #selector(continuePermissionSetup))
        finishSetup.bezelStyle = .rounded; continueSetupButton = finishSetup
        let retryListener = NSButton(title: "Retry listener", target: self, action: #selector(retryListener))
        retryListener.bezelStyle = .rounded; listenerRetryButton = retryListener
        let setupActions = NSStackView(views: [finishSetup, retryListener]); setupActions.spacing = 8
        stack.addArrangedSubview(setupActions)
        let progress = NSProgressIndicator(); progress.style = .bar; progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1; progress.translatesAutoresizingMaskIntoConstraints = false
        let modelsAction = NSButton(title: "Pause model setup", target: self, action: #selector(toggleModelSetup))
        modelsAction.bezelStyle = .rounded
        let modelRow = NSStackView(views: [progress, modelsAction]); modelRow.spacing = 10
        progress.widthAnchor.constraint(equalToConstant: 220).isActive = true
        modelProgress = progress; modelActionButton = modelsAction; stack.addArrangedSubview(modelRow)
        let statusLabel = NSTextField(wrappingLabelWithString: "Checking permissions…")
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor
        setupStatus = statusLabel; stack.addArrangedSubview(statusLabel)
        let keyboard = NSTextField(wrappingLabelWithString: "In Keyboard settings, set “Press 🌐 key to” to “Do Nothing” and make sure Apple Dictation does not use Fn / Globe. Quit Wispr Flow while using the same Fn key.")
        keyboard.font = .systemFont(ofSize: 13); keyboardHint = keyboard; stack.addArrangedSubview(keyboard)
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
        setupWindow = window; updateShortcutAppearance(); updateSetupStatus()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

    private func updateSetupStatus() {
        let canChange = phase == .idle && !recordingShortcut && !editingVocabulary && !copyInProgress && !isTerminating
        shortcutChangeButton?.isEnabled = canChange
        shortcutResetButton?.isEnabled = canChange && shortcutConfiguration != .fn
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = TextInserter.accessibilityGranted(), input = FnHotkey.permissionGranted
        for (name, allowed) in [("Microphone", mic), ("Accessibility", accessibility), ("Input Monitoring", input)] {
            permissionButtons[name]?.title = allowed ? "✓ \(name)" : "Allow \(name)…"
            permissionButtons[name]?.isEnabled = !allowed
        }
        continueSetupButton?.isHidden = allPermissions
        continueSetupButton?.isEnabled = !guidedPermissionSetup
        listenerRetryButton?.isHidden = !allPermissions || monitoring
        listenerRetryButton?.isEnabled = !monitoring && !isTerminating
        modelProgress?.isHidden = runtimeInitialized
        modelActionButton?.isHidden = runtimeInitialized
        modelActionButton?.title = modelPreparationTask == nil ? "Resume model setup" : "Pause model setup"
        let shortcutProblem = shortcutFailure.map { "\nShortcut: \($0)" } ?? ""
        let listener = monitoring ? "Shortcut listener: active" : listenerFailure?.localizedDescription ?? "Shortcut listener: starting"
        setupStatus?.stringValue = "\(listener)\(shortcutProblem)\n\(modelPreparationStatus ?? correctionStatus)\n\(status)"
    }

    @objc private func showCustomWords() {
        guard !isTerminating, phase != .listening, phase != .processing, !recordingShortcut else { return }
        if customWordsController == nil {
            customWordsController = CustomWordsController(snapshot: { [weak self] in self?.vocabulary ?? .empty },
                onSave: { [weak self] entries in
                    guard let self else { return "The application is closing." }
                    do {
                        let updated = try VocabularySnapshot(entries: entries, revision: self.vocabulary.revision &+ 1)
                        guard VocabularyPreferences.save(updated) else { return "Your words could not be saved. Try again." }
                        self.vocabulary = updated
                        return nil
                    } catch { return error.localizedDescription }
                }, onEditingChanged: { [weak self] editing in
                    guard let self else { return }
                    self.editingVocabulary = editing; self.syncHotkey(); self.updateSetupStatus()
                })
        }
        customWordsController?.show()
    }

    @objc private func continuePermissionSetup() {
        guidedPermissionSetup = true; guidedPermissionStep = nil
        advancePermissionSetup(); updateSetupStatus()
    }

    private func advancePermissionSetup() {
        guard guidedPermissionSetup else { return }
        guard let missing = missingPermissions.first else {
            guidedPermissionSetup = false; guidedPermissionStep = nil
            updateSetupStatus(); return
        }
        guard guidedPermissionStep != missing else { return }
        guidedPermissionStep = missing
        switch missing {
        case "Microphone": allowMicrophone()
        case "Accessibility": allowAccessibility()
        default: allowMonitoring()
        }
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
                    "Do not delete the file. Send it to Yosef tomorrow.",
                    "Add 3, I mean 2 items to the list."]
                let expected = ["Let's meet on Friday at three.", "I need to send the document tomorrow.",
                    "The total is fifty dollars.", "Do not delete the file. Send it to Yosef tomorrow.",
                    "Add 2 items to the list."]
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
                guard let anchor = inserter.beginCapture() else {
                    throw DictationError.message("The test field has no stable identity or selection")
                }
                let destination = try await inserter.inspect(anchor)
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
