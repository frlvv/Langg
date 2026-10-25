import Foundation

// Successful replacements and explicit choices to keep the original word stay
// authoritative while their text remains intact, including after later typing.
public struct CorrectionHistory {
    private struct Entry {
        var range: NSRange
        let text: String
        let original: String?
    }

    private var text = ""
    private var entries: [Entry] = []
    private var nativeUndo: TextState?

    public init() {}

    public mutating func expectNativeUndo(in state: TextState) {
        reconcile(with: state.text)
        nativeUndo = state.selection.length == 0 ? state : nil
    }

    public mutating func reconcile(with updated: String) {
        guard updated != text else { return }
        if let before = nativeUndo {
            nativeUndo = nil
            for entry in entries {
                guard let original = entry.original,
                      let inverse = TextReplacement(before: before, range: entry.range, replacement: original),
                      let caretRange = LayoutConverter.validatedRange(inverse.after.selection, in: inverse.after.text) else { continue }
                let prefix = inverse.after.text[..<caretRange.lowerBound]
                let suffix = inverse.after.text[caretRange.upperBound...]
                // The first AX snapshot may include typing after native Undo.
                // Require an exact inverse plus an insertion at the known caret.
                if updated.utf16.count >= inverse.after.text.utf16.count,
                   updated.hasPrefix(prefix), updated.hasSuffix(suffix) {
                    reconcile(with: inverse.after.text)
                    reconcile(with: updated)
                    return
                }
            }
        }
        let old = Array(text.utf16)
        let new = Array(updated.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let oldEnd = old.count - suffix
        let delta = new.count - old.count
        entries = entries.compactMap { entry in
            var entry = entry
            if NSMaxRange(entry.range) <= prefix {
                // The changed region follows this word.
            } else if entry.range.location >= oldEnd {
                entry.range.location += delta
            } else if let original = entry.original,
                      let replacedRange = LayoutConverter.validatedRange(entry.range, in: text),
                      text.replacingCharacters(in: replacedRange, with: original).utf16.elementsEqual(updated.utf16) {
                // A native editor Undo can restore the original without going
                // through our Undo action. Accept only this exact inverse;
                // surrounding edits or other spellings are not user choices.
                let restoredRange = NSRange(location: entry.range.location, length: original.utf16.count)
                guard Self.isWholeWord(restoredRange, in: updated) else { return nil }
                return Entry(range: restoredRange, text: original, original: nil)
            } else { return nil }
            guard LayoutConverter.substring(updated, range: entry.range) == entry.text,
                  Self.isWholeWord(entry.range, in: updated) else { return nil }
            return entry
        }
        text = updated
    }

    public mutating func remember(_ edit: TextReplacement) {
        reconcile(with: edit.after.text)
        let range = NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
        remember(range, text: edit.replacement, original: edit.original)
    }

    public mutating func rememberUnchanged(_ range: NSRange, in updated: String) {
        reconcile(with: updated)
        guard let word = LayoutConverter.substring(updated, range: range), !word.isEmpty,
              Self.isWholeWord(range, in: updated) else { return }
        remember(range, text: word)
    }

    private mutating func remember(_ range: NSRange, text: String, original: String? = nil) {
        entries.removeAll { NSIntersectionRange($0.range, range).length > 0 }
        entries.append(Entry(range: range, text: text, original: original))
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
    }

    /// Fresh physical typing supersedes a prior correction or Undo choice only
    /// where its authenticated span overlaps that choice in the current text.
    public mutating func forget(overlapping range: NSRange) {
        guard range.length > 0, LayoutConverter.validatedRange(range, in: text) != nil else { return }
        entries.removeAll { NSIntersectionRange($0.range, range).length > 0 }
    }

    public func contains(_ range: NSRange) -> Bool {
        entries.contains { NSIntersectionRange($0.range, range).length > 0 }
    }

    private static func isWholeWord(_ range: NSRange, in text: String) -> Bool {
        guard let swiftRange = LayoutConverter.validatedRange(range, in: text) else { return false }
        if swiftRange.lowerBound > text.startIndex,
           text[text.index(before: swiftRange.lowerBound)].isLetter { return false }
        if swiftRange.upperBound < text.endIndex, text[swiftRange.upperBound].isLetter { return false }
        return true
    }
}
