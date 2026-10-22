import Foundation

/// Geometry belongs to the edited range, which can precede the typing caret.
enum TextGeometry {
    static func leadingCharacter(in text: String, range: NSRange) -> NSRange? {
        guard let selected = Range(range, in: text), !selected.isEmpty else { return nil }
        guard let index = text[selected].firstIndex(where: { !$0.isWhitespace }) else { return nil }
        return NSRange(index..<text.index(after: index), in: text)
    }

    /// A leaf must occur exactly once, byte-for-byte in UTF-16, in the focused input.
    /// Repeated snippets cannot establish which rendered occurrence was edited.
    static func mappedLeaf(_ leaf: String, in text: String, covering range: NSRange) -> NSRange? {
        guard !leaf.isEmpty, Range(range, in: text) != nil else { return nil }
        let input = text as NSString
        let match = input.range(of: leaf, options: .literal)
        guard match.location != NSNotFound, Range(match, in: text) != nil,
              range.location >= match.location,
              NSMaxRange(range) <= NSMaxRange(match) else { return nil }
        let remaining = NSRange(location: match.location + 1, length: input.length - match.location - 1)
        guard input.range(of: leaf, options: .literal, range: remaining).location == NSNotFound else { return nil }
        return match
    }

    /// A single-line leaf frame supplies its first glyph's origin, never an interior word.
    static func leafFrameAnchor(_ rect: CGRect, leaf: String, mapped: NSRange,
                                leading: NSRange, fieldFrame: CGRect) -> CGRect? {
        guard leading.location == mapped.location, !leaf.contains(where: { $0.isNewline }),
              usable(rect, characterCount: leaf.count, fieldFrame: fieldFrame) else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
    }

    static func usable(_ rect: CGRect, characterCount: Int, fieldFrame: CGRect?) -> Bool {
        rejection(rect, characterCount: characterCount, fieldFrame: fieldFrame) == nil
    }

    static func rejection(_ rect: CGRect, characterCount: Int, fieldFrame: CGRect?) -> String? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return "nonfinite" }
        // A zero-width insertion rectangle still gives an exact text anchor.
        guard rect.width >= 0, rect.height > 0 else { return "emptyHeight" }
        guard rect.height <= 120 else { return "tooTall" }
        guard rect.width <= rect.height * CGFloat(max(characterCount, 1)) * 4 else { return "tooWide" }
        if let fieldFrame, !fieldFrame.isEmpty {
            // Some editors return their entire input frame for every range.
            guard fieldFrame.intersects(rect) || fieldFrame.contains(rect.origin) else { return "outsideField" }
            guard rect != fieldFrame else { return "wholeField" }
        }
        return nil
    }
}
