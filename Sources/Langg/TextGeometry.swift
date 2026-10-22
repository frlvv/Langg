import Foundation

/// Geometry belongs to the edited range, which can precede the typing caret.
enum TextGeometry {
    static func leadingCharacter(in text: String, range: NSRange) -> NSRange? {
        guard let selected = Range(range, in: text), !selected.isEmpty else { return nil }
        guard let index = text[selected].firstIndex(where: { !$0.isWhitespace }) else { return nil }
        return NSRange(index..<text.index(after: index), in: text)
    }

    static func usable(_ rect: CGRect, characterCount: Int, fieldFrame: CGRect?) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0, rect.height <= 120,
              rect.width <= rect.height * CGFloat(max(characterCount, 1)) * 4 else { return false }
        if let fieldFrame, !fieldFrame.isEmpty {
            // Some editors return their entire input frame for every range.
            guard fieldFrame.intersects(rect), rect != fieldFrame else { return false }
        }
        return true
    }
}
