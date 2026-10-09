import AppKit
import AVFoundation
import DictationCore
import ServiceManagement

/// Ordinary preferences stay open when another app activates. First-run setup
/// remains a separate flow, entered through the supplied setup action.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSTabViewDelegate {
    struct Snapshot {
        var status: String
        var shortcutDisplay: String
        var usesFn: Bool
        var canChangeControls: Bool
        var readiness: String
        var setupNeeded: Bool
        var vocabularyCount: Int

        static let initial = Snapshot(status: "Starting…", shortcutDisplay: "Fn / Globe", usesFn: true,
            canChangeControls: false, readiness: "Checking readiness…", setupNeeded: true, vocabularyCount: 0)
    }

    enum Action: CaseIterable, Hashable {
        case changeShortcut, resetShortcut, customWords, setup
        case retryEngines, retryListener, exportMetrics, exportPermissions
    }

    struct Actions {
        var changeShortcut: () -> Void
        var resetShortcut: () -> Void
        var customWords: () -> Void
        var setup: () -> Void
        var retryEngines: () -> Void
        var retryListener: () -> Void
        var exportMetrics: () -> Void
        var exportPermissions: () -> Void
        var preferencesChanged: () -> Void = {}

        func perform(_ action: Action) {
            switch action {
            case .changeShortcut: changeShortcut()
            case .resetShortcut: resetShortcut()
            case .customWords: customWords()
            case .setup: setup()
            case .retryEngines: retryEngines()
            case .retryListener: retryListener()
            case .exportMetrics: exportMetrics()
            case .exportPermissions: exportPermissions()
            }
        }
    }

    /// The same action gate drives buttons and dispatch, so an already queued
    /// click cannot change recording controls after dictation starts.
    struct State {
        var snapshot = Snapshot.initial
        let actions: Actions

        func permits(_ action: Action) -> Bool {
            switch action {
            case .setup, .exportMetrics, .exportPermissions: return true
            case .resetShortcut: return snapshot.canChangeControls && !snapshot.usesFn
            default: return snapshot.canChangeControls
            }
        }

        @discardableResult func perform(_ action: Action) -> Bool {
            guard permits(action) else { return false }
            actions.perform(action)
            return true
        }
    }

    let window: NSWindow
    private var state: State
    private let login: LoginItemController
    private let preview = AudioRecorder()
    private let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modeDetail = NSTextField(wrappingLabelWithString: "")
    private let loginButton = NSButton(checkboxWithTitle: "Open Local Dictation at login", target: nil, action: nil)
    private let loginDetail = NSTextField(wrappingLabelWithString: "")
    private let loginSettingsButton = NSButton(title: "Open Login Items Settings…", target: nil, action: nil)
    private let inputPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputDetail = NSTextField(wrappingLabelWithString: "")
    private let inputNotice = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: "Test microphone", target: nil, action: nil)
    private let testMeter = NSLevelIndicator()
    private let testDetail = NSTextField(wrappingLabelWithString: "The microphone listens only while a test is running.")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let shortcutDetail = NSTextField(wrappingLabelWithString: "")
    private let wordsLabel = NSTextField(labelWithString: "")
    private let readinessLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var actionButtons: [Action: NSButton] = [:]
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(actions: Actions, loginEnvironment: LoginItemController.Environment? = nil) {
        state = State(actions: actions)
        login = LoginItemController(environment: loginEnvironment)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Local Dictation Settings"
        window.identifier = .init("dictation-settings")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 670, height: 440)
        window.delegate = self
        window.center()
        buildWindow()
        preview.onLevel = { [weak self] level in
            // Display a useful speech range without exposing or storing samples.
            let decibels = 20 * log10(max(0.000_001, Double(level)))
            self?.testMeter.doubleValue = max(0, min(1, (decibels + 60) / 60))
        }
        preview.onAutomaticStop = { [weak self] in self?.stopMicrophoneTest() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopMicrophoneTest() }
            })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window.isVisible else { return }
                    self.refreshExternalState()
                }
            })
        update(.initial)
    }

    deinit {
        refreshTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func show() {
        refreshExternalState()
        if refreshTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window.isVisible else { return }
                    self.refreshExternalState()
                }
            }
            refreshTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        stopMicrophoneTest()
        refreshTimer?.invalidate(); refreshTimer = nil
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopMicrophoneTest()
        refreshTimer?.invalidate(); refreshTimer = nil
    }

    func windowDidResignKey(_ notification: Notification) { stopMicrophoneTest() }
    func windowDidMiniaturize(_ notification: Notification) { stopMicrophoneTest() }
    func windowDidBecomeKey(_ notification: Notification) { refreshExternalState() }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if tabViewItem?.identifier as? String != "Audio" { stopMicrophoneTest() }
    }

    func update(_ snapshot: Snapshot) {
        state.snapshot = snapshot
        if !snapshot.canChangeControls { stopMicrophoneTest() }
        statusLabel.stringValue = snapshot.status
        readinessLabel.stringValue = snapshot.readiness
        shortcutLabel.stringValue = snapshot.shortcutDisplay
        shortcutDetail.stringValue = snapshot.usesFn
            ? "Double-tap Fn / Globe to start. Tap once to finish. In Keyboard Settings, set the Globe key to Do Nothing and choose a different shortcut for Apple Dictation."
            : "Press your shortcut once to start and again to finish. Choose a combination you do not use in other apps."
        wordsLabel.stringValue = snapshot.vocabularyCount == 1 ? "1 custom word saved" : "\(snapshot.vocabularyCount) custom words saved"
        for (action, button) in actionButtons { button.isEnabled = state.permits(action) }
        actionButtons[.setup]?.title = snapshot.setupNeeded ? "Finish setup…" : "Review setup…"
        modePicker.isEnabled = snapshot.canChangeControls
        inputPicker.isEnabled = snapshot.canChangeControls
        testButton.isEnabled = snapshot.canChangeControls
        refreshMode()
    }

    /// Call before microphone capture begins, including starts from shortcuts.
    func stopMicrophoneTest() {
        let wasRecording = preview.isRecording
        preview.cancel()
        testMeter.doubleValue = 0
        testButton.title = "Test microphone"
        if wasRecording {
            testDetail.stringValue = "Microphone test stopped. No recording was saved."
            refreshAudioDevices()
        }
    }

    private func buildWindow() {
        let tabs = NSTabView()
        tabs.delegate = self
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.identifier = .init("settings-sections")
        let sections: [(String, NSView)] = [
            ("General", generalSection()), ("Audio", audioSection()),
            ("Shortcuts", shortcutSection()), ("Custom Words", wordsSection()),
            ("Advanced", advancedSection())
        ]
        for (name, view) in sections {
            let item = NSTabViewItem(identifier: name)
            item.label = name; item.view = view; tabs.addTabViewItem(item)
        }
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.identifier = .init("settings-status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(tabs); content.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabs.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    private func generalSection() -> NSView {
        modePicker.identifier = .init("dictation-mode")
        modePicker.setAccessibilityLabel("Dictation mode")
        for mode in DictationMode.allCases {
            modePicker.addItem(withTitle: mode.displayName)
            modePicker.lastItem?.representedObject = mode.rawValue
        }
        modePicker.target = self; modePicker.action = #selector(changeMode)
        loginButton.identifier = .init("launch-at-login")
        loginButton.target = self; loginButton.action = #selector(changeLogin)
        loginSettingsButton.target = self; loginSettingsButton.action = #selector(openLoginSettings)
        loginSettingsButton.bezelStyle = .rounded
        return section(title: "Make dictation work your way", views: [
            heading("Dictation mode"), modePicker, detail(modeDetail),
            note("Changes apply to your next recording."), separator(),
            loginButton, detail(loginDetail), loginSettingsButton, separator(),
            note("Audio and transcription stay on your Mac. Recordings are temporary and no transcript history is saved.")
        ])
    }

    private func audioSection() -> NSView {
        inputPicker.identifier = .init("audio-input")
        inputPicker.setAccessibilityLabel("Microphone")
        inputPicker.target = self; inputPicker.action = #selector(changeInput)
        inputPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        inputNotice.textColor = .systemOrange
        testButton.identifier = .init("test-microphone")
        testButton.bezelStyle = .rounded
        testButton.target = self; testButton.action = #selector(toggleMicrophoneTest)
        testMeter.levelIndicatorStyle = .continuousCapacity
        testMeter.minValue = 0; testMeter.maxValue = 1; testMeter.doubleValue = 0
        testMeter.setAccessibilityLabel("Microphone input level")
        testMeter.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let testRow = NSStackView(views: [testButton, testMeter]); testRow.spacing = 14; testRow.alignment = .centerY
        return section(title: "Choose your microphone", views: [
            heading("Input device"), inputPicker, detail(inputDetail), detail(inputNotice),
            note("System Default follows the microphone selected in macOS. A saved microphone that is unavailable falls back to the system input for the next recording."),
            separator(), heading("Microphone test"), testRow, detail(testDetail),
            note("Testing stops when you leave this window or start dictation. Device changes apply to your next recording.")
        ])
    }

    private func shortcutSection() -> NSView {
        shortcutLabel.font = .systemFont(ofSize: 20, weight: .medium)
        shortcutLabel.identifier = .init("settings-shortcut")
        let buttons = NSStackView(views: [actionButton("Change shortcut…", .changeShortcut),
                                         actionButton("Use Fn / Globe", .resetShortcut)])
        buttons.spacing = 10
        return section(title: "Start dictation from any app", views: [
            heading("Current shortcut"), shortcutLabel, buttons, detail(shortcutDetail), separator(),
            note("If text is waiting, click the intended text box and press the shortcut to place it. With Fn / Globe, tap once."),
            note("Shortcut changes are available when no dictation or recovery action is in progress.")
        ])
    }

    private func wordsSection() -> NSView {
        wordsLabel.font = .systemFont(ofSize: 14, weight: .medium)
        wordsLabel.identifier = .init("settings-vocabulary-count")
        return section(title: "Keep names and terms familiar", views: [
            note("Save preferred spellings for people, projects, and technical terms. You can also add an alternate spelling when it is repeatedly recognized that way."),
            wordsLabel, actionButton("Manage custom words…", .customWords), separator(),
            note("Custom words are saved only on this Mac. Changes apply to the next recording.")
        ])
    }

    private func advancedSection() -> NSView {
        let retryRow = NSStackView(views: [actionButton("Retry local engines", .retryEngines),
                                          actionButton("Retry shortcut listener", .retryListener)])
        retryRow.spacing = 10
        let exportRow = NSStackView(views: [actionButton("Export performance…", .exportMetrics),
                                           actionButton("Export permission diagnostics…", .exportPermissions)])
        exportRow.spacing = 10
        return section(title: "Setup and troubleshooting", views: [
            heading("Readiness"), detail(readinessLabel), actionButton("Review setup…", .setup),
            separator(), heading("Recovery"), retryRow,
            note("Retry local engines if speech recognition or correction is unavailable. Retry the shortcut listener if your configured shortcut stops responding."),
            separator(), heading("Diagnostics"), exportRow,
            note("Performance exports contain timings, not dictated text or audio. Permission diagnostics include the installation path and permission states.")
        ])
    }

    private func section(title: String, views: [NSView]) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        stack.addArrangedSubview(titleLabel)
        for view in views { stack.addArrangedSubview(view) }
        document.addSubview(stack); scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        for view in views {
            if view is NSTextField || view is NSBox {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        }
        return scroll
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func detail(_ label: NSTextField) -> NSTextField {
        label.font = .systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = detail(NSTextField(wrappingLabelWithString: text))
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox(); box.boxType = .separator; return box
    }

    private func actionButton(_ title: String, _ action: Action) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(invokeAction(_:)))
        button.bezelStyle = .rounded
        button.tag = Action.allCases.firstIndex(of: action)!
        button.identifier = .init("settings-action-\(action)")
        actionButtons[action] = button
        return button
    }

    @objc private func invokeAction(_ sender: NSButton) {
        guard Action.allCases.indices.contains(sender.tag) else { return }
        stopMicrophoneTest()
        state.perform(Action.allCases[sender.tag])
    }

    @objc private func changeMode() {
        guard state.snapshot.canChangeControls,
              let raw = modePicker.selectedItem?.representedObject as? String,
              let mode = DictationMode(rawValue: raw) else { refreshMode(); return }
        DictationPreferences.mode = mode
        refreshMode(); state.actions.preferencesChanged()
    }

    private func refreshMode() {
        let mode = DictationPreferences.mode
        modePicker.selectItem(at: DictationMode.allCases.firstIndex(of: mode) ?? 0)
        modeDetail.stringValue = mode == .clean
            ? "Clean removes hesitation and repetition, adds punctuation, and applies clear spoken corrections."
            : "Verbatim uses the speech model’s original transcript without the cleanup step."
    }

    @objc private func changeInput() {
        guard state.snapshot.canChangeControls else { refreshAudioDevices(); return }
        stopMicrophoneTest()
        DictationPreferences.inputUID = inputPicker.selectedItem?.representedObject as? String
        refreshAudioDevices(); state.actions.preferencesChanged()
    }

    private func refreshAudioDevices() {
        // Keep an unavailable preference visible instead of silently overwriting it.
        let selectedUID = DictationPreferences.inputUID
        let devices = AudioInputProvider.devices()
        let entries = [("System Default", nil as String?)] + devices.map { ($0.name, Optional($0.uid)) }
            + ((selectedUID != nil && !devices.contains(where: { $0.uid == selectedUID }))
                ? [("Saved microphone (unavailable)", selectedUID)] : [])
        let current = inputPicker.itemArray.map { ($0.title, $0.representedObject as? String) }
        if current.count != entries.count || !zip(current, entries).allSatisfy({ $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1 }) {
            inputPicker.removeAllItems()
            for (title, uid) in entries {
                inputPicker.addItem(withTitle: title); inputPicker.lastItem?.representedObject = uid
            }
        }
        if let index = entries.firstIndex(where: { $0.1 == selectedUID }) { inputPicker.selectItem(at: index) }
        if preview.isRecording, let name = preview.activeInputName {
            inputDetail.stringValue = "Testing: \(name)"
            inputNotice.stringValue = preview.inputNotice ?? ""
            return
        }
        do {
            let resolved = try AudioInputProvider.resolve(uid: selectedUID)
            inputDetail.stringValue = "Next recording: \(resolved.device.name)"
            inputNotice.stringValue = resolved.fallbackNotice ?? ""
        } catch {
            inputDetail.stringValue = "No microphone is available."
            inputNotice.stringValue = error.localizedDescription
        }
    }

    @objc private func toggleMicrophoneTest() {
        if preview.isRecording { stopMicrophoneTest(); return }
        guard state.snapshot.canChangeControls, window.isVisible else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            testDetail.stringValue = "Allow microphone access in setup before testing."
            state.perform(.setup)
            return
        }
        do {
            try preview.start(inputUID: DictationPreferences.inputUID)
            testButton.title = "Stop test"
            testDetail.stringValue = "Listening to \(preview.activeInputName ?? "your microphone"). Speak to check the meter."
            refreshAudioDevices()
        } catch {
            preview.cancel()
            testMeter.doubleValue = 0
            testDetail.stringValue = error.localizedDescription
        }
    }

    private func refreshExternalState() {
        refreshMode(); refreshAudioDevices(); refreshLogin()
    }

    private func refreshLogin() {
        login.refresh()
        loginButton.state = login.status == .enabled ? .on : .off
        loginButton.isEnabled = login.status != .unavailable
        loginDetail.stringValue = login.message
        loginSettingsButton.isHidden = login.status != .requiresApproval
    }

    @objc private func changeLogin() {
        login.setEnabled(loginButton.state != .off)
        refreshLogin()
    }

    @objc private func openLoginSettings() { login.openSettings() }
}

private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// No preference boolean substitutes for the actual macOS login-item state.
/// Tests inject this boundary and never register the real app as a login item.
@MainActor
final class LoginItemController {
    enum Status: Equatable { case disabled, enabled, requiresApproval, unavailable }

    struct Environment {
        var status: () -> Status
        var register: () throws -> Void
        var unregister: () throws -> Void
        var openSettings: () -> Void

        static let live = Environment(status: {
            switch SMAppService.mainApp.status {
            case .notRegistered: return .disabled
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notFound: return .unavailable
            @unknown default: return .unavailable
            }
        }, register: { try SMAppService.mainApp.register() },
           unregister: { try SMAppService.mainApp.unregister() },
           openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }

    private let environment: Environment
    private(set) var status: Status = .disabled
    private(set) var lastError: String?

    init(environment: Environment? = nil) { self.environment = environment ?? .live }

    func refresh() {
        let current = environment.status()
        if current != status { lastError = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) {
        refresh(); lastError = nil
        do {
            if enabled, status != .enabled { try environment.register() }
            else if !enabled, status != .disabled { try environment.unregister() }
        } catch { lastError = error.localizedDescription }
        status = environment.status()
    }

    func openSettings() { environment.openSettings() }

    var message: String {
        if let lastError { return "Could not change the login setting: \(lastError)" }
        switch status {
        case .disabled: return "The app opens when you launch it."
        case .enabled: return "Local Dictation will open in the menu bar when you log in."
        case .requiresApproval: return "Allow Local Dictation in macOS Login Items to enable this setting."
        case .unavailable: return "Login registration is unavailable for this app. Use an installed, signed copy."
        }
    }
}
