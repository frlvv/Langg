import Foundation

// Successful replacements stay authoritative while their text remains intact.
// A later contextual pass must not reverse an earlier correction.
public struct CorrectionHistory {
    private struct Entry {
        var range: NSRange
        let text: String
    }

    private var text = ""
    private var entries: [Entry] = []

    public init() {}

    public mutating func reconcile(with updated: String) {
        guard updated != text else { return }
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
        entries.removeAll { NSIntersectionRange($0.range, range).length > 0 }
        entries.append(Entry(range: range, text: edit.replacement))
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
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
