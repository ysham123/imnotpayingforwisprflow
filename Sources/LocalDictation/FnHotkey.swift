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

    deinit {
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
        return true
    }

    func stop() {
        generation &+= 1
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
    }

    private func process(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        at time: TimeInterval,
        generation expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration, eventTap != nil else { return }
        guard type == .flagsChanged || type == .keyDown else { return }
        let companions: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let action = gesture.handle(type == .flagsChanged ? .flagsChanged : .keyDown,
                                    keyCode: keyCode, functionDown: flags.contains(.maskSecondaryFn),
                                    otherModifiersHeld: !flags.intersection(companions).isEmpty,
                                    at: time)
        if let action { onAction?(action) }
    }

    private func recoverDisabledTap(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration, let eventTap else { return }
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

        // The callback executes on the main run loop, preserving FIFO delivery
        // and allowing generation to invalidate queued events after stop().
        let currentGeneration = MainActor.assumeIsolated { owner.generation }
        DispatchQueue.main.async {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.recoverDisabledTap(generation: currentGeneration)
            } else {
                owner.process(type: type, keyCode: keyCode, flags: flags, at: time,
                              generation: currentGeneration)
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
