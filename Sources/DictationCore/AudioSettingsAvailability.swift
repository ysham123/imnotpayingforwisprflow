import Foundation

/// Choosing or testing an input does not depend on speech-model readiness.
/// It must remain exclusive with dictation, recovery, and other input capture.
public enum AudioSettingsAvailability {
    public static func canChange(phase: DictationSessionState.Phase,
                                 choosingShortcut: Bool = false, editingWords: Bool = false,
                                 copying: Bool = false, terminating: Bool = false) -> Bool {
        (phase == .idle || phase == .loading) && !choosingShortcut && !editingWords && !copying && !terminating
    }
}
