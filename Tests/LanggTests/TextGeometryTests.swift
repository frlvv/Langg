import Foundation
import Testing
@testable import Langg

@Test func correctionAnchorUsesEditedWordEvenWhenCaretHasMovedOn() {
    #expect(TextGeometry.leadingCharacter(in: "ghbdtn next words", range: NSRange(location: 0, length: 6)) == NSRange(location: 0, length: 1))
    #expect(TextGeometry.leadingCharacter(in: "hello 🙂word", range: NSRange(location: 6, length: 6)) == NSRange(location: 6, length: 2))
}

@Test func anchorSkipsLeadingLineBreaksAndKeepsComposedCharacters() {
    let text = "\n e\u{301}cho"
    #expect(TextGeometry.leadingCharacter(in: text, range: NSRange(location: 0, length: text.utf16.count)) == NSRange(location: 2, length: 2))
    #expect(TextGeometry.leadingCharacter(in: "word", range: NSRange(location: 4, length: 0)) == nil)
    #expect(TextGeometry.leadingCharacter(in: "word", range: NSRange(location: 20, length: 1)) == nil)
}

@Test func anchorRejectsInputFrameAndUnavailableGeometry() {
    let input = CGRect(x: 300, y: 400, width: 600, height: 200)
    #expect(!TextGeometry.usable(input, characterCount: 1, fieldFrame: input))
    #expect(!TextGeometry.usable(.zero, characterCount: 1, fieldFrame: input))
    #expect(!TextGeometry.usable(CGRect(x: 0, y: 0, width: 8, height: 18), characterCount: 1, fieldFrame: input))
    #expect(TextGeometry.usable(CGRect(x: 325, y: 430, width: 8, height: 18), characterCount: 1, fieldFrame: input))
    #expect(TextGeometry.usable(CGRect(x: 325, y: 430, width: 0, height: 18), characterCount: 1, fieldFrame: input))
}

@MainActor @Test func toastAppearsAboveEditedWordInsteadOfAFullPanelWidthToTheLeft() throws {
    let word = CGRect(x: 600, y: 300, width: 8, height: 18)
    let size = CGSize(width: 150, height: 30)
    let frame = try #require(CaretToast.frame(near: word, in: CGRect(x: 0, y: 0, width: 1440, height: 900), size: size))
    #expect(frame.minX + 12 == word.minX)
    #expect(frame.minY == word.maxY + 4)
    #expect(!frame.intersects(word))
}

@MainActor @Test func toastStaysOnSecondaryScreenAndFallsBelowTextAtTopEdge() throws {
    let screen = CGRect(x: -1920, y: 400, width: 1920, height: 1080)
    let word = CGRect(x: -1910, y: 1440, width: 8, height: 18)
    let frame = try #require(CaretToast.frame(near: word, in: screen, size: CGSize(width: 150, height: 30)))
    #expect(screen.contains(frame))
    #expect(frame.maxY == word.minY - 4)
    #expect(!frame.intersects(word))
}


@Test func descendantGeometryMapsExactUTF16Offsets() {
    let text = "🙂first\nновое слово"
    let edited = NSRange(location: 8, length: 5)
    #expect(TextGeometry.mappedLeaf("новое слово", in: text, covering: edited) == NSRange(location: 8, length: 11))
    #expect(TextGeometry.mappedLeaf("новое", in: text, covering: edited) == edited)
    #expect(TextGeometry.mappedLeaf("first", in: text, covering: edited) == nil)
}

@Test func descendantGeometryRejectsAmbiguousAndNonliteralText() {
    #expect(TextGeometry.mappedLeaf("word", in: "word word", covering: NSRange(location: 5, length: 4)) == nil)
    #expect(TextGeometry.mappedLeaf("aaa", in: "aaaa", covering: NSRange(location: 0, length: 3)) == nil)
    #expect(TextGeometry.mappedLeaf("é", in: "e\u{301}", covering: NSRange(location: 0, length: 2)) == nil)
    #expect(TextGeometry.mappedLeaf("", in: "word", covering: NSRange(location: 0, length: 4)) == nil)
    #expect(TextGeometry.mappedLeaf("word", in: "word", covering: NSRange(location: 0, length: 5)) == nil)
}


@Test func descendantLeafFrameAnchorsOnlyItsLeadingWord() throws {
    let input = CGRect(x: 100, y: 100, width: 600, height: 200)
    let leafFrame = CGRect(x: 120, y: 120, width: 150, height: 18)
    let leaf = "hello world "
    let mapped = try #require(TextGeometry.mappedLeaf(leaf, in: leaf, covering: NSRange(location: 0, length: 5)))
    #expect(TextGeometry.leafFrameAnchor(leafFrame, leaf: leaf, mapped: mapped,
        leading: NSRange(location: 0, length: 1), fieldFrame: input) == CGRect(x: 120, y: 120, width: 0, height: 18))
    #expect(TextGeometry.leafFrameAnchor(leafFrame, leaf: leaf, mapped: mapped,
        leading: NSRange(location: 6, length: 1), fieldFrame: input) == nil)
    #expect(TextGeometry.leafFrameAnchor(input, leaf: leaf, mapped: mapped,
        leading: NSRange(location: 0, length: 1), fieldFrame: input) == nil)
    #expect(TextGeometry.leafFrameAnchor(leafFrame, leaf: "hello\nworld", mapped: mapped,
        leading: NSRange(location: 0, length: 1), fieldFrame: input) == nil)
}
