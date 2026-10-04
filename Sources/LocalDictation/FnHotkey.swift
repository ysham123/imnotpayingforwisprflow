import AppKit
import CoreGraphics
import DictationCore

/// Observes Fn/Globe gestures without suppressing keyboard events.
@MainActor
final class FnHotkey {
    private var gesture = FnKeyEventMapper(doubleTapInterval: NSEvent.doubleClickInterval)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onAction: ((HotkeyGesture.Action) -> Void)?
    private var generation: UInt64 = 0
    private var pendingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// Physical input only; synthetic paste events must not change target epochs.
    var onInputActivity: (() -> Void)?

    deinit {
        pendingTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
    }

    static var permissionGranted: Bool {
        CGPreflightListenEventAccess()
    }

    var isActive: Bool {
        guard let eventTap, CFMachPortIsValid(eventTap) else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    /// Returns false if macOS denies monitoring or cannot create an event tap.
    @discardableResult
    func start(onAction: @escaping (HotkeyGesture.Action) -> Void) -> Bool {
        stop()
        guard Self.permissionGranted else { return false }
        self.onAction = onAction

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.onAction = nil
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            self.onAction = nil
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateGesture() }
        }
        return true
    }

    func stop() {
        generation &+= 1
        pendingTimer?.invalidate()
        pendingTimer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        onAction = nil
        gesture = FnKeyEventMapper(doubleTapInterval: NSEvent.doubleClickInterval)
    }

    func setPhase(_ phase: HotkeyGesture.Phase) {
        gesture.setPhase(phase, at: ProcessInfo.processInfo.systemUptime)
        schedulePendingAction()
    }

    func invalidateGesture() {
        gesture.invalidate()
        pendingTimer?.invalidate()
        pendingTimer = nil
    }

    private func schedulePendingAction() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        guard let deadline = gesture.pendingActionDeadline else { return }
        let expectedGeneration = generation
        let timer = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime),
                          repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == expectedGeneration else { return }
                self.pendingTimer = nil
                // An event-tap callback queues its work on the main actor. A
                // boundary-time second press can precede that queued callback;
                // never place while Fn or another shortcut modifier is held.
                let held = CGEventSource.flagsState(.combinedSessionState)
                let modifiers: CGEventFlags = [.maskSecondaryFn, .maskCommand, .maskControl, .maskAlternate, .maskShift]
                if !held.intersection(modifiers).isEmpty {
                    self.invalidateGesture()
                    return
                }
                if let action = self.gesture.advance(at: ProcessInfo.processInfo.systemUptime) {
                    self.onAction?(action)
                }
                self.schedulePendingAction()
            }
        }
        pendingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func process(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        at time: TimeInterval,
        isPhysical: Bool,
        generation expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration, eventTap != nil else { return }
        guard type == .flagsChanged || type == .keyDown else {
            if isPhysical {
                invalidateGesture()
                onInputActivity?()
            }
            return
        }
        let interruptionsBefore = gesture.interruptionCount
        let companions: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let action = gesture.handle(type == .flagsChanged ? .flagsChanged : .keyDown,
                                    keyCode: keyCode, functionDown: flags.contains(.maskSecondaryFn),
                                    otherModifiersHeld: !flags.intersection(companions).isEmpty,
                                    at: time, isPhysical: isPhysical)
        if isPhysical, gesture.interruptionCount != interruptionsBefore { onInputActivity?() }
        if let action { onAction?(action) }
        schedulePendingAction()
    }

    private func recoverDisabledTap(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration, let eventTap else { return }
        invalidateGesture()
        onInputActivity?()
        // Missing a key-up while disabled must not leave a partial gesture.
        let phase = gesture.phase
        gesture = FnKeyEventMapper(doubleTapInterval: NSEvent.doubleClickInterval)
        gesture.setPhase(phase, at: ProcessInfo.processInfo.systemUptime)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    // The run-loop source is installed only on the main run loop. The C callback
    // reads event fields and queues work; it never records or transcribes audio.
    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<FnHotkey>.fromOpaque(userInfo).takeUnretainedValue()
        let time = Double(event.timestamp) / 1_000_000_000
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isPhysical = event.getIntegerValueField(.eventSourceUnixProcessID) == 0

        // The callback executes on the main run loop, preserving FIFO delivery
        // and allowing generation to invalidate queued events after stop().
        let currentGeneration = MainActor.assumeIsolated { owner.generation }
        DispatchQueue.main.async {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.recoverDisabledTap(generation: currentGeneration)
            } else {
                owner.process(type: type, keyCode: keyCode, flags: flags, at: time,
                              isPhysical: isPhysical, generation: currentGeneration)
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
