import AppKit
import AVFoundation

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
        let defaultsName = "LocalDictation.SettingsUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preview = FakeMicrophonePreview()
        var permission = AVAuthorizationStatus.authorized
        var permissionRequests = 0
        let devices = [AudioInputDevice(id: 1, uid: "built-in", name: "MacBook Microphone"),
                       AudioInputDevice(id: 2, uid: "usb-mic", name: "USB Microphone")]
        let controller = SettingsController(actions: .init(changeShortcut: noAction, resetShortcut: noAction,
            customWords: noAction, setup: noAction, retryEngines: noAction, retryListener: noAction,
            exportMetrics: noAction, exportPermissions: noAction,
            allowMicrophone: { permissionRequests += 1 }), loginEnvironment: .init(status: { .disabled },
                register: { fatalError("UI fixture must never register login items") },
                unregister: { fatalError("UI fixture must never unregister login items") }, openSettings: noAction),
            audioEnvironment: .init(authorizationStatus: { permission }, devices: { devices },
                resolve: { try AudioInputProvider.resolve(uid: $0, available: devices, defaultID: 1) }),
            preview: preview, preferences: defaults)
        controller.update(.init(status: "Ready", shortcutDisplay: "Fn / Globe", usesFn: true,
            canChangeControls: true, readiness: "Ready", setupNeeded: false, vocabularyCount: 3))
        guard let content = controller.window.contentView,
              let tabs = content.subviews.compactMap({ $0 as? NSTabView }).first else {
            fatalError("Settings sections missing")
        }
        precondition(tabs.tabViewItems.map(\.label) == ["Home", "Microphone", "General", "Shortcuts", "Custom Words", "Advanced"])
        precondition(controller.window.title == "Local Dictation")
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
                    if size == "normal" { controller.window.setContentSize(NSSize(width: 900, height: 620)) }
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
                // Actual NSControl target/action dispatch with a fake audio
                // boundary; no microphone, permissions, or public defaults.
                guard let microphoneTab = tabs.tabViewItems.first(where: { $0.label == "Microphone" }),
                      let microphoneView = microphoneTab.view else { fatalError("Microphone screen missing") }
                tabs.selectTabViewItem(microphoneTab)
                let controls = descendants(microphoneView)
                let picker = controls.first { $0.identifier?.rawValue == "audio-input" } as! NSPopUpButton
                let test = controls.first { $0.identifier?.rawValue == "test-microphone" } as! NSButton
                let allow = controls.first { $0.identifier?.rawValue == "allow-microphone" } as! NSButton
                var loading = SettingsController.Snapshot(status: "Loading local models", shortcutDisplay: "Control-Shift-Space",
                    usesFn: false, canChangeControls: false, readiness: "Loading", setupNeeded: true, vocabularyCount: 0,
                    canChangeAudioControls: true)
                controller.update(loading)
                precondition(picker.isEnabled && test.isEnabled)
                tabs.selectTabViewItem(at: 0)
                let homeMicrophone = descendants(tabs.tabViewItems[0].view!).first {
                    $0.identifier?.rawValue == "home-microphone"
                } as! NSButton
                homeMicrophone.performClick(nil)
                precondition(tabs.selectedTabViewItem === microphoneTab)
                test.performClick(nil)
                precondition(preview.isRecording && test.title == "Stop test")
                picker.selectItem(at: 2)
                picker.sendAction(picker.action!, to: picker.target)
                precondition(!preview.isRecording)
                precondition(DictationPreferences.loadInputUID(from: defaults) == "usb-mic",
                    "Switching microphones during a test must retain the newly clicked choice")
                test.performClick(nil)
                precondition(preview.lastInputUID == "usb-mic" && preview.isRecording)
                test.performClick(nil)
                precondition(!preview.isRecording && test.title == "Test microphone")
                permission = .denied
                controller.update(loading)
                precondition(!allow.isHidden && allow.title == "Open Microphone Settings")
                allow.performClick(nil)
                precondition(permissionRequests == 1)
                test.performClick(nil)
                precondition(permissionRequests == 2 && !preview.isRecording)
                permission = .authorized
                controller.update(loading)
                test.performClick(nil)
                let general = descendants(content).first { $0.identifier?.rawValue == "navigate-General" } as! NSButton
                general.performClick(nil)
                precondition(!preview.isRecording && tabs.selectedTabViewItem?.label == "General")
                homeMicrophone.performClick(nil)
                test.performClick(nil)
                loading.canChangeAudioControls = false
                controller.update(loading)
                precondition(!preview.isRecording && !picker.isEnabled && !test.isEnabled)
                print("Passed microphone button dispatch, loading availability, device change during preview, permission recovery, and busy-state exclusion")
            } catch { fputs("SETTINGS RENDER FAILED: \(error)\n", stderr); exit(1) }
        }
        controller.window.setFrame(NSRect(origin: controller.window.frame.origin, size: controller.window.minSize), display: false)
        content.layoutSubtreeIfNeeded()
        for item in tabs.tabViewItems {
            tabs.selectTabViewItem(item)
            content.layoutSubtreeIfNeeded()
            precondition(item.view is NSScrollView, "Each settings section must remain scrollable at small sizes")
        }
        controller.stopMicrophoneTest(); controller.hide()
        print("Passed isolated Settings window structure checks")
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor private final class FakeMicrophonePreview: MicrophonePreview {
    var isRecording = false
    var activeInputName: String? = "Fixture microphone"
    var inputNotice: String?
    var onAutomaticStop: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    var lastInputUID: String?
    func start(inputUID: String?) throws { lastInputUID = inputUID; isRecording = true; onLevel?(0.1) }
    func cancel() { isRecording = false }
}
