import AppKit
import DictationCore

/// Injected actions never request permissions, record audio, or run models.
@main struct SetupUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let noAction = {}
        let controller = SetupController(actions: .init(startModels: noAction, toggleModels: noAction,
            allowPermission: { _ in }, chooseShortcut: noAction, useRecommendedShortcut: noAction,
            useFn: noAction, openKeyboard: noAction, retryListener: noAction, togglePractice: noAction,
            retryPractice: noAction, discardPractice: noAction, cancelPractice: noAction,
            closed: noAction, finished: noAction))
        guard let content = controller.window.contentView else { fatalError("Missing setup content") }
        var snapshot = SetupController.Snapshot()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func click(_ title: String) {
            guard let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title && !$0.isHidden }) else { fatalError("Missing button: \(title)") }
            precondition(button.isEnabled, "Disabled button: \(title)")
            button.performClick(nil)
        }
        let render = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--render-only"
        let output = render ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) : nil
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            NSApp.setActivationPolicy(.accessory)
            controller.window.appearance = NSAppearance(named: .aqua)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1).cgColor
            controller.window.setFrameOrigin(NSPoint(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 1920) + 1000, y: 2000))
            controller.window.orderFrontRegardless()
        }
        func capture(_ name: String) throws {
            guard let output else { return }
            for size in ["normal", "minimum"] {
                if size == "normal" { controller.window.setContentSize(NSSize(width: 660, height: 610)) }
                else { controller.window.setFrame(NSRect(origin: controller.window.frame.origin, size: controller.window.minSize), display: false) }
                content.layoutSubtreeIfNeeded(); controller.window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("Missing preview bitmap") }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Missing preview data") }
                try data.write(to: output.appendingPathComponent("setup-\(name)-\(size).png"))
            }
        }
        try capture("welcome"); click("Start setup")
        precondition(controller.flow.step == .microphone); try capture("microphone")
        click("Allow Microphone…"); snapshot.readiness.microphone = true; controller.update(snapshot)
        precondition(controller.flow.step == .accessibility); try capture("accessibility")
        click("Allow Accessibility…"); snapshot.readiness.accessibility = true; controller.update(snapshot)
        precondition(controller.flow.step == .inputMonitoring); try capture("input-monitoring")
        click("Allow Input Monitoring…"); snapshot.readiness.inputMonitoring = true; controller.update(snapshot)
        snapshot.modelsBusy = true; snapshot.modelFraction = 0.4
        snapshot.modelDetail = "Speech model · 1.4 GB of 3.4 GB · 40%\n12 MB/s · about 3 min remaining"
        controller.update(snapshot); precondition(controller.flow.step == .models); try capture("models")
        snapshot.readiness.modelsReady = true; snapshot.readiness.listenerActive = true
        snapshot.readiness.shortcut = .custom(keyCode: 49, modifiers: ShortcutConfiguration.control | ShortcutConfiguration.shift, displayName: "Space")
        controller.update(snapshot); precondition(controller.flow.step == .shortcut); try capture("shortcut")
        controller.detectedShortcut(); click("Continue")
        precondition(controller.flow.step == .practice); try capture("practice")
        let token = UUID(); controller.beginPractice(token)
        snapshot.recording = true; controller.update(snapshot); controller.updateRecording(elapsed: 3, level: 0.65)
        try capture("recording")
        snapshot.recording = false; snapshot.processing = true; controller.update(snapshot)
        try capture("processing")
        snapshot.processing = false; controller.update(snapshot)
        snapshot.retainedRecording = true; controller.update(snapshot)
        controller.practiceFailed("Recognition stopped. Retry the same recording.")
        try capture("retry")
        click("Retry the recording")
        let retry = UUID(); controller.beginPractice(retry)
        snapshot.retainedRecording = false; controller.update(snapshot)
        precondition(!controller.finishPractice("Stale result", token: token))
        precondition(controller.finishPractice("My first dictation is ready.", token: retry)); try capture("result")
        click("Finish setup"); precondition(controller.flow.step == .complete); try capture("complete")
        controller.window.orderOut(nil)
        print("Passed isolated guided setup UI actions and rendering structure checks")
    }
}
