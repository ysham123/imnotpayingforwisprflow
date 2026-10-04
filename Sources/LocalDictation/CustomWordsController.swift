import AppKit
import DictationCore

/// A small native editor for explicitly saved words. It never reads a transcript.
@MainActor
final class CustomWordsController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let snapshot: () -> VocabularySnapshot
    private let onSave: ([VocabularyEntry]) -> String?
    private let onEditingChanged: (Bool) -> Void
    private var window: NSWindow?
    private var table: NSTableView?
    private var entries: [VocabularyEntry] = []
    private var overflowIDs: Set<UUID> = []
    private var recognitionRevision: UInt64?
    private var editing = false
    private var editButton: NSButton?
    private var removeButton: NSButton?
    private var editor: (alert: NSAlert, preferred: NSTextField, aliases: NSTextField, feedback: NSTextField, id: UUID?)?
    private var activationObserver: NSObjectProtocol?

    init(snapshot: @escaping () -> VocabularySnapshot,
         onSave: @escaping ([VocabularyEntry]) -> String?,
         onEditingChanged: @escaping (Bool) -> Void) {
        self.snapshot = snapshot; self.onSave = onSave; self.onEditingChanged = onEditingChanged
        super.init()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func show() {
        let saved = snapshot()
        entries = saved.entries
        if recognitionRevision != saved.revision { recognitionRevision = nil; overflowIDs.removeAll() }
        if window == nil { buildWindow() }
        table?.reloadData(); updateButtons(); setEditing(true)
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        if let editor, let window { window.endSheet(editor.alert.window, returnCode: .cancel) }
        window?.orderOut(nil); setEditing(false)
    }

    func updateRecognitionStatus(overflowIDs: Set<UUID>) {
        self.overflowIDs = overflowIDs; recognitionRevision = snapshot().revision; table?.reloadData()
    }

    func windowWillClose(_ notification: Notification) { setEditing(false) }
    func windowDidResignKey(_ notification: Notification) {
        guard editor == nil, let window, window.attachedSheet == nil else { return }
        hide()
    }

    private func setEditing(_ value: Bool) {
        guard editing != value else { return }
        editing = value; onEditingChanged(value)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Custom words"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 540, height: 350); window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Use your intended spellings")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "Save names and terms you dictate. Add an alternate spelling only if it is repeatedly recognized that way. Changes apply to your next dictation.")
        detail.font = .systemFont(ofSize: 13)
        let table = NSTableView(); table.delegate = self; table.dataSource = self
        table.allowsMultipleSelection = false; table.rowHeight = 26
        for (id, title, width) in [("word", "Preferred spelling", 190.0), ("aliases", "Sometimes recognized as", 245.0), ("status", "Recognition", 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.setAccessibilityLabel("Saved custom words")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder; scroll.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: "Add…", target: self, action: #selector(addWord))
        let edit = NSButton(title: "Edit…", target: self, action: #selector(editWord))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeWord))
        for button in [add, edit, remove] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [add, edit, remove]); buttons.spacing = 8
        let footer = NSTextField(wrappingLabelWithString: "Saved only on this Mac. Close this window to resume dictation. Recognition status updates after you dictate. Hints have limited space; words marked Cleanup only can still help correct matching alternate spellings.")
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        for view in [title, detail, scroll, buttons, footer] { stack.addArrangedSubview(view) }
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        self.window = window; self.table = table; editButton = edit; removeButton = remove
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        switch tableColumn?.identifier.rawValue {
        case "word": return entry.preferredSpelling
        case "aliases": return entry.aliases.joined(separator: ", ")
        case "status": return recognitionRevision == nil ? "Next dictation" : overflowIDs.contains(entry.id) ? "Cleanup only" : "Recognition hint"
        default: return nil
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        let selected = entries.indices.contains(table?.selectedRow ?? -1)
        editButton?.isEnabled = selected; removeButton?.isEnabled = selected
    }
    @objc private func addWord() { beginEditor(nil) }
    @objc private func editWord() {
        guard let row = table?.selectedRow, entries.indices.contains(row) else { return }
        beginEditor(entries[row])
    }
    @objc private func removeWord() {
        guard let row = table?.selectedRow, entries.indices.contains(row) else { return }
        var updated = entries; updated.remove(at: row)
        if let error = onSave(updated) { showError(error); return }
        recognitionRevision = nil; overflowIDs.removeAll()
        entries = updated; table?.reloadData(); updateButtons()
    }
    private func beginEditor(_ entry: VocabularyEntry?) {
        guard editor == nil, let window else { return }
        let alert = NSAlert(); alert.messageText = entry == nil ? "Add a custom word" : "Edit custom word"
        alert.informativeText = "Use a preferred spelling such as Wispr Flow. Alternate spellings are optional; separate them with commas."
        let save = alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        save.target = self; save.action = #selector(saveEditor)
        let preferred = NSTextField(string: entry?.preferredSpelling ?? "")
        preferred.placeholderString = "Preferred spelling"; preferred.setAccessibilityLabel("Preferred spelling")
        let aliases = NSTextField(string: entry?.aliases.joined(separator: ", ") ?? "")
        aliases.placeholderString = "Sometimes recognized as (optional)"; aliases.setAccessibilityLabel("Alternate spellings")
        let feedback = NSTextField(wrappingLabelWithString: "")
        feedback.textColor = .systemOrange; feedback.font = .systemFont(ofSize: 12)
        let fields = NSStackView(views: [preferred, aliases, feedback]); fields.orientation = .vertical
        fields.alignment = .leading; fields.spacing = 10; fields.frame = NSRect(x: 0, y: 0, width: 440, height: 100)
        for field in [preferred, aliases] { field.widthAnchor.constraint(equalToConstant: 440).isActive = true }
        alert.accessoryView = fields
        editor = (alert, preferred, aliases, feedback, entry?.id)
        alert.beginSheetModal(for: window) { [weak self] _ in self?.editor = nil }
        alert.window.makeFirstResponder(preferred)
    }
    @objc private func saveEditor() {
        guard let editor, let window else { return }
        do {
            let entry = try VocabularyEntry.normalized(preferredSpelling: editor.preferred.stringValue,
                aliases: editor.aliases.stringValue.split(separator: ",", omittingEmptySubsequences: true).map(String.init),
                id: editor.id ?? UUID())
            var updated = entries
            if let row = updated.firstIndex(where: { $0.id == entry.id }) { updated[row] = entry } else { updated.append(entry) }
            _ = try VocabularySnapshot(entries: updated)
            if let error = onSave(updated) { throw VocabularyError.invalid(error) }
            recognitionRevision = nil; overflowIDs.removeAll()
            entries = updated; table?.reloadData(); updateButtons()
            window.endSheet(editor.alert.window, returnCode: .OK)
        } catch {
            editor.feedback.stringValue = error.localizedDescription
            NSAccessibility.post(element: editor.feedback, notification: .announcementRequested,
                                 userInfo: [.announcement: error.localizedDescription, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
    private func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Could not save custom words"; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}
