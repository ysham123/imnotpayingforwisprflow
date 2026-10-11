import AppKit
import DictationCore

/// A first-run walkthrough. macOS remains responsible for privacy approvals;
/// snapshots confirm grants, model readiness, and actual shortcut detection.
@MainActor
final class SetupController: NSObject, NSWindowDelegate {
    struct Snapshot {
        var readiness = SetupReadiness()
        var modelsBusy = false
        var modelFraction = 0.0
        var modelDetail = "About 3.4 GB. Keep 8 GB free."
        var modelError: String?
        var listenerError: String?
        var recording = false
        var processing = false
        var retainedRecording = false
        var canChangeShortcut = true
    }
    struct Actions {
        var startModels: () -> Void
        var toggleModels: () -> Void
        var allowPermission: (SetupStep) -> Void
        var chooseShortcut: () -> Void
        var useRecommendedShortcut: () -> Void
        var useFn: () -> Void
        var openKeyboard: () -> Void
        var retryListener: () -> Void
        var togglePractice: () -> Void
        var retryPractice: () -> Void
        var discardPractice: () -> Void
        var cancelPractice: () -> Void
        var closed: () -> Void
        var finished: () -> Void
    }
    let window: NSWindow
    private let actions: Actions
    private(set) var flow = SetupFlow()
    private var snapshot = Snapshot()
    private var waitingPermission: SetupStep?
    private var renderedStep: SetupStep?
    private var practiceText = ""
    private var practiceMessage = ""
    private let page = NSStackView()
    private let stepLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let primary = NSButton()
    private let back = NSButton()
    private let later = NSButton()
    private var detailLabel: NSTextField?
    private var actionButton: NSButton?
    private var permissionStatus: NSTextField?
    private var modelBar: NSProgressIndicator?
    private var shortcutStatus: NSTextField?
    private var transcript: NSTextView?
    private var practiceStatus: NSTextField?
    private var practiceButton: NSButton?
    private var retryButton: NSButton?
    private var discardButton: NSButton?
    private var recordingMeter: NSProgressIndicator?

    init(actions: Actions) {
        self.actions = actions
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 610),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Set up Local Dictation"
        window.minSize = NSSize(width: 600, height: 530)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildWindow()
        render()
    }

    var isShortcutTest: Bool { window.isVisible && flow.step == .shortcut }
    var isPractice: Bool { window.isVisible && flow.step == .practice }
    var acceptsPracticeHotkey: Bool { isPractice && window.isKeyWindow }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hideForDictation() { window.orderOut(nil) }

    func update(_ value: Snapshot) {
        let previouslyReady = snapshot.readiness.modelsReady
        snapshot = value
        flow.reconcile(value.readiness)
        if let permission = waitingPermission, value.readiness.granted(permission) {
            waitingPermission = nil
            _ = flow.advance(value.readiness)
        } else if flow.step == .models, !previouslyReady, value.readiness.modelsReady {
            _ = flow.advance(value.readiness)
        }
        render()
    }

    func detectedShortcut() {
        _ = flow.detectShortcut(snapshot.readiness)
        render()
    }

    func beginPractice(_ token: UUID) {
        flow.beginPractice(token)
        practiceText = ""; practiceMessage = "Listening. Say a short sentence, then finish."
        render()
    }

    @discardableResult func finishPractice(_ text: String, token: UUID) -> Bool {
        guard flow.finishPractice(text, token: token) else { return false }
        practiceText = text
        practiceMessage = "Your first dictation worked. Review the words below."
        render()
        return true
    }

    func practiceFailed(_ message: String) {
        flow.cancelPractice(); practiceMessage = message
        render()
    }

    func updateRecording(elapsed: Double, level: Double? = nil) {
        guard flow.step == .practice else { return }
        if let level { recordingMeter?.doubleValue = min(1, max(0, level)) }
        if snapshot.recording {
            practiceStatus?.stringValue = "Listening · \(RecordingPolicy.clock(elapsed)) · finish when you’re done."
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if snapshot.recording || snapshot.processing { actions.cancelPractice() }
        if snapshot.retainedRecording { actions.discardPractice() }
        flow = SetupFlow(); waitingPermission = nil; practiceText = ""; practiceMessage = ""
        window.orderOut(nil)
        actions.closed()
        return true
    }

    private func buildWindow() {
        guard let content = window.contentView else { return }
        let title = label("Local Dictation", size: 18, weight: .semibold)
        var headerViews: [NSView] = []
        if let artwork = NSImage(named: "AppIcon") {
            let icon = NSImageView(image: artwork)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
            headerViews.append(icon)
        }
        headerViews += [title, NSView(), stepLabel]
        let header = NSStackView(views: headerViews)
        header.alignment = .centerY; header.spacing = 12
        stepLabel.font = .systemFont(ofSize: 12); stepLabel.textColor = .secondaryLabelColor
        progress.style = .bar; progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 7
        let top = NSStackView(views: [header, progress]); top.orientation = .vertical
        top.alignment = .leading; top.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        progress.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true

        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = SetupDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        page.orientation = .vertical; page.alignment = .leading; page.spacing = 17
        page.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(page); scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
            page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            page.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        back.title = "Back"; back.target = self; back.action = #selector(goBack); back.bezelStyle = .rounded
        later.title = "Finish later"; later.target = self; later.action = #selector(finishLater); later.bezelStyle = .rounded
        primary.target = self; primary.action = #selector(continueSetup); primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        let footer = NSStackView(views: [back, later, NSView(), primary]); footer.spacing = 12
        footer.alignment = .centerY
        for view in [top, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -15),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func label(_ text: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }
    private func add(_ text: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSTextField {
        let view = label(text, size: size, weight: weight); page.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        return view
    }
    private func button(_ title: String, action: Selector) -> NSButton {
        let view = NSButton(title: title, target: self, action: action); view.bezelStyle = .rounded
        page.addArrangedSubview(view); return view
    }
    private func heading(_ title: String, description: String, symbol: String) {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .systemBlue
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 40).isActive = true
        image.heightAnchor.constraint(equalToConstant: 40).isActive = true
        page.addArrangedSubview(image)
        _ = add(title, size: 27, weight: .semibold)
        _ = add(description)
    }

    private func render() {
        if renderedStep != flow.step {
            for view in page.arrangedSubviews { page.removeArrangedSubview(view); view.removeFromSuperview() }
            detailLabel = nil; actionButton = nil; permissionStatus = nil; modelBar = nil
            shortcutStatus = nil; transcript = nil; practiceStatus = nil; practiceButton = nil
            retryButton = nil; discardButton = nil; recordingMeter = nil
            renderedStep = flow.step
            buildPage()
        }
        progress.doubleValue = Double(flow.step.rawValue)
        stepLabel.stringValue = flow.step == .welcome ? "Welcome" : flow.step == .complete ? "Ready to go" : "Step \(flow.step.rawValue) of 6"
        back.isHidden = flow.step == .welcome || flow.step == .complete
        back.isEnabled = !snapshot.recording && !snapshot.processing && !snapshot.retainedRecording
        later.isHidden = flow.step == .complete
        later.isEnabled = !snapshot.recording && !snapshot.processing
        primary.title = flow.step == .welcome ? "Start setup" : flow.step == .practice ? "Finish setup" : flow.step == .complete ? "Start using Local Dictation" : "Continue"
        switch flow.step {
        case .welcome: primary.isEnabled = true
        case .microphone, .accessibility, .inputMonitoring:
            let allowed = snapshot.readiness.granted(flow.step)
            permissionStatus?.stringValue = allowed ? "✓ Access confirmed" : waitingPermission != nil ? "Waiting for approval. Turn on Local Dictation in System Settings." : "Access has not been approved yet."
            permissionStatus?.textColor = allowed ? .systemGreen : .secondaryLabelColor
            actionButton?.title = allowed ? "Access confirmed" : "Allow \(flow.step.permission ?? "access")…"
            actionButton?.isEnabled = !allowed
            primary.isEnabled = allowed
        case .models:
            modelBar?.doubleValue = snapshot.modelFraction
            detailLabel?.stringValue = snapshot.modelError ?? snapshot.modelDetail
            actionButton?.title = snapshot.modelsBusy ? "Pause download" : "Resume setup"
            actionButton?.isEnabled = !snapshot.readiness.modelsReady
            primary.isEnabled = snapshot.readiness.modelsReady
        case .shortcut:
            let detected = flow.verifiedShortcut == snapshot.readiness.shortcut
            detailLabel?.stringValue = snapshot.readiness.shortcut == .fn
                ? "Using Fn / Globe: double-tap to start, tap once to finish. Free the key in Keyboard Settings first."
                : "Using \(snapshot.readiness.shortcut.displayName): press once to start, and once to finish. No Fn settings changes are needed."
            shortcutStatus?.stringValue = snapshot.listenerError ?? (detected ? "✓ Shortcut detected. You’re ready to try dictation." : snapshot.readiness.shortcut == .fn ? "Double-tap Fn / Globe now to check it. This test does not record audio." : "Press \(snapshot.readiness.shortcut.displayName) now to check it. This test does not record audio.")
            shortcutStatus?.textColor = detected ? .systemGreen : .secondaryLabelColor
            primary.isEnabled = detected && snapshot.readiness.ready
            for view in page.arrangedSubviews.compactMap({ $0 as? NSButton }) {
                view.isEnabled = snapshot.canChangeShortcut
            }
        case .practice:
            transcript?.string = practiceText
            practiceStatus?.stringValue = snapshot.processing ? "Turning your speech into text on your Mac…" : snapshot.retainedRecording ? "Recognition did not finish. Retry the same recording, or discard it and try again." : practiceMessage.isEmpty ? "Say a sentence such as: “My first dictation is ready.”" : practiceMessage
            practiceButton?.title = snapshot.recording ? "Finish recording" : "Start practice dictation"
            practiceButton?.isEnabled = snapshot.recording || (snapshot.readiness.ready && !snapshot.processing && !snapshot.retainedRecording)
            retryButton?.isHidden = !snapshot.retainedRecording
            discardButton?.isHidden = !snapshot.retainedRecording
            primary.isEnabled = flow.practiceSucceeded && flow.practiceToken == nil && snapshot.readiness.ready && flow.verifiedShortcut == snapshot.readiness.shortcut
        case .complete: primary.isEnabled = snapshot.readiness.ready && flow.practiceSucceeded && flow.verifiedShortcut == snapshot.readiness.shortcut
        }
    }

    private func buildPage() {
        switch flow.step {
        case .welcome:
            heading("Let’s get your Mac ready.", description: "We’ll help you approve access, download the local models, choose a shortcut, and try your first dictation.", symbol: "mic.badge.plus")
            _ = add("Apple Silicon (M1 or newer) · macOS 14+ · English", weight: .medium)
            _ = add("Setup downloads about 3.4 GB once. Keep 8 GB of disk space free; 16 GB of memory is recommended. You can pause the download and continue later.")
            _ = add("Speech is processed on your Mac. Recordings and practice text are not saved to disk.")
        case .microphone, .accessibility, .inputMonitoring:
            let name = flow.step.permission!
            let purpose = flow.step == .microphone ? "Let Local Dictation hear you while you dictate." : flow.step == .accessibility ? "Let Local Dictation place your words into the text box you choose." : "Let Local Dictation recognize your shortcut while you work in other apps."
            heading("Allow \(name).", description: purpose, symbol: flow.step == .microphone ? "mic" : flow.step == .accessibility ? "cursorarrow.and.square.on.square.dashed" : "keyboard")
            if flow.step == .microphone {
                _ = add("1. Click Allow Microphone below.\n2. Choose Allow in the macOS prompt.\n3. If access was previously denied, turn on Local Dictation in Microphone settings.")
            } else {
                _ = add("1. Click the button below to open System Settings.\n2. Turn on Local Dictation in the \(name) list.\n3. Return here. We’ll confirm access automatically.")
                _ = add("If Local Dictation is missing, click + and select the installed Local Dictation.app in Applications. If macOS asks to quit and reopen the app, do so; setup picks up from the remaining approvals.")
            }
            let illustrated = NSBox(); illustrated.boxType = .custom; illustrated.cornerRadius = 12
            illustrated.fillColor = .controlBackgroundColor; illustrated.borderColor = .separatorColor
            illustrated.contentViewMargins = NSSize(width: 16, height: 14)
            let row = NSStackView(views: [label("Local Dictation", weight: .semibold), NSView(), label("Turn on  →  ◉", weight: .medium)])
            row.spacing = 12; illustrated.contentView = row
            page.addArrangedSubview(illustrated)
            illustrated.translatesAutoresizingMaskIntoConstraints = false
            illustrated.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
            illustrated.heightAnchor.constraint(equalToConstant: 65).isActive = true
            _ = add("Illustration of the app entry in System Settings.", size: 11)
            actionButton = button("Allow \(name)…", action: #selector(allowCurrentPermission))
            permissionStatus = add("", size: 13)
        case .models:
            heading("Your Mac is downloading its models.", description: "This is a one-time download. Dictation works offline afterward, and app updates reuse these files.", symbol: "arrow.down.circle")
            let bar = NSProgressIndicator(); bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1
            page.addArrangedSubview(bar); bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
            modelBar = bar
            detailLabel = add("", size: 14, weight: .medium)
            _ = add("Keep your Mac connected to the internet. You can pause and resume without starting over. We verify the files before using them.")
            actionButton = button("Pause download", action: #selector(toggleModels))
        case .shortcut:
            heading("Choose a shortcut. Then test it.", description: "Control-Shift-Space is an easy starting point. Choose another combination if you already use it in other apps.", symbol: "keyboard")
            _ = button("Use Control-Shift-Space (recommended)", action: #selector(useRecommended))
            _ = button("Choose another shortcut…", action: #selector(chooseShortcut))
            _ = button("Use Fn / Globe instead", action: #selector(useFn))
            detailLabel = add("", size: 13)
            _ = button("Open Keyboard Settings…", action: #selector(openKeyboard))
            shortcutStatus = add("", size: 14, weight: .medium)
            _ = button("Recheck shortcut access", action: #selector(retryListener))
        case .practice:
            heading("Try your first dictation.", description: "Use your shortcut or the button below. Speak a short sentence, then finish. Your words will appear here instead of being pasted into another app.", symbol: "text.bubble")
            practiceButton = button("Start practice dictation", action: #selector(togglePractice))
            let meter = NSProgressIndicator(); meter.style = .bar; meter.isIndeterminate = false; meter.minValue = 0; meter.maxValue = 1
            page.addArrangedSubview(meter); meter.translatesAutoresizingMaskIntoConstraints = false
            meter.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
            recordingMeter = meter
            practiceStatus = add("", size: 13)
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            let text = NSTextView(); text.isEditable = false; text.isSelectable = true
            text.font = .systemFont(ofSize: 18); text.textContainerInset = NSSize(width: 14, height: 14)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            text.setAccessibilityLabel("Your practice dictation")
            scroll.documentView = text; page.addArrangedSubview(scroll)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 125).isActive = true
            transcript = text
            retryButton = button("Retry the recording", action: #selector(retryPractice))
            discardButton = button("Discard and try again", action: #selector(discardPractice))
            _ = add("Audio stays in memory. Closing setup clears the practice text; quitting releases any recording waiting for retry.", size: 11)
        case .complete:
            heading("You’re ready to dictate.", description: "Click a text box in your usual app. Start with your shortcut, speak, then use the shortcut again to finish.", symbol: "checkmark.circle.fill")
            _ = add(snapshot.readiness.shortcut == .fn ? "Double-tap Fn / Globe to start. Tap once to finish." : "Press \(snapshot.readiness.shortcut.displayName) to start. Press it again to finish.", size: 18, weight: .medium)
            _ = add("Look for the microphone icon in your Mac’s menu bar. That’s where you’ll find Settings, custom words, and Quit.")
            _ = add("If an editor can’t accept text automatically, your words stay ready to copy or place. Always review your text before using it.")
        }
    }

    @objc private func continueSetup() {
        if flow.step == .complete {
            guard snapshot.readiness.ready, flow.practiceSucceeded,
                  flow.verifiedShortcut == snapshot.readiness.shortcut else { return }
            practiceText = ""; transcript?.string = ""; actions.finished(); window.orderOut(nil); return
        }
        if flow.step == .welcome { actions.startModels() }
        _ = flow.advance(snapshot.readiness); render()
    }
    @objc private func allowCurrentPermission() {
        waitingPermission = flow.step; actions.allowPermission(flow.step); render()
    }
    @objc private func goBack() { waitingPermission = nil; flow.back(); render() }
    @objc private func finishLater() { window.performClose(nil) }
    @objc private func toggleModels() { actions.toggleModels() }
    @objc private func chooseShortcut() { actions.chooseShortcut() }
    @objc private func useRecommended() { actions.useRecommendedShortcut() }
    @objc private func useFn() { actions.useFn() }
    @objc private func openKeyboard() { actions.openKeyboard() }
    @objc private func retryListener() { actions.retryListener() }
    @objc private func togglePractice() { actions.togglePractice() }
    @objc private func retryPractice() { actions.retryPractice() }
    @objc private func discardPractice() { actions.discardPractice() }
}

private final class SetupDocumentView: NSView {
    override var isFlipped: Bool { true }
}
