import Foundation

/// Geometry belongs to the edited range, which can precede the typing caret.
enum TextGeometry {
    static func leadingCharacter(in text: String, range: NSRange) -> NSRange? {
        guard let selected = Range(range, in: text), !selected.isEmpty else { return nil }
        guard let index = text[selected].firstIndex(where: { !$0.isWhitespace }) else { return nil }
        return NSRange(index..<text.index(after: index), in: text)
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
