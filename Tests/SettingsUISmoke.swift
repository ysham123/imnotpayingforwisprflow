import AppKit

/// Compile-only by default. This fixture never records audio or writes login state.
@main struct SettingsUISmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        let arguments = CommandLine.arguments
        let renderDirectory: URL?
        if arguments.count == 3 && arguments[1] == "--render-only" {
            renderDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
            NSApplication.shared.setActivationPolicy(.accessory)
        } else if arguments.count == 1 { renderDirectory = nil }
        else { fputs("Usage: SettingsUISmoke [--render-only output-directory]\n", stderr); exit(2) }
        let noAction = {}
        let controller = SettingsController(actions: .init(changeShortcut: noAction, resetShortcut: noAction,
            customWords: noAction, setup: noAction, retryEngines: noAction, retryListener: noAction,
            exportMetrics: noAction, exportPermissions: noAction), loginEnvironment: .init(status: { .disabled },
                register: { fatalError("UI fixture must never register login items") },
                unregister: { fatalError("UI fixture must never unregister login items") }, openSettings: noAction))
        controller.update(.init(status: "Ready", shortcutDisplay: "Fn / Globe", usesFn: true,
            canChangeControls: true, readiness: "Ready", setupNeeded: false, vocabularyCount: 3))
        guard let content = controller.window.contentView,
              let tabs = content.subviews.compactMap({ $0 as? NSTabView }).first else {
            fatalError("Settings sections missing")
        }
        precondition(tabs.tabViewItems.map(\.label) == ["General", "Audio", "Shortcuts", "Custom Words", "Advanced"])
        precondition(controller.window.styleMask.contains(.resizable))
        if let renderDirectory {
            do {
                try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
                controller.window.appearance = NSAppearance(named: .aqua)
                // The window normally supplies this opaque backdrop; view-only
                // snapshots need it explicitly to keep dark text legible.
                content.wantsLayer = true
                content.layer?.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1).cgColor
                // Refresh read-only device labels with the injected login boundary.
                controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
                let offscreen = NSPoint(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 1920) + 1000,
                                        y: (NSScreen.screens.map(\.frame.maxY).max() ?? 1080) + 1000)
                controller.window.setFrameOrigin(offscreen)
                controller.window.orderFrontRegardless()
                for size in ["normal", "minimum"] {
                    if size == "normal" { controller.window.setContentSize(NSSize(width: 740, height: 560)) }
                    else { controller.window.setFrame(NSRect(origin: controller.window.frame.origin,
                                                             size: controller.window.minSize), display: false) }
                    for item in tabs.tabViewItems {
                        tabs.selectTabViewItem(item)
                        content.layoutSubtreeIfNeeded()
                        controller.window.displayIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                        let filename = "settings-\(item.label.lowercased().replacingOccurrences(of: " ", with: "-"))-\(size).png"
                        guard let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                            throw NSError(domain: "Cannot create Settings preview bitmap", code: 1)
                        }
                        content.cacheDisplay(in: content.bounds, to: image)
                        guard let data = image.representation(using: .png, properties: [:]) else {
                            throw NSError(domain: "Cannot encode Settings preview PNG", code: 1)
                        }
                        let file = renderDirectory.appendingPathComponent(filename)
                        try data.write(to: file)
                        print("Settings preview: \(file.path)")
                    }
                }
            } catch { fputs("SETTINGS RENDER FAILED: \(error)\n", stderr); exit(1) }
        }
        controller.window.setContentSize(NSSize(width: 670, height: 440))
        content.layoutSubtreeIfNeeded()
        for item in tabs.tabViewItems {
            tabs.selectTabViewItem(item)
            content.layoutSubtreeIfNeeded()
            precondition(item.view is NSScrollView, "Each settings section must remain scrollable at small sizes")
        }
        controller.stopMicrophoneTest(); controller.hide()
        print("Passed isolated Settings window structure checks")
    }
}
