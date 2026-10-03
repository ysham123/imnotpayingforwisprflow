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
        let focusedLeaf: AXUIElement?
        let role: String
        let selection: CFRange?
        let selectionMarker: CFTypeRef?
        let selectedText: String?
        let value: String?
        let rangeText: String?
        let webEditor: Bool
        var canInsertAutomatically: Bool { focusedElement != nil }
    }

    private struct Editor {
        let element: AXUIElement
        let focusedLeaf: AXUIElement
        let webEditor: Bool
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

    func captureTarget(expectedProcessIdentifier: pid_t? = nil) throws -> Target {
        // The optional PID bounds integration tests to their own fixture, even
        // if another application becomes frontmost between caller and capture.
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              expectedProcessIdentifier == nil || app.processIdentifier == expectedProcessIdentifier
        else { throw InsertionError.chooseTextField }
        Self.inspectionDeadline = ProcessInfo.processInfo.systemUptime + 1.2
        Self.inspectionFailed = false
        defer { Self.inspectionDeadline = .infinity }
        guard Self.accessibilityGranted() else { throw InsertionError.accessibilityRequired }
        let freshlyEnabled = Self.prepareAccessibility(in: app)
        var editor = try Self.focusedEditor(in: app.processIdentifier)
        let enhanced = editor == nil && !Self.inspectionFailed && Self.prepareEnhancedAccessibility(in: app)
        if enhanced {
            editor = try Self.focusedEditor(in: app.processIdentifier)
        }
        if editor == nil, !Self.inspectionFailed, freshlyEnabled || enhanced,
           Self.isChromiumRuntime(app),
           ProcessInfo.processInfo.systemUptime + 0.12 < Self.inspectionDeadline {
            // Chromium publishes its newly enabled tree asynchronously. This
            // one cold-start settle stays inside the synchronous AX budget;
            // warm captures and native applications take no added delay.
            Thread.sleep(forTimeInterval: 0.1)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            else { throw InsertionError.chooseTextField }
            editor = try Self.focusedEditor(in: app.processIdentifier)
        }
        // An opaque control must not prevent speech capture. Preserve the result
        // for Copy rather than guessing which control should receive a paste.
        guard let editor, !Self.inspectionFailed else {
            return Target(processIdentifier: app.processIdentifier, focusedElement: nil, focusedLeaf: nil,
                          role: "unverified", selection: nil, selectionMarker: nil, selectedText: nil, value: nil,
                          rangeText: nil, webEditor: false)
        }
        let element = editor.element
        let selection = Self.selection(of: element)
        let marker = selection == nil ? Self.attribute("AXSelectedTextMarkerRange", of: element) : nil
        let result = Target(
            processIdentifier: app.processIdentifier,
            focusedElement: element,
            focusedLeaf: editor.focusedLeaf,
            role: Self.stringAttribute(kAXRoleAttribute, of: element) ?? "editable",
            selection: selection,
            selectionMarker: marker,
            selectedText: Self.stringAttribute(kAXSelectedTextAttribute, of: element),
            value: Self.stringAttribute(kAXValueAttribute, of: element),
            rangeText: editor.webEditor ? Self.fullRangeText(of: element) : nil,
            webEditor: editor.webEditor
        )
        // Without a range or stable marker, cursor movement cannot be guarded.
        let stableMarker = marker.map { expected in
            Self.attribute("AXSelectedTextMarkerRange", of: element).map { CFEqual(expected, $0) } ?? false
        } ?? false
        guard !Self.inspectionFailed, selection != nil || stableMarker else {
            return Target(processIdentifier: app.processIdentifier, focusedElement: nil, focusedLeaf: nil,
                          role: "unverified", selection: nil, selectionMarker: nil, selectedText: nil, value: nil,
                          rangeText: nil, webEditor: false)
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

        // AX updates and rich-editor render cycles are asynchronous. Observe a
        // bounded window without sending another paste. An unchanged AXValue
        // can be a stale wrapper, so it cannot establish that paste failed.
        let result = await observeInsertion(text: text, into: target)
        Self.restoreIfOwned(previous, pasteboard: pasteboard,
                            changeCount: ourChangeCount, token: token)
        return result
    }

    func copyForRecovery(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
    }

    private static func wait(milliseconds: Int) async {
        // A canceled parent task must not shorten the receiver's opportunity to
        // read the staged text. A dispatch deadline is independent of Task's
        // cancellation state and does not block the main thread.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    private func observeInsertion(text: String, into target: Target) async -> InsertionResult {
        let start = ProcessInfo.processInfo.systemUptime
        let minimumReadWindow = start + 1
        let deadline = start + 2.5
        var verified = false
        repeat {
            // Observe only the captured control. After dispatch, switching apps
            // does not invalidate a paste that already reached its destination.
            // Do not discover or read a new app's focused control here.
            if !verified {
                Self.inspectionDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.6)
                Self.inspectionFailed = false
                if let element = target.focusedElement {
                    let currentValue = Self.stringAttribute(kAXValueAttribute, of: element)
                    let currentRangeText = target.rangeText != nil ? Self.fullRangeText(of: element) : nil
                    let caret = Self.selection(of: element)
                    if !Self.inspectionFailed {
                        verified = Self.matchesInsertion(original: target.rangeText, current: currentRangeText,
                                                         selection: target.selection, caret: caret, text: text)
                            || Self.matchesInsertion(original: target.value, current: currentValue,
                                                     selection: target.selection, caret: caret, text: text)
                    }
                }
                Self.inspectionDeadline = .infinity
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= minimumReadWindow && (verified || now >= deadline) { break }
            // Cancellation after dispatch cannot skip key/clipboard cleanup.
            await Self.wait(milliseconds: 80)
        } while true
        return verified ? .verified : .sentWithoutVerification
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

    private static func fullRangeText(of element: AXUIElement) -> String? {
        // A rich editor may expose text through its range API while AXValue is
        // empty. Limit the read to this editor and bound large-document costs.
        guard let count = attribute(kAXNumberOfCharactersAttribute, of: element, failureIsFatal: false) as? NSNumber,
              count.intValue >= 0, count.intValue <= 200_000 else { return nil }
        var range = CFRange(location: 0, length: count.intValue)
        guard let parameter = AXValueCreate(.cfRange, &range),
              ProcessInfo.processInfo.systemUptime < inspectionDeadline else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                                parameter, &value)
        // This supplementary API is optional; unsupported/slow range text must
        // not disqualify an otherwise valid editor or erase a verified value.
        return result == .success ? value as? String : nil
    }

    @discardableResult
    private static func prepareAccessibility(in running: NSRunningApplication) -> Bool {
        let pid = running.processIdentifier
        if let previous = preparedApplications[pid], !previous.isTerminated { return false }
        if let next = retryAfter[pid], ProcessInfo.processInfo.systemUptime < next { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        // Reading AXRole enables basic native accessibility in Chromium shells.
        // Electron and Chromium use different opt-ins. These setters may have
        // an effect even when isAttributeSettable reports unsupported.
        var role: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if [read, manual].contains(.cannotComplete) {
            retryAfter[pid] = ProcessInfo.processInfo.systemUptime + 3
            return false
        }
        retryAfter.removeValue(forKey: pid)
        preparedApplications[pid] = running
        preparedApplications = preparedApplications.filter { !$0.value.isTerminated }
        return true
    }

    private static var enhancedApplications: [pid_t: NSRunningApplication] = [:]

    private static func prepareEnhancedAccessibility(in running: NSRunningApplication) -> Bool {
        // The enhanced interface also changes screen-reader behavior. Use it
        // only after normal focus discovery failed in a known Chromium shell,
        // never as a blanket setter on every foreground application.
        let pid = running.processIdentifier
        guard enhancedApplications[pid]?.isTerminated != false, isChromiumRuntime(running)
        else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success
        else { return false }
        enhancedApplications[pid] = running
        enhancedApplications = enhancedApplications.filter { !$0.value.isTerminated }
        return true
    }

    private static func isChromiumRuntime(_ running: NSRunningApplication) -> Bool {
        guard let bundle = running.bundleURL else { return false }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let names = ["Electron Framework.framework", "Google Chrome Framework.framework",
                     "Chromium Framework.framework", "Chromium Embedded Framework.framework"]
        return names.contains { FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path) }
    }

    private func validate(_ target: Target) throws {
        Self.inspectionDeadline = ProcessInfo.processInfo.systemUptime + 1.2
        Self.inspectionFailed = false
        defer { Self.inspectionDeadline = .infinity }
        guard Self.accessibilityGranted() else { throw InsertionError.accessibilityRequired }
        guard let expectedElement = target.focusedElement else { throw InsertionError.unverifiedTarget }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let editor = try Self.focusedEditor(in: target.processIdentifier),
              CFEqual(editor.element, expectedElement),
              target.focusedLeaf.map({ CFEqual(editor.focusedLeaf, $0) }) == true
        else { throw InsertionError.targetChanged }
        let current = editor.element
        if let expected = target.selectedText,
           Self.stringAttribute(kAXSelectedTextAttribute, of: current) != expected {
            throw InsertionError.targetChanged
        }
        if let expected = target.value,
           Self.stringAttribute(kAXValueAttribute, of: current) != expected {
            throw InsertionError.targetChanged
        }
        if let expected = target.rangeText, Self.fullRangeText(of: current) != expected {
            throw InsertionError.targetChanged
        }
        guard !Self.inspectionFailed else { throw InsertionError.unverifiedTarget }
        // Check the cursor after content reads as well: an AXValue getter may
        // return unchanged text even if the user moved within this same field.
        if let expected = target.selection {
            guard let actual = Self.selection(of: current),
                  actual.location == expected.location, actual.length == expected.length
            else { throw InsertionError.targetChanged }
        }
        if let expected = target.selectionMarker {
            guard let actual = Self.attribute("AXSelectedTextMarkerRange", of: current), CFEqual(expected, actual)
            else { throw InsertionError.targetChanged }
        }
        // Field reads can cross process boundaries and take time. Recheck focus
        // after those reads so a change during inspection cannot redirect the
        // global paste shortcut. This reads identity only, not another field's
        // text, and uses the same bounded inspection budget.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let leaf = Self.currentFocusedLeaf(in: target.processIdentifier),
              target.focusedLeaf.map({ CFEqual(leaf, $0) }) == true,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        else { throw InsertionError.targetChanged }
        guard !Self.inspectionFailed else { throw InsertionError.unverifiedTarget }
    }

    private static func currentFocusedLeaf(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused = elementAttribute(kAXFocusedUIElementAttribute, of: app)
        if focused == nil, let window = elementAttribute(kAXFocusedWindowAttribute, of: app) {
            focused = elementAttribute(kAXFocusedUIElementAttribute, of: window)
        }
        if focused == nil {
            focused = elementAttribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide())
        }
        // The caller requires this exact leaf to equal the already verified
        // target; a system-wide fallback cannot substitute a new destination.
        guard var leaf = focused else { return nil }
        for _ in 0..<4 {
            guard let next = elementAttribute(kAXFocusedUIElementAttribute, of: leaf),
                  !CFEqual(next, leaf) else { break }
            leaf = next
        }
        return leaf
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

    private static func focusedEditor(in pid: pid_t) throws -> Editor? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused = elementAttribute(kAXFocusedUIElementAttribute, of: app)
        if focused == nil,
           let window = elementAttribute(kAXFocusedWindowAttribute, of: app) {
            focused = elementAttribute(kAXFocusedUIElementAttribute, of: window)
        }
        if focused == nil {
            // A system-wide fallback has not been rooted in this application's
            // tree. Require its PID or its containing window to match the app.
            if let candidate = elementAttribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()),
               belongs(candidate, to: pid) || sameWindow(candidate, app: app) {
                focused = candidate
            }
        }
        // App/window focus links can legitimately return a remote WebContent
        // element. Ownership is the rooted focus chain, not every child's PID.
        guard var leaf = focused else { return nil }
        // Follow explicit focus links only; never pick the first text box found
        // elsewhere in the window.
        for _ in 0..<4 {
            if isSecure(leaf) { throw InsertionError.secureField }
            guard let next = elementAttribute(kAXFocusedUIElementAttribute, of: leaf),
                  !CFEqual(next, leaf) else { break }
            leaf = next
        }
        if isSecure(leaf) { throw InsertionError.secureField }
        if let role = stringAttribute(kAXRoleAttribute, of: leaf),
           [kAXButtonRole, "AXLink", kAXPopUpButtonRole, kAXMenuItemRole,
            kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole, kAXTabGroupRole].contains(role) {
            return nil
        }
        // Walk only the focused node's bounded ancestry. Never search sibling
        // controls or a whole window for something that happens to be editable.
        var ancestry = [leaf]
        var node = leaf
        var webEditor = false
        for _ in 0..<12 {
            let role = stringAttribute(kAXRoleAttribute, of: node)
            if role == "AXWebArea" { webEditor = true; break }
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            guard let parent = elementAttribute(kAXParentAttribute, of: node),
                  !ancestry.contains(where: { CFEqual($0, parent) }) else { break }
            if isSecure(parent) { throw InsertionError.secureField }
            ancestry.append(parent)
            node = parent
        }
        // Chromium exposes these links specifically for editable descendants.
        for name in ["AXEditableAncestor", "AXHighestEditableAncestor"] {
            if let editor = elementAttribute(name, of: leaf) {
                if isSecure(editor) { throw InsertionError.secureField }
                if isEditable(editor, webEditor: true, explicitEditableAncestor: true) {
                    return Editor(element: editor, focusedLeaf: leaf, webEditor: true)
                }
            }
        }
        for candidate in ancestry {
            let role = stringAttribute(kAXRoleAttribute, of: candidate)
            if role == "AXWebArea" || role == kAXWindowRole || role == kAXApplicationRole { break }
            if isEditable(candidate, webEditor: webEditor) {
                return Editor(element: candidate, focusedLeaf: leaf, webEditor: webEditor)
            }
        }
        return nil
    }

    private static func sameWindow(_ element: AXUIElement, app: AXUIElement) -> Bool {
        guard let expected = elementAttribute(kAXFocusedWindowAttribute, of: app) else { return false }
        if let actual = elementAttribute(kAXWindowAttribute, of: element) { return CFEqual(expected, actual) }
        // Remote WebKit nodes may omit AXWindow. Prove containment by identity
        // in the captured application's focused window. This finds the already
        // focused node (or one of its parents), never a substitute text field.
        var lineage = [element]
        var parent = element
        for _ in 0..<12 {
            guard let next = elementAttribute(kAXParentAttribute, of: parent),
                  !lineage.contains(where: { CFEqual($0, next) }) else { break }
            if CFEqual(next, expected) { return true }
            let role = stringAttribute(kAXRoleAttribute, of: next)
            if role == kAXWindowRole || role == kAXApplicationRole { return false }
            lineage.append(next); parent = next
        }
        var pending: [(AXUIElement, Int)] = [(expected, 0)]
        var visited: [AXUIElement] = []
        while !pending.isEmpty, visited.count < 64,
              ProcessInfo.processInfo.systemUptime < inspectionDeadline {
            let (node, depth) = pending.removeFirst()
            if lineage.contains(where: { CFEqual($0, node) }) { return true }
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            guard depth < 6,
                  let children = attribute(kAXChildrenAttribute, of: node) as? [AXUIElement] else { continue }
            pending.append(contentsOf: children.prefix(64 - visited.count).map { ($0, depth + 1) })
        }
        return false
    }

    private static func isEditable(_ element: AXUIElement, webEditor: Bool,
                                   explicitEditableAncestor: Bool = false) -> Bool {
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
        var rangeIsSettable = DarwinBoolean(false)
        let rangeStatus = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeIsSettable)
        // Chromium's generic contenteditable groups can support ordinary
        // editing without direct AXValue writes. A group editor relationship
        // plus writable range is a narrow fallback. Text-field roles retain a
        // negative value-write answer: both engines permit selection changes
        // in read-only fields, so a range/editor link alone is insufficient.
        if webEditor {
            if settableStatus == .success && valueIsSettable.boolValue {
                return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
                    || hasTextCursor(element)
            }
            let genericRichEditor = role == kAXGroupRole && explicitEditableAncestor
            return rangeStatus == .success && rangeIsSettable.boolValue
                && genericRichEditor
                && hasTextCursor(element)
        }
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

    private static func hasTextCursor(_ element: AXUIElement) -> Bool {
        selection(of: element) != nil || attribute("AXSelectedTextMarkerRange", of: element) != nil
    }

    private static func attribute(_ name: String, of element: AXUIElement, failureIsFatal: Bool = true) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < inspectionDeadline else {
            if failureIsFatal { inspectionFailed = true }; return nil
        }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
        guard error == .success else {
            if failureIsFatal && error != .attributeUnsupported && error != .noValue && error != .notImplemented {
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
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0,
              range.location != NSNotFound, range.length != NSNotFound else { return nil }
        return range
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
