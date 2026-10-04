import AppKit

/// A status surface, never an editor: ordering or clicking it must not activate
/// this app, take the key window, or move another application's insertion point.
@MainActor
final class DictationHUD {
    enum State: Equatable {
        case starting, listening, transcribing, correcting, inserting
        case ready, inserted, pasteSent, error

        var title: String {
            switch self {
            case .starting: return "Starting microphone"
            case .listening: return "Listening"
            case .transcribing: return "Transcribing"
            case .correcting: return "Correcting"
            case .inserting: return "Placing text"
            case .ready: return "Text ready"
            case .inserted: return "Inserted"
            case .pasteSent: return "Paste sent"
            case .error: return "Dictation needs attention"
            }
        }

        var detail: String {
            switch self {
            case .starting: return "Your microphone is starting."
            case .listening: return "Tap Fn to finish."
            case .transcribing: return "Turning your speech into text."
            case .correcting: return "Cleaning up your words locally."
            case .inserting: return "Checking the text box."
            case .ready: return "Click a text box, then tap Fn once."
            case .inserted: return "Ready for your next dictation."
            case .pasteSent: return "Check the text box. A copy is available."
            case .error: return "Open the microphone menu for details."
            }
        }

        var symbol: String {
            switch self {
            case .starting, .listening: return "mic.fill"
            case .transcribing: return "text.bubble"
            case .correcting: return "text.badge.checkmark"
            case .inserting: return "cursorarrow"
            case .ready: return "text.cursor"
            case .inserted: return "checkmark.circle.fill"
            case .pasteSent: return "arrow.up.right.circle"
            case .error: return "exclamationmark.circle"
            }
        }
    }

    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDiscard: (() -> Void)?

    private(set) var panel: NSPanel
    private(set) var state: State?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let symbol = NSImageView()
    private let meter = AudioLevelView()
    private let cancelButton = PassiveButton(title: "Cancel", target: nil, action: nil)
    private let copyButton = PassiveButton(title: "Copy", target: nil, action: nil)
    private let discardButton = PassiveButton(title: "Discard", target: nil, action: nil)
    private var displayID: NSNumber?
    private var screenObserver: NSObjectProtocol?
    private let announce: (String) -> Void

    init(announce: ((String) -> Void)? = nil) {
        self.announce = announce ?? { message in
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        panel = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 78),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.title = "Local Dictation status"
        panel.animationBehavior = .none

        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 20
        content.layer?.masksToBounds = true
        content.setAccessibilityRole(.group)
        content.setAccessibilityLabel("Local Dictation")
        panel.contentView = content

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let graphic = NSView()
        graphic.translatesAutoresizingMaskIntoConstraints = false
        symbol.translatesAutoresizingMaskIntoConstraints = false
        meter.translatesAutoresizingMaskIntoConstraints = false
        symbol.contentTintColor = .controlAccentColor
        symbol.imageScaling = .scaleProportionallyUpOrDown
        graphic.addSubview(symbol)
        graphic.addSubview(meter)
        for view in [symbol, meter] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: graphic.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: graphic.trailingAnchor),
                view.topAnchor.constraint(equalTo: graphic.topAnchor),
                view.bottomAnchor.constraint(equalTo: graphic.bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            graphic.widthAnchor.constraint(equalToConstant: 26),
            graphic.heightAnchor.constraint(equalToConstant: 26)
        ])

        let buttons = NSStackView(views: [cancelButton, copyButton, discardButton])
        buttons.spacing = 6
        for button in [cancelButton, copyButton, discardButton] {
            button.target = self
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.refusesFirstResponder = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        cancelButton.action = #selector(cancel)
        cancelButton.identifier = .init("dictation-cancel")
        cancelButton.setAccessibilityLabel("Cancel dictation")
        copyButton.action = #selector(copy)
        copyButton.identifier = .init("dictation-copy")
        copyButton.setAccessibilityLabel("Copy dictated text")
        discardButton.action = #selector(discard)
        discardButton.identifier = .init("dictation-discard")
        discardButton.setAccessibilityLabel("Discard waiting text")

        let row = NSStackView(views: [graphic, labels, buttons])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.spacing = 13
        row.alignment = .centerY
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Pass a screen only when starting a new session. Further state changes
    /// preserve its display, even if the pointer moves to a different monitor.
    func show(_ state: State, message: String? = nil, on screen: NSScreen? = nil) {
        let previousState = self.state
        let previousDetail = detail.stringValue
        self.state = state
        if let screen { displayID = Self.id(of: screen) }
        if displayID == nil { displayID = Self.id(of: Self.activeScreen) }
        title.stringValue = state.title
        detail.stringValue = message ?? state.detail
        symbol.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)
        symbol.isHidden = state == .listening
        meter.isHidden = state != .listening
        if state != .listening { meter.level = 0 }
        cancelButton.isHidden = ![.starting, .listening, .transcribing, .correcting, .inserting].contains(state)
        copyButton.isHidden = ![.ready, .pasteSent].contains(state)
        discardButton.isHidden = state != .ready
        let width: CGFloat = state == .ready ? 520 : (state == .pasteSent || state == .error ? 430 : 360)
        panel.setContentSize(NSSize(width: width, height: 78))
        positionPanel()
        panel.orderFrontRegardless()
        if previousState != state || previousDetail != detail.stringValue {
            announce("\(state.title). \(detail.stringValue)")
        }
    }

    func updateLevel(_ rms: Float) {
        guard state == .listening else { return }
        meter.level = rms.isFinite ? min(1, max(0, rms)) : 0
    }

    func hide() {
        panel.orderOut(nil)
        state = nil
        meter.level = 0
    }

    /// The screen containing the mouse is a fallback for field-less recording.
    static var activeScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private static func id(of screen: NSScreen?) -> NSNumber? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func positionPanel() {
        guard let screen = NSScreen.screens.first(where: { Self.id(of: $0) == displayID }) ?? Self.activeScreen else { return }
        displayID = Self.id(of: screen)
        let visible = screen.visibleFrame
        let width = min(panel.frame.width, max(240, visible.width - 32))
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 24,
                              width: width, height: panel.frame.height), display: panel.isVisible)
    }

    @objc private func cancel() { onCancel?() }
    @objc private func copy() { onCopy?() }
    @objc private func discard() { onDiscard?() }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PassiveButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override var intrinsicContentSize: NSSize {
        let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 12)])
        return NSSize(width: ceil(text.size().width) + 20, height: 26)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        // Standard inline buttons dim their text when the app is inactive. This
        // panel intentionally never activates, so draw an explicitly available
        // action while preserving NSButton's native hit testing and AX behavior.
        let highlighted = cell?.isHighlighted == true
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(highlighted ? 0.22 : 0.10).setFill()
        shape.fill()
        NSColor.labelColor.withAlphaComponent(0.20).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let text = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

private final class AudioLevelView: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Microphone activity")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityValue() -> Any? { level > 0.008 ? "Sound detected" : "Quiet" }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // A fixed-size dot indicates activity without moving bars.
            (level > 0.008 ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10)).fill()
            return
        }
        let normalized = max(0, min(1, (20 * log10(max(CGFloat(level), 0.0001)) + 55) / 45))
        for index in 0..<5 {
            let emphasis = CGFloat([0.55, 0.8, 1, 0.8, 0.55][index])
            let height = 4 + 20 * normalized * emphasis
            let rect = NSRect(x: CGFloat(index) * 5, y: bounds.midY - height / 2, width: 3, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
