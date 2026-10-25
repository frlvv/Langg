import AppKit
import Carbon
import LanggCore

struct CorrectionWriteResult {
    let snapshot: TextSnapshot
    let preEditBounds: CGRect?
}

/// The engine's only contact with the editor, dictionary and input source.
/// Production writes keep TextAccess's verified selection transaction intact.
@MainActor protocol CorrectionBackend: AnyObject {
    var frontmostPID: pid_t? { get }
    var bundleIdentifier: String? { get }
    var currentSourceID: String? { get }
    var secureInputEnabled: Bool { get }
    func capture(recoveringFocus: Bool, excluding: TextFieldIdentity?) -> TextSnapshot?
    func isWarmingUp(pid: pid_t) -> Bool
    func shouldCorrect(_ candidate: CorrectionCandidate, in text: String) async -> Bool
    func isKnown(_ word: String, language: String) async -> Bool?
    func replace(_ snapshot: TextSnapshot, edit: TextReplacement, captureBounds: Bool) async -> CorrectionWriteResult?
    func bounds(_ snapshot: TextSnapshot, range: NSRange) -> CGRect?
    func selectLanguage(_ language: String) -> Bool
    func selectIdentifier(_ id: String) -> Bool
    func retranslate(_ event: CGEvent, language: String) -> CGEvent?
    func retranslate(_ event: CGEvent, sourceIdentifier: String) -> CGEvent?
}

@MainActor final class NativeCorrectionBackend: CorrectionBackend {
    private let spelling = SpellingService()
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var bundleIdentifier: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var currentSourceID: String? { InputSources.currentIdentifier() }
    var secureInputEnabled: Bool { IsSecureEventInputEnabled() }

    func capture(recoveringFocus: Bool, excluding: TextFieldIdentity?) -> TextSnapshot? {
        TextAccess.capture(recoveringFocus: recoveringFocus, excluding: excluding)
    }
    func isWarmingUp(pid: pid_t) -> Bool { TextAccess.isTextAccessibilityWarmingUp(forPID: pid) }
    func shouldCorrect(_ candidate: CorrectionCandidate, in text: String) async -> Bool {
        await spelling.shouldCorrect(candidate, in: text)
    }
    func isKnown(_ word: String, language: String) async -> Bool? {
        await spelling.isKnown(word, language: language)
    }
    func replace(_ snapshot: TextSnapshot, edit: TextReplacement, captureBounds: Bool) async -> CorrectionWriteResult? {
        var selectedBounds: CGRect?
        let capture: ((CGRect) -> Void)? = captureBounds ? { selectedBounds = $0 } : nil
        guard let after = await TextAccess.replace(snapshot, edit: edit, selectedBounds: capture) else { return nil }
        return CorrectionWriteResult(snapshot: after, preEditBounds: selectedBounds)
    }
    func bounds(_ snapshot: TextSnapshot, range: NSRange) -> CGRect? { TextAccess.textBounds(snapshot, range: range) }
    func selectLanguage(_ language: String) -> Bool { InputSources.requestSelection(language) }
    func selectIdentifier(_ id: String) -> Bool { InputSources.requestSelection(identifier: id) }
    func retranslate(_ event: CGEvent, language: String) -> CGEvent? { InputSources.retranslated(event, language: language) }
    func retranslate(_ event: CGEvent, sourceIdentifier: String) -> CGEvent? {
        InputSources.retranslated(event, sourceIdentifier: sourceIdentifier)
    }
}
