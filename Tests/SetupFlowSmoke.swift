import DictationCore
import Foundation

@main struct SetupFlowSmoke {
    static func main() {
        var readiness = SetupReadiness()
        var flow = SetupFlow()
        precondition(flow.advance(readiness) && flow.step == .microphone)
        precondition(!flow.advance(readiness), "A click must not grant microphone access")
        readiness.microphone = true
        precondition(flow.advance(readiness) && flow.step == .accessibility)
        readiness.accessibility = true
        precondition(flow.advance(readiness) && flow.step == .inputMonitoring)
        readiness.inputMonitoring = true
        precondition(flow.advance(readiness) && flow.step == .models)
        precondition(!flow.advance(readiness), "Model files must be verified and the engine loaded")
        readiness.modelsReady = true
        precondition(flow.advance(readiness) && flow.step == .shortcut)
        precondition(!flow.detectShortcut(readiness), "An inactive listener is not a working shortcut")
        readiness.listenerActive = true
        precondition(!flow.advance(readiness), "A saved key binding is not a detected key press")
        precondition(flow.detectShortcut(readiness) && flow.advance(readiness) && flow.step == .practice)
        let first = UUID(), retry = UUID()
        flow.beginPractice(first)
        precondition(!flow.finishPractice("wrong session", token: retry))
        precondition(!flow.advance(readiness))
        flow.cancelPractice()
        precondition(!flow.finishPractice("late result", token: first))
        flow.beginPractice(retry)
        precondition(!flow.finishPractice("   ", token: retry))
        flow.beginPractice(retry)
        precondition(flow.finishPractice("My first dictation works.", token: retry))
        readiness.shortcut = .custom(keyCode: 49, modifiers: ShortcutConfiguration.control | ShortcutConfiguration.shift, displayName: "Space")
        precondition(readiness.shortcut.validationError == nil)
        flow.reconcile(readiness)
        precondition(flow.step == .shortcut && !flow.practiceSucceeded)
        precondition(!flow.advance(readiness), "Changing the shortcut requires another actual key press")
        precondition(flow.detectShortcut(readiness) && flow.advance(readiness))
        flow.beginPractice(retry)
        precondition(flow.finishPractice("Works again.", token: retry))
        precondition(flow.advance(readiness) && flow.step == .complete)
        readiness.accessibility = false
        flow.reconcile(readiness)
        precondition(flow.step == .accessibility && !flow.practiceSucceeded)
        precondition(!flow.advance(readiness), "Revoked access must block completion")
        var estimate = SetupDownloadEstimate()
        estimate.sample(bytes: 100, now: 0)
        precondition(estimate.bytesPerSecond == nil)
        estimate.sample(bytes: 200, now: 1)
        precondition(estimate.remaining(total: 400, completed: 200) == 2)
        estimate.sample(bytes: 200, now: 2)
        precondition(estimate.remaining(total: 400, completed: 200) == nil)
        estimate.sample(bytes: 50, now: 3)
        precondition(estimate.bytesPerSecond == nil, "Resumed/reset progress must not show negative rates")
        print("Passed guided setup permission, model, shortcut, practice ownership, revocation, and download estimate checks")
    }
}
