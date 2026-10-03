import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Inserts into the same app and text control where recording began. It never
/// activates a window, sends Return, or replaces text after focus has changed.
@MainActor
final class TextInserter {
    struct Target {
        let processIdentifier: pid_t
        let focusedElement: AXUIElement?
        let role: String
        let selection: CFRange?
        let selectedText: String?
        let value: String?
        var canInsertAutomatically: Bool { focusedElement != nil }
    }

    enum InsertionResult { case verified, sentWithoutVerification }

    private static let markerType = NSPasteboard.PasteboardType("org.localdictation.paste-session")
    private static var preparedApplications: [pid_t: NSRunningApplication] = [:]
    private static var insertionInProgress = false
    private static var inspectionDeadline = TimeInterval.infinity
    private static var inspectionFailed = false
    private static var retryAfter: [pid_t: TimeInterval] = [:]

    init() {
        // A system-wide object sets the default for all AX objects in this
        // process, including subsequently returned focused children.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
    }

    var hasPendingPaste: Bool { Self.insertionInProgress }

    func waitForPendingPaste() async {
        while Self.insertionInProgress {
            // This is used by the termination delegate in a separate task,
            // after canceling inference. Do not cancel the restore window.
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Call on app activation or a permission timer so Electron can expose its
    /// accessibility tree before the user starts dictation. Reads no field text.
    func primeFrontmostAccessibility() {
        guard Self.accessibilityGranted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        Self.prepareAccessibility(in: app)
    }

    func captureTarget() throws -> Target {
        Self.inspectionDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        Self.inspectionFailed = false
        defer { Self.inspectionDeadline = .infinity }
        guard Self.accessibilityGranted() else { throw InsertionError.accessibilityRequired }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw InsertionError.chooseTextField }
        Self.prepareAccessibility(in: app)
        let element = try Self.focusedEditor(in: app.processIdentifier)
        // An opaque control must not prevent speech capture. Preserve the result
        // for Copy rather than guessing which control should receive a paste.
        guard let element, !Self.inspectionFailed else {
            return Target(processIdentifier: app.processIdentifier, focusedElement: nil,
                          role: "unverified", selection: nil, selectedText: nil, value: nil)
        }
        let result = Target(
            processIdentifier: app.processIdentifier,
            focusedElement: element,
            role: Self.stringAttribute(kAXRoleAttribute, of: element) ?? "editable",
            selection: Self.selection(of: element),
            selectedText: Self.stringAttribute(kAXSelectedTextAttribute, of: element),
            value: Self.stringAttribute(kAXValueAttribute, of: element)
        )
        guard !Self.inspectionFailed else {
            return Target(processIdentifier: app.processIdentifier, focusedElement: nil,
                          role: "unverified", selection: nil, selectedText: nil, value: nil)
        }
        return result
    }

    @discardableResult
    func insert(text: String, into target: Target) async throws -> InsertionResult {
        guard !text.isEmpty else { return .verified }
        guard !Self.insertionInProgress else { throw InsertionError.pasteInProgress }
        Self.insertionInProgress = true
        defer { Self.insertionInProgress = false }
        try Task.checkCancellation()
        try validate(target)
        try await waitForReleasedModifiers()
        try validate(target)
        try Task.checkCancellation()

        let pasteboard = NSPasteboard.general
        let previous = Self.snapshot(pasteboard)
        let token = UUID().uuidString.data(using: .utf8)!
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(token, forType: Self.markerType)
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        guard pasteboard.writeObjects([item]) else {
            Self.restore(previous, to: pasteboard)
            throw InsertionError.clipboardUnavailable
        }
        let ourChangeCount = pasteboard.changeCount

        do {
            // No await occurs between the final focus check and the paste.
            try validate(target)
            try Task.checkCancellation()
            guard Self.modifiersReleased else { throw InsertionError.modifiersHeld }
            guard pasteboard.changeCount == ourChangeCount,
                  pasteboard.data(forType: Self.markerType) == token else {
                throw InsertionError.clipboardChanged
            }
            try Self.paste()
        } catch {
            Self.restoreIfOwned(previous, pasteboard: pasteboard,
                                changeCount: ourChangeCount, token: token)
            throw error
        }

        // Receiving applications may read the clipboard after handling the key
        // event. Preserve it for a full second, then restore only our own write.
        // Cancellation after the event still restores the user's clipboard.
        await Self.waitForClipboardReadWindow()
        Self.restoreIfOwned(previous, pasteboard: pasteboard,
                            changeCount: ourChangeCount, token: token)
        guard let element = target.focusedElement else { throw InsertionError.unverifiedTarget }
        if let original = target.value,
           let current = Self.stringAttribute(kAXValueAttribute, of: element) {
            if let selection = target.selection,
               selection.location >= 0, selection.length >= 0,
               selection.location <= (original as NSString).length,
               selection.length <= (original as NSString).length - selection.location {
                let expected = (original as NSString).replacingCharacters(
                    in: NSRange(location: selection.location, length: selection.length), with: text)
                if current == expected {
                    // Identical replacement needs caret evidence: an unchanged
                    // value alone cannot distinguish a successful paste.
                    if expected != original { return .verified }
                    if let actual = Self.selection(of: element),
                       actual.length == 0,
                       actual.location == selection.location + (text as NSString).length {
                        return .verified
                    }
                    return .sentWithoutVerification
                }
            }
            guard current != original else { throw InsertionError.pasteNotAccepted }
        }
        return .sentWithoutVerification
    }

    func copyForRecovery(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
    }

    private static func waitForClipboardReadWindow() async {
        // A canceled parent task must not shorten the receiver's opportunity to
        // read the staged text. A dispatch deadline is independent of Task's
        // cancellation state and does not block the main thread.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                continuation.resume()
            }
        }
    }

    private static func prepareAccessibility(in running: NSRunningApplication) {
        let pid = running.processIdentifier
        if let previous = preparedApplications[pid], !previous.isTerminated { return }
        if let next = retryAfter[pid], ProcessInfo.processInfo.systemUptime < next { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        // Reading AXRole enables basic native accessibility in Chromium shells.
        // Electron and Chromium use different opt-ins. These setters may have
        // an effect even when isAttributeSettable reports unsupported.
        var role: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        if [read, manual, enhanced].contains(.cannotComplete) {
            retryAfter[pid] = ProcessInfo.processInfo.systemUptime + 3
            return
        }
        retryAfter.removeValue(forKey: pid)
        preparedApplications[pid] = running
        preparedApplications = preparedApplications.filter { !$0.value.isTerminated }
    }

    private func validate(_ target: Target) throws {
        Self.inspectionDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        Self.inspectionFailed = false
        defer { Self.inspectionDeadline = .infinity }
        guard Self.accessibilityGranted() else { throw InsertionError.accessibilityRequired }
        guard let expectedElement = target.focusedElement else { throw InsertionError.unverifiedTarget }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let current = try Self.focusedEditor(in: target.processIdentifier),
              CFEqual(current, expectedElement),
              Self.isEditable(current)
        else { throw InsertionError.targetChanged }
        if let expected = target.selection {
            guard let actual = Self.selection(of: current),
                  actual.location == expected.location, actual.length == expected.length
            else { throw InsertionError.targetChanged }
        }
        if let expected = target.selectedText,
           Self.stringAttribute(kAXSelectedTextAttribute, of: current) != expected {
            throw InsertionError.targetChanged
        }
        if let expected = target.value,
           Self.stringAttribute(kAXValueAttribute, of: current) != expected {
            throw InsertionError.targetChanged
        }
        guard !Self.inspectionFailed else { throw InsertionError.unverifiedTarget }
    }

    private func waitForReleasedModifiers() async throws {
        let deadline = Date().addingTimeInterval(2)
        while !Self.modifiersReleased {
            guard Date() < deadline else { throw InsertionError.modifiersHeld }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static var modifiersReleased: Bool {
        let held = CGEventSource.flagsState(.combinedSessionState)
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate,
                                       .maskShift, .maskSecondaryFn]
        return held.intersection(modifiers).isEmpty
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func belongs(_ element: AXUIElement, to pid: pid_t) -> Bool {
        var actual: pid_t = 0
        return AXUIElementGetPid(element, &actual) == .success && actual == pid
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXRoleAttribute, of: element) == "AXSecureTextField"
            || stringAttribute(kAXSubroleAttribute, of: element) == kAXSecureTextFieldSubrole
            || boolAttribute("AXProtected", of: element) == true
    }

    private static func focusedEditor(in pid: pid_t) throws -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused = elementAttribute(kAXFocusedUIElementAttribute, of: app)
        if focused == nil,
           let window = elementAttribute(kAXFocusedWindowAttribute, of: app) {
            focused = elementAttribute(kAXFocusedUIElementAttribute, of: window)
        }
        if focused == nil {
            focused = elementAttribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide())
        }
        guard var leaf = focused, belongs(leaf, to: pid) else { return nil }
        // Follow explicit focus links only; never pick the first text box found
        // elsewhere in the window.
        for _ in 0..<4 {
            if isSecure(leaf) { throw InsertionError.secureField }
            guard let next = elementAttribute(kAXFocusedUIElementAttribute, of: leaf),
                  belongs(next, to: pid), !CFEqual(next, leaf) else { break }
            leaf = next
        }
        if isSecure(leaf) { throw InsertionError.secureField }
        // Rich web editors may focus an inline child. Chromium exposes its
        // actual editor through these attributes only for editable descendants.
        for name in ["AXEditableAncestor", "AXHighestEditableAncestor"] {
            if let editor = elementAttribute(name, of: leaf), belongs(editor, to: pid) {
                if isSecure(editor) { throw InsertionError.secureField }
                if isEditable(editor) { return editor }
            }
        }
        if isEditable(leaf) { return leaf }
        return nil
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, of: element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, of: element) ?? ""
        guard role != "AXSecureTextField", subrole != kAXSecureTextFieldSubrole,
              boolAttribute("AXProtected", of: element) != true,
              boolAttribute(kAXEnabledAttribute, of: element) != false,
              boolAttribute("AXReadOnly", of: element) != true,
              boolAttribute("AXEditable", of: element) != false
        else { return false }

        if boolAttribute("AXEditable", of: element) == true { return true }
        var valueIsSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueIsSettable)
        // Native read-only text views have the same role as editors. Respect
        // an explicit negative answer; an unsupported query is not a refusal.
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
            return settableStatus == .success ? valueIsSettable.boolValue : settableStatus == .attributeUnsupported
        }
        // Some web contenteditable controls expose a generic role. An editable
        // value together with a text selection is stronger evidence than a
        // selection alone, which is also available on ordinary web pages.
        return settableStatus == .success
            && valueIsSettable.boolValue && selection(of: element) != nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < inspectionDeadline else {
            inspectionFailed = true; return nil
        }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
        guard error == .success else {
            if error != .attributeUnsupported && error != .noValue && error != .notImplemented {
                inspectionFailed = true
            }
            return nil
        }
        return result
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        attribute(name, of: element) as? Bool
    }

    private static func selection(of element: AXUIElement) -> CFRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private typealias ClipboardSnapshot = [[(NSPasteboard.PasteboardType, Data)]]

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
        case pasteNotAccepted
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
            case .pasteNotAccepted: return "The text box did not accept the paste. Use Copy last result."
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
