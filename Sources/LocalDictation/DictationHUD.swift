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
            case .starting: return "Starting"
            case .listening: return "Listening"
            case .transcribing: return "Transcribing"
            case .correcting: return "Correcting"
            case .inserting: return "Placing text"
            case .ready: return "Text ready"
            case .inserted: return "Inserted"
            case .pasteSent: return "Paste sent"
            case .error: return "Needs attention"
            }
        }

        var detail: String {
            switch self {
            case .starting: return "Getting your microphone ready"
            case .listening: return "Tap Fn to finish"
            case .transcribing, .correcting: return "On your Mac"
            case .inserting: return "Checking your text box"
            case .ready: return "Click a text box · tap Fn"
            case .inserted: return ""
            case .pasteSent: return "Check your text box"
            case .error: return "Open the microphone menu for details"
            }
        }

        var symbol: String {
            switch self {
            case .starting, .listening: return "mic.fill"
            case .transcribing: return "text.bubble"
            case .correcting: return "sparkle"
            case .inserting: return "cursorarrow"
            case .ready: return "text.alignleft"
            case .inserted: return "checkmark"
            case .pasteSent: return "arrow.up.right"
            case .error: return "exclamationmark.circle"
            }
        }
    }

    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDiscard: (() -> Void)?
    var finishInstruction = "Tap Fn to finish"
    var placementInstruction = "Click a text box · tap Fn"

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
    private var actionsWidth: NSLayoutConstraint!

    init(announce: ((String) -> Void)? = nil) {
        self.announce = announce ?? { message in
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        panel = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 268, height: 48),
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

        let content = CapsuleSurface()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.setAccessibilityRole(.group)
        content.setAccessibilityLabel("Local Dictation")
        panel.contentView = content

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        let graphic = NSView()
        graphic.translatesAutoresizingMaskIntoConstraints = false
        symbol.translatesAutoresizingMaskIntoConstraints = false
        meter.translatesAutoresizingMaskIntoConstraints = false
        symbol.contentTintColor = .labelColor
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
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
            graphic.widthAnchor.constraint(equalToConstant: 20),
            graphic.heightAnchor.constraint(equalToConstant: 20)
        ])

        let buttons = NSStackView(views: [cancelButton, copyButton, discardButton])
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isCloseAction = true
        discardButton.isQuietAction = true
        for button in [cancelButton, copyButton, discardButton] {
            button.target = self
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.refusesFirstResponder = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.toolTip = button.title
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

        content.addSubview(graphic)
        content.addSubview(labels)
        content.addSubview(buttons)
        actionsWidth = buttons.widthAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            graphic.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            graphic.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: graphic.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 6),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            actionsWidth
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
        let defaultDetail = state == .listening ? finishInstruction
            : (state == .ready ? placementInstruction : state.detail)
        var guidance = message ?? defaultDetail
        // The menu includes its state in the same string; the capsule already
        // has a dedicated title, so avoid repeating it in the smaller subtitle.
        let prefix = state.title + " · "
        if guidance.hasPrefix(prefix) { guidance.removeFirst(prefix.count) }
        if state == .ready, guidance.lowercased() == "click a text box, then tap fn once" {
            guidance = state.detail
        }
        detail.stringValue = guidance
        detail.isHidden = guidance.isEmpty
        symbol.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)
        symbol.contentTintColor = state == .inserted ? .systemGreen : (state == .error ? .systemOrange : .labelColor)
        symbol.isHidden = state == .listening
        meter.isHidden = state != .listening
        if state != .listening { meter.level = 0 }
        cancelButton.isHidden = ![.starting, .listening, .transcribing, .correcting, .inserting].contains(state)
        copyButton.isHidden = ![.ready, .pasteSent].contains(state)
        discardButton.isHidden = state != .ready
        let visibleButtons = [cancelButton, copyButton, discardButton].filter { !$0.isHidden }
        actionsWidth.constant = visibleButtons.reduce(0) { $0 + $1.intrinsicContentSize.width }
            + CGFloat(max(0, visibleButtons.count - 1)) * 8
        let size: NSSize
        switch state {
        case .ready: size = NSSize(width: 392, height: 56)
        case .inserted: size = guidance.isEmpty ? NSSize(width: 168, height: 44) : NSSize(width: 324, height: 56)
        case .pasteSent: size = NSSize(width: message == nil ? 276 : 372, height: message == nil ? 52 : 56)
        case .error: size = NSSize(width: 380, height: 56)
        default: size = NSSize(width: 268, height: 48)
        }
        panel.setContentSize(size)
        positionPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        if previousState != state || previousDetail != detail.stringValue {
            announce(guidance.isEmpty ? state.title : "\(state.title). \(guidance)")
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
        let width = min(panel.frame.width, max(160, visible.width - 32))
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 24,
                              width: width, height: panel.frame.height), display: panel.isVisible)
    }

    @objc private func cancel() { onCancel?() }
    @objc private func copy() { onCopy?() }
    @objc private func discard() { onDiscard?() }
}

private final class CapsuleSurface: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .circular
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        // Layer clipping alone leaves the behind-window material rectangular.
        // Mask the material itself so its backdrop and window shadow follow the
        // capsule too. The drawing image stays sharp at either display scale.
        if bounds.width > 0, bounds.height > 0, maskImage?.size != bounds.size {
            maskImage = NSImage(size: bounds.size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                             yRadius: rect.height / 2).fill()
                return true
            }
        }
        refreshEdge()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshEdge()
    }

    private func refreshEdge() {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.borderWidth = highContrast ? 1 : 0.5
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(highContrast ? 0.35 : 0.10).cgColor
    }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PassiveButton: NSButton {
    var isCloseAction = false
    var isQuietAction = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override var intrinsicContentSize: NSSize {
        if isCloseAction { return NSSize(width: 24, height: 24) }
        let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 12)])
        return NSSize(width: ceil(text.size().width) + 18, height: 26)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        // Standard inline buttons dim their text when the app is inactive. This
        // panel intentionally never activates, so draw an explicitly available
        // action while preserving NSButton's native hit testing and AX behavior.
        let highlighted = cell?.isHighlighted == true
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if !isQuietAction || highlighted {
            NSColor.labelColor.withAlphaComponent(highlighted ? 0.16 : (isCloseAction ? 0.055 : 0.08)).setFill()
            shape.fill()
        }
        if isCloseAction {
            NSColor.secondaryLabelColor.setStroke()
            let mark = NSBezierPath()
            mark.lineWidth = 1.25
            mark.lineCapStyle = .round
            mark.move(to: NSPoint(x: bounds.midX - 3, y: bounds.midY - 3))
            mark.line(to: NSPoint(x: bounds.midX + 3, y: bounds.midY + 3))
            mark.move(to: NSPoint(x: bounds.midX - 3, y: bounds.midY + 3))
            mark.line(to: NSPoint(x: bounds.midX + 3, y: bounds.midY - 3))
            mark.stroke()
            return
        }
        if !isQuietAction {
            NSColor.labelColor.withAlphaComponent(0.12).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isEnabled ? (isQuietAction ? NSColor.secondaryLabelColor : NSColor.labelColor) : NSColor.tertiaryLabelColor
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
        NSColor.systemTeal.setFill()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // A fixed-size dot indicates activity without moving bars.
            (level > 0.008 ? NSColor.systemTeal : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
            return
        }
        let normalized = max(0, min(1, (20 * log10(max(CGFloat(level), 0.0001)) + 55) / 45))
        for index in 0..<5 {
            let emphasis = CGFloat([0.55, 0.8, 1, 0.8, 0.55][index])
            let height = 3 + 13 * normalized * emphasis
            let rect = NSRect(x: CGFloat(index) * 4, y: bounds.midY - height / 2, width: 2.2, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
