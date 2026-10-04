import AppKit
import CoreGraphics
import DictationCore
import Carbon

enum ShortcutRegistrationError: LocalizedError, Equatable {
    case invalid(String)
    case inUse(String)
    case unavailable(Int32)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .inUse(let name): return "\(name) is already registered by another app. Choose another shortcut."
        case .unavailable(let code): return "The shortcut could not be registered (macOS error \(code)). Choose another shortcut."
        }
    }
}

/// Fn is observed passively. Custom shortcuts use exclusive Carbon registration
/// to consume only the assigned chord and report registration conflicts.
@MainActor
final class FnHotkey {
    private var gesture = FnKeyEventMapper(doubleTapInterval: NSEvent.doubleClickInterval)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onAction: ((HotkeyGesture.Action) -> Void)?
    private var generation: UInt64 = 0
    private var pendingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var customGesture = CustomHotkeyGesture()
    private var customInput: CustomHotkeyInputFilter?
    private var carbonHandler: EventHandlerRef?
    private var carbonHotkey: EventHotKeyRef?
    private var carbonID: UInt32 = 0
    private var nextCarbonID: UInt32 = 0
    private var carbonReleasePending = false
    private var awaitingArmRelease = false
    private var carbonAcceptEventsAfter: TimeInterval = 0
    private static let signature: OSType = 0x4C444354 // LDCT
    private(set) var configuration: ShortcutConfiguration = .fn
    private(set) var lastRegistrationError: ShortcutRegistrationError?
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
        if let carbonHotkey { UnregisterEventHotKey(carbonHotkey) }
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
    }

    static var permissionGranted: Bool {
        CGPreflightListenEventAccess()
    }

    var isActive: Bool {
        guard let eventTap, CFMachPortIsValid(eventTap) else { return false }
        if case .custom = configuration, carbonHotkey == nil { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    /// Register before removing the old binding, so a conflict leaves a working
    /// shortcut untouched. A stopped listener can reserve a chord before start.
    @discardableResult
    func configure(_ proposed: ShortcutConfiguration) -> Result<Void, ShortcutRegistrationError> {
        if let message = proposed.validationError {
            let error = ShortcutRegistrationError.invalid(message)
            lastRegistrationError = error
            return .failure(error)
        }
        if proposed.hasSameBinding(as: configuration), proposed == .fn || carbonHotkey != nil {
            configuration = proposed
            lastRegistrationError = nil
            return .success(())
        }
        var candidate: EventHotKeyRef?
        var candidateID: UInt32 = 0
        if case let .custom(keyCode, modifiers, _) = proposed {
            let handlerStatus = installCarbonHandler()
            guard handlerStatus == noErr else {
                let error = ShortcutRegistrationError.unavailable(handlerStatus)
                lastRegistrationError = error
                return .failure(error)
            }
            nextCarbonID &+= 1
            candidateID = nextCarbonID
            let status = RegisterEventHotKey(keyCode, modifiers,
                EventHotKeyID(signature: Self.signature, id: candidateID),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &candidate)
            guard status == noErr, candidate != nil else {
                if let candidate { UnregisterEventHotKey(candidate) }
                if carbonHotkey == nil { removeCarbonHandler() }
                let error: ShortcutRegistrationError = status == eventHotKeyExistsErr
                    ? .inUse(proposed.displayName) : .unavailable(status)
                lastRegistrationError = error
                return .failure(error)
            }
        }
        let phase = gesture.phase
        unregisterCarbonHotkey()
        carbonHotkey = candidate
        carbonID = candidateID
        configuration = proposed
        carbonAcceptEventsAfter = ProcessInfo.processInfo.systemUptime
        gesture = FnKeyEventMapper(doubleTapInterval: NSEvent.doubleClickInterval)
        gesture.setPhase(phase, at: ProcessInfo.processInfo.systemUptime)
        customGesture = CustomHotkeyGesture()
        customGesture.setPhase(phase, at: ProcessInfo.processInfo.systemUptime)
        if case let .custom(keyCode, modifiers, _) = proposed {
            customInput = CustomHotkeyInputFilter(keyCode: keyCode, modifiers: modifiers)
        } else {
            customInput = nil
            removeCarbonHandler()
        }
        invalidateGesture()
        suppressCurrentlyHeldShortcut()
        lastRegistrationError = nil
        return .success(())
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    /// Returns false if macOS denies monitoring or cannot create an event tap.
    @discardableResult
    func start(onAction: @escaping (HotkeyGesture.Action) -> Void) -> Bool {
        stopMonitoring()
        guard Self.permissionGranted else {
            unregisterCarbonHotkey(); removeCarbonHandler()
            return false
        }
        if case .failure = configure(configuration) { return false }
        suppressCurrentlyHeldShortcut()
        self.onAction = onAction

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
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
            unregisterCarbonHotkey(); removeCarbonHandler()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            self.onAction = nil
            unregisterCarbonHotkey(); removeCarbonHandler()
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
        stopMonitoring()
        unregisterCarbonHotkey()
        removeCarbonHandler()
    }

    private func stopMonitoring() {
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
        customGesture = CustomHotkeyGesture()
        carbonReleasePending = false
        awaitingArmRelease = false
        carbonAcceptEventsAfter = ProcessInfo.processInfo.systemUptime
        if case let .custom(keyCode, modifiers, _) = configuration {
            customInput = CustomHotkeyInputFilter(keyCode: keyCode, modifiers: modifiers)
        }
    }

    func setPhase(_ phase: HotkeyGesture.Phase) {
        gesture.setPhase(phase, at: ProcessInfo.processInfo.systemUptime)
        customGesture.setPhase(phase, at: ProcessInfo.processInfo.systemUptime)
        schedulePendingAction()
    }

    func invalidateGesture() {
        gesture.invalidate()
        customGesture.invalidate()
        pendingTimer?.invalidate()
        pendingTimer = nil
    }

    private func schedulePendingAction() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        guard configuration == .fn else { return }
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
        if case let .custom(code, _, _) = configuration {
            let kind: CustomHotkeyInputFilter.EventKind
            switch type {
            case .keyDown: kind = .keyDown
            case .keyUp: kind = .keyUp
            case .flagsChanged: kind = .flagsChanged
            default: kind = .pointer
            }
            if customInput?.interrupts(kind, keyCode: UInt32(clamping: keyCode),
                                       modifiers: Self.carbonModifiers(flags), isPhysical: isPhysical) == true {
                invalidateGesture()
                onInputActivity?()
            }
            if isPhysical, type == .keyUp, keyCode == Int64(code), carbonReleasePending || awaitingArmRelease {
                finishCustomRelease(at: time)
            }
            return
        }
        // Fn mapper historically sees keyDown/modifier events only.
        guard type != .keyUp else { return }
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
        customGesture = CustomHotkeyGesture()
        customGesture.setPhase(phase, at: ProcessInfo.processInfo.systemUptime)
        carbonReleasePending = false
        awaitingArmRelease = false
        carbonAcceptEventsAfter = ProcessInfo.processInfo.systemUptime
        suppressCurrentlyHeldShortcut()
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskCommand) { result |= ShortcutConfiguration.command }
        if flags.contains(.maskShift) { result |= ShortcutConfiguration.shift }
        if flags.contains(.maskAlternate) { result |= ShortcutConfiguration.option }
        if flags.contains(.maskControl) { result |= ShortcutConfiguration.control }
        return result
    }

    private func installCarbonHandler() -> OSStatus {
        guard carbonHandler == nil else { return noErr }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        return InstallEventHandler(GetApplicationEventTarget(), Self.carbonCallback, events.count,
                                   &events, Unmanaged.passUnretained(self).toOpaque(), &carbonHandler)
    }

    private func unregisterCarbonHotkey() {
        if let carbonHotkey { UnregisterEventHotKey(carbonHotkey) }
        carbonHotkey = nil
        carbonID = 0
        carbonReleasePending = false
    }

    private func removeCarbonHandler() {
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        carbonHandler = nil
    }

    private func handleCarbon(_ event: EventRef) -> OSStatus {
        let kind = GetEventKind(event)
        guard kind == UInt32(kEventHotKeyPressed) || kind == UInt32(kEventHotKeyReleased) else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == Self.signature, identifier.id == carbonID,
              carbonHotkey != nil, case let .custom(keyCode, _, _) = configuration else { return OSStatus(eventNotHandledErr) }
        guard isActive else { return noErr }
        let time = GetEventTime(event)
        guard time >= carbonAcceptEventsAfter else { return noErr }
        if kind == UInt32(kEventHotKeyPressed) {
            customGesture.press(at: time)
        } else {
            carbonReleasePending = true
            // Carbon may release as soon as a modifier is released. Wait for
            // the primary physical key too, so modifier repress/autorepeat
            // cannot turn one held shortcut into multiple dictations.
            if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) {
                finishCustomRelease(at: time)
            }
        }
        return noErr
    }

    private func finishCustomRelease(at time: TimeInterval) {
        carbonReleasePending = false
        awaitingArmRelease = false
        if let action = customGesture.release(at: time) { onAction?(action) }
    }

    private func suppressCurrentlyHeldShortcut() {
        guard case let .custom(keyCode, _, _) = configuration,
              CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) else { return }
        awaitingArmRelease = true
        customGesture.suppressUntilRelease()
    }

    private static let carbonCallback: EventHandlerUPP = { _, event, userInfo in
        guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<FnHotkey>.fromOpaque(userInfo).takeUnretainedValue()
        return MainActor.assumeIsolated { owner.handleCarbon(event) }
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
