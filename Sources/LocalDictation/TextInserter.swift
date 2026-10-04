import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Delivers text only to a verified destination. Full AX reads run on the
/// inspector's serial queue; clipboard transactions remain on the main actor.
@MainActor
final class TextInserter {
    struct Target: @unchecked Sendable {
        let processIdentifier: pid_t
        let focusedElement: AXUIElement?
        let focusedLeaf: AXUIElement?
        let role: String
        let selection: CFRange?
        let selectionMarker: CFTypeRef?
        let selectedText: String?
        let value: String?
        let rangeText: String?
        let webEditor: Bool
        var captureEpoch: UInt64? = nil
        var captureOwner: UUID? = nil
        var canInsertAutomatically: Bool { focusedElement != nil }
    }

    /// Contains identities and cursor evidence, never a field's text. An anchor
    /// cannot be adopted by another inserter or silently rebound to another leaf.
    struct Anchor: @unchecked Sendable {
        let processIdentifier: pid_t
        let focusedLeaf: AXUIElement
        let cursorElement: AXUIElement
        let selection: CFRange?
        let selectionMarker: CFTypeRef?
        let epoch: UInt64
        let owner: UUID
    }

    enum InsertionResult { case verified, sentWithoutVerification }

    private static let markerType = NSPasteboard.PasteboardType("org.localdictation.paste-session")
    private static let deliveries = DeliveryCoordinator()
    private let inspector = TargetInspector()
    private let owner = UUID()
    private var captureEpoch: UInt64 = 0
    private var activationObserver: NSObjectProtocol?
    private var focusObserver: AXObserver?
    private var focusObserverPID: pid_t?
    var onFocusChanged: (() -> Void)?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.invalidateCapture()
                self.onFocusChanged?()
                self.primeFrontmostAccessibility()
            }
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let focusObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes) }
    }

    var hasPendingPaste: Bool { Self.deliveries.hasPendingDelivery }
    func waitForPendingPaste() async { await Self.deliveries.waitUntilFinished() }

    static func accessibilityGranted() -> Bool { AXIsProcessTrusted() }
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Hook physical mouse/key/scroll activity here. No typed characters are
    /// collected. An away-and-return interaction stays invalid for this origin.
    func invalidateCapture() { captureEpoch &+= 1 }

    func primeFrontmostAccessibility() {
        guard Self.accessibilityGranted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        installFocusObserver(for: app.processIdentifier)
        inspector.prime(app)
    }

    private func installFocusObserver(for pid: pid_t) {
        guard focusObserverPID != pid else { return }
        if let focusObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes) }
        focusObserver = nil; focusObserverPID = nil
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.focusCallback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.02)
        guard AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        focusObserver = observer; focusObserverPID = pid
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private static let focusCallback: AXObserverCallback = { _, _, _, info in
        guard let info else { return }
        let owner = Unmanaged<TextInserter>.fromOpaque(info).takeUnretainedValue()
        DispatchQueue.main.async {
            owner.invalidateCapture()
            owner.onFocusChanged?()
        }
    }

    /// Call after starting the microphone. This is a bounded identity-only
    /// snapshot; no text reads or Chromium enablement waits. A remote focused
    /// leaf may use a bounded identity-only window-containment check.
    func beginCapture(expectedProcessIdentifier: pid_t? = nil) -> Anchor? {
        guard Self.accessibilityGranted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              expectedProcessIdentifier == nil || app.processIdentifier == expectedProcessIdentifier else { return nil }
        let epoch = captureEpoch
        let context = AXInspection(budget: 0.1, timeout: 0.025)
        guard let leaf = context.anchorLeaf(in: app.processIdentifier), !context.isSecure(leaf) else { return nil }
        var cursorElement = leaf
        var range = context.selection(of: leaf)
        if range == nil, let editor = context.elementAttribute("AXEditableAncestor", of: leaf)
            ?? context.elementAttribute("AXHighestEditableAncestor", of: leaf) {
            cursorElement = editor
            range = context.selection(of: editor)
        }
        let marker = range == nil ? context.attribute("AXSelectedTextMarkerRange", of: cursorElement) : nil
        let stableMarker = marker.map { expected in
            context.attribute("AXSelectedTextMarkerRange", of: cursorElement).map { CFEqual(expected, $0) } ?? false
        } ?? false
        guard !context.inspectionFailed, range != nil || stableMarker, epoch == captureEpoch,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        return Anchor(processIdentifier: app.processIdentifier, focusedLeaf: leaf, cursorElement: cursorElement,
                      selection: range, selectionMarker: marker, epoch: epoch, owner: owner)
    }

    func inspect(_ anchor: Anchor) async throws -> Target {
        try checkOrigin(anchor)
        var target = try await inspector.inspect(anchor)
        try checkOrigin(anchor)
        target.captureEpoch = anchor.epoch; target.captureOwner = owner
        try finalIdentityCheck(target)
        return target
    }

    private func checkOrigin(_ anchor: Anchor) throws {
        try Task.checkCancellation()
        guard anchor.owner == owner, anchor.epoch == captureEpoch,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.processIdentifier
        else { throw InsertionError.targetChanged }
    }

    /// Compatibility path for fixtures and explicit placement. Full capture is
    /// synchronous here; the recording path uses beginCapture/inspect instead.
    func captureTarget(expectedProcessIdentifier: pid_t? = nil) throws -> Target {
        guard Self.accessibilityGranted() else { throw InsertionError.accessibilityRequired }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              expectedProcessIdentifier == nil || app.processIdentifier == expectedProcessIdentifier
        else { throw InsertionError.chooseTextField }
        let target = try inspector.captureSynchronously(app)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        else { throw InsertionError.targetChanged }
        return target
    }

    private func validate(_ target: Target) async throws {
        try checkTargetOrigin(target)
        try await inspector.validate(target)
        try checkTargetOrigin(target)
    }

    private func checkTargetOrigin(_ target: Target) throws {
        try Task.checkCancellation()
        guard Self.accessibilityGranted() else { throw InsertionError.accessibilityRequired }
        guard target.canInsertAutomatically else { throw InsertionError.unverifiedTarget }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              target.captureOwner == nil || target.captureOwner == owner,
              target.captureEpoch == nil || target.captureEpoch == captureEpoch
        else { throw InsertionError.targetChanged }
    }

    private func finalIdentityCheck(_ target: Target) throws {
        try checkTargetOrigin(target)
        let context = AXInspection(budget: 0.1, timeout: 0.025)
        try context.confirmIdentity(target)
        try checkTargetOrigin(target)
    }

    @discardableResult
    func insert(text: String, into target: Target,
                onDispatched: (@MainActor () -> Void)? = nil,
                onVerified: (@MainActor () -> Void)? = nil) async throws -> InsertionResult {
        guard !text.isEmpty else { return .verified }
        try await Self.deliveries.acquire()
        defer { Self.deliveries.release() }
        try await validate(target)
        try await waitForReleasedModifiers()
        try await validate(target)
        try Task.checkCancellation()

        let pasteboard = NSPasteboard.general
        let previous = Self.snapshot(pasteboard)
        let token = UUID().uuidString.data(using: .utf8)!
        let item = NSPasteboardItem()
        item.setString(text, forType: .string); item.setData(token, forType: Self.markerType)
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        guard pasteboard.writeObjects([item]) else {
            Self.restore(previous, to: pasteboard); throw InsertionError.clipboardUnavailable
        }
        let ourChangeCount = pasteboard.changeCount
        do {
            try await validate(target)
            // Only bounded identity/caret checks remain on the main actor. No
            // await occurs between this final check and posting the shortcut.
            try finalIdentityCheck(target)
            guard Self.modifiersReleased else { throw InsertionError.modifiersHeld }
            guard pasteboard.changeCount == ourChangeCount, pasteboard.data(forType: Self.markerType) == token
            else { throw InsertionError.clipboardChanged }
            try Self.paste()
        } catch {
            Self.restoreIfOwned(previous, pasteboard: pasteboard, changeCount: ourChangeCount, token: token)
            throw error
        }
        onDispatched?()
        let result = await observeInsertion(text: text, into: target, onVerified: onVerified)
        Self.restoreIfOwned(previous, pasteboard: pasteboard, changeCount: ourChangeCount, token: token)
        return result
    }

    @discardableResult
    func copyForRecovery(text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        return pasteboard.setString(text, forType: .string)
    }

    private static func wait(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { continuation.resume() }
        }
    }

    private func observeInsertion(text: String, into target: Target,
                                  onVerified: (@MainActor () -> Void)?) async -> InsertionResult {
        let start = ProcessInfo.processInfo.systemUptime, minimumReadWindow = start + 1, deadline = start + 2.5
        var verified = false
        repeat {
            if !verified {
                let observation = await inspector.observe(target, until: deadline)
                if !observation.failed {
                    verified = Self.matchesInsertion(original: target.rangeText, current: observation.rangeText,
                        selection: target.selection, caret: observation.caret, text: text)
                        || Self.matchesInsertion(original: target.value, current: observation.value,
                        selection: target.selection, caret: observation.caret, text: text)
                    if verified { onVerified?() }
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= minimumReadWindow && (verified || now >= deadline) { break }
            // Cancellation after dispatch cannot shorten the receiver's window.
            await Self.wait(milliseconds: 80)
        } while true
        return verified ? .verified : .sentWithoutVerification
    }

    private func waitForReleasedModifiers() async throws {
        let deadline = Date().addingTimeInterval(2)
        while !Self.modifiersReleased {
            guard Date() < deadline else { throw InsertionError.modifiersHeld }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private typealias ClipboardSnapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static var modifiersReleased: Bool {
        let held = CGEventSource.flagsState(.combinedSessionState)
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate,
                                       .maskShift, .maskSecondaryFn]
        return held.intersection(modifiers).isEmpty
    }

    private static func matchesInsertion(original: String?, current: String?, selection: CFRange?,
                                         caret: CFRange?, text: String) -> Bool {
        guard let original, let current, let selection,
              selection.location >= 0, selection.length >= 0,
              selection.location <= (original as NSString).length,
              selection.length <= (original as NSString).length - selection.location
        else { return false }
        let expected = (original as NSString).replacingCharacters(
            in: NSRange(location: selection.location, length: selection.length), with: text)
        guard current == expected else { return false }
        if expected != original { return true }
        // Replacing a selection with the same text still needs caret evidence.
        return caret?.length == 0 && caret?.location == selection.location + (text as NSString).length
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            // Read promised data now, before replacing the owning pasteboard.
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restoreIfOwned(_ previous: ClipboardSnapshot,
                                       pasteboard: NSPasteboard, changeCount: Int, token: Data) {
        guard pasteboard.changeCount == changeCount,
              pasteboard.data(forType: markerType) == token else { return }
        restore(previous, to: pasteboard)
    }

    private static func restore(_ previous: ClipboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = previous.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private static func paste() throws {
        let key = pasteKeyCode()
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { throw InsertionError.eventUnavailable }
        down.flags = .maskCommand
        // Release the synthesized modifier with the key-up. Leaving Command
        // on both events can keep combinedSessionState latched until a real
        // keyboard event arrives, blocking the next insertion.
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func pasteKeyCode() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return 9 }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return 9 }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for key in UInt16(0)..<UInt16(128) {
            var state: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 8)
            var length = 0
            let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown),
                                        UInt32(cmdKey >> 8), UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &state,
                                        characters.count, &length, &characters)
            if status == noErr, String(utf16CodeUnits: characters, count: length).lowercased() == "v" {
                return CGKeyCode(key)
            }
        }
        return 9
    }

    enum InsertionError: LocalizedError {
        case accessibilityRequired
        case chooseTextField
        case secureField
        case unverifiedTarget
        case pasteInProgress
        case clipboardChanged
        case targetChanged
        case modifiersHeld
        case clipboardUnavailable
        case eventUnavailable

        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: return "Accessibility permission is needed to paste dictation."
            case .chooseTextField: return "Click a text box in another app first."
            case .secureField: return "Dictation is unavailable in password fields."
            case .unverifiedTarget: return "This app did not expose its text box. Use Copy last result."
            case .pasteInProgress: return "The previous paste is finishing. Use Copy last result."
            case .clipboardChanged: return "The clipboard changed before pasting. Use Copy last result."
            case .targetChanged: return "The text field or cursor changed. Your dictation is available to copy."
            case .modifiersHeld: return "Release the keyboard modifiers to paste. Your dictation is available to copy."
            case .clipboardUnavailable: return "Could not place the dictation on the clipboard."
            case .eventUnavailable: return "Could not send the paste shortcut. Your dictation is available to copy."
            }
        }
    }
}
