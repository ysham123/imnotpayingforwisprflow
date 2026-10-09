import DictationCore
import Foundation

/// Headless: no window, microphone, real preference domain, or login registration.
@main struct SettingsSmoke {
    @MainActor static func main() throws {
        let name = "LocalDictation.SettingsSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        precondition(DictationPreferences.loadMode(from: defaults) == .clean)
        precondition(DictationPreferences.loadInputUID(from: defaults) == nil)
        DictationPreferences.saveMode(.verbatim, to: defaults)
        DictationPreferences.saveInputUID("device-stable-uid", to: defaults)
        let reloaded = UserDefaults(suiteName: name)!
        precondition(DictationPreferences.loadMode(from: reloaded) == .verbatim)
        precondition(DictationPreferences.loadInputUID(from: reloaded) == "device-stable-uid")
        defaults.set("unknown-future-mode", forKey: DictationPreferences.modeKey)
        precondition(DictationPreferences.loadMode(from: defaults) == .clean)
        DictationPreferences.saveInputUID(nil, to: defaults)
        precondition(defaults.object(forKey: DictationPreferences.inputUIDKey) == nil)
        defaults.set("", forKey: DictationPreferences.inputUIDKey)
        precondition(DictationPreferences.loadInputUID(from: defaults) == nil)

        var events: [SettingsController.Action] = []
        let actions = SettingsController.Actions(
            changeShortcut: { events.append(.changeShortcut) }, resetShortcut: { events.append(.resetShortcut) },
            customWords: { events.append(.customWords) }, setup: { events.append(.setup) },
            retryEngines: { events.append(.retryEngines) }, retryListener: { events.append(.retryListener) },
            exportMetrics: { events.append(.exportMetrics) }, exportPermissions: { events.append(.exportPermissions) })
        var state = SettingsController.State(actions: actions)
        precondition(!state.perform(.changeShortcut))
        precondition(!state.perform(.customWords))
        precondition(!state.perform(.retryEngines))
        precondition(state.perform(.setup))
        precondition(state.perform(.exportMetrics))
        precondition(events == [.setup, .exportMetrics])
        state.snapshot = .init(status: "Ready", shortcutDisplay: "Option-D", usesFn: false,
            canChangeControls: true, readiness: "Models and permissions ready", setupNeeded: false, vocabularyCount: 7)
        events.removeAll()
        for action in SettingsController.Action.allCases { precondition(state.perform(action)) }
        precondition(events == SettingsController.Action.allCases)
        precondition(state.snapshot.shortcutDisplay == "Option-D" && state.snapshot.vocabularyCount == 7)
        precondition(!state.snapshot.setupNeeded && state.snapshot.readiness == "Models and permissions ready")
        state.snapshot.usesFn = true
        precondition(!state.perform(.resetShortcut))
        state.snapshot.canChangeControls = false
        precondition(!state.perform(.changeShortcut) && !state.perform(.retryListener))

        var osStatus = LoginItemController.Status.disabled
        var registrations = 0, unregistrations = 0, settingsOpens = 0
        var failure = false, nextStatus = LoginItemController.Status.enabled
        let login = LoginItemController(environment: .init(status: { osStatus }, register: {
            registrations += 1
            if failure { throw NSError(domain: "Synthetic registration failure", code: 1) }
            osStatus = nextStatus
        }, unregister: {
            unregistrations += 1
            if failure { throw NSError(domain: "Synthetic unregistration failure", code: 2) }
            osStatus = .disabled
        }, openSettings: { settingsOpens += 1 }))
        login.refresh()
        precondition(login.status == .disabled && registrations == 0)
        failure = true; login.setEnabled(true)
        precondition(login.status == .disabled && login.lastError != nil)
        failure = false; nextStatus = .requiresApproval; login.setEnabled(true)
        precondition(login.status == .requiresApproval && login.lastError == nil)
        login.openSettings(); precondition(settingsOpens == 1)
        osStatus = .enabled; login.refresh()
        let beforeRefresh = registrations
        login.refresh(); login.setEnabled(true)
        precondition(login.status == .enabled && registrations == beforeRefresh)
        // External removal of consent is observed without silently re-registering.
        osStatus = .requiresApproval; login.refresh()
        precondition(login.status == .requiresApproval && registrations == beforeRefresh)
        failure = true; login.setEnabled(false)
        precondition(login.status == .requiresApproval && login.lastError != nil)
        failure = false; login.setEnabled(false)
        precondition(login.status == .disabled && unregistrations == 2)
        osStatus = .unavailable; login.refresh()
        precondition(login.status == .unavailable)
        print("Passed 3 Settings groups: isolated preferences, action/snapshot gating, live login-state semantics")
    }
}
