import AppKit
import Carbon
import DictationCore

@main struct ShortcutSmoke {
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: message, code: 1) }
            count += 1
        }
        let cmd = ShortcutConfiguration.command, ctrl = ShortcutConfiguration.control
        let opt = ShortcutConfiguration.option, shift = ShortcutConfiguration.shift
        func binding(_ code: UInt32 = 40, _ modifiers: UInt32 = ShortcutConfiguration.control,
                     _ name: String = "K") -> ShortcutConfiguration {
            .custom(keyCode: code, modifiers: modifiers, displayName: name)
        }
        try check(ShortcutConfiguration.fn.validationError == nil, "Default Fn is valid")
        try check(binding().displayName == "⌃K", "Modifiers appear in label")
        try check(binding(40, cmd | ctrl | opt | shift).displayName == "⌃⌥⇧⌘K", "Modifier ordering")
        try check(binding(0, 0, "A").validationError != nil, "Bare letter rejected")
        try check(binding(0, shift, "A").validationError != nil, "Shift letter rejected")
        try check(binding(0, opt, "A").validationError == nil, "Intentional Option letter accepted")
        for code in ShortcutConfiguration.functionKeyCodes {
            try check(binding(code, 0, "F").validationError == nil, "Bare function key accepted")
            try check(binding(code, shift, "F").validationError == nil, "Shift function key accepted")
        }
        for code: UInt32 in [53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 179, 255] {
            try check(binding(code).validationError != nil, "Modifier/Escape/invalid key rejected")
        }
        for code: UInt32 in [0, 4, 6, 7, 8, 9, 12, 13, 46, 48, 49, 50] {
            try check(binding(code, cmd).validationError != nil, "Standard Command shortcut reserved")
            try check(binding(code, cmd | shift).validationError != nil, "Shift variant reserved")
        }
        try check(binding(49, cmd | opt).validationError != nil, "Spotlight alternate reserved")
        try check(binding(12, cmd | ctrl).validationError != nil, "Lock shortcut reserved")
        try check(binding(40, 1).validationError != nil, "Unknown modifier bits rejected")
        try check(binding(40, ctrl, "\n").validationError != nil, "Control label rejected")
        try check(binding().hasSameBinding(as: binding(40, ctrl, "Other")), "Labels do not alter identity")
        let suite = "LocalDictation.ShortcutSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(HotkeyPreferences.load(from: defaults) == .fn, "Absent setting defaults to Fn")
        try check(HotkeyPreferences.save(binding(), to: defaults), "Valid setting saved")
        try check(HotkeyPreferences.load(from: defaults) == binding(), "Setting survives reload")
        try check(!HotkeyPreferences.save(binding(0, 0), to: defaults), "Invalid save refused")
        try check(HotkeyPreferences.load(from: defaults) == binding(), "Failed save preserves setting")
        defaults.set(Data("{}".utf8), forKey: HotkeyPreferences.storageKey)
        try check(HotkeyPreferences.load(from: defaults) == .fn, "Malformed setting falls back to Fn")
        defaults.set(try JSONEncoder().encode(binding(0, 0)), forKey: HotkeyPreferences.storageKey)
        try check(HotkeyPreferences.load(from: defaults) == .fn, "Invalid decoded setting falls back to Fn")

        var gesture = CustomHotkeyGesture()
        gesture.press(at: 1)
        for t in [1.1, 1.2, 1.3] { gesture.press(at: t) }
        try check(gesture.release(at: 2) == .start, "Held chord starts exactly once on release")
        try check(gesture.release(at: 2.01) == nil, "Duplicate release ignored")
        gesture.press(at: 2.1)
        try check(gesture.release(at: 2.2) == nil, "Accidental rapid second press cannot stop")
        gesture.press(at: 3)
        try check(gesture.release(at: 3.1) == .stop, "Next deliberate press stops")
        gesture.press(at: 3.2)
        gesture.setPhase(.idle, at: 4)
        gesture.press(at: 5)
        try check(gesture.release(at: 6) == nil, "Held processing press cannot restart after phase change")
        gesture.press(at: 7)
        try check(gesture.release(at: 7.1) == .start, "Fresh post-processing press can start")
        gesture.setPhase(.pending, at: 8)
        gesture.press(at: 9)
        try check(gesture.release(at: 9.1) == .placePending, "Pending press places instead of replacing")
        gesture.press(at: 10)
        try check(gesture.release(at: 10.1) == nil, "Processing ignores shortcut")
        gesture.setPhase(.idle, at: 11)
        gesture.press(at: 12)
        gesture.invalidate()
        gesture.press(at: 13)
        try check(gesture.release(at: 14) == nil, "Interruption cannot be rearmed by held repeats")
        gesture.suppressUntilRelease()
        gesture.press(at: 15)
        try check(gesture.release(at: 16) == nil, "Recorder held key and late Carbon press suppressed")
        gesture.press(at: 17)
        try check(gesture.release(at: 17.1) == .start, "Fresh chord after recorder release accepted")

        var input = CustomHotkeyInputFilter(keyCode: 40, modifiers: ctrl | opt)
        try check(!input.interrupts(.flagsChanged, keyCode: 59, modifiers: ctrl, isPhysical: true), "Own Control edge preserves target")
        try check(!input.interrupts(.flagsChanged, keyCode: 58, modifiers: ctrl | opt, isPhysical: true), "Own Option edge preserves target")
        try check(!input.interrupts(.keyDown, keyCode: 40, modifiers: ctrl | opt, isPhysical: true), "Own chord preserves target")
        try check(!input.interrupts(.flagsChanged, keyCode: 59, modifiers: opt, isPhysical: true), "Modifier release before key preserves target")
        try check(input.interrupts(.keyDown, keyCode: 40, modifiers: opt, isPhysical: true), "Repeat without required modifiers may type and must invalidate")
        try check(!input.interrupts(.flagsChanged, keyCode: 59, modifiers: ctrl | opt, isPhysical: true), "Modifier repress preserves target")
        try check(!input.interrupts(.keyUp, keyCode: 40, modifiers: 0, isPhysical: true), "Own key release preserves target")
        try check(input.interrupts(.keyDown, keyCode: 40, modifiers: 0, isPhysical: true), "Same bare letter still invalidates target")
        try check(input.interrupts(.keyDown, keyCode: 0, modifiers: ctrl | opt, isPhysical: true), "Other shortcut invalidates target")
        try check(input.interrupts(.flagsChanged, keyCode: 55, modifiers: cmd, isPhysical: true), "Unassigned modifier invalidates target")
        try check(input.interrupts(.pointer, keyCode: 0, modifiers: 0, isPhysical: true), "Mouse/scroll invalidates target")
        try check(!input.interrupts(.keyDown, keyCode: 9, modifiers: cmd, isPhysical: false), "Synthetic paste preserves target")
        try check(!input.interrupts(.flagsChanged, keyCode: 55, modifiers: cmd, isPhysical: false), "Synthetic modifier preserves target")
        try check(!input.interrupts(.pointer, keyCode: 0, modifiers: 0, isPhysical: false), "Synthetic pointer ignored")
        try check(input.interrupts(.flagsChanged, keyCode: 63, modifiers: 0, isPhysical: true), "Fn does not act as custom chord")
        var functionInput = CustomHotkeyInputFilter(keyCode: 100, modifiers: 0)
        try check(!functionInput.interrupts(.flagsChanged, keyCode: 63, modifiers: 0, isPhysical: true), "Fn hardware modifier can expose F8")
        try check(!functionInput.interrupts(.keyDown, keyCode: 100, modifiers: 0, isPhysical: true), "Physical F8 remains shortcut")
        print("Passed \(count) shortcut validation, persistence, gesture, and target-input checks")

        if CommandLine.arguments.contains("--registration") {
            _ = NSApplication.shared
            let hotkey = FnHotkey()
            defer { hotkey.stop() }
            let original = binding(90, cmd | ctrl | opt, "F20")
            try hotkey.configure(original).get()
            try hotkey.configure(original).get()
            var competitor: EventHotKeyRef?
            let conflictStatus = RegisterEventHotKey(90, cmd | ctrl | opt,
                EventHotKeyID(signature: 0x54455354, id: 1), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &competitor)
            if let competitor { UnregisterEventHotKey(competitor) }
            try check(conflictStatus == eventHotKeyExistsErr, "Registered shortcut is exclusive")
            var blocker: EventHotKeyRef?
            let blockedStatus = RegisterEventHotKey(80, cmd | ctrl | opt,
                EventHotKeyID(signature: 0x54455354, id: 2), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &blocker)
            guard blockedStatus == noErr, let blocker else { throw NSError(domain: "Could not establish conflict fixture", code: Int(blockedStatus)) }
            defer { UnregisterEventHotKey(blocker) }
            if case .success = hotkey.configure(binding(80, cmd | ctrl | opt, "F19")) {
                throw NSError(domain: "Conflicting replacement was accepted", code: 1)
            }
            try check(hotkey.configuration == original, "Registration conflict preserves prior choice")
            try check(hotkey.lastRegistrationError != nil, "Registration conflict is exposed")
            var preserved: EventHotKeyRef?
            let preservedStatus = RegisterEventHotKey(90, cmd | ctrl | opt,
                EventHotKeyID(signature: 0x54455354, id: 4), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &preserved)
            if let preserved { UnregisterEventHotKey(preserved) }
            try check(preservedStatus == eventHotKeyExistsErr, "Conflict preserves actual previous registration")
            hotkey.stop()
            var whileStopped: EventHotKeyRef?
            let stoppedStatus = RegisterEventHotKey(90, cmd | ctrl | opt,
                EventHotKeyID(signature: 0x54455354, id: 5), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &whileStopped)
            if let whileStopped { UnregisterEventHotKey(whileStopped) }
            try check(stoppedStatus == noErr, "Stop releases shortcut for recorder")
            try hotkey.configure(original).get()
            try hotkey.configure(binding(90, cmd | ctrl | opt, "Renamed F20")).get()
            try check(hotkey.configuration.displayName.hasSuffix("Renamed F20"), "Relabeling does not self-conflict")
            try hotkey.configure(.fn).get()
            var reclaimed: EventHotKeyRef?
            let reclaimedStatus = RegisterEventHotKey(90, cmd | ctrl | opt,
                EventHotKeyID(signature: 0x54455354, id: 3), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &reclaimed)
            if let reclaimed { UnregisterEventHotKey(reclaimed) }
            try check(reclaimedStatus == noErr, "Reset to Fn releases old chord")
            print("Passed native Carbon exclusive-registration, conflict, unchanged-binding, and reset checks")
        }
    }
}
