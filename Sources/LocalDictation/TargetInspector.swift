import AppKit
import ApplicationServices
import Foundation

/// Full AX inspection has one owner and request-local timeouts. It never binds
/// a newly focused control to a recording after that recording's anchor exists.
final class TargetInspector: @unchecked Sendable {
    private let queue: DispatchQueue
    private var preparedApplications: [pid_t: NSRunningApplication] = [:]
    private var enhancedApplications: [pid_t: NSRunningApplication] = [:]
    private var retryAfter: [pid_t: TimeInterval] = [:]

    init(queue: DispatchQueue = DispatchQueue(label: "localdictation.target-inspector", qos: .userInitiated)) {
        self.queue = queue
    }

    struct Observation: @unchecked Sendable {
        let value: String?
        let rangeText: String?
        let caret: CFRange?
        let failed: Bool
    }

    func prime(_ application: NSRunningApplication) {
        queue.async { [self] in _ = prepareAccessibility(in: application) }
    }

    func captureSynchronously(_ application: NSRunningApplication) throws -> TextInserter.Target {
        try queue.sync {
            let context = AXInspection(budget: 1.2)
            let freshlyEnabled = prepareAccessibility(in: application)
            var editor = try context.focusedEditor(in: application.processIdentifier)
            let enhanced = editor == nil && !context.inspectionFailed && prepareEnhancedAccessibility(in: application)
            if enhanced { editor = try context.focusedEditor(in: application.processIdentifier) }
            if editor == nil, !context.inspectionFailed, freshlyEnabled || enhanced,
               isChromiumRuntime(application), context.hasTime(0.12) {
                Thread.sleep(forTimeInterval: 0.1)
                editor = try context.focusedEditor(in: application.processIdentifier)
            }
            guard let editor, !context.inspectionFailed else {
                return context.unverifiedTarget(pid: application.processIdentifier)
            }
            return context.snapshot(editor, pid: application.processIdentifier)
        }
    }

    func inspect(_ anchor: TextInserter.Anchor) async throws -> TextInserter.Target {
        let cancellation = AXRequestCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let target: TextInserter.Target = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let context = AXInspection(budget: 1.2, cancellation: cancellation)
                        try context.verifyAnchor(anchor)
                        guard let editor = try context.focusedEditor(in: anchor.processIdentifier, pinnedLeaf: anchor.focusedLeaf),
                              !context.inspectionFailed else { throw TextInserter.InsertionError.unverifiedTarget }
                        let target = context.snapshot(editor, pid: anchor.processIdentifier)
                        try context.verifyAnchor(anchor)
                        try cancellation.check()
                        guard !context.inspectionFailed, target.canInsertAutomatically else {
                            throw TextInserter.InsertionError.unverifiedTarget
                        }
                        continuation.resume(returning: target)
                    } catch {
                        continuation.resume(throwing: cancellation.isCancelled ? CancellationError() : error)
                    }
                }
            }
            try Task.checkCancellation()
            return target
        }, onCancel: { cancellation.cancel() })
    }

    /// Cosmetic HUD positioning only. Resolve geometry from the original
    /// anchored element, never a newly focused window, without reading text or
    /// delaying microphone startup. Queue delay consumes the request budget.
    func originWindowFrame(_ anchor: TextInserter.Anchor) async -> CGRect? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        let cancellation = AXRequestCancellation()
        return await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                queue.async {
                    let context = AXInspection(deadline: deadline, timeout: 0.025)
                    guard !cancellation.isCancelled, context.hasTime(),
                          let window = context.elementAttribute(kAXWindowAttribute, of: anchor.focusedLeaf)
                            ?? context.elementAttribute(kAXWindowAttribute, of: anchor.cursorElement),
                          let positionValue = context.attribute(kAXPositionAttribute, of: window),
                          let sizeValue = context.attribute(kAXSizeAttribute, of: window),
                          CFGetTypeID(positionValue) == AXValueGetTypeID(),
                          CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
                        continuation.resume(returning: nil); return
                    }
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    let position = unsafeBitCast(positionValue, to: AXValue.self)
                    let dimensions = unsafeBitCast(sizeValue, to: AXValue.self)
                    guard AXValueGetType(position) == .cgPoint, AXValueGetType(dimensions) == .cgSize,
                          AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(dimensions, .cgSize, &size),
                          !context.inspectionFailed, context.hasTime(), !cancellation.isCancelled,
                          size.width > 0, size.height > 0,
                          [point.x, point.y, size.width, size.height].allSatisfy(\.isFinite) else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: CGRect(origin: point, size: size))
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    func validate(_ target: TextInserter.Target) async throws {
        let cancellation = AXRequestCancellation()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try cancellation.check()
                        let context = AXInspection(budget: 1.2, cancellation: cancellation)
                        try context.validate(target)
                        try cancellation.check()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: cancellation.isCancelled ? CancellationError() : error)
                    }
                }
            }
            try Task.checkCancellation()
        }, onCancel: { cancellation.cancel() })
    }

    func validateDestination(_ target: TextInserter.Target, cancellation: AXRequestCancellation) async throws {
        _ = try await destinationRequest(target, restore: false, cancellation: cancellation)
    }

    func restoreDestination(_ target: TextInserter.Target, cancellation: AXRequestCancellation) async throws -> TextInserter.Target {
        try await destinationRequest(target, restore: true, cancellation: cancellation)
    }

    private func destinationRequest(_ target: TextInserter.Target, restore: Bool,
                                    cancellation: AXRequestCancellation) async throws -> TextInserter.Target {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result: TextInserter.Target = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let context = AXInspection(budget: 1.2, cancellation: cancellation)
                        try context.validateDestination(target)
                        let result = restore ? try context.restoreDestination(target) : target
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: cancellation.isCancelled ? CancellationError() : error)
                    }
                }
            }
            try Task.checkCancellation()
            return result
        }, onCancel: { cancellation.cancel() })
    }

    func observe(_ target: TextInserter.Target, until deadline: TimeInterval) async -> Observation {
        await withCheckedContinuation { continuation in
            queue.async {
                let context = AXInspection(deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.6))
                guard let element = target.focusedElement else {
                    continuation.resume(returning: Observation(value: nil, rangeText: nil, caret: nil, failed: true))
                    return
                }
                let value = context.stringAttribute(kAXValueAttribute, of: element)
                let rangeText = target.rangeText != nil ? context.fullRangeText(of: element) : nil
                let caret = context.selection(of: element)
                continuation.resume(returning: Observation(value: value, rangeText: rangeText, caret: caret,
                                                            failed: context.inspectionFailed))
            }
        }
    }

    private func prepareAccessibility(in running: NSRunningApplication) -> Bool {
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

    private func prepareEnhancedAccessibility(in running: NSRunningApplication) -> Bool {
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

    private func isChromiumRuntime(_ running: NSRunningApplication) -> Bool {
        guard let bundle = running.bundleURL else { return false }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let names = ["Electron Framework.framework", "Google Chrome Framework.framework",
                     "Chromium Framework.framework", "Chromium Embedded Framework.framework"]
        return names.contains { FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path) }
    }
}

/// DispatchQueue work is outside the originating Swift task. This small flag
/// lets canceled queued work exit without making AX requests for an old session.
final class AXRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return canceled
    }
    func cancel() { lock.lock(); canceled = true; lock.unlock() }
    func check() throws { if isCancelled { throw CancellationError() } }
}

/// Every inspection owns its deadline and failure flag. Quick identity anchors
/// use a shorter per-message timeout and never read AXValue or selected text.
final class AXInspection {
    typealias InsertionError = TextInserter.InsertionError
    struct Editor {
        let element: AXUIElement
        let focusedLeaf: AXUIElement
        let webEditor: Bool
    }

    let inspectionDeadline: TimeInterval
    let timeout: Float
    private let cancellation: AXRequestCancellation?
    var inspectionFailed = false

    init(budget: TimeInterval, timeout: Float = 0.1, cancellation: AXRequestCancellation? = nil) {
        inspectionDeadline = ProcessInfo.processInfo.systemUptime + budget
        self.timeout = timeout
        self.cancellation = cancellation
    }
    init(deadline: TimeInterval, timeout: Float = 0.1) {
        inspectionDeadline = deadline
        self.timeout = timeout
        self.cancellation = nil
    }
    func hasTime(_ interval: TimeInterval = 0) -> Bool {
        cancellation?.isCancelled != true && ProcessInfo.processInfo.systemUptime + interval < inspectionDeadline
    }

    func unverifiedTarget(pid: pid_t) -> TextInserter.Target {
        TextInserter.Target(processIdentifier: pid, focusedElement: nil, focusedLeaf: nil, role: "unverified",
                            selection: nil, selectionMarker: nil, selectedText: nil, value: nil,
                            rangeText: nil, webEditor: false)
    }

    func snapshot(_ editor: Editor, pid: pid_t) -> TextInserter.Target {
        let element = editor.element
        let range = selection(of: element)
        let marker = range == nil ? attribute("AXSelectedTextMarkerRange", of: element) : nil
        var target = TextInserter.Target(processIdentifier: pid, focusedElement: element,
            focusedLeaf: editor.focusedLeaf, role: stringAttribute(kAXRoleAttribute, of: element) ?? "editable",
            selection: range, selectionMarker: marker,
            selectedText: stringAttribute(kAXSelectedTextAttribute, of: element),
            value: stringAttribute(kAXValueAttribute, of: element),
            rangeText: editor.webEditor ? fullRangeText(of: element) : nil, webEditor: editor.webEditor)
        target.originalWindow = elementAttribute(kAXWindowAttribute, of: element)
            ?? elementAttribute(kAXWindowAttribute, of: editor.focusedLeaf)
            ?? elementAttribute(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(pid))
        let stableMarker = marker.map { expected in
            attribute("AXSelectedTextMarkerRange", of: element).map { CFEqual(expected, $0) } ?? false
        } ?? false
        guard !inspectionFailed, range != nil || stableMarker else { return unverifiedTarget(pid: pid) }
        return target
    }

    func anchorLeaf(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var focused = elementAttribute(kAXFocusedUIElementAttribute, of: app)
        if focused == nil, let window = elementAttribute(kAXFocusedWindowAttribute, of: app) {
            focused = elementAttribute(kAXFocusedUIElementAttribute, of: window)
        }
        if focused == nil,
           let candidate = elementAttribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()),
           belongs(candidate, to: pid) || sameWindow(candidate, app: app) { focused = candidate }
        guard var leaf = focused else { return nil }
        for _ in 0..<4 {
            guard let next = elementAttribute(kAXFocusedUIElementAttribute, of: leaf), !CFEqual(next, leaf) else { break }
            leaf = next
        }
        return inspectionFailed ? nil : leaf
    }

    func verifyAnchor(_ anchor: TextInserter.Anchor) throws {
        guard let leaf = currentFocusedLeaf(in: anchor.processIdentifier), CFEqual(leaf, anchor.focusedLeaf)
        else { throw InsertionError.targetChanged }
        if let expected = anchor.selection {
            guard let actual = selection(of: anchor.cursorElement), actual.location == expected.location,
                  actual.length == expected.length else { throw InsertionError.targetChanged }
        }
        if let expected = anchor.selectionMarker {
            guard let actual = attribute("AXSelectedTextMarkerRange", of: anchor.cursorElement), CFEqual(expected, actual)
            else { throw InsertionError.targetChanged }
        }
        guard !inspectionFailed else { throw InsertionError.unverifiedTarget }
    }

    func validate(_ target: TextInserter.Target) throws {
        guard let expected = target.focusedElement,
              let editor = try focusedEditor(in: target.processIdentifier, pinnedLeaf: target.focusedLeaf),
              CFEqual(editor.element, expected),
              target.focusedLeaf.map({ CFEqual(editor.focusedLeaf, $0) }) == true
        else { throw InsertionError.targetChanged }
        if let expected = target.selectedText, stringAttribute(kAXSelectedTextAttribute, of: editor.element) != expected {
            throw InsertionError.targetChanged
        }
        if let expected = target.value, stringAttribute(kAXValueAttribute, of: editor.element) != expected {
            throw InsertionError.targetChanged
        }
        if let expected = target.rangeText, fullRangeText(of: editor.element) != expected { throw InsertionError.targetChanged }
        try confirmIdentity(target)
    }

    func confirmIdentity(_ target: TextInserter.Target) throws {
        guard let element = target.focusedElement else { throw InsertionError.unverifiedTarget }
        if let expected = target.selection {
            guard let actual = selection(of: element), actual.location == expected.location,
                  actual.length == expected.length else { throw InsertionError.targetChanged }
        }
        if let expected = target.selectionMarker {
            guard let actual = attribute("AXSelectedTextMarkerRange", of: element), CFEqual(expected, actual)
            else { throw InsertionError.targetChanged }
        }
        guard let leaf = currentFocusedLeaf(in: target.processIdentifier),
              target.focusedLeaf.map({ CFEqual(leaf, $0) }) == true else { throw InsertionError.targetChanged }
        guard !inspectionFailed else { throw InsertionError.unverifiedTarget }
    }

    /// Validate the saved control without relying on whichever field is now
    /// focused. Text must remain byte-for-byte unchanged before restoring a
    /// caret; selection alone is insufficient to prove an unchanged document.
    func validateDestination(_ target: TextInserter.Target) throws {
        guard target.preserveDestination, let element = target.focusedElement,
              let window = target.originalWindow,
              target.value != nil || target.rangeText != nil,
              stringAttribute(kAXRoleAttribute, of: window) == kAXWindowRole,
              belongs(window, to: target.processIdentifier),
              contained(element, in: window),
              stringAttribute(kAXRoleAttribute, of: element) == target.role,
              !isSecure(element),
              isEditable(element, webEditor: target.webEditor, explicitEditableAncestor: target.webEditor)
        else { throw InsertionError.targetChanged }
        if let expected = target.value, stringAttribute(kAXValueAttribute, of: element) != expected {
            throw InsertionError.targetChanged
        }
        if let expected = target.rangeText, fullRangeText(of: element) != expected {
            throw InsertionError.targetChanged
        }
        guard !inspectionFailed, hasTime() else { throw InsertionError.unverifiedTarget }
    }

    func restoreDestination(_ target: TextInserter.Target) throws -> TextInserter.Target {
        guard let element = target.focusedElement, let window = target.originalWindow else {
            throw InsertionError.unverifiedTarget
        }
        try requireTime()
        AXUIElementSetMessagingTimeout(window, timeout)
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw InsertionError.targetChanged
        }
        try requireTime()
        // Focus exactly the saved editable control, never its coordinates or
        // the first matching field. An unsupported AX setter leaves text held.
        if let current = try focusedEditor(in: target.processIdentifier), CFEqual(current.element, element) {
            // A caret move in the same editor only needs selection restoration.
        } else {
            try set(kAXFocusedAttribute, on: element, to: kCFBooleanTrue)
        }
        try validateDestination(target)
        if var range = target.selection, let value = AXValueCreate(.cfRange, &range) {
            try set(kAXSelectedTextRangeAttribute, on: element, to: value)
        } else if let marker = target.selectionMarker {
            try set("AXSelectedTextMarkerRange", on: element, to: marker)
        } else {
            throw InsertionError.unverifiedTarget
        }
        // Focusing an editable ancestor can change its focused descendant.
        // Refresh only that leaf after proving the editor itself is identical.
        guard let editor = try focusedEditor(in: target.processIdentifier), CFEqual(editor.element, element) else {
            throw InsertionError.targetChanged
        }
        var restored = target
        restored.focusedLeaf = editor.focusedLeaf
        try validate(restored)
        try requireTime()
        return restored
    }

    private func requireTime() throws {
        try cancellation?.check()
        guard hasTime(), !inspectionFailed else { throw InsertionError.unverifiedTarget }
    }

    private func set(_ name: String, on element: AXUIElement, to value: CFTypeRef) throws {
        try requireTime()
        AXUIElementSetMessagingTimeout(element, timeout)
        guard AXUIElementSetAttributeValue(element, name as CFString, value) == .success else {
            throw InsertionError.targetChanged
        }
        try requireTime()
    }

    func fullRangeText(of element: AXUIElement) -> String? {
        // A rich editor may expose text through its range API while AXValue is
        // empty. Limit the read to this editor and bound large-document costs.
        guard let count = attribute(kAXNumberOfCharactersAttribute, of: element, failureIsFatal: false) as? NSNumber,
              count.intValue >= 0, count.intValue <= 200_000 else { return nil }
        var range = CFRange(location: 0, length: count.intValue)
        guard let parameter = AXValueCreate(.cfRange, &range),
              hasTime() else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                                parameter, &value)
        // This supplementary API is optional; unsupported/slow range text must
        // not disqualify an otherwise valid editor or erase a verified value.
        return result == .success ? value as? String : nil
    }

    func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func belongs(_ element: AXUIElement, to pid: pid_t) -> Bool {
        var actual: pid_t = 0
        return AXUIElementGetPid(element, &actual) == .success && actual == pid
    }

    func isSecure(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXRoleAttribute, of: element) == "AXSecureTextField"
            || stringAttribute(kAXSubroleAttribute, of: element) == kAXSecureTextFieldSubrole
            || boolAttribute("AXProtected", of: element) == true
    }

    func focusedEditor(in pid: pid_t, pinnedLeaf: AXUIElement? = nil) throws -> Editor? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
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
        if let pinnedLeaf, !CFEqual(leaf, pinnedLeaf) { throw InsertionError.targetChanged }
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

    func currentFocusedLeaf(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
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

    func sameWindow(_ element: AXUIElement, app: AXUIElement) -> Bool {
        guard let expected = elementAttribute(kAXFocusedWindowAttribute, of: app) else { return false }
        return contained(element, in: expected)
    }

    func contained(_ element: AXUIElement, in expected: AXUIElement) -> Bool {
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
        while !pending.isEmpty, visited.count < 64, hasTime() {
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

    func isEditable(_ element: AXUIElement, webEditor: Bool,
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
        guard hasTime() else { inspectionFailed = true; return false }
        AXUIElementSetMessagingTimeout(element, timeout)
        var valueIsSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueIsSettable)
        guard hasTime() else { inspectionFailed = true; return false }
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

    func hasTextCursor(_ element: AXUIElement) -> Bool {
        selection(of: element) != nil || attribute("AXSelectedTextMarkerRange", of: element) != nil
    }

    func attribute(_ name: String, of element: AXUIElement, failureIsFatal: Bool = true) -> CFTypeRef? {
        guard cancellation?.isCancelled != true else { inspectionFailed = true; return nil }
        guard ProcessInfo.processInfo.systemUptime < inspectionDeadline else {
            if failureIsFatal { inspectionFailed = true }; return nil
        }
        AXUIElementSetMessagingTimeout(element, timeout)
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

    func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        attribute(name, of: element) as? Bool
    }

    func selection(of element: AXUIElement) -> CFRange? {
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
}
